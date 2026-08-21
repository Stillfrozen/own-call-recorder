import AppKit
import Foundation
import Network
import Security

final class LocalControlServer {
    static let shared = LocalControlServer()
    static let buildTag = "ocr-control-2026-08-21-r1"
    private static let maxRequestBytes = 64 * 1024

    private let settingsStore = SettingsStore.shared
    private let secretsStore = SecureSecretsStore.shared
    private let queue = DispatchQueue(label: "com.own-recorder.control-server")
    private var listener: NWListener?
    private(set) var port: UInt16 = 9780
    private var sessionToken = ""
    var onSettingsSaved: (() -> Void)?

    private init() {}

    func start(port: UInt16 = 9780) {
        guard listener == nil else { return }
        self.port = port
        sessionToken = Self.makeSessionToken()

        do {
            let params = NWParameters.tcp
            params.allowLocalEndpointReuse = true
            guard let loopback = IPv4Address("127.0.0.1"),
                  let nwPort = NWEndpoint.Port(rawValue: port) else {
                throw NSError(domain: "LocalControlServer", code: 1, userInfo: [
                    NSLocalizedDescriptionKey: "invalid loopback endpoint",
                ])
            }
            params.requiredLocalEndpoint = NWEndpoint.hostPort(host: .ipv4(loopback), port: nwPort)
            let listener = try NWListener(using: params)
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.stateUpdateHandler = { state in
                Logger.shared.info("LocalControlServer: state=\(state)")
            }
            listener.start(queue: queue)
            self.listener = listener
            Logger.shared.info("LocalControlServer: started on http://127.0.0.1:\(port) (loopback, token required)")
        } catch {
            Logger.shared.error("LocalControlServer: failed to start — \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        sessionToken = ""
    }

    var rootURL: URL {
        var comps = URLComponents()
        comps.scheme = "http"
        comps.host = "127.0.0.1"
        comps.port = Int(port)
        comps.path = "/"
        comps.queryItems = [URLQueryItem(name: "token", value: sessionToken)]
        return comps.url!
    }

    private static func makeSessionToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        let status = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        if status == errSecSuccess {
            return bytes.map { String(format: "%02x", $0) }.joined()
        }
        return UUID().uuidString.replacingOccurrences(of: "-", with: "")
            + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    }

    private func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let aa = Array(a.utf8)
        let bb = Array(b.utf8)
        guard aa.count == bb.count, !aa.isEmpty else { return false }
        var diff: UInt8 = 0
        for i in 0..<aa.count { diff |= aa[i] ^ bb[i] }
        return diff == 0
    }

    private func isAuthorized(_ req: HTTPRequest) -> Bool {
        guard !sessionToken.isEmpty else { return false }
        let provided = req.headers["x-own-recorder-token"] ?? req.queryItem("token") ?? ""
        return constantTimeEquals(provided, sessionToken)
    }

    private func isLoopback(_ connection: NWConnection) -> Bool {
        switch connection.currentPath?.remoteEndpoint {
        case .hostPort(let host, _):
            switch host {
            case .ipv4(let addr):
                return addr == IPv4Address("127.0.0.1")
            case .ipv6(let addr):
                return addr == IPv6Address("::1")
            case .name(let name, _):
                return name == "localhost" || name == "127.0.0.1" || name == "::1"
            @unknown default:
                return false
            }
        default:
            return true
        }
    }

