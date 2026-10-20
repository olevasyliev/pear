import AVFoundation

/// Records the default microphone. When the input device changes (AirPods connect or drop),
/// AVAudioEngine stops itself; this restarts it into a new segment file on the new device.
final class MicCapture {
    private let control = DispatchQueue(label: "pear.mic.control")
    private var makeSegment: (() -> URL)?
    private var engine: AVAudioEngine?
    private var file: AVAudioFile?
    private var observer: NSObjectProtocol?
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
        }
    }

    func stop() {
        control.sync {
            makeSegment = nil
            stopCapture()
        }
    }

    private func startCapture() throws {
        let engine = AVAudioEngine()
        let input = engine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else { throw RecorderError.noMicrophone }
        guard let url = makeSegment?() else { return }

        let file = try AVAudioFile(forWriting: url, settings: int16FileSettings(for: format),
                                   commonFormat: format.commonFormat, interleaved: format.isInterleaved)
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { buffer, _ in
            try? file.write(from: buffer)
        }
        observer = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: engine, queue: nil
        ) { [weak self] _ in
            self?.control.async { self?.scheduleRestart() }
        }
        self.engine = engine
        self.file = file
        try engine.start()
    }

    private func stopCapture() {
        if let observer {
            NotificationCenter.default.removeObserver(observer)
        }
        observer = nil
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        engine = nil
        file?.close()
        file = nil
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
            NSLog("Pear: microphone restart attempt \(attempt) failed: \(error)")
            guard attempt < 10 else { return }
            control.asyncAfter(deadline: .now() + 1) { [weak self] in
                guard let self, generation == self.restartGeneration, self.makeSegment != nil else { return }
                self.restart(attempt: attempt + 1, generation: generation)
            }
        }
    }
}
