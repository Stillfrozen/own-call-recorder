import Foundation

/// One-shot rename of legacy `record-ddMMyy-HHmm` (and old ISO+title) folders to `YYYY-MM-DD_HHmm`.
enum RecordsMigrator {

    static func migrateIfNeeded() {
        let root = RecordsArchive.rootDirectory()
        let fm = FileManager.default
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)

        guard let children = try? fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            RecordsIndex.rewriteIndexMarkdown()
            return
        }

        var migrated = 0
        var failed = 0

        for url in children {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = url.lastPathComponent
            if RecordsIndex.isCanonicalFolderName(name) { continue }

            let startedAt = startedAtForMigration(sessionDir: url)
            let baseName = RecordsArchive.sessionFolderName(startedAt: startedAt, title: nil)
            var dest = root.appendingPathComponent(baseName, isDirectory: true)
            if dest.standardizedFileURL.path == url.standardizedFileURL.path {
                continue
            }
            if fm.fileExists(atPath: dest.path) {
                dest = RecordsArchive.uniqueSessionDirectory(root: root, baseName: baseName)
            }

            do {
                try fm.moveItem(at: url, to: dest)
                rewriteMetadataPaths(
                    sessionDir: dest,
                    oldFolderName: name,
                    newFolderName: dest.lastPathComponent
                )
                migrated += 1
                Logger.shared.info("RecordsMigrator: migrated \(name) → \(dest.lastPathComponent)")
            } catch {
                failed += 1
                Logger.shared.error("RecordsMigrator: failed \(name) — \(error.localizedDescription)")
            }
        }

        Logger.shared.info("RecordsMigrator: done migrated=\(migrated) failed=\(failed)")
        RecordsIndex.rewriteIndexMarkdown()
    }

    private static func startedAtForMigration(sessionDir: URL) -> Date {
        let candidates = [
            sessionDir.appendingPathComponent("result/metadata.json"),
            sessionDir.appendingPathComponent("metadata.json"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let raw = json["started_at"] as? String,
                  let date = RecordsIndex.parseISODate(raw)
            else { continue }
            return date
        }
        return RecordsIndex.parseStartedAt(from: sessionDir.lastPathComponent)
            ?? (try? sessionDir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
            ?? Date()
    }

    private static func rewriteMetadataPaths(sessionDir: URL, oldFolderName: String, newFolderName: String) {
        let candidates = [
            sessionDir.appendingPathComponent("result/metadata.json"),
            sessionDir.appendingPathComponent("metadata.json"),
        ]
        let keys = ["audio_path", "transcript_path", "summary_path"]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  var json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            var changed = false
            for key in keys {
                guard let raw = json[key] as? String else { continue }
                let updated = raw.replacingOccurrences(of: "/\(oldFolderName)/", with: "/\(newFolderName)/")
                if updated != raw {
                    json[key] = updated
                    changed = true
                }
            }
            guard changed else { continue }
            guard let out = try? JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]) else { continue }
            try? out.write(to: url, options: .atomic)
        }
    }
}