    private func handle(connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state, !self.isLoopback(connection) {
                Logger.shared.warn("LocalControlServer: dropped non-loopback peer")
                connection.cancel()
            }
        }
        connection.start(queue: queue)
        readFullRequest(on: connection, accumulated: Data()) { [weak self] requestData in
            guard let self else {
                connection.cancel()
                return
            }
            guard let requestData, !requestData.isEmpty else {
                Logger.shared.warn("LocalControlServer: dropped empty/aborted request")
                self.send(response: .plain(400, "bad request: empty"), on: connection)
                return
            }
            Task {
                let response = await self.route(rawRequest: requestData)
                self.send(response: response, on: connection)
            }
        }
    }

    private func send(response: HTTPResponse, on connection: NWConnection) {
        connection.send(content: response.toData(), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    /// Read HTTP request until we have full headers + body according to Content-Length.
    private func readFullRequest(on connection: NWConnection, accumulated: Data, completion: @escaping (Data?) -> Void) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { [weak self] data, _, isComplete, error in
            guard let self else {
                completion(nil)
                return
            }
            if error != nil {
                completion(nil)
                return
            }

            var buffer = accumulated
            if let data { buffer.append(data) }
            if buffer.count > Self.maxRequestBytes + 4096 {
                completion(nil)
                return
            }

            if let fullLength = Self.fullHTTPRequestLength(in: buffer), buffer.count >= fullLength {
                completion(buffer.subdata(in: 0..<fullLength))
                return
            }

            if isComplete {
                completion(buffer.isEmpty ? nil : buffer)
                return
            }

            self.readFullRequest(on: connection, accumulated: buffer, completion: completion)
        }
    }

    private static func fullHTTPRequestLength(in data: Data) -> Int? {
        guard let headerEnd = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerData = data.subdata(in: 0..<headerEnd.upperBound)
        let headerText = String(decoding: headerData, as: UTF8.self)
        let requestLine = headerText.components(separatedBy: "\r\n").first ?? ""
        let method = requestLine.split(separator: " ").first.map(String.init)?.uppercased() ?? ""

        let lower = headerText.lowercased()
        if lower.contains("transfer-encoding: chunked") {
            let bodyStart = headerEnd.upperBound
            let bodyData = data.count > bodyStart ? data.subdata(in: bodyStart..<data.count) : Data()
            guard let chunkedBytesLen = chunkedWireLength(bodyData) else { return nil }
            return bodyStart + chunkedBytesLen
        }

        var contentLength = 0
        var hasContentLength = false
        for line in headerText.components(separatedBy: "\r\n") {
            if line.lowercased().hasPrefix("content-length:") {
                let raw = line.split(separator: ":", maxSplits: 1).map(String.init).last ?? ""
                contentLength = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                hasContentLength = true
                break
            }
        }
        if hasContentLength {
            if contentLength > maxRequestBytes { return headerEnd.upperBound + contentLength }
            return headerEnd.upperBound + contentLength
        }
        // For methods that normally have no body, headers are enough.
        if method == "GET" || method == "HEAD" || method == "OPTIONS" {
            return headerEnd.upperBound
        }
        // Unknown body size (no Content-Length, not chunked): wait for socket completion.
        return nil
    }

    /// Returns total wire bytes occupied by a full chunked body (incl. chunk metadata), else nil.
    private static func chunkedWireLength(_ data: Data) -> Int? {
        var idx = 0
        while true {
            guard let lineEnd = data.range(of: Data("\r\n".utf8), in: idx..<data.count) else { return nil }
            let sizeLineData = data.subdata(in: idx..<lineEnd.lowerBound)
            let sizeLine = String(decoding: sizeLineData, as: UTF8.self)
            let sizeHex = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeHex.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else { return nil }

            let payloadStart = lineEnd.upperBound
            let payloadEnd = payloadStart + size
            let chunkEnd = payloadEnd + 2 // trailing CRLF after payload
            guard chunkEnd <= data.count else { return nil }
            guard data.subdata(in: payloadEnd..<chunkEnd) == Data("\r\n".utf8) else { return nil }

            idx = chunkEnd
            if size == 0 {
                // End marker chunk, optional trailers end with extra CRLF.
                if idx + 2 <= data.count, data.subdata(in: idx..<(idx + 2)) == Data("\r\n".utf8) {
                    idx += 2
                }
                return idx
            }
        }
    }

    private func route(rawRequest: Data) async -> HTTPResponse {
        guard let req = HTTPRequest.parse(rawRequest) else {
            Logger.shared.error("LocalControlServer: HTTP parse failed (\(rawRequest.count) B)")
            return .plain(400, "bad request: parse failed")
        }

        if req.body.count > Self.maxRequestBytes {
            return .plain(413, "payload too large")
        }

        Logger.shared.info("LocalControlServer: \(req.method) \(req.path) body=\(req.body.count) B")

        guard isAuthorized(req) else {
            Logger.shared.warn("LocalControlServer: unauthorized \(req.method) \(req.path)")
            if req.method == "GET" && req.path == "/" {
                return .html(401, Self.unauthorizedHTML)
            }
            return .json(401, ["ok": false, "error": "unauthorized"])
        }

        let response: HTTPResponse
        switch (req.method, req.path) {
        case ("GET", "/"):
            response = .html(200, Self.dashboardHTML)
        case ("GET", "/api/state"):
            response = .json(200, stateJSON())
        case ("GET", "/api/settings"):
            response = .json(200, stateJSON())
        case ("GET", "/api/logs"):
            let lines = req.queryItem("lines").flatMap(Int.init) ?? 200
            response = .json(200, ["logs": tailLog(lines: max(10, min(lines, 1000)))])
        case ("POST", "/api/settings"):
            response = saveSettings(req.body)
        case ("POST", "/api/check/xai"):
            let key = req.jsonBody()?["key"] as? String ?? ""
            let ok = await checkXAIKey(key)
            response = .json(200, ["ok": ok])
        case ("POST", "/api/check/groq"):
            let key = req.jsonBody()?["key"] as? String ?? ""
            let ok = await checkGroqKey(key)
            response = .json(200, ["ok": ok])
        case ("POST", "/api/check/anthropic"):
            let key = req.jsonBody()?["key"] as? String ?? ""
            let ok = await checkAnthropicKey(key)
            response = .json(200, ["ok": ok])
        default:
            if let recordsResponse = await routeRecords(req) {
                response = recordsResponse
            } else {
                response = .plain(404, "not found")
            }
        }

        if response.status >= 400 {
            Logger.shared.warn("LocalControlServer: \(req.method) \(req.path) -> \(response.status)")
        }
        return response.withHeader("X-Own-Recorder-Build", Self.buildTag)
    }

    private func stateJSON() -> [String: Any] {
        let settings = settingsStore.load()
        let xaiKey = secretsStore.get("xai_api_key") ?? secretsStore.get("groq_api_key") ?? ""
        let groqKey = secretsStore.get("groq_whisper_api_key") ?? ""
        let anthropicKey = secretsStore.get("anthropic_api_key") ?? ""
        return [
            "summaryProvider": settings.summaryProvider.rawValue,
            "sttProvider": settings.sttProvider.rawValue,
            "xaiSttLanguage": settings.xaiSttLanguage,
            "groqModel": settings.groqModel,
            "summaryApiModel": settings.summaryApiModel,
            "cursorAgentBin": settings.cursorAgentBin,
            "cursorModel": settings.cursorModel,
            "startHotkey": settings.startHotkey,
            "stopHotkey": settings.stopHotkey,
            "notificationsEnabled": settings.notificationsEnabled,
            "hasXaiKey": !xaiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "hasGroqKey": !groqKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "hasAnthropicKey": !anthropicKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            "recordsRoot": RecordsArchive.rootDirectory().path,
            "logFile": RecorderLogger.logFileURL().path,
        ]
    }

    private func persistSecretIfPresent(_ raw: Any?, key: String) throws {
        guard let text = raw as? String else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        try secretsStore.set(trimmed, for: key)
    }

    private func saveSettings(_ body: Data) -> HTTPResponse {
        guard !body.isEmpty else {
            Logger.shared.error("saveSettings: empty body")
            return .json(400, ["ok": false, "error": "empty body"])
        }
        let parsed: Any?
        do {
            parsed = try JSONSerialization.jsonObject(with: body)
        } catch {
            Logger.shared.error("saveSettings: JSON parse failed (\(body.count) B) — \(error.localizedDescription)")
            return .json(400, ["ok": false, "error": "invalid json: \(error.localizedDescription)"])
        }
        guard let obj = parsed as? [String: Any] else {
            Logger.shared.error("saveSettings: JSON is not an object")
            return .json(400, ["ok": false, "error": "expected JSON object"])
        }

        let summaryRaw = (obj["summaryProvider"] as? String) ?? SummaryProvider.api.rawValue
        let summary = SummaryProvider(rawValue: summaryRaw) ?? .api

        let settings = RecorderSettings(
            summaryProvider: summary,
            sttProvider: STTProvider(rawValue: (obj["sttProvider"] as? String ?? STTProvider.xai.rawValue)) ?? .xai,
            xaiSttLanguage: (obj["xaiSttLanguage"] as? String ?? "ru").trimmingCharacters(in: .whitespacesAndNewlines),
            groqModel: (obj["groqModel"] as? String ?? "whisper-large-v3-turbo").trimmingCharacters(in: .whitespacesAndNewlines),
            summaryApiModel: (obj["summaryApiModel"] as? String ?? "claude-sonnet-4-20250514").trimmingCharacters(in: .whitespacesAndNewlines),
            cursorAgentBin: (obj["cursorAgentBin"] as? String ?? "agent").trimmingCharacters(in: .whitespacesAndNewlines),
            cursorModel: (obj["cursorModel"] as? String ?? "sonnet-4").trimmingCharacters(in: .whitespacesAndNewlines),
            startHotkey: (obj["startHotkey"] as? String ?? "cmd+shift+9").trimmingCharacters(in: .whitespacesAndNewlines),
            stopHotkey: (obj["stopHotkey"] as? String ?? "cmd+shift+0").trimmingCharacters(in: .whitespacesAndNewlines),
            notificationsEnabled: (obj["notificationsEnabled"] as? Bool) ?? true
        )

        var hotkeyWarning: String?
        do {
            _ = try GlobalHotkeyManager.parseShortcut(settings.startHotkey)
            _ = try GlobalHotkeyManager.parseShortcut(settings.stopHotkey)
        } catch {
            hotkeyWarning = "invalid hotkey format"
        }

        do {
            settingsStore.save(settings)
            try persistSecretIfPresent(obj["xaiApiKey"], key: "xai_api_key")
            if let xai = obj["xaiApiKey"] as? String, !xai.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                try secretsStore.set(xai.trimmingCharacters(in: .whitespacesAndNewlines), for: "groq_api_key")
            }
            try persistSecretIfPresent(obj["groqApiKey"], key: "groq_whisper_api_key")
            try persistSecretIfPresent(obj["anthropicApiKey"], key: "anthropic_api_key")
            onSettingsSaved?()
            if let hotkeyWarning {
                return .json(200, ["ok": true, "warning": hotkeyWarning])
            }
            return .json(200, ["ok": true])
        } catch {
            return .json(500, ["ok": false, "error": "\(error)"])
        }
    }

    private func tailLog(lines: Int) -> String {
        let path = RecorderLogger.logFileURL().path
        guard let raw = try? String(contentsOfFile: path, encoding: .utf8) else {
            return "(no log file yet)"
        }
        let all = raw.split(separator: "\n", omittingEmptySubsequences: false)
        return all.suffix(lines).joined(separator: "\n")
    }

    private func resolvedSecret(submitted: String, storedKeys: [String]) -> String {
        let trimmed = submitted.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { return trimmed }
        for key in storedKeys {
            if let stored = secretsStore.get(key)?.trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
                return stored
            }
        }
        return ""
    }

    private func checkXAIKey(_ key: String) async -> Bool {
        let trimmed = resolvedSecret(submitted: key, storedKeys: ["xai_api_key", "groq_api_key"])
        guard !trimmed.isEmpty else { return false }
        guard let url = URL(string: "https://api.x.ai/v1/models") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func checkGroqKey(_ key: String) async -> Bool {
        let trimmed = resolvedSecret(submitted: key, storedKeys: ["groq_whisper_api_key"])
        guard !trimmed.isEmpty else { return false }
        guard let url = URL(string: "https://api.groq.com/openai/v1/models") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue("Bearer \(trimmed)", forHTTPHeaderField: "Authorization")

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }

    private func routeRecords(_ req: HTTPRequest) async -> HTTPResponse? {
        let path = req.path
        if req.method == "GET" && path == "/api/records" {
            return await recordsListResponse()
        }
        guard path.hasPrefix("/api/records/") else { return nil }
        let rest = String(path.dropFirst("/api/records/".count))
        let parts = rest.split(separator: "/").map(String.init)
        guard let rawSessionId = parts.first, !rawSessionId.isEmpty else { return .plain(404, "not found") }
        let sessionId = rawSessionId.removingPercentEncoding ?? rawSessionId
        let action = parts.count > 1 ? parts[1] : nil

        switch (req.method, action) {
        case ("GET", nil), ("GET", ""):
            return await recordDetailResponse(sessionId: sessionId)
        case ("GET", "status"):
            return await recordStatusResponse(sessionId: sessionId)
        case ("POST", "reprocess"):
            return await recordReprocessResponse(sessionId: sessionId)
        case ("POST", "reveal"):
            return recordRevealResponse(sessionId: sessionId)
        default:
            return .plain(404, "not found")
        }
    }

    private func processingSnapshot() async -> (ids: Set<String>, stages: [String: String]) {
        await MainActor.run { TranscriptionJobRunner.shared.processingSnapshot() }
    }

    private func recordsListResponse() async -> HTTPResponse {
        let snapshot = await processingSnapshot()
        let entries = RecordsIndex.listAll(
            processingSessionIds: snapshot.ids,
            stages: snapshot.stages
        )
        return .json(200, [
            "recordsRoot": RecordsArchive.rootDirectory().path,
            "records": entries.map { $0.asJSONObject() },
        ])
    }

    private func recordDetailResponse(sessionId: String) async -> HTTPResponse {
        let snapshot = await processingSnapshot()
        guard let entry = RecordsIndex.entry(
            forSessionId: sessionId,
            processingSessionIds: snapshot.ids,
            stages: snapshot.stages
        ) else {
            return .json(404, ["ok": false, "error": "session not found"])
        }
        return .json(200, ["ok": true, "record": entry.asJSONObject()])
    }

    private func recordStatusResponse(sessionId: String) async -> HTTPResponse {
        let snapshot = await processingSnapshot()
        guard let entry = RecordsIndex.entry(
            forSessionId: sessionId,
            processingSessionIds: snapshot.ids,
            stages: snapshot.stages
        ) else {
            return .json(404, ["ok": false, "error": "session not found"])
        }
        return .json(200, [
            "ok": true,
            "status": entry.status,
            "stage": entry.stage as Any,
            "error": entry.lastError as Any,
        ])
    }

    private func recordReprocessResponse(sessionId: String) async -> HTTPResponse {
        let started = await MainActor.run { TranscriptionJobRunner.shared.startReprocess(sessionId: sessionId) }
        if !started {
            if RecordsIndex.sessionDirectory(forSessionId: sessionId) == nil {
                return .json(404, ["ok": false, "error": "session not found"])
            }
            return .json(409, ["ok": false, "error": "already processing"])
        }
        return .json(200, ["ok": true, "sessionId": sessionId, "status": RecordSessionStatus.processing.rawValue])
    }

    private func recordRevealResponse(sessionId: String) -> HTTPResponse {
        guard let sessionDir = RecordsIndex.sessionDirectory(forSessionId: sessionId) else {
            return .json(404, ["ok": false, "error": "session not found"])
        }
        NSWorkspace.shared.activateFileViewerSelecting([sessionDir])
        return .json(200, ["ok": true, "sessionPath": sessionDir.path])
    }

    private func checkAnthropicKey(_ key: String) async -> Bool {
        let trimmed = resolvedSecret(submitted: key, storedKeys: ["anthropic_api_key"])
        guard !trimmed.isEmpty else { return false }
        guard let url = URL(string: "https://api.anthropic.com/v1/models") else { return false }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        req.setValue(trimmed, forHTTPHeaderField: "x-api-key")
        req.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")

        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            guard let http = response as? HTTPURLResponse else { return false }
            return (200...299).contains(http.statusCode)
        } catch {
            return false
        }
    }
}

