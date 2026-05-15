import AppKit
import Foundation

enum AppRecorderState: CustomStringConvertible {
    case idle
    case recording
    case transcribing
    case summarizing

    var description: String {
        switch self {
        case .idle: return "idle"
        case .recording: return "recording"
        case .transcribing: return "transcribing"
        case .summarizing: return "summarizing"
        }
    }
}

/// Menu bar app with manual start/stop, global hotkeys, in-app transcription and notifications.
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let audioRecorder = AudioRecorder()
    private let hotkeys = GlobalHotkeyManager()
    private let transcriptionManager = TranscriptionManager()
    private let notifications = NotificationService.shared
    private let settingsStore = SettingsStore.shared
    private let controlServer = LocalControlServer.shared

    private var statusItem: NSStatusItem?
    private var appState: AppRecorderState = .idle

    private var currentUploadID: String?
    private var currentTitle: String?
    private var recordingStartedAt: Date?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        Logger.shared.info("OwnRecorder launched (pid=\(ProcessInfo.processInfo.processIdentifier))")
        Logger.shared.info("Records root: \(RecordsArchive.rootDirectory().path)")

        setupStatusItem()
        setupAudioRecorderCallbacks()
        setupHotkeys()
        notifications.ensureAuthorization()

        controlServer.onSettingsSaved = { [weak self] in
            self?.configureHotkeysFromSettings()
            self?.refreshMenu()
        }
        controlServer.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        hotkeys.unregisterAll()
        controlServer.stop()
    }

    private func setupAudioRecorderCallbacks() {
        audioRecorder.onStageChanged = { [weak self] stage in
            switch stage {
            case .mergedAudio(let url):
                self?.notifications.post(title: "Own Recorder", body: "Собран общий аудиофайл: \(url.lastPathComponent)")
            case .encodedMP3(let url):
                self?.notifications.post(title: "Own Recorder", body: "Собран общий mp3 файл: \(url.lastPathComponent)")
            case .mergeFailed:
                self?.notifications.post(title: "Own Recorder", body: "Не удалось собрать общий mp3, продолжаю с исходным файлом")
            case .started, .stopped:
                break
            }
        }
        transcriptionManager.onStageChanged = { [weak self] stage in
            Task { @MainActor in
                guard let self else { return }
                switch stage {
                case .transcribing:
                    self.setAppState(.transcribing)
                case .summarizing:
                    self.setAppState(.summarizing)
                }
            }
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Own Recorder")
            button.toolTip = "Own Call Recorder"
        }
        updateStatusAppearance()
        refreshMenu()
    }

    private func setupHotkeys() {
        hotkeys.onStart = { [weak self] in
            Task { @MainActor in self?.manualStart() }
        }
        hotkeys.onStop = { [weak self] in
            Task { @MainActor in self?.manualStop() }
        }
        configureHotkeysFromSettings()
    }

    private func configureHotkeysFromSettings() {
        do {
            let settings = settingsStore.load()
            try hotkeys.configure(startShortcut: settings.startHotkey, stopShortcut: settings.stopHotkey)
        } catch {
            Logger.shared.error("AppDelegate: hotkey setup failed — \(error.localizedDescription)")
        }
    }

    private func refreshMenu() {
        let menu = NSMenu()
        let settings = settingsStore.load()

        let statusTitle: String
        switch appState {
        case .idle: statusTitle = "○ Ожидание"
        case .recording: statusTitle = "● Запись..."
        case .transcribing: statusTitle = "◔ Транскрибация..."
        case .summarizing: statusTitle = "◕ Нейросводка..."
        }
        let statusMenuItem = NSMenuItem(title: statusTitle, action: nil, keyEquivalent: "")
        statusMenuItem.isEnabled = false
        menu.addItem(statusMenuItem)
        menu.addItem(.separator())

        if appState == .recording {
            let stopItem = NSMenuItem(
                title: "Остановить запись (\(settings.stopHotkey))",
                action: #selector(manualStop),
                keyEquivalent: ""
            )
            stopItem.target = self
            menu.addItem(stopItem)
        } else if appState == .idle {
            let startItem = NSMenuItem(
                title: "Начать запись (\(settings.startHotkey))",
                action: #selector(manualStart),
                keyEquivalent: ""
            )
            startItem.target = self
            menu.addItem(startItem)
        } else {
            let processingItem = NSMenuItem(title: "Идёт обработка...", action: nil, keyEquivalent: "")
            processingItem.isEnabled = false
            menu.addItem(processingItem)
        }

        menu.addItem(.separator())

        let openRecordsItem = NSMenuItem(title: "Открыть папку records", action: #selector(openRecordsFolder), keyEquivalent: "")
        openRecordsItem.target = self
        menu.addItem(openRecordsItem)

        let settingsItem = NSMenuItem(title: "Настройки...", action: #selector(openSettings), keyEquivalent: ",")
        settingsItem.target = self
        menu.addItem(settingsItem)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        statusItem?.menu = menu
        updateStatusAppearance()
    }

    private func setAppState(_ newState: AppRecorderState) {
        appState = newState
        refreshMenu()
    }

    private func updateStatusAppearance() {
        guard let button = statusItem?.button else { return }
        button.image = NSImage(systemSymbolName: "mic.circle.fill", accessibilityDescription: "Own Recorder")
        switch appState {
        case .idle:
            button.contentTintColor = NSColor.systemGray
            button.toolTip = "Own Recorder: ожидание"
        case .recording:
            button.contentTintColor = NSColor.systemRed
            button.toolTip = "Own Recorder: идет запись"
        case .transcribing:
            button.contentTintColor = NSColor.systemYellow
            button.toolTip = "Own Recorder: идет транскрибация"
        case .summarizing:
            button.contentTintColor = NSColor.systemCyan
            button.toolTip = "Own Recorder: идет обработка нейронкой"
        }
    }

    @MainActor
    @objc private func manualStart() {
        guard appState == .idle else {
            Logger.shared.warn("AppDelegate: start ignored, state is \(appState)")
            return
        }

        currentUploadID = UUID().uuidString
        currentTitle = "Manual Recording"
        recordingStartedAt = Date()

        Task {
            do {
                _ = try await audioRecorder.startRecording()
                setAppState(.recording)
                notifications.post(title: "Own Recorder", body: "Начал запись")
                Logger.shared.info("AppDelegate: manual recording started id=\(currentUploadID ?? "-")")
            } catch {
                currentUploadID = nil
                currentTitle = nil
                recordingStartedAt = nil
                notifications.post(title: "Own Recorder", body: "Не удалось начать запись")
                Logger.shared.error("AppDelegate: startRecording failed — \(error.localizedDescription)")
            }
        }
    }

    @MainActor
    @objc private func manualStop() {
        guard appState == .recording else {
            Logger.shared.warn("AppDelegate: stop ignored, state is \(appState)")
            return
        }
        guard let uploadID = currentUploadID,
              let title = currentTitle,
              let startedAt = recordingStartedAt
        else {
            Logger.shared.warn("AppDelegate: stop requested but session state is incomplete")
            return
        }

        setAppState(.transcribing)

        Task {
            do {
                let audioURL = try await audioRecorder.stopRecording(
                    archiveStartedAt: startedAt,
                    archiveTitle: title
                )
                notifications.post(title: "Own Recorder", body: "Закончил запись")
                notifications.post(title: "Own Recorder", body: "Отправил на транскрайб")

                _ = try await transcriptionManager.process(
                    audioURL: audioURL,
                    title: title,
                    startedAt: startedAt,
                    uploadID: uploadID
                )
                notifications.post(title: "Own Recorder", body: "Закончил транскрибацию")
            } catch {
                notifications.post(title: "Own Recorder", body: "Ошибка: \(error.localizedDescription)")
                Logger.shared.error("AppDelegate: stop/process failed — \(error.localizedDescription)")
            }

            currentUploadID = nil
            currentTitle = nil
            recordingStartedAt = nil
            setAppState(.idle)
        }
    }

    @objc private func openRecordsFolder() {
        NSWorkspace.shared.open(RecordsArchive.rootDirectory())
    }

    @objc private func openSettings() {
        controlServer.start()
        NSWorkspace.shared.open(controlServer.rootURL)
    }
}
