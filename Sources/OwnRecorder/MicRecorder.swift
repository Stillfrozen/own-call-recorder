import AVFoundation
import Foundation

/// Records the default microphone in parallel with system audio (ScreenCaptureKit).
/// Requires Microphone TCC + embedded `NSMicrophoneUsageDescription` in the binary.
final class MicRecorder {
    private var recorder: AVAudioRecorder?
    private var outputURL: URL?

    /// Requests mic access if needed, then starts AAC recording at 48 kHz mono.
    /// Returns `false` if permission denied or recorder could not start.
    func start() async -> Bool {
        let status = AVCaptureDevice.authorizationStatus(for: .audio)
        let granted: Bool
        switch status {
        case .authorized:
            granted = true
        case .notDetermined:
            granted = await withCheckedContinuation { cont in
                AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
            }
        default:
            granted = false
        }

        guard granted else {
            Logger.shared.warn("MicRecorder: microphone permission denied or restricted")
            return false
        }

        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("own-rec-mic-\(UUID().uuidString).m4a")
        outputURL = url

        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]

        do {
            let r = try AVAudioRecorder(url: url, settings: settings)
            r.isMeteringEnabled = false
            guard r.prepareToRecord() else {
                Logger.shared.error("MicRecorder: prepareToRecord failed")
                return false
            }
            guard r.record() else {
                Logger.shared.error("MicRecorder: record() returned false")
                return false
            }
            recorder = r
            Logger.shared.info("MicRecorder: started → \(url.lastPathComponent)")
            return true
        } catch {
            Logger.shared.error("MicRecorder: \(error.localizedDescription)")
            outputURL = nil
            return false
        }
    }

    /// Stops recording. Returns the mic file URL if it looks non-empty.
    func stop() -> URL? {
        recorder?.stop()
        recorder = nil

        guard let url = outputURL else { return nil }
        outputURL = nil
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }

        let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
        if size < 512 {
            Logger.shared.warn("MicRecorder: output too small (\(size) B), discarding")
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        Logger.shared.info("MicRecorder: stopped — \(url.lastPathComponent) (\(size) B)")
        return url
    }
}
