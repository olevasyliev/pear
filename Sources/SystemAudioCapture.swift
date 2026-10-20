import AVFoundation
import AudioToolbox
import CoreAudio

private let unknownObject = AudioObjectID(kAudioObjectUnknown)

/// Captures everything the Mac plays (the other side of a call) through a Core Audio process tap.
/// When the default output device changes (AirPods connect or drop), it restarts into a new segment file.
final class SystemAudioCapture {
    private let control = DispatchQueue(label: "pear.system.control")
    private let io = DispatchQueue(label: "pear.system.io", qos: .userInteractive)
    private var makeSegment: (() -> URL)?
    private var tapID = unknownObject
    private var aggregateID = unknownObject
    private var procID: AudioDeviceIOProcID?
    private var file: AVAudioFile?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private var restartGeneration = 0

    func start(makeSegment: @escaping () -> URL) throws {
        try control.sync {
            self.makeSegment = makeSegment
            do {
                try startCapture()
            } catch {
                stopCapture()
                self.makeSegment = nil
                throw error
            }
            listenForOutputChanges()
        }
    }

    func stop() {
        control.sync {
            makeSegment = nil
            stopListening()
            stopCapture()
        }
    }

    private func startCapture() throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        description.name = "Pear"
        description.isPrivate = true
        description.muteBehavior = .unmuted

        var tap = unknownObject
        try check(AudioHardwareCreateProcessTap(description, &tap), "create the system audio tap")
        tapID = tap

        var streamDescription = AudioStreamBasicDescription()
        try readProperty(tap, kAudioTapPropertyFormat, into: &streamDescription, "read the tap format")
        guard let format = AVAudioFormat(streamDescription: &streamDescription) else {
            throw RecorderError.unsupportedFormat
        }

        let outputUID = try deviceUID(try defaultOutputDevice())
        let aggregateDescription: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Pear Tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: description.uuid.uuidString,
            ]],
        ]
        var aggregate = unknownObject
        try check(AudioHardwareCreateAggregateDevice(aggregateDescription as CFDictionary, &aggregate),
                  "create the capture device")
        aggregateID = aggregate

        guard let url = makeSegment?() else { return }
        let file = try AVAudioFile(forWriting: url, settings: int16FileSettings(for: format),
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        self.file = file

        var proc: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&proc, aggregate, io) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else {
                return
            }
            try? file.write(from: buffer)
        }, "attach to the capture device")
        procID = proc
        try check(AudioDeviceStart(aggregate, proc), "start the capture device")
    }

    private func stopCapture() {
        if aggregateID != unknownObject {
            if let procID {
                AudioDeviceStop(aggregateID, procID)
                AudioDeviceDestroyIOProcID(aggregateID, procID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != unknownObject {
            AudioHardwareDestroyProcessTap(tapID)
        }
        io.sync {}  // a buffer still being written finishes before the file closes
        file?.close()
        file = nil
        procID = nil
        aggregateID = unknownObject
        tapID = unknownObject
    }

    // MARK: Output device changes

    private func listenForOutputChanges() {
        var address = defaultOutputAddress
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.scheduleRestart() }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control, block)
        outputListener = block
    }

    private func stopListening() {
        guard let outputListener else { return }
        var address = defaultOutputAddress
        AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, control,
                                               outputListener)
        self.outputListener = nil
    }

    /// Runs on `control`. Device switches arrive in bursts, so wait for them to settle.
    private func scheduleRestart() {
        restartGeneration += 1
        let generation = restartGeneration
        control.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            guard let self, generation == self.restartGeneration, self.makeSegment != nil else { return }
            self.stopCapture()
            self.restart(attempt: 1, generation: generation)
        }
    }

    private func restart(attempt: Int, generation: Int) {
        do {
            try startCapture()
        } catch {
            stopCapture()
            NSLog("Pear: system audio restart attempt \(attempt) failed: \(error)")
            guard attempt < 10 else { return }
            control.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, generation == self.restartGeneration, self.makeSegment != nil else { return }
                self.restart(attempt: attempt + 1, generation: generation)
            }
        }
    }
}

private var defaultOutputAddress = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)

private func defaultOutputDevice() throws -> AudioObjectID {
    var device = unknownObject
    try readProperty(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice,
                     into: &device, "find the output device")
    return device
}

private func deviceUID(_ device: AudioObjectID) throws -> String {
    var uid: Unmanaged<CFString>?
    try readProperty(device, kAudioDevicePropertyDeviceUID, into: &uid, "read the output device ID")
    guard let uid else { throw RecorderError.coreAudio("read the output device ID", -1) }
    return uid.takeRetainedValue() as String
}

private func readProperty<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector, into value: inout T,
                             _ action: String) throws {
    var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
    var size = UInt32(MemoryLayout<T>.size)
    let status = withUnsafeMutablePointer(to: &value) { AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0) }
    try check(status, action)
}

private func check(_ status: OSStatus, _ action: String) throws {
    guard status == noErr else { throw RecorderError.coreAudio(action, status) }
}
