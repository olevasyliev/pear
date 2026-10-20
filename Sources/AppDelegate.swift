import AVFoundation
import AppKit
import Carbon.HIToolbox
import ServiceManagement
import UserNotifications

/// Menu bar app: Start / Stop recording (also ⌃⌥⌘R), then hands each finished call to transcribe.py,
/// one at a time, and posts a notification that opens the transcript.
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, UNUserNotificationCenterDelegate {
    /// Where transcripts and audio go: ~/Documents/Pear until "Choose Calls Folder…" sets another one.
    private var callsDirectory: URL {
        if let path = UserDefaults.standard.string(forKey: "CallsDirectory") {
            return URL(fileURLWithPath: path)
        }
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0].appendingPathComponent("Pear")
    }
    /// Recordings waiting for transcription. ".nosync" keeps iCloud from uploading raw audio when the folder syncs.
    private var rawRoot: URL { callsDirectory.appendingPathComponent(".raw.nosync") }
    /// Speech models, downloaded by install.sh.
    private let modelsDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Pear/models")
    private var statusItem: NSStatusItem!
    private var session: RecordingSession?
    private var clock: Timer?
    private var pending: [URL] = []
    private var transcriber: Process?
    private var lastTranscript: URL?
    private var hotKey: EventHotKeyRef?
    private var quitWhenIdle = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.autosaveName = "Pear"  // keeps the place you ⌘-drag the icon to
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateButton()
        registerHotKey()

        let notifications = UNUserNotificationCenter.current()
        notifications.delegate = self
        notifications.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        if !FileManager.default.fileExists(atPath: modelsDirectory.appendingPathComponent("ggml-large-v3-turbo.bin").path) {
            notify(title: "Pear has no speech model yet",
                   body: "Run ./install.sh in the Pear folder; it downloads the model.", open: nil)
        }

        // Calls left behind by a crash or a quit during transcription.
        let leftovers = (try? FileManager.default.contentsOfDirectory(at: rawRoot, includingPropertiesForKeys: nil))
            ?? []
        for directory in leftovers.sorted(by: { $0.path < $1.path })
        where FileManager.default.fileExists(atPath: directory.appendingPathComponent("meta.json").path) {
            enqueue(directory)
        }

        // Test hook: --record-seconds N records for N seconds, then quits once the transcript is written.
        let arguments = CommandLine.arguments
        if let flag = arguments.firstIndex(of: "--record-seconds"), flag + 1 < arguments.count,
           let seconds = Double(arguments[flag + 1]) {
            quitWhenIdle = true
            startRecording()
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in self?.stopRecording() }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        guard let session else { return }
        session.stop()
        self.session = nil
        enqueue(session.directory)
    }

    // MARK: Recording

    @objc private func toggleRecording() {
        session == nil ? startRecording() : stopRecording()
    }

    private func startRecording() {
        guard session == nil else { return }
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized:
            beginSession(microphoneAllowed: true)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                DispatchQueue.main.async { self.beginSession(microphoneAllowed: granted) }
            }
        default:
            beginSession(microphoneAllowed: false)
        }
    }

    private func beginSession(microphoneAllowed: Bool) {
        guard session == nil else { return }
        do {
            let session = try RecordingSession(rawRoot: rawRoot, callsDirectory: callsDirectory)
            session.start(microphoneAllowed: microphoneAllowed)
            self.session = session
        } catch {
            notify(title: "Recording did not start", body: error.localizedDescription, open: nil)
            return
        }
        clock = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.updateButton() }
        updateButton()
    }

    private func stopRecording() {
        guard let session else { return }
        clock?.invalidate()
        clock = nil
        session.stop()
        self.session = nil
        enqueue(session.directory)
        updateButton()
    }

    // MARK: Transcription

    private func enqueue(_ directory: URL) {
        guard !pending.contains(directory) else { return }
        pending.append(directory)
        runNextTranscription()
    }

    private func runNextTranscription() {
        guard transcriber == nil else { return }
        guard !pending.isEmpty else {
            updateButton()
            if quitWhenIdle && session == nil { NSApp.terminate(nil) }
            return
        }
        let directory = pending.removeFirst()
        guard let script = Bundle.main.url(forResource: "transcribe", withExtension: "py") else { return }

        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        process.arguments = [script.path, directory.path, "--out", callsDirectory.path,
                             "--models", modelsDirectory.path]
        process.environment = ["PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin", "HOME": NSHomeDirectory(),
                               "LANG": "en_US.UTF-8"]
        process.standardOutput = output
        process.standardError = output
        process.terminationHandler = { [weak self] finished in
            let text = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            DispatchQueue.main.async { self?.transcriptionFinished(finished, output: text, directory: directory) }
        }
        do {
            try process.run()
            transcriber = process
        } catch {
            notify(title: "Transcription did not start", body: error.localizedDescription, open: directory)
        }
        updateButton()
    }

    private func transcriptionFinished(_ process: Process, output: String, directory: URL) {
        transcriber = nil
        let lastLine = output.split(separator: "\n").last.map(String.init) ?? ""
        if process.terminationStatus == 0, lastLine.hasSuffix(".md") {
            let transcript = URL(fileURLWithPath: lastLine)
            lastTranscript = transcript
            notify(title: "Transcript ready", body: transcript.lastPathComponent, open: transcript)
        } else {
            notify(title: "Transcription failed",
                   body: "Audio is kept. Log: \(directory.lastPathComponent)/transcribe.log", open: directory)
        }
        runNextTranscription()
    }

    // MARK: Menu and status button

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let toggle = NSMenuItem(title: session == nil ? "Start Recording" : "Stop Recording",
                                action: #selector(toggleRecording), keyEquivalent: "r")
        toggle.keyEquivalentModifierMask = [.control, .option, .command]
        menu.addItem(toggle)

        if transcriber != nil {
            let queued = pending.isEmpty ? "" : " (+\(pending.count) waiting)"
            let status = NSMenuItem(title: "Transcribing…\(queued)", action: nil, keyEquivalent: "")
            status.isEnabled = false
            menu.addItem(status)
        }
        menu.addItem(.separator())
        let openLast = NSMenuItem(title: "Open Last Transcript", action: #selector(openLastTranscript),
                                  keyEquivalent: "")
        openLast.isEnabled = lastTranscript != nil
        menu.addItem(openLast)
        menu.addItem(NSMenuItem(title: "Open Calls Folder", action: #selector(openCallsFolder), keyEquivalent: ""))
        menu.addItem(NSMenuItem(title: "Choose Calls Folder…", action: #selector(chooseCallsFolder),
                                keyEquivalent: ""))
        menu.addItem(.separator())
        // Quit gets a system icon on macOS 26; icons on its neighbours keep the section aligned.
        let about = NSMenuItem(title: "About Pear", action: #selector(showAbout), keyEquivalent: "")
        about.image = NSImage(systemSymbolName: "info.circle", accessibilityDescription: nil)
        menu.addItem(about)
        let login = NSMenuItem(title: "Open at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.image = NSImage(systemSymbolName: "power", accessibilityDescription: nil)
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off
        menu.addItem(login)
        menu.addItem(NSMenuItem(title: "Quit Pear", action: #selector(NSApplication.terminate(_:)),
                                keyEquivalent: "q"))
        for item in menu.items where item.action != #selector(NSApplication.terminate(_:)) {
            item.target = self
        }
    }

    private func updateButton() {
        guard let button = statusItem?.button else { return }
        button.image = pearGlyph
        if let session {
            // pear ● 12:34, the dot and time in red while recording
            let elapsed = Int(Date().timeIntervalSince(session.startedAt))
            button.attributedTitle = NSAttributedString(
                string: String(format: " ● %d:%02d", elapsed / 60, elapsed % 60),
                attributes: [.foregroundColor: NSColor.systemRed,
                             .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)])
            button.setAccessibilityLabel("Pear, recording")
        } else if transcriber != nil {
            button.title = "…"
            button.setAccessibilityLabel("Pear, transcribing")
        } else {
            button.title = ""
            button.setAccessibilityLabel("Pear")
        }
        button.imagePosition = button.title.isEmpty ? .imageOnly : .imageLeading
    }

    @objc private func openLastTranscript() {
        if let lastTranscript { NSWorkspace.shared.open(lastTranscript) }
    }

    @objc private func openCallsFolder() {
        NSWorkspace.shared.open(callsDirectory)
    }

    @objc private func chooseCallsFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = callsDirectory
        panel.prompt = "Use This Folder"
        panel.message = "New transcripts and audio will go here."
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        UserDefaults.standard.set(url.path, forKey: "CallsDirectory")
        try? FileManager.default.createDirectory(at: rawRoot, withIntermediateDirectories: true)
    }

    @objc private func showAbout() {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let small = NSFont.systemFont(ofSize: NSFont.smallSystemFontSize)
        func text(_ string: String, _ color: NSColor, _ font: NSFont = small) -> NSAttributedString {
            NSAttributedString(string: string, attributes: [.font: font, .foregroundColor: color,
                                                            .paragraphStyle: centered])
        }
        let italic = NSFontManager.shared.convert(small, toHaveTrait: .italicFontMask)
        let calls = (callsDirectory.path as NSString).abbreviatingWithTildeInPath
        let credits = NSMutableAttributedString()
        credits.append(text("A pair of voices, one pear.\n\n", .secondaryLabelColor, italic))
        credits.append(text("Records your calls and puts the transcript next to the audio. "
                            + "Speech to text runs on this Mac; nothing leaves it.\n\n", .labelColor))
        credits.append(text("Start or stop: ⌃⌥⌘R\nCalls: \(calls)", .secondaryLabelColor))
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [
            .credits: credits,
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Oleksii Vasyliev",
        ])
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            notify(title: "Open at Login failed", body: error.localizedDescription, open: nil)
        }
    }

    // MARK: Global hotkey ⌃⌥⌘R

    private func registerHotKey() {
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, userData in
            guard let userData else { return noErr }
            let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
            DispatchQueue.main.async { delegate.toggleRecording() }
            return noErr
        }, 1, &eventType, Unmanaged.passUnretained(self).toOpaque(), nil)
        let id = EventHotKeyID(signature: OSType(0x5045_4152), id: 1)  // 'PEAR'
        RegisterEventHotKey(UInt32(kVK_ANSI_R), UInt32(controlKey | optionKey | cmdKey), id,
                            GetApplicationEventTarget(), 0, &hotKey)
    }

    // MARK: Notifications

    private func notify(title: String, body: String, open url: URL?) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let url { content.userInfo = ["open": url.path] }
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content,
                                                                     trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions)
                                    -> Void) {
        completionHandler([.banner, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let path = response.notification.request.content.userInfo["open"] as? String {
            NSWorkspace.shared.open(URL(fileURLWithPath: path))
        }
        completionHandler()
    }
}
