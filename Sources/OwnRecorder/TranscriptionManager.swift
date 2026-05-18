import Foundation

struct TranscriptionArtifacts {
    let transcriptURL: URL
    let summaryURL: URL
    let metadataURL: URL
}

enum TranscriptionPipelineStage {
    case transcribing
    case summarizing
}

enum TranscriptionError: Error, LocalizedError {
    case missingXAIAPIKey
    case missingGroqAPIKey
    case missingAnthropicAPIKey
    case missingAudio
    case invalidResponse(String)
    case cursorAgentNotFound
    case cursorAgentFailed(String)
    case commandTimeout

    var errorDescription: String? {
        switch self {
        case .missingXAIAPIKey:
            return "Missing xAI API key in settings"
        case .missingGroqAPIKey:
            return "Missing Groq API key in settings"
        case .missingAnthropicAPIKey:
            return "Missing Anthropic API key in settings"
        case .missingAudio:
            return "No audio file found in session folder"
        case .invalidResponse(let message):
            return "Invalid API response: \(message)"
        case .cursorAgentNotFound:
            return "Cursor agent binary not found"
        case .cursorAgentFailed(let message):
            return "Cursor agent failed: \(message)"
        case .commandTimeout:
            return "Command timed out"
        }
    }
}

private struct STTResult {
    let transcript: String
    let diarizedSegments: [[String: Any]]
    let usedProvider: STTProvider
    let fallbackFromProvider: STTProvider?
}

final class TranscriptionManager {
    private let settingsStore = SettingsStore.shared
    private let secretsStore = SecureSecretsStore.shared
    var onStageChanged: ((TranscriptionPipelineStage) -> Void)?

