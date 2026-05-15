import Foundation

/// Copies the finished recording into `<package-root>/records/record-ddmmyy-hhmm/audio/recording.<ext>`.
enum RecordsArchive {

    /// Root directory for all sessions. Override with `OWN_RECORDER_RECORDS_DIR` (absolute or `~`).
    static func rootDirectory() -> URL {
        if let raw = ProcessInfo.processInfo.environment["OWN_RECORDER_RECORDS_DIR"]?.trimmingCharacters(in: .whitespaces),
           !raw.isEmpty {
            return URL(fileURLWithPath: (raw as NSString).expandingTildeInPath, isDirectory: true)
        }

        let binary = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[0]).standardizedFileURL
        var dir = binary.deletingLastPathComponent()
        for _ in 0..<12 {
            let pkg = dir.appendingPathComponent("Package.swift")
            if FileManager.default.fileExists(atPath: pkg.path) {
                return dir.appendingPathComponent("records", isDirectory: true)
            }
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("records", isDirectory: true)
    }

    /// `record-ddMMyy-HHmm` in local timezone.
    static func sessionFolderName(startedAt: Date, title: String?) -> String {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = "ddMMyy-HHmm"
        let stamp = df.string(from: startedAt)
        _ = title
        return "record-\(stamp)"
    }

    /// Moves `tempFile` into a new session folder under `records/`. Returns the new file URL.
    static func moveFinalRecording(tempFile: URL, startedAt: Date, title: String?) throws -> URL {
        let root = rootDirectory()
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let baseName = sessionFolderName(startedAt: startedAt, title: title)
        var sessionDir = root.appendingPathComponent(baseName, isDirectory: true)
        var counter = 1
        while FileManager.default.fileExists(atPath: sessionDir.path) {
            counter += 1
            sessionDir = root.appendingPathComponent("\(baseName)_\(counter)", isDirectory: true)
        }

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
        return dest
    }
}
