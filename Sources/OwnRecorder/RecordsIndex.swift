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
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private static let isoFractionalFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let canonicalNameRegex: NSRegularExpression = {
        try! NSRegularExpression(pattern: #"^\d{4}-\d{2}-\d{2}_\d{4}(_\d+)?$"#)
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
            let lDate = parseISODate(lhs.startedAt) ?? Date.distantPast
            let rDate = parseISODate(rhs.startedAt) ?? Date.distantPast
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

    static func isCanonicalFolderName(_ name: String) -> Bool {
        let range = NSRange(name.startIndex..., in: name)
        return canonicalNameRegex.firstMatch(in: name, options: [], range: range) != nil
    }

    static func parseISODate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        return isoFormatter.date(from: raw) ?? isoFractionalFormatter.date(from: raw)
    }

    static func parseStartedAt(from folderName: String) -> Date? {
        if folderName.hasPrefix("record-") {
            let rest = String(folderName.dropFirst("record-".count))
            let stamp = rest.split(separator: "_").first.map(String.init) ?? rest
            return posixDate(format: "ddMMyy-HHmm", value: stamp)
        }

        let parts = folderName.split(separator: "_").map(String.init)
        guard parts.count >= 2 else { return nil }
        let datePart = parts[0]
        let timePart = parts[1]
        guard datePart.count == 10, timePart.allSatisfy(\.isNumber) else { return nil }
        if timePart.count == 4 {
            return posixDate(format: "yyyy-MM-dd_HHmm", value: "\(datePart)_\(timePart)")
        }
        if timePart.count == 6 {
            return posixDate(format: "yyyy-MM-dd_HHmmss", value: "\(datePart)_\(timePart)")
        }
        return nil
    }

    static func rewriteIndexMarkdown() {
        let root = RecordsArchive.rootDirectory()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let entries = listAll()
        let body = renderIndex(entries: entries, root: root)
        let url = root.appendingPathComponent("INDEX.md")
        do {
            try body.write(to: url, atomically: true, encoding: .utf8)
            Logger.shared.info("RecordsIndex: wrote INDEX.md (\(entries.count) sessions)")
        } catch {
            Logger.shared.error("RecordsIndex: failed to write INDEX.md — \(error.localizedDescription)")
        }
    }

    static func canonicalSummaryURL(in sessionDir: URL) -> URL? {
        let fm = FileManager.default
        let known = [
            "meeting-summary.md",
            "meeting_summary.md",
            "meeting_summary_manual_recording.md",
            "конспект-встречи.md",
        ]
        for name in known {
            let url = sessionDir.appendingPathComponent(name)
            if fm.fileExists(atPath: url.path) { return url }
        }

        if let children = try? fm.contentsOfDirectory(at: sessionDir, includingPropertiesForKeys: nil) {
            let matches = children
                .filter { $0.pathExtension.lowercased() == "md" }
                .filter { $0.lastPathComponent.lowercased().hasPrefix("meeting-summary-") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let first = matches.first { return first }
        }

        let docs = sessionDir.appendingPathComponent("docs", isDirectory: true)
        if let children = try? fm.contentsOfDirectory(at: docs, includingPropertiesForKeys: nil) {
            let matches = children
                .filter { $0.pathExtension.lowercased() == "md" }
                .filter { $0.lastPathComponent.lowercased().contains("meeting-summary") }
                .sorted { $0.lastPathComponent < $1.lastPathComponent }
            if let first = matches.first { return first }
        }

        let resultSummary = sessionDir.appendingPathComponent("result/summary.md")
        if fm.fileExists(atPath: resultSummary.path) { return resultSummary }
        let legacy = sessionDir.appendingPathComponent("summary.md")
        if fm.fileExists(atPath: legacy.path) { return legacy }
        return nil
    }

    private static func posixDate(format: String, value: String) -> Date? {
        let df = DateFormatter()
        df.locale = Locale(identifier: "en_US_POSIX")
        df.timeZone = TimeZone.current
        df.dateFormat = format
        return df.date(from: value)
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
        let summaryURL = canonicalSummaryURL(in: sessionDir)
        let summaryPath = summaryURL?.path
        let metadataPath = existingPath(
            sessionDir.appendingPathComponent("result/metadata.json"),
            sessionDir.appendingPathComponent("metadata.json")
        )
        let errorPath = sessionDir.appendingPathComponent("result/error.txt")
        let hasError = FileManager.default.fileExists(atPath: errorPath.path)
        let lastError = hasError ? (try? String(contentsOf: errorPath, encoding: .utf8)) : nil

        let startedAt = metadata.startedAt ?? isoFormatter.string(
            from: parseStartedAt(from: sessionId)
                ?? (try? sessionDir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date()
        )
        let title = displayTitle(sessionDir: sessionDir, metadataTitle: metadata.title, fallback: sessionId)

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

    private static func displayTitle(sessionDir: URL, metadataTitle: String?, fallback: String) -> String {
        if let url = canonicalSummaryURL(in: sessionDir),
           let text = try? String(contentsOf: url, encoding: .utf8),
           let topic = extractTopic(from: text) {
            return topic
        }
        if let metadataTitle, !isDummyTitle(metadataTitle) {
            return metadataTitle
        }
        if isDummyTitle(fallback) { return fallback }
        return fallback
    }

    private static func isDummyTitle(_ raw: String) -> Bool {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return true }
        if trimmed == "Manual Recording" || trimmed == "Untitled" { return true }
        if trimmed.hasPrefix("record-") { return true }
        if isCanonicalFolderName(trimmed) { return true }
        return false
    }

    private static func extractTopic(from text: String) -> String? {
        let body = stripFrontmatter(text)
        let lines = body.components(separatedBy: .newlines)

        if let headingIndex = lines.firstIndex(where: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            return t.compare("## Тема и цель", options: .caseInsensitive) == .orderedSame
                || t.compare("## Тема и цель", options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame
        }) {
            var collected: [String] = []
            var idx = headingIndex + 1
            while idx < lines.count {
                let t = lines[idx].trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("## ") { break }
                if t.isEmpty {
                    if !collected.isEmpty { break }
                    idx += 1
                    continue
                }
                collected.append(t)
                idx += 1
            }
            if let title = sanitizeTitle(collected.joined(separator: " ")), !title.isEmpty {
                return title
            }
        }

        for line in lines {
            let t = line.trimmingCharacters(in: .whitespaces)
            let markers = ["- **Тема и цель**:", "**Тема и цель**:", "- **Тема и цель:**"]
            for marker in markers {
                if let range = t.range(of: marker, options: .caseInsensitive) {
                    let rest = String(t[range.upperBound...])
                    if let title = sanitizeTitle(rest), !title.isEmpty { return title }
                }
            }
        }
        return nil
    }

    private static func stripFrontmatter(_ text: String) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("---") else { return text }
        let parts = trimmed.components(separatedBy: "\n")
        guard parts.count > 1 else { return text }
        var i = 1
        while i < parts.count {
            if parts[i].trimmingCharacters(in: .whitespaces) == "---" {
                return parts.dropFirst(i + 1).joined(separator: "\n")
            }
            i += 1
        }
        return text
    }

    private static func sanitizeTitle(_ raw: String) -> String? {
        var s = raw
        s = s.replacingOccurrences(of: "**", with: "")
        s = s.replacingOccurrences(of: "__", with: "")
        s = s.replacingOccurrences(of: "`", with: "")
        s = s.replacingOccurrences(of: "\n", with: " ")
        while s.contains("  ") {
            s = s.replacingOccurrences(of: "  ", with: " ")
        }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return nil }
        if s.count > 80 {
            let end = s.index(s.startIndex, offsetBy: 80)
            s = String(s[..<end]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return s
    }

    private static func renderIndex(entries: [RecordSessionEntry], root: URL) -> String {
        var lines: [String] = [
            "# Записи встреч",
            "",
            "Новые сверху. Файл пересобирается рекордером, руками не править.",
            "",
        ]

        if entries.isEmpty {
            lines.append("_Записей пока нет._")
            lines.append("")
            return lines.joined(separator: "\n")
        }

        let monthFormatter = DateFormatter()
        monthFormatter.locale = Locale(identifier: "en_US_POSIX")
        monthFormatter.timeZone = TimeZone.current
        monthFormatter.dateFormat = "yyyy-MM"

        let displayFormatter = DateFormatter()
        displayFormatter.locale = Locale(identifier: "ru_RU")
        displayFormatter.timeZone = TimeZone.current
        displayFormatter.dateFormat = "dd.MM.yyyy HH:mm"

        var currentMonth: String?

        for entry in entries {
            let date = parseISODate(entry.startedAt) ?? RecordsIndex.parseStartedAt(from: entry.sessionId)
            let month = date.map { monthFormatter.string(from: $0) } ?? "unknown"
            if month != currentMonth {
                if currentMonth != nil {
                    lines.append("")
                }
                currentMonth = month
                lines.append("## \(month)")
                lines.append("")
            }

            let when = date.map { displayFormatter.string(from: $0) } ?? entry.sessionId
            let statusNote = indexStatusNote(entry.status)
            let titlePart: String
            if isDummyTitle(entry.title) || entry.title == entry.sessionId {
                titlePart = statusNote
            } else {
                titlePart = statusNote.isEmpty ? " — \(entry.title)" : " — \(entry.title) \(statusNote)"
            }
            lines.append("- **\(when)**\(titlePart)")

            var links: [String] = []
            if let summaryPath = entry.summaryPath {
                let rel = relativeLink(root: root, filePath: summaryPath)
                links.append("[конспект](\(rel))")
            }
            if let transcriptPath = entry.transcriptPath {
                let rel = relativeLink(root: root, filePath: transcriptPath)
                links.append("[транскрипт](\(rel))")
            }
            links.append("[папка](\(entry.sessionId)/)")
            lines.append("  \(links.joined(separator: " · "))")
        }

        lines.append("")
        return lines.joined(separator: "\n")
    }

    private static func indexStatusNote(_ status: String) -> String {
        switch status {
        case RecordSessionStatus.failed.rawValue: return " (ошибка)"
        case RecordSessionStatus.audioOnly.rawValue: return " (только аудио)"
        case RecordSessionStatus.transcribedOnly.rawValue: return " (без конспекта)"
        case RecordSessionStatus.processing.rawValue: return " (обработка)"
        default: return ""
        }
    }

    private static func relativeLink(root: URL, filePath: String) -> String {
        let rootPath = root.standardizedFileURL.path
        let file = URL(fileURLWithPath: filePath).standardizedFileURL.path
        if file.hasPrefix(rootPath) {
            var rel = String(file.dropFirst(rootPath.count))
            if rel.hasPrefix("/") { rel.removeFirst() }
            return rel
        }
        return URL(fileURLWithPath: filePath).lastPathComponent
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
}
