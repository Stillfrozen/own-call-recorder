import AppKit
import Foundation
import UserNotifications

final class NotificationService: NSObject, UNUserNotificationCenterDelegate, NSUserNotificationCenterDelegate {
    static let shared = NotificationService()

    static let meetingOfferCategory = "ownrecorder.talk-meeting"
    static let actionStartRecording = "start-recording"
    static let actionDismiss = "dismiss-offer"
    static let meetingOfferRequestId = "ownrecorder.talk-meeting-offer"

    var onStartRecordingFromNotification: (() -> Void)?

    private var configured = false
    private var unGranted = false

    private override init() {
        super.init()
    }

    func ensureAuthorization() {
        guard !configured else { return }
        configured = true

        NSUserNotificationCenter.default.delegate = self

        let center = UNUserNotificationCenter.current()
        center.delegate = self

        let start = UNNotificationAction(
            identifier: Self.actionStartRecording,
            title: "Начать запись",
            options: [.foreground]
        )
        let dismiss = UNNotificationAction(
            identifier: Self.actionDismiss,
            title: "Закрыть уведомление",
            options: []
        )
        let category = UNNotificationCategory(
            identifier: Self.meetingOfferCategory,
            actions: [start, dismiss],
            intentIdentifiers: [],
            options: []
        )
        center.setNotificationCategories([category])

        center.requestAuthorization(options: [.alert, .sound]) { [weak self] granted, error in
            if let error {
                Logger.shared.warn("NotificationService: UN auth error — \(error.localizedDescription)")
            } else {
                Logger.shared.info("NotificationService: UN authorization granted=\(granted)")
            }
            self?.unGranted = (error == nil && granted)
        }
    }

    func post(title: String, body: String) {
        guard SettingsStore.shared.load().notificationsEnabled else { return }
        if unGranted {
            postModern(title: title, body: body, identifier: "ownrecorder.status.\(UUID().uuidString)", meetingOffer: false)
        } else {
            postLegacy(title: title, body: body, identifier: "ownrecorder.status.\(UUID().uuidString)", meetingOffer: false)
        }
    }

    func postTalkMeetingOffer() {
        guard SettingsStore.shared.load().notificationsEnabled else { return }
        // Always the two-button legacy alert: UN banners hide actions until hover.
        postLegacy(
            title: "Own Recorder",
            body: "Похоже, началась встреча в Толке. Записать?",
            identifier: Self.meetingOfferRequestId,
            meetingOffer: true
        )
        Logger.shared.info("NotificationService: posted Talk meeting offer")
    }

    func dismissTalkMeetingOffer() {
        NSUserNotificationCenter.default.deliveredNotifications
            .filter { $0.identifier == Self.meetingOfferRequestId }
            .forEach { NSUserNotificationCenter.default.removeDeliveredNotification($0) }
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [Self.meetingOfferRequestId])
        center.removePendingNotificationRequests(withIdentifiers: [Self.meetingOfferRequestId])
    }

    private func postModern(title: String, body: String, identifier: String, meetingOffer: Bool) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        if meetingOffer {
            content.categoryIdentifier = Self.meetingOfferCategory
        }
        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Logger.shared.warn("NotificationService: UN send failed — \(error.localizedDescription)")
            }
        }
    }

    private func postLegacy(title: String, body: String, identifier: String, meetingOffer: Bool) {
        let notification = NSUserNotification()
        notification.title = title
        notification.informativeText = body
        notification.identifier = identifier
        notification.soundName = NSUserNotificationDefaultSoundName
        if meetingOffer {
            notification.hasActionButton = true
            notification.actionButtonTitle = "Начать запись"
            notification.otherButtonTitle = "Закрыть уведомление"
        } else {
            notification.hasActionButton = false
        }
        NSUserNotificationCenter.default.deliver(notification)
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        if response.actionIdentifier == Self.actionStartRecording {
            Logger.shared.info("NotificationService: UN tap Начать запись")
            DispatchQueue.main.async { [weak self] in
                self?.onStartRecordingFromNotification?()
            }
        } else if response.actionIdentifier == Self.actionDismiss {
            Logger.shared.info("NotificationService: UN dismiss Talk offer")
            dismissTalkMeetingOffer()
        }
        completionHandler()
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, shouldPresent notification: NSUserNotification) -> Bool {
        true
    }

    func userNotificationCenter(_ center: NSUserNotificationCenter, didActivate notification: NSUserNotification) {
        guard notification.identifier == Self.meetingOfferRequestId else { return }
        switch notification.activationType {
        case .actionButtonClicked:
            Logger.shared.info("NotificationService: tap Начать запись")
            onStartRecordingFromNotification?()
        default:
            Logger.shared.info("NotificationService: dismiss Talk offer")
            dismissTalkMeetingOffer()
        }
    }
}
