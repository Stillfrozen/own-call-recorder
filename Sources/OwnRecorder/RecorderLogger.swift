import Foundation

/// File + console logger. Singleton; initialised once on first access.
final class RecorderLogger {
    static let shared = RecorderLogger()

    private let fileHandle: FileHandle?
    private let dateFormatter: DateFormatter
    private let queue = DispatchQueue(label: "com.own-recorder.logger")

    private init() {
        dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss"

        let logDir = RecorderLogger.resolveLogDirectory()
        let logFile = RecorderLogger.logFileURL()

        try? FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logFile.path) {
            FileManager.default.createFile(atPath: logFile.path, contents: nil)
        }
        fileHandle = try? FileHandle(forWritingTo: logFile)
        fileHandle?.seekToEndOfFile()
    }

    private static func resolveLogDirectory() -> URL {
        if let env = ProcessInfo.processInfo.environment["OWN_RECORDER_LOG_PATH"] {
            return URL(fileURLWithPath: env)
        }
        return FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/own-call-recorder")
    }

    static func logFileURL() -> URL {
        resolveLogDirectory().appendingPathComponent("own-call-recorder.log")
    }

    func log(_ level: String, _ message: String) {
        let ts = dateFormatter.string(from: Date())
        let line = "[\(ts)] [\(level)] \(message)\n"
        queue.async { [weak self] in
            print(line, terminator: "")
            if let data = line.data(using: .utf8) {
                self?.fileHandle?.write(data)
            }
        }
    }

    func info(_ msg: String)  { log("INFO",  msg) }
    func warn(_ msg: String)  { log("WARN",  msg) }
    func error(_ msg: String) { log("ERROR", msg) }
}

// Convenience alias used throughout the codebase.
typealias Logger = RecorderLogger
