import AppKit
import CoreGraphics
import Foundation

/// Polls on-screen windows of Контур.Толк (`kontur.talk`).
/// Lobby is one large window (calendar). A call adds a second large window.
/// Does **not** start a screen stream — only `CGWindowListCopyWindowInfo`.
final class TalkMeetingDetector {
    static let bundleIdentifier = "kontur.talk"

    /// Ignore menu extras / tooltips. Calendar ~1250×750, call ~1440×875 in the 17.08.2026 sample.
    private static let minWidth: CGFloat = 400
    private static let minHeight: CGFloat = 400
    private static let pollInterval: TimeInterval = 3
    private static let confirmTicks = 2

    var onMeetingStarted: (() -> Void)?
    var onMeetingEnded: (() -> Void)?

    private var timer: Timer?
    private var inMeeting = false
    private var consecutiveIn = 0
    private var consecutiveOut = 0

    func start() {
        stop()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.tick()
        }
        timer.tolerance = 0.5
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
        tick()
        Logger.shared.info("TalkMeetingDetector: started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    var isInMeeting: Bool { inMeeting }

    private func tick() {
        if Self.largeOnScreenWindowCount() >= 2 {
            consecutiveIn += 1
            consecutiveOut = 0
            if !inMeeting, consecutiveIn >= Self.confirmTicks {
                inMeeting = true
                Logger.shared.info("TalkMeetingDetector: meeting started")
                onMeetingStarted?()
            }
        } else {
            consecutiveOut += 1
            consecutiveIn = 0
            if inMeeting, consecutiveOut >= Self.confirmTicks {
                inMeeting = false
                Logger.shared.info("TalkMeetingDetector: meeting ended")
                onMeetingEnded?()
            }
        }
    }

    static func largeOnScreenWindowCount() -> Int {
        let talkPIDs = Set(
            NSWorkspace.shared.runningApplications
                .filter { $0.bundleIdentifier == bundleIdentifier }
                .map(\.processIdentifier)
        )
        guard !talkPIDs.isEmpty else { return 0 }

        guard let raw = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]]
        else { return 0 }

        var count = 0
        for window in raw {
            let pid = pid_t((window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value ?? 0)
            guard talkPIDs.contains(pid) else { continue }
            let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
            guard layer == 0 else { continue }
            let bounds = window[kCGWindowBounds as String] as? [String: Any] ?? [:]
            let width = CGFloat((bounds["Width"] as? NSNumber)?.doubleValue ?? 0)
            let height = CGFloat((bounds["Height"] as? NSNumber)?.doubleValue ?? 0)
            guard width >= minWidth, height >= minHeight else { continue }
            count += 1
        }
        return count
    }
}
