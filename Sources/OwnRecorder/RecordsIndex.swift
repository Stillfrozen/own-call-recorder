import Foundation

enum RecordSessionStatus: String {
    case complete
    case transcribedOnly = "transcribed_only"
    case audioOnly = "audio_only"
    case failed
    case processing
}

struct RecordSessionEntry: Codable {
    let sessionId: String
    let sessionPath: String
    let audioPath: String?
    let transcriptPath: String?
    let summaryPath: String?
    let metadataPath: String?
    let errorPath: String?
    let title: String
    let startedAt: String?
    let uploadId: String?
    let status: String
    let sttProvider: String?
    let sttFallbackFrom: String?
    let lastError: String?
    let stage: String?
}

extension RecordSessionEntry {
    func asJSONObject() -> [String: Any] {
        guard let data = try? JSONEncoder().encode(self),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return obj
    }
}

enum RecordsIndex {
    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        return f
    }()

    static func listAll(processingSessionIds: Set<String> = [], stages: [String: String] = [:]) -> [RecordSessionEntry] {
        let root = RecordsArchive.rootDirectory()
        guard let children = try? FileManager.default.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        var entries: [RecordSessionEntry] = []
        for url in children {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { continue }
            let name = url.lastPathComponent
            if name.hasPrefix(".") { continue }
            entries.append(scanSession(
                sessionDir: url,
                processingSessionIds: processingSessionIds,
                stages: stages
            ))
        }

        entries.sort { lhs, rhs in
            let lDate = parseISO(lhs.startedAt) ?? Date.distantPast
            let rDate = parseISO(rhs.startedAt) ?? Date.distantPast
            if lDate != rDate { return lDate > rDate }
            return lhs.sessionId > rhs.sessionId
        }
        return entries
    }

    static func entry(
        forSessionId sessionId: String,
        processingSessionIds: Set<String> = [],
        stages: [String: String] = [:]
    ) -> RecordSessionEntry? {
        let root = RecordsArchive.rootDirectory()
        let sessionDir = root.appendingPathComponent(sessionId, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionDir.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return scanSession(sessionDir: sessionDir, processingSessionIds: processingSessionIds, stages: stages)
    }

    static func sessionDirectory(forSessionId sessionId: String) -> URL? {
        let root = RecordsArchive.rootDirectory()
        let sessionDir = root.appendingPathComponent(sessionId, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: sessionDir.path, isDirectory: &isDir), isDir.boolValue else {
            return nil
        }
        return sessionDir
    }

    static func parseStartedAt(from folderName: String) -> Date? {
        let base = folderName.split(separator: "_", maxSplits: 1).first.map(String.init) ?? folderName
        if base.hasPrefix("record-") {
            let stamp = String(base.dropFirst("record-".count))
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone.current
            df.dateFormat = "ddMMyy-HHmm"
            return df.date(from: stamp)
        }
        let parts = folderName.split(separator: "_")
        if parts.count >= 2, parts[1].count == 6, parts[1].allSatisfy(\.isNumber) {
            let df = DateFormatter()
            df.locale = Locale(identifier: "en_US_POSIX")
            df.timeZone = TimeZone.current
            df.dateFormat = "yyyy-MM-dd_HHmmss"
            return df.date(from: "\(parts[0])_\(parts[1])")
        }
        return nil
    }

    private static func scanSession(
        sessionDir: URL,
        processingSessionIds: Set<String>,
        stages: [String: String]
    ) -> RecordSessionEntry {
        let sessionId = sessionDir.lastPathComponent
        let metadata = readMetadata(sessionDir: sessionDir)

        let audioPath = TranscriptionManager.findAudioFile(in: sessionDir)?.path
        let transcriptPath = existingPath(
            sessionDir.appendingPathComponent("transcribe/transcript.txt"),
            sessionDir.appendingPathComponent("transcript.txt")
        )
        let summaryPath = existingPath(
            sessionDir.appendingPathComponent("result/summary.md"),
            sessionDir.appendingPathComponent("summary.md")
        )
        let metadataPath = existingPath(
            sessionDir.appendingPathComponent("result/metadata.json"),
            sessionDir.appendingPathComponent("metadata.json")
        )
        let errorPath = sessionDir.appendingPathComponent("result/error.txt")
        let hasError = FileManager.default.fileExists(atPath: errorPath.path)
        let lastError = hasError ? (try? String(contentsOf: errorPath, encoding: .utf8)) : nil

        let title = metadata.title ?? sessionId
        let startedAt = metadata.startedAt ?? isoFormatter.string(
            from: parseStartedAt(from: sessionId)
                ?? (try? sessionDir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date()
        )

        let status: RecordSessionStatus
        if processingSessionIds.contains(sessionId) {
            status = .processing
        } else if hasError {
            status = .failed
        } else if transcriptPath != nil && summaryPath != nil {
            status = .complete
        } else if transcriptPath != nil {
            status = .transcribedOnly
        } else if audioPath != nil {
            status = .audioOnly
        } else {
            status = .failed
        }

        return RecordSessionEntry(
            sessionId: sessionId,
            sessionPath: sessionDir.path,
            audioPath: audioPath,
            transcriptPath: transcriptPath,
            summaryPath: summaryPath,
            metadataPath: metadataPath,
            errorPath: hasError ? errorPath.path : nil,
            title: title,
            startedAt: startedAt,
            uploadId: metadata.uploadId,
            status: status.rawValue,
            sttProvider: metadata.sttProvider,
            sttFallbackFrom: metadata.sttFallbackFrom,
            lastError: lastError.map { String($0.prefix(500)) },
            stage: stages[sessionId]
        )
    }

    private static func readMetadata(sessionDir: URL) -> (
        title: String?,
        startedAt: String?,
        uploadId: String?,
        sttProvider: String?,
        sttFallbackFrom: String?
    ) {
        let candidates = [
            sessionDir.appendingPathComponent("result/metadata.json"),
            sessionDir.appendingPathComponent("metadata.json"),
        ]
        for url in candidates where FileManager.default.fileExists(atPath: url.path) {
            guard let data = try? Data(contentsOf: url),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            return (
                title: json["title"] as? String,
                startedAt: json["started_at"] as? String,
                uploadId: json["upload_id"] as? String,
                sttProvider: json["stt_provider"] as? String,
                sttFallbackFrom: (json["stt_fallback_from"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            )
        }
        return (nil, nil, nil, nil, nil)
    }

    private static func existingPath(_ primary: URL, _ legacy: URL) -> String? {
        if FileManager.default.fileExists(atPath: primary.path) { return primary.path }
        if FileManager.default.fileExists(atPath: legacy.path) { return legacy.path }
        return nil
    }

    private static func parseISO(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return isoFormatter.date(from: raw)
    }
}
