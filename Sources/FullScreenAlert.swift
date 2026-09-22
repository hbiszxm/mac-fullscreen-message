import AppKit

private final class AlertWindow: NSWindow {
    var onEscape: (() -> Void)?
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
    override func cancelOperation(_ sender: Any?) { onEscape?() }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onEscape?() }
        else { super.keyDown(with: event) }
    }
}

final class FullScreenAlertController: NSWindowController {
    private var screenWindows: [NSWindow] = []

    init(message: WireMessage) {
        let screens = NSScreen.screens
        let primaryScreen = NSScreen.main ?? screens.first!
        let primaryWindow = Self.makeWindow(for: primaryScreen)
        super.init(window: primaryWindow)

        screenWindows = [primaryWindow]
        primaryWindow.onEscape = { [weak self] in self?.dismiss() }
        configure(primaryWindow, message: message)
        for screen in screens where screen !== primaryScreen {
            let extraWindow = Self.makeWindow(for: screen)
            extraWindow.onEscape = { [weak self] in self?.dismiss() }
            screenWindows.append(extraWindow)
            configure(extraWindow, message: message)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private static func makeWindow(for screen: NSScreen) -> AlertWindow {
        let window = AlertWindow(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
        window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.screenSaverWindow)))
        window.title = "收到全屏消息"
        window.backgroundColor = NSColor(calibratedRed: 0.055, green: 0.075, blue: 0.12, alpha: 0.98)
        window.isOpaque = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        return window
    }

    private func configure(_ window: NSWindow, message: WireMessage) {
        let content = NSView()
        window.contentView = content

        let badge = NSTextField(labelWithString: "收到重要消息")
        badge.font = .systemFont(ofSize: 22, weight: .semibold)
        badge.textColor = NSColor(calibratedRed: 0.35, green: 0.76, blue: 1, alpha: 1)
        badge.alignment = .center

        let sender = NSTextField(labelWithString: message.sender)
        sender.font = .systemFont(ofSize: 30, weight: .bold)
        sender.textColor = .white
        sender.alignment = .center

        let body = NSTextField(wrappingLabelWithString: message.text)
        body.font = .systemFont(ofSize: 42, weight: .medium)
        body.textColor = .white
        body.alignment = .center
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let time = NSTextField(labelWithString: formatter.string(from: message.sentAt))
        time.font = .systemFont(ofSize: 16)
        time.textColor = .secondaryLabelColor
        time.alignment = .center

        let hint = NSTextField(labelWithString: "按 ESC 退出")
        hint.font = .systemFont(ofSize: 18, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.72)
        hint.alignment = .center

        let stack = NSStackView(views: [badge, sender, body, time, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(40, after: sender)
        stack.setCustomSpacing(42, after: body)
        content.addSubview(stack)

        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: content.leadingAnchor, constant: 80),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -80),
            body.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.78)
        ])
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        for window in screenWindows { window.orderFrontRegardless() }
        window?.makeKey()
    }

    @objc private func dismiss() {
        for window in screenWindows { window.orderOut(nil) }
        screenWindows.removeAll()
        close()
    }
}
