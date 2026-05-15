@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import ScreenCaptureKit

enum RecorderError: Error, LocalizedError {
    case alreadyRecording
    case notRecording
    case noDisplay
    case writerSetupFailed(String)
    case writeFailed(String)

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:          return "Recording already in progress"
        case .notRecording:              return "No active recording"
        case .noDisplay:                 return "No display found for ScreenCaptureKit"
        case .writerSetupFailed(let m):  return "Writer setup failed: \(m)"
        case .writeFailed(let m):        return "Write failed: \(m)"
        }
    }
}

enum AudioRecorderStage {
    case started
    case stopped
    case mergedAudio(URL)
    case encodedMP3(URL)
    case mergeFailed
}

/// Captures system audio (all desktop audio from the primary display) via
/// ScreenCaptureKit and encodes it to M4A/AAC using AVAssetWriter.
/// Optionally records the default microphone in parallel (`MicRecorder`) and mixes
/// system + mic with **ffmpeg** (`amix`) into one file before optional MP3 export.
///
/// - Requires: Screen Recording TCC (SCStream).
/// - Requires: Microphone TCC + embedded `NSMicrophoneUsageDescription` for mic capture.
/// - Requires: **ffmpeg** in PATH for mixing and for MP3 conversion (`brew install ffmpeg`).
final class AudioRecorder: NSObject {
    private(set) var isRecording = false
    var onStageChanged: ((AudioRecorderStage) -> Void)?

    private var stream: SCStream?
    private var assetWriter: AVAssetWriter?
    private var audioInput: AVAssetWriterInput?
    private var outputURL: URL?
    private var sessionStarted = false

    private let micRecorder = MicRecorder()
    /// When true (default), start `MicRecorder` in parallel and mix with ffmpeg if available.
    private var captureMicrophone: Bool {
        let settingsValue = ProcessInfo.processInfo.environment["OWN_RECORDER_MIC"]
        let v = (settingsValue ?? "1").lowercased()
        return v != "0" && v != "false" && v != "no"
    }

    /// Serial queue for SCStreamOutput callbacks and writer access.
    private let audioQueue = DispatchQueue(label: "com.own-recorder.audio-io")

    // MARK: - Public API

    /// Starts capturing system audio. Returns the (temporary) output file URL.
    func startRecording() async throws -> URL {
        guard !isRecording else { throw RecorderError.alreadyRecording }

        let content: SCShareableContent = try await withCheckedThrowingContinuation { cont in
            SCShareableContent.getExcludingDesktopWindows(false, onScreenWindowsOnly: false) { content, error in
                if let error = error { cont.resume(throwing: error); return }
                guard let content = content else {
                    cont.resume(throwing: RecorderError.writerSetupFailed("SCShareableContent returned nil"))
                    return
                }
                cont.resume(returning: content)
            }
        }

        guard let display = content.displays.first else { throw RecorderError.noDisplay }

        // Prepare output URL in tmp
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("own-rec-\(UUID().uuidString).m4a")
        outputURL = url

        // Set up AVAssetWriter (AAC 128 kbps stereo 48 kHz)
        let writer: AVAssetWriter
        do {
            writer = try AVAssetWriter(url: url, fileType: .m4a)
        } catch {
            throw RecorderError.writerSetupFailed(error.localizedDescription)
        }

        let outputSettings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVEncoderBitRateKey: 128_000,
        ]
        let input = AVAssetWriterInput(mediaType: .audio, outputSettings: outputSettings)
        input.expectsMediaDataInRealTime = true
        writer.add(input)

        guard writer.startWriting() else {
            throw RecorderError.writerSetupFailed(writer.error?.localizedDescription ?? "startWriting returned false")
        }

        assetWriter = writer
        audioInput = input
        sessionStarted = false

        // Configure SCStream: capture full-display audio, minimal video
        let filter = SCContentFilter(
            display: display,
            excludingApplications: [],
            exceptingWindows: []
        )
        let config = SCStreamConfiguration()
        config.capturesAudio = true
        config.excludesCurrentProcessAudio = true
        config.sampleRate = 48_000
        config.channelCount = 2
        // Tiny video frame — we only care about audio output
        config.width = 4
        config.height = 4
        config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        config.showsCursor = false

