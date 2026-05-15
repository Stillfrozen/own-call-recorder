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

    func process(audioURL: URL, title: String, startedAt: Date, uploadID: String) async throws -> TranscriptionArtifacts {
        let sessionDir = audioURL.deletingLastPathComponent().deletingLastPathComponent()
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
        ]
        let metadataData = try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted])
        try metadataData.write(to: metadataURL)

        Logger.shared.info("TranscriptionManager: artifacts written in \(sessionDir.path)")
        return TranscriptionArtifacts(transcriptURL: transcriptURL, summaryURL: summaryURL, metadataURL: metadataURL)
    }

    private func transcribeWithProviderSelection(audioURL: URL) async throws -> STTResult {
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
        guard case let TranscriptionError.invalidResponse(msg) = error else { return false }
        if msg.contains("status 429") { return true }
        if msg.contains("status 500") || msg.contains("status 502") || msg.contains("status 503") || msg.contains("status 504") { return true }
        return false
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
        req.timeoutInterval = 300

        let (data, response) = try await URLSession.shared.upload(for: req, from: body)
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
        req.timeoutInterval = 300

        let (data, response) = try await URLSession.shared.upload(for: req, from: body)
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
        let bin = settings.cursorAgentBin.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !bin.isEmpty else { throw TranscriptionError.cursorAgentNotFound }

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

        if executable.contains("/") {
            proc.executableURL = URL(fileURLWithPath: executable)
        } else if let resolved = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map({ URL(fileURLWithPath: String($0)).appendingPathComponent(executable).path })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        {
            proc.executableURL = URL(fileURLWithPath: resolved)
        } else {
            throw TranscriptionError.cursorAgentNotFound
        }
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
