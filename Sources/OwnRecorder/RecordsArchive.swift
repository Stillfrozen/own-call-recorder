import Foundation

/// Copies the finished recording into `<package-root>/records/YYYY-MM-DD_HHmm/audio/recording.<ext>`.
enum RecordsArchive {

    /// Root directory for all sessions. Override with `OWN_RECORDER_RECORDS_DIR` (absolute or `~`).
    ///
    /// Do **not** walk up from `/Applications/OwnRecorder.app` looking for `Package.swift` —
    /// that misses the project and falls back to `cwd/records`, which for a GUI app is `/records`
    /// (read-only system volume). Pin via env, bundled `RecordsRoot.path`, compile-time `#filePath`,
    /// or Application Support.
    static func rootDirectory() -> URL {
        if let fromEnv = expandedDirectory(ProcessInfo.processInfo.environment["OWN_RECORDER_RECORDS_DIR"]) {
            return fromEnv
        }
        if let fromBundle = bundledRecordsRoot() {
            return fromBundle
        }
        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).standardizedFileURL
        if let fromBinary = recordsDirNearPackage(startingAt: binary) {
            return fromBinary
        }
        if let fromSource = recordsDirNearPackage(startingAt: URL(fileURLWithPath: #filePath)) {
            return fromSource
        }
        Logger.shared.warn("RecordsArchive: no Package.swift near binary — using Application Support")
        return applicationSupportRecords()
    }

    private static func expandedDirectory(_ raw: String?) -> URL? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let path = (raw.trimmingCharacters(in: .whitespacesAndNewlines) as NSString).expandingTildeInPath
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Written by `scripts/install-app-launcher.sh` into `Contents/Resources/RecordsRoot.path`.
    private static func bundledRecordsRoot() -> URL? {
        guard let url = Bundle.main.url(forResource: "RecordsRoot", withExtension: "path"),
              let raw = try? String(contentsOf: url, encoding: .utf8)
        else { return nil }
        return expandedDirectory(raw)
    }

    private static func recordsDirNearPackage(startingAt start: URL) -> URL? {
        var dir = start.standardizedFileURL
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir), !isDir.boolValue {
            dir = dir.deletingLastPathComponent()
        }
        for _ in 0..<16 {
            if FileManager.default.fileExists(atPath: dir.appendingPathComponent("Package.swift").path) {
                return dir.appendingPathComponent("records", isDirectory: true)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        return nil
    }

    private static func applicationSupportRecords() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("OwnRecorder/records", isDirectory: true)
    }

    /// `YYYY-MM-DD_HHmm` in local timezone. Title is ignored (lives in INDEX.md).
    static func sessionFolderName(startedAt: Date, title: String?) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "yyyy-MM-dd_HHmm"
        _ = title
        return df.string(from: startedAt)
    }

    /// Unique folder under `records/` for `baseName`, adding `_2`, `_3`, … on collision.
    static func uniqueSessionDirectory(root: URL, baseName: String) -> URL {
        var sessionDir = root.appendingPathComponent(baseName, isDirectory: true)
        var counter = 1
        while FileManager.default.fileExists(atPath: sessionDir.path) {
            counter += 1
            sessionDir = root.appendingPathComponent("\(baseName)_\(counter)", isDirectory: true)
        }
        return sessionDir
    }

    /// Moves `tempFile` into a new session folder under `records/`. Returns the new file URL.
    static func moveFinalRecording(tempFile: URL, startedAt: Date, title: String?) throws -> URL {
        let root = rootDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let baseName = sessionFolderName(startedAt: startedAt, title: title)
        let sessionDir = uniqueSessionDirectory(root: root, baseName: baseName)

        let audioDir = sessionDir.appendingPathComponent("audio", isDirectory: true)
        let transcribeDir = sessionDir.appendingPathComponent("transcribe", isDirectory: true)
        let resultDir = sessionDir.appendingPathComponent("result", isDirectory: true)
        try FileManager.default.createDirectory(at: audioDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: transcribeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        let ext = tempFile.pathExtension.isEmpty ? "m4a" : tempFile.pathExtension
        let dest = audioDir.appendingPathComponent("recording.\(ext)")

        if FileManager.default.fileExists(atPath: dest.path) {
            try FileManager.default.removeItem(at: dest)
        }

        do {
            try FileManager.default.moveItem(at: tempFile, to: dest)
        } catch {
            try FileManager.default.copyItem(at: tempFile, to: dest)
            try? FileManager.default.removeItem(at: tempFile)
        }

        Logger.shared.info("RecordsArchive: saved → \(dest.path)")
        RecordsIndex.rewriteIndexMarkdown()
        return dest
    }
}
