import Foundation

/// Prepares audio for cloud STT: compress large files, split long recordings into chunks.
enum AudioSTTPreprocessor {
    static let compressThresholdBytes = 12 * 1024 * 1024

    /// Split when duration exceeds this (seconds). Default 8 minutes.
    static let chunkWhenDurationExceedsSec: Double = {
        if let raw = ProcessInfo.processInfo.environment["OWN_RECORDER_STT_CHUNK_THRESHOLD_SEC"],
           let v = Double(raw), v >= 60
        {
            return v
        }
        return 480
    }()

    /// Target chunk length (seconds). Default 10 minutes.
    static let chunkDurationSec: Double = {
        if let raw = ProcessInfo.processInfo.environment["OWN_RECORDER_STT_CHUNK_SEC"],
           let v = Double(raw), v >= 60
        {
            return v
        }
        return 600
    }()

    struct PreparedAudio {
        let url: URL
        let cleanupURL: URL?
    }

    struct STTChunk {
        let url: URL
        let startOffsetSec: Double
        let needsCleanup: Bool
    }

    static func prepare(audioURL: URL) async -> PreparedAudio {
        let size = (try? FileManager.default.attributesOfItem(atPath: audioURL.path)[.size] as? Int64) ?? 0
        guard size > compressThresholdBytes else {
            Logger.shared.info("AudioSTTPreprocessor: using original (\(size) bytes)")
            return PreparedAudio(url: audioURL, cleanupURL: nil)
        }

        Logger.shared.info("AudioSTTPreprocessor: file \(size) bytes > \(compressThresholdBytes), compressing for STT")
        if let compressed = await compressForSTT(inputURL: audioURL) {
            let newSize = (try? FileManager.default.attributesOfItem(atPath: compressed.path)[.size] as? Int64) ?? 0
            Logger.shared.info("AudioSTTPreprocessor: compressed \(size) → \(newSize) bytes")
            return PreparedAudio(url: compressed, cleanupURL: compressed)
        }

        Logger.shared.warn("AudioSTTPreprocessor: ffmpeg unavailable — STT will use full \(size) byte file")
        return PreparedAudio(url: audioURL, cleanupURL: nil)
    }

    /// Returns one or more chunks; each file is suitable for a single STT API call.
    static func chunks(for preparedURL: URL) async -> [STTChunk] {
        let duration = await mediaDuration(url: preparedURL) ?? 0
        guard duration > chunkWhenDurationExceedsSec else {
            return [STTChunk(url: preparedURL, startOffsetSec: 0, needsCleanup: false)]
        }

        Logger.shared.info(
            "AudioSTTPreprocessor: duration \(Int(duration))s > \(Int(chunkWhenDurationExceedsSec))s, splitting into ~\(Int(chunkDurationSec))s chunks"
        )
        let split = await splitIntoChunks(inputURL: preparedURL, segmentSec: chunkDurationSec)
        if split.isEmpty {
            Logger.shared.warn("AudioSTTPreprocessor: split failed, using single file")
            return [STTChunk(url: preparedURL, startOffsetSec: 0, needsCleanup: false)]
        }
        Logger.shared.info("AudioSTTPreprocessor: created \(split.count) chunk(s)")
        return split
    }

    static func offsetTranscriptLines(_ transcript: String, offsetSec: Double) -> String {
        guard offsetSec > 0.5 else { return transcript }
        let lines = transcript.split(separator: "\n", omittingEmptySubsequences: false)
        return lines.map { line -> String in
            let s = String(line)
            guard s.hasPrefix("["), let close = s.firstIndex(of: "]") else { return s }
            let inner = s[s.index(after: s.startIndex)..<close]
            guard inner.hasSuffix("s"), let sec = Double(inner.dropLast()) else { return s }
            let rest = s[s.index(after: close)...]
            return "[\(Int(sec + offsetSec))s]\(rest)"
        }.joined(separator: "\n")
    }

    // MARK: - ffmpeg

    private static func splitIntoChunks(inputURL: URL, segmentSec: Double) async -> [STTChunk] {
        guard ffmpegExecutable() != nil else { return [] }

        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("own-stt-chunks-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            return []
        }

        let pattern = dir.appendingPathComponent("chunk_%03d.mp3").path
        let ok = await runFFmpeg(arguments: [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", inputURL.path,
            "-f", "segment",
            "-segment_time", "\(max(60, Int(segmentSec)))",
            "-reset_timestamps", "1",
            "-ar", "16000",
            "-ac", "1",
            "-b:a", "32k",
            pattern,
        ])
        guard ok else {
            try? FileManager.default.removeItem(at: dir)
            return []
        }

        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter({ $0.pathExtension.lowercased() == "mp3" })
            .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
        else {
            try? FileManager.default.removeItem(at: dir)
            return []
        }

        return files.enumerated().map { index, url in
            STTChunk(url: url, startOffsetSec: Double(index) * segmentSec, needsCleanup: true)
        }
    }

    private static func compressForSTT(inputURL: URL) async -> URL? {
        guard ffmpegExecutable() != nil else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("own-stt-\(UUID().uuidString).mp3")
        let ok = await runFFmpeg(arguments: [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-y",
            "-i", inputURL.path,
            "-ar", "16000",
            "-ac", "1",
            "-b:a", "32k",
            out.path,
        ])
        return ok ? out : nil
    }

    private static func mediaDuration(url: URL) async -> Double? {
        guard let ffprobe = ffprobeExecutable() else { return nil }
        return await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffprobe)
            configureFFmpegIO(proc)
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.arguments = [
                "-v", "error",
                "-show_entries", "format=duration",
                "-of", "default=noprint_wrappers=1:nokey=1",
                url.path,
            ]
            proc.terminationHandler = { p in
                guard p.terminationStatus == 0 else {
                    cont.resume(returning: nil)
                    return
                }
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                cont.resume(returning: Double(raw))
            }
            do {
                try proc.run()
            } catch {
                cont.resume(returning: nil)
            }
        }
    }

    @discardableResult
    private static func runFFmpeg(arguments: [String]) async -> Bool {
        guard let ffmpeg = ffmpegExecutable() else { return false }
        return await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            configureFFmpegIO(proc)
            proc.arguments = arguments
            proc.terminationHandler = { p in
                cont.resume(returning: p.terminationStatus == 0)
            }
            do {
                try proc.run()
            } catch {
                cont.resume(returning: false)
            }
        }
    }

    private static func configureFFmpegIO(_ proc: Process) {
        if let nullIn = FileHandle(forReadingAtPath: "/dev/null") {
            proc.standardInput = nullIn
        }
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
    }

    private static func ffmpegExecutable() -> String? {
        executable(named: "ffmpeg", searchPaths: [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ])
    }

    private static func ffprobeExecutable() -> String? {
        executable(named: "ffprobe", searchPaths: [
            "/opt/homebrew/bin/ffprobe",
            "/usr/local/bin/ffprobe",
            "/usr/bin/ffprobe",
        ])
    }

    private static func executable(named: String, searchPaths: [String]) -> String? {
        if let fromPath = ProcessInfo.processInfo.environment["PATH"]?
            .split(separator: ":")
            .map({ String($0).appending("/\(named)") })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) })
        {
            return fromPath
        }
        return searchPaths.first { FileManager.default.fileExists(atPath: $0) }
    }
}