private struct HTTPRequest {
    let method: String
    let path: String
    let rawPath: String
    let headers: [String: String]
    let body: Data

    static func parse(_ data: Data) -> HTTPRequest? {
        guard let headerEndRange = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headerBytes = data.subdata(in: 0..<headerEndRange.lowerBound)
        let bodyStart = headerEndRange.upperBound
        let rawBody = data.count > bodyStart ? data.subdata(in: bodyStart..<data.count) : Data()

        guard let headerText = String(data: headerBytes, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let parts = requestLine.components(separatedBy: " ")
        guard parts.count >= 2 else { return nil }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let p = line.split(separator: ":", maxSplits: 1).map(String.init)
            if p.count == 2 {
                headers[p[0].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()] =
                    p[1].trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }

        let rawPath = parts[1]
        let path = rawPath.split(separator: "?", maxSplits: 1).map(String.init).first ?? rawPath
        let isChunked = (headers["transfer-encoding"] ?? "").lowercased().contains("chunked")
        let bodyData = isChunked ? (dechunk(rawBody) ?? Data()) : rawBody
        return HTTPRequest(method: parts[0].uppercased(), path: path, rawPath: rawPath, headers: headers, body: bodyData)
    }

    func queryItem(_ name: String) -> String? {
        guard let comps = URLComponents(string: "http://localhost\(rawPath)") else { return nil }
        return comps.queryItems?.first(where: { $0.name == name })?.value
    }

    func jsonBody() -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
    }