    private static let sttRequestTimeoutSec: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["OWN_RECORDER_STT_TIMEOUT_SEC"],
           let v = TimeInterval(raw), v > 60
        {
            return v
        }
        return 900
    }()

    private static let sttResourceTimeoutSec: TimeInterval = {
        if let raw = ProcessInfo.processInfo.environment["OWN_RECORDER_STT_RESOURCE_TIMEOUT_SEC"],
           let v = TimeInterval(raw), v > 120
        {
            return v
        }
        return 3600
    }()

    private static let sttURLSession: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = sttRequestTimeoutSec
        config.timeoutIntervalForResource = sttResourceTimeoutSec
        config.waitsForConnectivity = true
        return URLSession(configuration: config)
    }()

    func process(audioURL: URL, title: String, startedAt: Date, uploadID: String) async throws -> TranscriptionArtifacts {
        let sessionDir = audioURL.deletingLastPathComponent().deletingLastPathComponent()
        clearError(in: sessionDir)
        return try await runPipeline(
            sessionDir: sessionDir,
            audioURL: audioURL,
            title: title,
            startedAt: startedAt,
            uploadID: uploadID
        )
    }

    func reprocess(sessionDir: URL) async throws -> TranscriptionArtifacts {
        guard let audioURL = Self.findAudioFile(in: sessionDir) else {
            throw TranscriptionError.missingAudio
        }
        let context = Self.loadSessionContext(sessionDir: sessionDir)
        clearError(in: sessionDir)
        return try await runPipeline(
            sessionDir: sessionDir,
            audioURL: audioURL,
            title: context.title,
            startedAt: context.startedAt,
            uploadID: context.uploadID
        )
    }

    static func persistError(_ error: Error, sessionDir: URL) {
        let resultDir = sessionDir.appendingPathComponent("result", isDirectory: true)
        try? FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)
        let errorURL = resultDir.appendingPathComponent("error.txt")
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        let body = "\(ISO8601DateFormatter().string(from: Date()))\n\(message)\n"
        try? body.write(to: errorURL, atomically: true, encoding: .utf8)
    }

    static func findAudioFile(in sessionDir: URL) -> URL? {
        let audioDir = sessionDir.appendingPathComponent("audio", isDirectory: true)
        if let url = firstRecordingFile(in: audioDir) { return url }
        return firstRecordingFile(in: sessionDir)
    }

    private static func firstRecordingFile(in directory: URL) -> URL? {
        guard let items = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return items.first { url in
            let name = url.lastPathComponent.lowercased()
            if name.hasPrefix("recording.") { return true }
            if !url.pathExtension.isEmpty, ["m4a", "mp3", "wav", "webm", "mp4", "ogg", "flac"].contains(url.pathExtension.lowercased()) {
                return true
            }
            return false
        }
    }

    private static func loadSessionContext(sessionDir: URL) -> (title: String, startedAt: Date, uploadID: String) {
        let metadataURL = sessionDir.appendingPathComponent("result/metadata.json")
        let legacyMetadataURL = sessionDir.appendingPathComponent("metadata.json")
        let url = FileManager.default.fileExists(atPath: metadataURL.path) ? metadataURL : legacyMetadataURL
        if let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        {
            let title = (json["title"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let uploadID = (json["upload_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            var startedAt: Date?
            if let raw = json["started_at"] as? String {
                startedAt = ISO8601DateFormatter().date(from: raw)
            }
            return (
                title: (title?.isEmpty == false) ? title! : sessionDir.lastPathComponent,
                startedAt: startedAt ?? RecordsIndex.parseStartedAt(from: sessionDir.lastPathComponent)
                    ?? (try? sessionDir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                    ?? Date(),
                uploadID: (uploadID?.isEmpty == false) ? uploadID! : UUID().uuidString
            )
        }
        return (
            title: sessionDir.lastPathComponent,
            startedAt: RecordsIndex.parseStartedAt(from: sessionDir.lastPathComponent)
                ?? (try? sessionDir.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                ?? Date(),
            uploadID: UUID().uuidString
        )
    }

    private func clearError(in sessionDir: URL) {
        let errorURL = sessionDir.appendingPathComponent("result/error.txt")
        try? FileManager.default.removeItem(at: errorURL)
    }

    private func runPipeline(
        sessionDir: URL,
        audioURL: URL,
        title: String,
        startedAt: Date,
        uploadID: String
    ) async throws -> TranscriptionArtifacts {
        let transcribeDir = sessionDir.appendingPathComponent("transcribe", isDirectory: true)
        let resultDir = sessionDir.appendingPathComponent("result", isDirectory: true)
        try FileManager.default.createDirectory(at: transcribeDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resultDir, withIntermediateDirectories: true)

        onStageChanged?(.transcribing)
        let sttResult = try await transcribeWithProviderSelection(audioURL: audioURL)
        let transcriptURL = transcribeDir.appendingPathComponent("transcript.txt")
        try sttResult.transcript.write(to: transcriptURL, atomically: true, encoding: .utf8)
        if !sttResult.diarizedSegments.isEmpty {
            let segmentsURL = transcribeDir.appendingPathComponent("segments.json")
            let segmentsData = try JSONSerialization.data(withJSONObject: sttResult.diarizedSegments, options: [.prettyPrinted])
            try segmentsData.write(to: segmentsURL)
        } else if FileManager.default.fileExists(atPath: transcribeDir.appendingPathComponent("segments.json").path) {
            try? FileManager.default.removeItem(at: transcribeDir.appendingPathComponent("segments.json"))
        }

        onStageChanged?(.summarizing)
        let summary = try await summarize(transcript: sttResult.transcript, title: title, workspaceDir: sessionDir, transcriptDir: transcribeDir)
        let summaryURL = resultDir.appendingPathComponent("summary.md")
        try summary.write(to: summaryURL, atomically: true, encoding: .utf8)

        let metadataURL = resultDir.appendingPathComponent("metadata.json")
        let metadata: [String: String] = [
            "upload_id": uploadID,
            "title": title,
            "started_at": ISO8601DateFormatter().string(from: startedAt),
            "audio_path": audioURL.path,
            "transcript_path": transcriptURL.path,
            "summary_path": summaryURL.path,
            "stt_provider": sttResult.usedProvider.rawValue,
            "stt_fallback_from": sttResult.fallbackFromProvider?.rawValue ?? "",
            "summary_provider": settingsStore.load().summaryProvider.rawValue,
            "last_reprocessed_at": ISO8601DateFormatter().string(from: Date()),
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted])
        try metadataData.write(to: metadataURL)
        clearError(in: sessionDir)

        Logger.shared.info("TranscriptionManager: artifacts written in \(sessionDir.path)")
        return TranscriptionArtifacts(transcriptURL: transcriptURL, summaryURL: summaryURL, metadataURL: metadataURL)
    }

    private func transcribeWithProviderSelection(audioURL: URL) async throws -> STTResult {
        let prepared = await AudioSTTPreprocessor.prepare(audioURL: audioURL)
        var cleanupURLs: [URL] = []
        if let c = prepared.cleanupURL { cleanupURLs.append(c) }
        defer {
            for url in cleanupURLs {
                try? FileManager.default.removeItem(at: url)
            }
        }

        let chunks = await AudioSTTPreprocessor.chunks(for: prepared.url)
        if chunks.count > 1, let first = chunks.first, first.needsCleanup {
            let chunkDir = first.url.deletingLastPathComponent()
            if chunkDir.lastPathComponent.hasPrefix("own-stt-chunks-") {
                cleanupURLs.append(chunkDir)
            }
        }

        if chunks.count == 1 {
            return try await transcribeSingleFile(audioURL: chunks[0].url)
        }

        Logger.shared.info("TranscriptionManager: STT in \(chunks.count) chunks")
        var transcriptParts: [String] = []
        var allSegments: [[String: Any]] = []
        var usedProvider: STTProvider?
        var fallbackFrom: STTProvider?

        for (index, chunk) in chunks.enumerated() {
            Logger.shared.info("TranscriptionManager: chunk \(index + 1)/\(chunks.count), offset \(Int(chunk.startOffsetSec))s")
            let part = try await transcribeSingleFile(audioURL: chunk.url)
            if usedProvider == nil {
                usedProvider = part.usedProvider
                fallbackFrom = part.fallbackFromProvider
            }
            let text = AudioSTTPreprocessor.offsetTranscriptLines(part.transcript, offsetSec: chunk.startOffsetSec)
            if !text.isEmpty { transcriptParts.append(text) }
            allSegments.append(contentsOf: part.diarizedSegments)
        }

        let merged = transcriptParts.joined(separator: "\n")
        guard !merged.isEmpty else {
            throw TranscriptionError.invalidResponse("empty transcript after chunk merge")
        }
        return STTResult(
            transcript: merged,
            diarizedSegments: allSegments,
            usedProvider: usedProvider ?? settingsStore.load().sttProvider,
            fallbackFromProvider: fallbackFrom
        )
    }

    private func transcribeSingleFile(audioURL: URL) async throws -> STTResult {
        let settings = settingsStore.load()
        switch settings.sttProvider {
        case .xai:
            let xai = try await transcribeXAI(audioURL: audioURL)
            return STTResult(transcript: xai.transcript, diarizedSegments: xai.diarizedSegments, usedProvider: .xai, fallbackFromProvider: nil)
        case .groq:
            do {
                let groq = try await transcribeGroq(audioURL: audioURL)
                return STTResult(transcript: groq.transcript, diarizedSegments: groq.diarizedSegments, usedProvider: .groq, fallbackFromProvider: nil)
            } catch {
                if shouldFallbackToXAI(for: error) {
                    Logger.shared.warn("TranscriptionManager: Groq STT failed, fallback to xAI — \(error.localizedDescription)")
                    let xai = try await transcribeXAI(audioURL: audioURL)
                    return STTResult(transcript: xai.transcript, diarizedSegments: xai.diarizedSegments, usedProvider: .xai, fallbackFromProvider: .groq)
                }
                throw error
            }
        }
    }

    private func shouldFallbackToXAI(for error: Error) -> Bool {
        if isTimeoutLike(error) { return true }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut, .networkConnectionLost, .notConnectedToInternet,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .dataNotAllowed, .internationalRoamingOff:
                return true
            default:
                break
            }
        }
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut {
            return true
        }
        if let underlying = ns.userInfo[NSUnderlyingErrorKey] as? Error, isTimeoutLike(underlying) {
            return true
        }
        if case let TranscriptionError.invalidResponse(msg) = error {
            if msg.contains("status 401") || msg.contains("status 403") { return true }
            if msg.contains("status 429") || msg.contains("status 408") { return true }
            if msg.contains("status 500") || msg.contains("status 502") || msg.contains("status 503") || msg.contains("status 504") {
                return true
            }
        }
        return false
    }

    private func isTimeoutLike(_ error: Error) -> Bool {
        let msg = error.localizedDescription.lowercased()
        if msg.contains("timed out") || msg.contains("timeout") || msg.contains("time out") {
            return true
        }
        if let urlError = error as? URLError, urlError.code == .timedOut {
            return true
        }
        let ns = error as NSError
        return ns.domain == NSURLErrorDomain && ns.code == NSURLErrorTimedOut
    }

    private func sttTimeoutInterval() -> TimeInterval {
        Self.sttRequestTimeoutSec
    }

    private func transcribeXAI(audioURL: URL) async throws -> (transcript: String, diarizedSegments: [[String: Any]]) {
        let settings = settingsStore.load()
        let xaiAPIKey = secretsStore.get("xai_api_key") ?? secretsStore.get("groq_api_key")
        guard let xaiAPIKey, !xaiAPIKey.isEmpty else {
            throw TranscriptionError.missingXAIAPIKey
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func appendField(_ name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("format", value: "true")
        appendField("language", value: settings.xaiSttLanguage)

        let fileData = try Data(contentsOf: audioURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "https://api.x.ai/v1/stt")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(xaiAPIKey)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = sttTimeoutInterval()

        let (data, response) = try await Self.sttURLSession.upload(for: req, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse("non-http response")
        }
        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.invalidResponse("xAI STT status \(http.statusCode): \(text.prefix(600))")
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return try parseTranscriptPayload(json: json, fallbackText: String(data: data, encoding: .utf8) ?? "")
        }

        let transcript = (String(data: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !transcript.isEmpty else {
            throw TranscriptionError.invalidResponse("empty transcript")
        }
        return (transcript, [])
    }

    private func transcribeGroq(audioURL: URL) async throws -> (transcript: String, diarizedSegments: [[String: Any]]) {
        let settings = settingsStore.load()
        guard let key = secretsStore.get("groq_whisper_api_key"), !key.isEmpty else {
            throw TranscriptionError.missingGroqAPIKey
        }

        let boundary = "Boundary-\(UUID().uuidString)"
        var body = Data()

        func appendField(_ name: String, value: String) {
            body.append("--\(boundary)\r\n".data(using: .utf8)!)
            body.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n".data(using: .utf8)!)
            body.append("\(value)\r\n".data(using: .utf8)!)
        }

        appendField("model", value: settings.groqModel)
        appendField("response_format", value: "verbose_json")
        appendField("language", value: settings.xaiSttLanguage)

        let fileData = try Data(contentsOf: audioURL)
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append(
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(audioURL.lastPathComponent)\"\r\n"
                .data(using: .utf8)!
        )
        body.append("Content-Type: audio/mpeg\r\n\r\n".data(using: .utf8)!)
        body.append(fileData)
        body.append("\r\n".data(using: .utf8)!)
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        var req = URLRequest(url: URL(string: "https://api.groq.com/openai/v1/audio/transcriptions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        req.timeoutInterval = sttTimeoutInterval()

        let (data, response) = try await Self.sttURLSession.upload(for: req, from: body)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse("non-http response")
        }
        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.invalidResponse("Groq STT status \(http.statusCode): \(text.prefix(600))")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw TranscriptionError.invalidResponse("Groq STT returned non-json body")
        }
        return try parseTranscriptPayload(json: json, fallbackText: String(data: data, encoding: .utf8) ?? "")
    }

    private func parseTranscriptPayload(json: [String: Any], fallbackText: String) throws -> (transcript: String, diarizedSegments: [[String: Any]]) {
        if let segments = json["segments"] as? [[String: Any]] {
            let plainSegmentLines = segments.compactMap { segment -> String? in
                let text = (segment["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                return text.isEmpty ? nil : text
            }
            if !plainSegmentLines.isEmpty {
                let plain = plainSegmentLines.joined(separator: "\n")
                if !plain.isEmpty {
                    var diarizedSegments: [[String: Any]] = []
                    diarizedSegments = segments.filter { segment in
                        (segment["speaker"] != nil || segment["speaker_id"] != nil || segment["speaker_label"] != nil)
                            && ((segment["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                    }
                    if !diarizedSegments.isEmpty {
                        let lines = diarizedSegments.compactMap { segment -> String? in
                            let text = (segment["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !text.isEmpty else { return nil }
                            let speakerValue = segment["speaker"] ?? segment["speaker_id"] ?? segment["speaker_label"] ?? "unknown"
                            return "Speaker \(speakerValue): \(text)"
                        }
                        let diarized = lines.joined(separator: "\n")
                        if !diarized.isEmpty {
                            return (diarized, diarizedSegments)
                        }
                    }
                    return (plain, [])
                }
            }
        }

        var diarizedSegments: [[String: Any]] = []
        if let segments = json["segments"] as? [[String: Any]] {
            diarizedSegments = segments.filter { segment in
                (segment["speaker"] != nil || segment["speaker_id"] != nil || segment["speaker_label"] != nil)
                    && ((segment["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
            }
        }

        if !diarizedSegments.isEmpty {
            let lines = diarizedSegments.compactMap { segment -> String? in
                let text = (segment["text"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else { return nil }
                let speakerValue = segment["speaker"] ?? segment["speaker_id"] ?? segment["speaker_label"] ?? "unknown"
                return "Speaker \(speakerValue): \(text)"
            }
            let transcript = lines.joined(separator: "\n")
            if !transcript.isEmpty {
                return (transcript, diarizedSegments)
            }
        }

        if let text = json["text"] as? String {
            let transcript = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !transcript.isEmpty {
                return (transcript, [])
            }
        }

        let trimmedFallback = fallbackText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFallback.isEmpty else {
            throw TranscriptionError.invalidResponse("empty transcript")
        }
        return (trimmedFallback, [])
    }

    private func summarize(transcript: String, title: String, workspaceDir: URL, transcriptDir: URL) async throws -> String {
        let settings = settingsStore.load()
        switch settings.summaryProvider {
        case .api:
            return try await summarizeViaAnthropic(transcript: transcript, title: title)
        case .cursorAgent:
            return try await summarizeViaCursorAgent(transcript: transcript, title: title, workspaceDir: workspaceDir, transcriptDir: transcriptDir)
        }
    }

    private func summarizeViaAnthropic(transcript: String, title: String) async throws -> String {
        let settings = settingsStore.load()
        guard let key = secretsStore.get("anthropic_api_key"), !key.isEmpty else {
            throw TranscriptionError.missingAnthropicAPIKey
        }

        let prompt = """
        Сформируй краткий, структурированный конспект встречи в Markdown.
        Язык: русский.
        Обязательно:
        - Тема и цель встречи
        - Ключевые решения
        - Следующие шаги (кто/что/когда, если есть)
        - Риски/блокеры

        Заголовок встречи: \(title)
        Транскрипт:
        \(transcript)
        """

        let payload: [String: Any] = [
            "model": settings.summaryApiModel,
            "max_tokens": 2048,
            "messages": [
                [
                    "role": "user",
                    "content": prompt,
                ]
            ],
        ]

        let body = try JSONSerialization.data(withJSONObject: payload, options: [])
        var req = URLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
        req.httpMethod = "POST"
        req.timeoutInterval = 300
        req.httpBody = body
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
        req.setValue(key, forHTTPHeaderField: "x-api-key")

        let (data, response) = try await URLSession.shared.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw TranscriptionError.invalidResponse("non-http response")
        }
        guard (200...299).contains(http.statusCode) else {
            let text = String(data: data, encoding: .utf8) ?? ""
            throw TranscriptionError.invalidResponse("anthropic status \(http.statusCode): \(text.prefix(600))")
        }

        guard
            let root = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let content = root["content"] as? [[String: Any]]
        else {
            throw TranscriptionError.invalidResponse("malformed anthropic json")
        }

        let text = content.compactMap { $0["text"] as? String }.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionError.invalidResponse("empty summary")
        }
        return text
    }

    private func summarizeViaCursorAgent(transcript: String, title: String, workspaceDir: URL, transcriptDir: URL) async throws -> String {
        let settings = settingsStore.load()
        guard let bin = CursorAgentLocator.resolve(configured: settings.cursorAgentBin) else {
            let configured = settings.cursorAgentBin
            let pathHint = ProcessInfo.processInfo.environment["PATH"] ?? "(empty)"
            Logger.shared.error(
                "TranscriptionManager: Cursor agent not found (configured=\(configured), PATH=\(pathHint)). " +
                    "Set full path e.g. \(CursorAgentLocator.wellKnownPaths().first ?? "~/.local/bin/agent")"
            )
            throw TranscriptionError.cursorAgentNotFound
        }
        Logger.shared.info("TranscriptionManager: using Cursor agent at \(bin)")

        let promptFile = transcriptDir.appendingPathComponent("transcript_for_cursor.txt")
        try transcript.write(to: promptFile, atomically: true, encoding: .utf8)

        let prompt = """
        В этой директории есть файл transcribe/transcript_for_cursor.txt с транскриптом.
        Сделай структурированный конспект в Markdown на русском.
        Разделы:
        - Тема и цель
        - Что обсудили
        - Что решили
        - Следующие шаги
        - Риски
        Заголовок встречи: \(title)
        """

        let args = [
            "--print",
            "--mode", "ask",
            "--output-format", "text",
            "--trust",
            "--workspace", workspaceDir.path,
            "--model", settings.cursorModel,
            prompt,
        ]

        let output = try await runProcess(executable: bin, arguments: args, timeoutSec: 900)
        let text = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else {
            throw TranscriptionError.cursorAgentFailed("empty output")
        }
        return text
    }

    private func runProcess(executable: String, arguments: [String], timeoutSec: Int) async throws -> String {
        let proc = Process()
        let outPipe = Pipe()
        let errPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = errPipe

        let resolved = executable.contains("/")
            ? ((executable as NSString).expandingTildeInPath)
            : CursorAgentLocator.resolve(configured: executable)
        guard let bin = resolved, FileManager.default.isExecutableFile(atPath: bin) else {
            throw TranscriptionError.cursorAgentNotFound
        }
        proc.executableURL = URL(fileURLWithPath: bin)
        proc.arguments = arguments

        try proc.run()

        return try await withCheckedThrowingContinuation { (cont: CheckedContinuation<String, Error>) in
            let deadline = Date().addingTimeInterval(TimeInterval(timeoutSec))
            DispatchQueue.global().async {
                while proc.isRunning && Date() < deadline {
                    Thread.sleep(forTimeInterval: 0.25)
                }
                if proc.isRunning {
                    proc.terminate()
                    cont.resume(throwing: TranscriptionError.commandTimeout)
                    return
                }

                let out = String(data: outPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                if proc.terminationStatus != 0 {
                    cont.resume(throwing: TranscriptionError.cursorAgentFailed(err.isEmpty ? out : err))
                    return
                }
                cont.resume(returning: out)
            }
        }
    }
}