        let newStream = SCStream(filter: filter, configuration: config, delegate: self)
        // ScreenCaptureKit: audio buffers are often not delivered unless a `.screen`
        // output is also registered — we discard video frames and keep audio only.
        try newStream.addStreamOutput(self, type: .screen, sampleHandlerQueue: audioQueue)
        try newStream.addStreamOutput(self, type: .audio, sampleHandlerQueue: audioQueue)
        try await newStream.startCapture()

        stream = newStream
        isRecording = true

        if captureMicrophone {
            let micOk = await micRecorder.start()
            if !micOk {
                Logger.shared.warn("AudioRecorder: continuing with system audio only (mic unavailable)")
            }
        } else {
            Logger.shared.info("AudioRecorder: microphone capture disabled (OWN_RECORDER_MIC=0)")
        }

        Logger.shared.info("AudioRecorder: started → \(url.lastPathComponent)")
        onStageChanged?(.started)
        return url
    }

    /// Stops the recording, flushes the writer, archives to `records/`, and returns the final file path
    /// (under `records/` when archiving succeeds; otherwise the temp path) — M4A or MP3 if ffmpeg is available.
    func stopRecording(archiveStartedAt: Date, archiveTitle: String?) async throws -> URL {
        guard isRecording else { throw RecorderError.notRecording }
        guard let activeStream = stream,
              let writer = assetWriter,
              let input = audioInput,
              let outURL = outputURL
        else { throw RecorderError.notRecording }

        // Stop SCStream — after this returns, no more didOutputSampleBuffer calls.
        try await activeStream.stopCapture()
        stream = nil
        isRecording = false

        // Flush the audioQueue to ensure any in-flight sample appends complete.
        let hadAnyAudioSamples = sessionStarted
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            audioQueue.async {
                // If the stream never produced audio, start a dummy session so
                // finishWriting succeeds and produces a valid (silent) file.
                if !hadAnyAudioSamples {
                    writer.startSession(atSourceTime: .zero)
                }
                cont.resume()
            }
        }

        // Finish writer
        input.markAsFinished()
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            writer.finishWriting { cont.resume() }
        }

        assetWriter = nil
        audioInput = nil
        sessionStarted = false

        guard writer.status == .completed else {
            let msg = writer.error?.localizedDescription ?? "unknown"
            Logger.shared.error("AudioRecorder: writer finished with error — \(msg)")
            throw RecorderError.writeFailed(msg)
        }

        Logger.shared.info("AudioRecorder: stopped — \(outURL.lastPathComponent)")
        onStageChanged?(.stopped)

        let micURL = captureMicrophone ? micRecorder.stop() : nil
        var finalURL = outURL

        if let mic = micURL {
            if let merged = await mergeSystemAndMicWithFFmpeg(systemURL: outURL, micURL: mic) {
                try? FileManager.default.removeItem(at: outURL)
                try? FileManager.default.removeItem(at: mic)
                finalURL = merged
                Logger.shared.info("AudioRecorder: merged system + microphone → \(merged.lastPathComponent)")
                onStageChanged?(.mergedAudio(merged))
            } else {
                try? FileManager.default.removeItem(at: mic)
                Logger.shared.warn(
                    "AudioRecorder: ffmpeg missing or merge failed — using system audio only. Install: brew install ffmpeg"
                )
                onStageChanged?(.mergeFailed)
            }
        }

        // Attempt MP3 conversion via ffmpeg
        if let mp3URL = await tryConvertToMP3(inputURL: finalURL) {
            finalURL = mp3URL
            onStageChanged?(.encodedMP3(mp3URL))
        }

        do {
            let archived = try RecordsArchive.moveFinalRecording(
                tempFile: finalURL,
                startedAt: archiveStartedAt,
                title: archiveTitle
            )
            return archived
        } catch {
            Logger.shared.error("RecordsArchive: \(error.localizedDescription) — using temp path for pipeline")
            return finalURL
        }
    }

    // MARK: - ffmpeg

    private func ffmpegExecutable() -> String? {
        let searchPaths = [
            "/opt/homebrew/bin/ffmpeg",
            "/usr/local/bin/ffmpeg",
            "/usr/bin/ffmpeg",
        ]
        return searchPaths.first { FileManager.default.fileExists(atPath: $0) }
    }

    /// Avoids ffmpeg blocking on inherited TTY stdin (common when the parent is launched from Terminal).
    private func configureFFmpegIO(_ proc: Process) {
        if let nullIn = FileHandle(forReadingAtPath: "/dev/null") {
            proc.standardInput = nullIn
        }
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
    }

    /// Mixes system (stereo) + mic (mono) AAC tracks into one stereo AAC file.
    private func mergeSystemAndMicWithFFmpeg(systemURL: URL, micURL: URL) async -> URL? {
        guard let ffmpeg = ffmpegExecutable() else { return nil }

        let merged = systemURL.deletingLastPathComponent()
            .appendingPathComponent("own-rec-merged-\(UUID().uuidString).m4a")

        Logger.shared.info("AudioRecorder: ffmpeg merge starting (system + mic) → \(merged.lastPathComponent)")

        return await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            configureFFmpegIO(proc)
            // -nostdin: never wait for interactive commands on stdin (prevents indefinite hang).
            proc.arguments = [
                "-nostdin",
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-i", systemURL.path,
                "-i", micURL.path,
                "-filter_complex", "[0:a][1:a]amix=inputs=2:duration=longest:normalize=0",
                "-c:a", "aac",
                "-b:a", "192k",
                merged.path,
            ]
            proc.terminationHandler = { p in
                if p.terminationStatus == 0, FileManager.default.fileExists(atPath: merged.path) {
                    Logger.shared.info("AudioRecorder: ffmpeg merge done")
                    cont.resume(returning: merged)
                } else {
                    Logger.shared.warn("AudioRecorder: ffmpeg merge failed (exit \(p.terminationStatus))")
                    try? FileManager.default.removeItem(at: merged)
                    cont.resume(returning: nil)
                }
            }
            do {
                try proc.run()
            } catch {
                Logger.shared.error("AudioRecorder: ffmpeg merge launch failed — \(error.localizedDescription)")
                cont.resume(returning: nil)
            }
        }
    }

    private func tryConvertToMP3(inputURL: URL) async -> URL? {
        guard let ffmpeg = ffmpegExecutable() else {
            Logger.shared.info("AudioRecorder: ffmpeg not found — keeping .m4a")
            return nil
        }

        let mp3URL = inputURL.deletingPathExtension().appendingPathExtension("mp3")
        Logger.shared.info("AudioRecorder: ffmpeg MP3 encode → \(mp3URL.lastPathComponent)")

        return await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: ffmpeg)
            configureFFmpegIO(proc)
            proc.arguments = [
                "-nostdin",
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-i", inputURL.path,
                "-codec:a", "libmp3lame",
                "-q:a", "2",
                mp3URL.path,
            ]
            proc.terminationHandler = { p in
                if p.terminationStatus == 0 {
                    try? FileManager.default.removeItem(at: inputURL)
                    Logger.shared.info("AudioRecorder: converted → \(mp3URL.lastPathComponent)")
                    cont.resume(returning: mp3URL)
                } else {
                    Logger.shared.warn("AudioRecorder: ffmpeg exited \(p.terminationStatus) — keeping .m4a")
                    cont.resume(returning: nil)
                }
            }
            do {
                try proc.run()
            } catch {
                Logger.shared.error("AudioRecorder: failed to launch ffmpeg — \(error.localizedDescription)")
                cont.resume(returning: nil)
            }
        }
    }
}

// MARK: - SCStreamOutput

extension AudioRecorder: SCStreamOutput {
    // Called on audioQueue (the sampleHandlerQueue passed to addStreamOutput).
    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        if type == .screen {
            // Video frames are required by SCK for system-audio delivery; ignore content.
            return
        }
        guard type == .audio else { return }
        guard let writer = assetWriter, let input = audioInput else { return }
        guard writer.status == .writing else { return }

        if !sessionStarted {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            writer.startSession(atSourceTime: pts)
            sessionStarted = true
        }

        guard input.isReadyForMoreMediaData else { return }
        if !input.append(sampleBuffer) {
            Logger.shared.warn("AudioRecorder: AVAssetWriterInput.append returned false (dropped buffer)")
        }
    }
}

// MARK: - SCStreamDelegate

extension AudioRecorder: SCStreamDelegate {
    func stream(_ stream: SCStream, didStopWithError error: Error) {
        Logger.shared.error("AudioRecorder: SCStream stopped unexpectedly — \(error.localizedDescription)")
    }
}