    private static func dechunk(_ data: Data) -> Data? {
        var idx = 0
        var out = Data()

        while true {
            guard let lineEnd = data.range(of: Data("\r\n".utf8), in: idx..<data.count) else { return nil }
            let sizeLineData = data.subdata(in: idx..<lineEnd.lowerBound)
            let sizeLine = String(decoding: sizeLineData, as: UTF8.self)
            let sizeHex = sizeLine.split(separator: ";", maxSplits: 1).first.map(String.init) ?? ""
            guard let size = Int(sizeHex.trimmingCharacters(in: .whitespacesAndNewlines), radix: 16) else { return nil }

            let payloadStart = lineEnd.upperBound
            let payloadEnd = payloadStart + size
            let chunkEnd = payloadEnd + 2
            guard chunkEnd <= data.count else { return nil }
            guard data.subdata(in: payloadEnd..<chunkEnd) == Data("\r\n".utf8) else { return nil }

            if size > 0 {
                out.append(data.subdata(in: payloadStart..<payloadEnd))
            }
            idx = chunkEnd
            if size == 0 {
                return out
            }
        }
    }
}

private struct HTTPResponse {
    let status: Int
    let headers: [String: String]
    let body: Data

    func toData() -> Data {
        var text = "HTTP/1.1 \(status) \(statusText(status))\r\n"
        var h = headers
        h["Content-Length"] = "\(body.count)"
        h["Connection"] = "close"
        for (k, v) in h {
            text += "\(k): \(v)\r\n"
        }
        text += "\r\n"
        var out = Data(text.utf8)
        out.append(body)
        return out
    }

