import Foundation
import Network

final class LocalControlServer {
    static let shared = LocalControlServer()
    static let buildTag = "ocr-control-2026-05-15-r3"

    private let settingsStore = SettingsStore.shared
    private let secretsStore = SecureSecretsStore.shared
    private let queue = DispatchQueue(label: "com.own-recorder.control-server")
    private var listener: NWListener?
    private(set) var port: UInt16 = 9780
    var onSettingsSaved: (() -> Void)?

    private init() {}

    func start(port: UInt16 = 9780) {
        guard listener == nil else { return }
        self.port = port

        do {
            let params = NWParameters.tcp
            let listener = try NWListener(using: params, on: NWEndpoint.Port(integerLiteral: port))
            listener.newConnectionHandler = { [weak self] connection in
                self?.handle(connection: connection)
            }
            listener.stateUpdateHandler = { state in
                Logger.shared.info("LocalControlServer: state=\(state)")
            }
            listener.start(queue: queue)
            self.listener = listener
            Logger.shared.info("LocalControlServer: started on http://127.0.0.1:\(port)")
        } catch {
            Logger.shared.error("LocalControlServer: failed to start — \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    var rootURL: URL {
        URL(string: "http://127.0.0.1:\(port)/")!
    }

    private func handle(connection: NWConnection) {
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
            let snippet = String(data: rawRequest.prefix(400), encoding: .utf8) ?? "<binary \(rawRequest.count) B>"
            Logger.shared.error("LocalControlServer: HTTP parse failed (\(rawRequest.count) B). raw=\(snippet)")
            return .plain(400, "bad request: parse failed")
        }

        Logger.shared.info("LocalControlServer: \(req.method) \(req.rawPath) body=\(req.body.count) B")

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
            response = .plain(404, "not found")
        }

        if response.status >= 400 {
            Logger.shared.warn("LocalControlServer: \(req.method) \(req.path) -> \(response.status)")
        }
        return response.withHeader("X-Own-Recorder-Build", Self.buildTag)
    }

    private func stateJSON() -> [String: Any] {
        let settings = settingsStore.load()
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
            "xaiApiKey": secretsStore.get("xai_api_key") ?? secretsStore.get("groq_api_key") ?? "",
            "groqApiKey": secretsStore.get("groq_whisper_api_key") ?? "",
            "anthropicApiKey": secretsStore.get("anthropic_api_key") ?? "",
            "recordsRoot": RecordsArchive.rootDirectory().path,
            "logFile": RecorderLogger.logFileURL().path,
        ]
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
            let snippet = String(data: body.prefix(500), encoding: .utf8) ?? "<binary \(body.count) B>"
            Logger.shared.error("saveSettings: JSON parse failed (\(body.count) B) — \(error.localizedDescription). body=\(snippet)")
            return .json(400, ["ok": false, "error": "invalid json: \(error.localizedDescription)"])
        }
        guard let obj = parsed as? [String: Any] else {
            let snippet = String(data: body.prefix(500), encoding: .utf8) ?? "<binary>"
            Logger.shared.error("saveSettings: JSON is not an object. body=\(snippet)")
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
            let xaiKey = obj["xaiApiKey"] as? String ?? ""
            try secretsStore.set(xaiKey, for: "xai_api_key")
            // Keep legacy key in sync for backward compatibility with previously saved configs.
            try secretsStore.set(xaiKey, for: "groq_api_key")
            try secretsStore.set(obj["groqApiKey"] as? String ?? "", for: "groq_whisper_api_key")
            try secretsStore.set(obj["anthropicApiKey"] as? String ?? "", for: "anthropic_api_key")
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

    private func checkXAIKey(_ key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
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
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
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

    private func checkAnthropicKey(_ key: String) async -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
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
    case 404: return "Not Found"
    case 500: return "Internal Server Error"
    default: return "HTTP"
    }
}

