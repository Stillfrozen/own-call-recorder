import Foundation

/// Resolves `agent` CLI when the menu bar app has a minimal PATH (no `~/.local/bin`).
enum CursorAgentLocator {
    static func resolve(configured: String) -> String? {
        let trimmed = configured.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return wellKnownPaths().first { FileManager.default.isExecutableFile(atPath: $0) }
        }

        let expanded = (trimmed as NSString).expandingTildeInPath
        if trimmed.contains("/") {
            return FileManager.default.isExecutableFile(atPath: expanded) ? expanded : nil
        }

        var candidates: [String] = []
        if let pathEnv = ProcessInfo.processInfo.environment["PATH"] {
            for dir in pathEnv.split(separator: ":") {
                let dirPath = String(dir)
                guard !dirPath.isEmpty else { continue }
                candidates.append(URL(fileURLWithPath: dirPath).appendingPathComponent(trimmed).path)
            }
        }
        candidates.append(contentsOf: wellKnownPaths())
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static func wellKnownPaths() -> [String] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return [
            "\(home)/.local/bin/agent",
            "\(home)/.cursor/bin/agent",
            "/opt/homebrew/bin/agent",
            "/usr/local/bin/agent",
        ]
    }
}