    static func html(_ status: Int, _ html: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/html; charset=utf-8"], body: Data(html.utf8))
    }

    static func plain(_ status: Int, _ text: String) -> HTTPResponse {
        HTTPResponse(status: status, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8))
    }

    static func json(_ status: Int, _ object: [String: Any]) -> HTTPResponse {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted])) ?? Data("{}".utf8)
        return HTTPResponse(status: status, headers: ["Content-Type": "application/json; charset=utf-8"], body: data)
    }

    func withHeader(_ key: String, _ value: String) -> HTTPResponse {
        var h = headers
        h[key] = value
        return HTTPResponse(status: status, headers: h, body: body)
    }
}

private func statusText(_ code: Int) -> String {
    switch code {
    case 200: return "OK"
    case 400: return "Bad Request"
    case 401: return "Unauthorized"
    case 404: return "Not Found"
    case 409: return "Conflict"
    case 413: return "Payload Too Large"
    case 500: return "Internal Server Error"
    default: return "HTTP"
    }
}

extension LocalControlServer {
    static let unauthorizedHTML = """
<!doctype html>
<html lang="ru"><head><meta charset="utf-8" /><title>Own Recorder</title></head>
<body>
  <p>Панель настроек открывается только из меню приложения («Настройки…»). Не сохраняйте эту страницу в закладки.</p>
</body></html>
"""