extension LocalControlServer {
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
    <div class="row"><label>xAI API key (Grok/fallback)</label><input id="xaiApiKey" /><span id="xaiHealth">—</span></div>
    <div class="row"><label>Groq API key (Whisper free)</label><input id="groqApiKey" /><span id="groqHealth">—</span></div>
    <div class="row"><label>Groq Whisper model</label><input id="groqModel" /><span></span></div>
    <div class="row"><label></label><div class="pending">При 429/5xx у Groq STT автоматически переключается на Grok AI.</div><span></span></div>
    <div class="row"><label>Anthropic API key</label><input id="anthropicApiKey" /><span id="anthropicHealth">—</span></div>
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
    <h3>Логи</h3>
    <div style="margin-bottom:8px;"><button onclick="refreshLogs()">Обновить</button></div>
    <textarea id="logs" readonly></textarea>
  </div>

<script>
let xaiTimer = null, groqTimer = null, anthTimer = null;

function setHealth(id, state) {
  const el = document.getElementById(id);
  if (state === 'ok') { el.textContent = '✅'; el.className = 'ok'; return; }
  if (state === 'bad') { el.textContent = '❌'; el.className = 'bad'; return; }
  if (state === 'pending') { el.textContent = '…'; el.className = 'pending'; return; }
  el.textContent = '—'; el.className = 'pending';
}

async function loadState() {
  const resp = await fetch('/api/state'); const s = await resp.json();
  for (const k of Object.keys(s)) {
    const el = document.getElementById(k);
    if (!el) continue;
    if (el.type === 'checkbox') el.checked = !!s[k]; else el.value = s[k] ?? '';
  }
  document.getElementById('status').textContent = 'Готово';
}

async function save() {
  const payload = {
    sttProvider: document.getElementById('sttProvider').value,
    summaryProvider: document.getElementById('summaryProvider').value,
    xaiApiKey: document.getElementById('xaiApiKey').value,
    groqApiKey: document.getElementById('groqApiKey').value,
    groqModel: document.getElementById('groqModel').value,
    anthropicApiKey: document.getElementById('anthropicApiKey').value,
    xaiSttLanguage: document.getElementById('xaiSttLanguage').value,
    summaryApiModel: document.getElementById('summaryApiModel').value,
    cursorAgentBin: document.getElementById('cursorAgentBin').value,
    cursorModel: document.getElementById('cursorModel').value,
    startHotkey: document.getElementById('startHotkey').value,
    stopHotkey: document.getElementById('stopHotkey').value,
    notificationsEnabled: document.getElementById('notificationsEnabled').checked,
  };
  const status = document.getElementById('saveStatus');
  status.textContent = 'Сохраняем…'; status.className = 'pending';
  try {
    const resp = await fetch('/api/settings', { method: 'POST', headers: {'Content-Type':'application/json'}, body: JSON.stringify(payload) });
    const build = resp.headers.get('X-Own-Recorder-Build') || '?';
    const raw = await resp.text();
    let r = {};
    try { r = JSON.parse(raw); } catch (e) { r = { error: 'non-json response: ' + raw.slice(0, 200) }; }
    if (resp.ok && r.ok) {
      status.textContent = (r.warning ? ('Сохранено с предупреждением: ' + r.warning) : 'Сохранено') + ' [' + build + ']';
      status.className = r.warning ? 'pending' : 'ok';
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
  const resp = await fetch('/api/logs?lines=300'); const r = await resp.json();
  const ta = document.getElementById('logs'); ta.value = r.logs || ''; ta.scrollTop = ta.scrollHeight;
}

async function checkXAI() {
  const key = document.getElementById('xaiApiKey').value.trim();
  if (!key) { setHealth('xaiHealth', 'none'); return; }
  setHealth('xaiHealth', 'pending');
  const resp = await fetch('/api/check/xai', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({key}) });
  const r = await resp.json().catch(() => ({ok:false}));
  setHealth('xaiHealth', r.ok ? 'ok' : 'bad');
}

async function checkGroq() {
  const key = document.getElementById('groqApiKey').value.trim();
  if (!key) { setHealth('groqHealth', 'none'); return; }
  setHealth('groqHealth', 'pending');
  const resp = await fetch('/api/check/groq', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({key}) });
  const r = await resp.json().catch(() => ({ok:false}));
  setHealth('groqHealth', r.ok ? 'ok' : 'bad');
}

async function checkAnthropic() {
  const key = document.getElementById('anthropicApiKey').value.trim();
  if (!key) { setHealth('anthropicHealth', 'none'); return; }
  setHealth('anthropicHealth', 'pending');
  const resp = await fetch('/api/check/anthropic', { method:'POST', headers:{'Content-Type':'application/json'}, body: JSON.stringify({key}) });
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

loadState().then(() => { refreshLogs(); debounceChecks(); });
setInterval(refreshLogs, 4000);
</script>
</body>
</html>
"""
}
