import Foundation

final class NotificationService {
    static let shared = NotificationService()
    private var capabilityChecked = false
    private var notificationsAvailable = true

    private init() {}

    func ensureAuthorization() {
        guard !capabilityChecked else { return }
        capabilityChecked = true

        // `UNUserNotificationCenter.current()` may crash for plain command-line binaries
        // (no .app bundle proxy). Use AppleScript notification as transport instead.
        let canRunOsa = FileManager.default.isExecutableFile(atPath: "/usr/bin/osascript")
        notificationsAvailable = canRunOsa
        if !canRunOsa {
            Logger.shared.warn("NotificationService: osascript not found, notifications disabled")
        }
    }

    func post(title: String, body: String) {
        let settings = SettingsStore.shared.load()
        guard settings.notificationsEnabled else { return }
        guard notificationsAvailable else { return }

        DispatchQueue.global(qos: .utility).async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")

            // Escape backslashes and quotes for AppleScript string literal.
            func esc(_ s: String) -> String {
                s.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"")
            }

            let script = "display notification \"\(esc(body))\" with title \"\(esc(title))\""
            proc.arguments = ["-e", script]
            proc.standardOutput = FileHandle.nullDevice
            proc.standardError = FileHandle.nullDevice

            do {
                try proc.run()
                proc.waitUntilExit()
            } catch {
                Logger.shared.warn("NotificationService: send failed — \(error.localizedDescription)")
            }
        }
    }
}