    static let dashboardHTML = """
<!doctype html>
<html lang="ru">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <title>Own Recorder Control</title>
  <style>
    body { font: 14px -apple-system, BlinkMacSystemFont, sans-serif; margin: 18px; color: #111; }
    h1 { margin: 0 0 12px 0; }
    .row { display: grid; grid-template-columns: 240px 1fr auto; gap: 8px; margin: 8px 0; align-items: center; }
    input, select { width: 100%; padding: 6px; }
    button { padding: 6px 10px; }
    #logs { width: 100%; min-height: 320px; font: 12px Menlo, monospace; white-space: pre; }
    .ok { color: #0a7a00; font-weight: 600; } .bad { color: #b00020; font-weight: 600; } .pending { color:#666; }
    .panel { border: 1px solid #ddd; border-radius: 8px; padding: 12px; margin-top: 14px; }
    table.records { width: 100%; border-collapse: collapse; font-size: 13px; }
    table.records th, table.records td { border-bottom: 1px solid #eee; padding: 6px 8px; text-align: left; vertical-align: top; }
    table.records td.path { font: 11px Menlo, monospace; color: #444; max-width: 280px; word-break: break-all; }
    .badge { display: inline-block; padding: 2px 8px; border-radius: 10px; font-size: 11px; font-weight: 600; }
    .badge.complete { background: #e6f4ea; color: #0a7a00; }
    .badge.transcribed_only { background: #e8f0fe; color: #1a56db; }
    .badge.audio_only { background: #f3f4f6; color: #444; }
    .badge.failed { background: #fde8e8; color: #b00020; }
    .badge.processing { background: #fff4e5; color: #9a6700; }
    .err-hint { font-size: 11px; color: #b00020; margin-top: 4px; max-width: 260px; }
    .rec-actions button { margin-right: 6px; margin-bottom: 4px; }
  </style>
</head>
<body>
  <h1>Own Recorder — localhost control</h1>
  <div id="status" class="pending">Загрузка...</div>

  <div class="panel">
    <h3>Настройки</h3>
    <div class="row"><label>STT provider</label>
      <select id="sttProvider"><option value="xai">Grok AI (xAI)</option><option value="groq">Groq Whisper (free)</option></select><span></span>
    </div>
    <div class="row"><label>Summary provider</label>
      <select id="summaryProvider"><option value="api">API</option><option value="cursor_agent">Cursor Agent</option></select><span></span>
    </div>
    <div class="row"><label>xAI API key (Grok/fallback)</label><input id="xaiApiKey" type="password" autocomplete="off" /><span id="xaiHealth">—</span></div>
    <div class="row"><label>Groq API key (Whisper free)</label><input id="groqApiKey" type="password" autocomplete="off" /><span id="groqHealth">—</span></div>
    <div class="row"><label>Groq Whisper model</label><input id="groqModel" /><span></span></div>
    <div class="row"><label></label><div class="pending">При сбое Groq STT (таймаут, 429, 5xx, сеть) автоматически переключается на Grok AI (xAI).</div><span></span></div>
    <div class="row"><label>Anthropic API key</label><input id="anthropicApiKey" type="password" autocomplete="off" /><span id="anthropicHealth">—</span></div>
    <div class="row"><label>xAI STT language</label><input id="xaiSttLanguage" /><span></span></div>
    <div class="row"><label>Summary API model</label><input id="summaryApiModel" /><span></span></div>
    <div class="row"><label>Cursor agent binary</label><input id="cursorAgentBin" /><span></span></div>
    <div class="row"><label>Cursor model</label><input id="cursorModel" /><span></span></div>
    <div class="row"><label>Start hotkey</label><input id="startHotkey" /><span></span></div>
    <div class="row"><label>Stop hotkey</label><input id="stopHotkey" /><span></span></div>
    <div class="row"><label>Notifications enabled</label><input type="checkbox" id="notificationsEnabled" /><span></span></div>
    <div class="row"><label>Records root</label><input id="recordsRoot" readonly /><span></span></div>
    <div class="row"><label>Log file</label><input id="logFile" readonly /><span></span></div>
    <div style="margin-top:10px;">
      <button onclick="save()">Сохранить</button>
      <span id="saveStatus" class="pending"></span>
    </div>
  </div>

  <div class="panel">
    <h3>Записи</h3>
    <div style="margin-bottom:8px;">
      <button onclick="refreshRecords()">Обновить список</button>
      <span id="recordsStatus" class="pending"></span>
    </div>
    <div style="overflow-x:auto;">
      <table class="records">
        <thead>
          <tr>
            <th>Дата</th>
            <th>Название</th>
            <th>Статус</th>
            <th>Путь</th>
            <th>Действия</th>
          </tr>
        </thead>
        <tbody id="recordsBody"></tbody>
      </table>
    </div>
  </div>

  <div class="panel">
    <h3>Логи</h3>
    <div style="margin-bottom:8px;"><button onclick="refreshLogs()">Обновить</button></div>
    <textarea id="logs" readonly></textarea>
  </div>

<script>
const TOKEN = new URLSearchParams(location.search).get('token') || '';
function api(path, opts) {
  const u = new URL(path, location.origin);
  if (TOKEN) u.searchParams.set('token', TOKEN);
  const headers = Object.assign({ 'X-Own-Recorder-Token': TOKEN }, (opts && opts.headers) || {});
  return fetch(u.toString(), Object.assign({}, opts || {}, { headers }));
}

let xaiTimer = null, groqTimer = null, anthTimer = null;

function setHealth(id, state) {
  const el = document.getElementById(id);
  if (state === 'ok') { el.textContent = '✅'; el.className = 'ok'; return; }
  if (state === 'bad') { el.textContent = '❌'; el.className = 'bad'; return; }
  if (state === 'pending') { el.textContent = '…'; el.className = 'pending'; return; }
  el.textContent = '—'; el.className = 'pending';
}

async function loadState() {
  const resp = await api('/api/state'); const s = await resp.json();
  for (const k of Object.keys(s)) {
    if (k === 'hasXaiKey' || k === 'hasGroqKey' || k === 'hasAnthropicKey') continue;
    const el = document.getElementById(k);
    if (!el) continue;
    if (el.type === 'checkbox') el.checked = !!s[k]; else el.value = s[k] ?? '';
  }
  document.getElementById('xaiApiKey').placeholder = s.hasXaiKey ? 'сохранён в Keychain' : '';
  document.getElementById('groqApiKey').placeholder = s.hasGroqKey ? 'сохранён в Keychain' : '';
  document.getElementById('anthropicApiKey').placeholder = s.hasAnthropicKey ? 'сохранён в Keychain' : '';
  document.getElementById('status').textContent = 'Готово';
}

async function save() {
  const payload = {
    sttProvider: document.getElementById('sttProvider').value,
    summaryProvider: document.getElementById('summaryProvider').value,
    groqModel: document.getElementById('groqModel').value,
    xaiSttLanguage: document.getElementById('xaiSttLanguage').value,
    summaryApiModel: document.getElementById('summaryApiModel').value,
    cursorAgentBin: document.getElementById('cursorAgentBin').value,
    cursorModel: document.getElementById('cursorModel').value,
    startHotkey: document.getElementById('startHotkey').value,
    stopHotkey: document.getElementById('stopHotkey').value,
    notificationsEnabled: document.getElementById('notificationsEnabled').checked,
  };
  const xai = document.getElementById('xaiApiKey').value.trim();
  const groq = document.getElementById('groqApiKey').value.trim();
  const anth = document.getElementById('anthropicApiKey').value.trim();
  if (xai) payload.xaiApiKey = xai;
  if (groq) payload.groqApiKey = groq;
  if (anth) payload.anthropicApiKey = anth;
  const status = document.getElementById('saveStatus');
  status.textContent = 'Сохраняем…'; status.className = 'pending';
  try {
    const resp = await api('/api/settings', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(payload) });
    const build = resp.headers.get('X-Own-Recorder-Build') || '?';
    const raw = await resp.text();
    let r = {};
    try { r = JSON.parse(raw); } catch (e) { r = { error: 'non-json response: ' + raw.slice(0, 200) }; }
    if (resp.ok && r.ok) {
      status.textContent = (r.warning ? ('Сохранено с предупреждением: ' + r.warning) : 'Сохранено') + ' [' + build + ']';
      status.className = r.warning ? 'pending' : 'ok';
      document.getElementById('xaiApiKey').value = '';
      document.getElementById('groqApiKey').value = '';
      document.getElementById('anthropicApiKey').value = '';
      await loadState();
    } else {
      status.textContent = 'Ошибка ' + resp.status + ': ' + (r.error || raw.slice(0, 200)) + ' [' + build + ']';
      status.className = 'bad';
    }
  } catch (e) {
    status.textContent = 'Сеть/таймаут: ' + (e && e.message ? e.message : e);
    status.className = 'bad';
  }
}

async function refreshLogs() {
  const resp = await api('/api/logs?lines=300'); const r = await resp.json();
  const ta = document.getElementById('logs'); ta.value = r.logs || ''; ta.scrollTop = ta.scrollHeight;
}

async function checkXAI() {
  setHealth('xaiHealth', 'pending');
  const key = document.getElementById('xaiApiKey').value.trim();
  const resp = await api('/api/check/xai', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({key}) });
  const r = await resp.json().catch(() => ({ok:false}));
  setHealth('xaiHealth', r.ok ? 'ok' : 'bad');
}

async function checkGroq() {
  setHealth('groqHealth', 'pending');
  const key = document.getElementById('groqApiKey').value.trim();
  const resp = await api('/api/check/groq', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({key}) });
  const r = await resp.json().catch(() => ({ok:false}));
  setHealth('groqHealth', r.ok ? 'ok' : 'bad');
}

async function checkAnthropic() {
  setHealth('anthropicHealth', 'pending');
  const key = document.getElementById('anthropicApiKey').value.trim();
  const resp = await api('/api/check/anthropic', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({key}) });
  const r = await resp.json().catch(() => ({ok:false}));
  setHealth('anthropicHealth', r.ok ? 'ok' : 'bad');
}

function debounceChecks() {
  clearTimeout(xaiTimer); clearTimeout(groqTimer); clearTimeout(anthTimer);
  xaiTimer = setTimeout(checkXAI, 500);
  groqTimer = setTimeout(checkGroq, 500);
  anthTimer = setTimeout(checkAnthropic, 500);
}

document.getElementById('xaiApiKey').addEventListener('input', () => { clearTimeout(xaiTimer); xaiTimer = setTimeout(checkXAI, 500); });
document.getElementById('groqApiKey').addEventListener('input', () => { clearTimeout(groqTimer); groqTimer = setTimeout(checkGroq, 500); });
document.getElementById('anthropicApiKey').addEventListener('input', () => { clearTimeout(anthTimer); anthTimer = setTimeout(checkAnthropic, 500); });

const statusLabels = {
  complete: 'Готово',
  transcribed_only: 'Только транскрипт',
  audio_only: 'Только аудио',
  failed: 'Ошибка',
  processing: 'Обработка…',
};

function formatStartedAt(iso) {
  if (!iso) return '—';
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return iso;
  return d.toLocaleString('ru-RU');
}

function statusBadge(rec) {
  const st = rec.status || 'audio_only';
  const stage = rec.stage ? (' (' + rec.stage + ')') : '';
  return '<span class="badge ' + st + '">' + (statusLabels[st] || st) + stage + '</span>';
}

async function refreshRecords() {
  const statusEl = document.getElementById('recordsStatus');
  statusEl.textContent = 'Загрузка…'; statusEl.className = 'pending';
  try {
    const resp = await api('/api/records');
    const data = await resp.json();
    const body = document.getElementById('recordsBody');
    body.innerHTML = '';
    const records = data.records || [];
    if (!records.length) {
      body.innerHTML = '<tr><td colspan="5" class="pending">Записей пока нет</td></tr>';
    } else {
      for (const rec of records) {
        const sid = encodeURIComponent(rec.sessionId);
        const err = rec.lastError ? '<div class="err-hint">' + rec.lastError.replace(/</g,'&lt;') + '</div>' : '';
        const busy = rec.status === 'processing';
        const tr = document.createElement('tr');
        tr.innerHTML =
          '<td>' + formatStartedAt(rec.startedAt) + '</td>' +
          '<td>' + (rec.title || rec.sessionId).replace(/</g,'&lt;') + '</td>' +
          '<td>' + statusBadge(rec) + err + '</td>' +
          '<td class="path" title="' + (rec.sessionPath || '').replace(/"/g,'&quot;') + '">' + (rec.sessionPath || '—').replace(/</g,'&lt;') + '</td>' +
          '<td class="rec-actions">' +
            '<button onclick="revealRecord(\\'' + sid + '\\')">Finder</button>' +
            '<button onclick="reprocessRecord(\\'' + sid + '\\')" ' + (busy ? 'disabled' : '') + '>Перезапустить</button>' +
          '</td>';
        body.appendChild(tr);
      }
    }
    statusEl.textContent = records.length + ' записей';
    statusEl.className = 'ok';
  } catch (e) {
    statusEl.textContent = 'Ошибка: ' + (e && e.message ? e.message : e);
    statusEl.className = 'bad';
  }
}

async function reprocessRecord(sessionIdEnc) {
  const statusEl = document.getElementById('recordsStatus');
  statusEl.textContent = 'Запуск…'; statusEl.className = 'pending';
  try {
    const resp = await api('/api/records/' + sessionIdEnc + '/reprocess', { method: 'POST' });
    const r = await resp.json().catch(() => ({}));
    if (!resp.ok) {
      statusEl.textContent = r.error || ('HTTP ' + resp.status);
      statusEl.className = 'bad';
    } else {
      statusEl.textContent = 'Перезапуск принят';
      statusEl.className = 'ok';
    }
    await refreshRecords();
  } catch (e) {
    statusEl.textContent = 'Сеть: ' + (e && e.message ? e.message : e);
    statusEl.className = 'bad';
  }
}

async function revealRecord(sessionIdEnc) {
  try {
    await api('/api/records/' + sessionIdEnc + '/reveal', { method: 'POST' });
  } catch (e) {
    alert('Не удалось открыть Finder: ' + (e && e.message ? e.message : e));
  }
}

loadState().then(() => { refreshLogs(); refreshRecords(); debounceChecks(); });
setInterval(refreshLogs, 4000);
setInterval(refreshRecords, 8000);
</script>
</body>
</html>
"""
}
