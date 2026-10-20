import AVFoundation
import Foundation

enum RecorderError: LocalizedError {
    case coreAudio(String, OSStatus)
    case noMicrophone
    case unsupportedFormat

    var errorDescription: String? {
        switch self {
        case let .coreAudio(action, status): return "Could not \(action) (Core Audio error \(status))."
        case .noMicrophone: return "No microphone is available."
        case .unsupportedFormat: return "The system audio format is not supported."
        }
    }
}

/// 16-bit PCM keeps raw files at about 1 GB per hour for both tracks; CAF stays readable if the app dies mid-call.
func int16FileSettings(for format: AVAudioFormat) -> [String: Any] {
    [
        AVFormatIDKey: kAudioFormatLinearPCM,
        AVSampleRateKey: format.sampleRate,
        AVNumberOfChannelsKey: format.channelCount,
        AVLinearPCMBitDepthKey: 16,
        AVLinearPCMIsFloatKey: false,
        AVLinearPCMIsBigEndianKey: false,
        AVLinearPCMIsNonInterleaved: false,
    ]
}

/// One call on disk: per-track segment files plus meta.json, which transcribe.py turns into a transcript.
/// A track gets a new segment each time its audio device changes; meta.json records where each one starts.
final class RecordingSession {
    private struct Segment: Codable {
        let track: String
        let file: String
        let offset: Double
    }

    private struct Meta: Codable {
        let id: String
        let started_at: String
        var ended_at: String?
        var segments: [Segment]
        var warnings: [String]
    }

    let id: String
    let directory: URL
    let startedAt: Date
    private var meta: Meta
    private let lock = NSLock()
    private let mic = MicCapture()
    private let system = SystemAudioCapture()

    private static let idFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()

    private static let timestampFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    init(rawRoot: URL, callsDirectory: URL) throws {
        let now = Date()
        let base = Self.idFormatter.string(from: now)
        let fileManager = FileManager.default
        var id = base
        var suffix = 2
        while fileManager.fileExists(atPath: rawRoot.appendingPathComponent(id).path)
            || fileManager.fileExists(atPath: callsDirectory.appendingPathComponent("\(id).md").path) {
            id = "\(base)-\(suffix)"
            suffix += 1
        }
        self.id = id
        startedAt = now
        directory = rawRoot.appendingPathComponent(id)
        meta = Meta(id: id, started_at: Self.timestampFormatter.string(from: now), ended_at: nil, segments: [],
                    warnings: [])
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        save()
    }

    func start(microphoneAllowed: Bool) {
        do {
            try system.start { [unowned self] in nextSegment(track: "system") }
        } catch {
            warn("System audio was not recorded: \(error.localizedDescription)")
        }
        guard microphoneAllowed else {
            warn("Microphone access is off for Pear, so your side was not recorded.")
            return
        }
        do {
            try mic.start { [unowned self] in nextSegment(track: "mic") }
        } catch {
            warn("Microphone was not recorded: \(error.localizedDescription)")
        }
    }

    func stop() {
        mic.stop()
        system.stop()
        lock.lock()
        meta.ended_at = Self.timestampFormatter.string(from: Date())
        lock.unlock()
        save()
    }

    private func nextSegment(track: String) -> URL {
        lock.lock()
        let index = meta.segments.filter { $0.track == track }.count + 1
        let name = String(format: "%@-%02d.caf", track, index)
        meta.segments.append(Segment(track: track, file: name, offset: Date().timeIntervalSince(startedAt)))
        lock.unlock()
        save()
        return directory.appendingPathComponent(name)
    }

    private func warn(_ message: String) {
        NSLog("Pear: \(message)")
        lock.lock()
        meta.warnings.append(message)
        lock.unlock()
        save()
    }

    private func save() {
        lock.lock()
        defer { lock.unlock() }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(meta) else { return }
        try? data.write(to: directory.appendingPathComponent("meta.json"), options: .atomic)
    }
}
