import AppKit

/// Floating offer that does not depend on Notification Center (ad-hoc apps are often blocked there).
final class TalkMeetingOfferPanel: NSObject, NSWindowDelegate {
    var onStart: (() -> Void)?
    var onDismiss: (() -> Void)?

    private var panel: NSPanel?
    private var closingFromCode = false

    func show() {
        if panel == nil {
            panel = makePanel()
        }
        guard let panel else { return }
        if let screen = NSScreen.main?.visibleFrame {
            let size = panel.frame.size
            let x = screen.midX - size.width / 2
            let y = screen.maxY - size.height - 48
            panel.setFrameOrigin(NSPoint(x: x, y: y))
        }
        panel.orderFrontRegardless()
        Logger.shared.info("TalkMeetingOfferPanel: shown")
    }

    func hide() {
        closingFromCode = true
        panel?.orderOut(nil)
        closingFromCode = false
    }

    func windowWillClose(_ notification: Notification) {
        if !closingFromCode {
            onDismiss?()
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 128),
            styleMask: [.titled, .closable, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "Own Recorder"
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self

        let root = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: 96))
        let label = NSTextField(wrappingLabelWithString: "Похоже, началась встреча в Толке. Записать?")
        label.translatesAutoresizingMaskIntoConstraints = false
        label.font = NSFont.systemFont(ofSize: 13)
        label.alignment = .left

        let start = NSButton(title: "Начать запись", target: self, action: #selector(tapStart))
        start.bezelStyle = .rounded
        start.keyEquivalent = "\r"
        start.translatesAutoresizingMaskIntoConstraints = false

        let close = NSButton(title: "Закрыть уведомление", target: self, action: #selector(tapDismiss))
        close.bezelStyle = .rounded
        close.translatesAutoresizingMaskIntoConstraints = false

        root.addSubview(label)
        root.addSubview(start)
        root.addSubview(close)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 16),
            label.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            label.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            start.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -16),
            start.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -12),
            close.trailingAnchor.constraint(equalTo: start.leadingAnchor, constant: -8),
            close.centerYAnchor.constraint(equalTo: start.centerYAnchor),
        ])
        panel.contentView = root
        return panel
    }

    @objc private func tapStart() {
        hide()
        onStart?()
    }

    @objc private func tapDismiss() {
        hide()
        onDismiss?()
    }
}
