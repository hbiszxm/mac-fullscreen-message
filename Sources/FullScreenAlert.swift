import AppKit
import QuartzCore

private final class AlertBackgroundView: NSView {
    private let gradient = CAGradientLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        gradient.colors = [
            NSColor(calibratedRed: 0.025, green: 0.045, blue: 0.105, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.055, green: 0.12, blue: 0.23, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.08, green: 0.04, blue: 0.16, alpha: 1).cgColor
        ]
        gradient.locations = [0, 0.56, 1]
        gradient.startPoint = CGPoint(x: 0, y: 0)
        gradient.endPoint = CGPoint(x: 1, y: 1)
        layer?.addSublayer(gradient)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        gradient.frame = bounds
    }

    func startAnimating() {
        let animation = CABasicAnimation(keyPath: "colors")
        animation.fromValue = gradient.colors
        animation.toValue = [
            NSColor(calibratedRed: 0.06, green: 0.025, blue: 0.14, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.025, green: 0.17, blue: 0.25, alpha: 1).cgColor,
            NSColor(calibratedRed: 0.03, green: 0.055, blue: 0.13, alpha: 1).cgColor
        ]
        animation.duration = 4.5
        animation.autoreverses = true
        animation.repeatCount = .infinity
        animation.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        gradient.add(animation, forKey: "ambientColors")
    }
}

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
    private var backgrounds: [AlertBackgroundView] = []
    private var messagePanels: [NSView] = []
    private let responseHandler: (Bool) -> Void

    init(message: WireMessage, responseHandler: @escaping (Bool) -> Void) {
        self.responseHandler = responseHandler
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
        window.backgroundColor = .black
        window.isOpaque = true
        window.hasShadow = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.isReleasedWhenClosed = false
        return window
    }

    private func configure(_ window: NSWindow, message: WireMessage) {
        let content = AlertBackgroundView()
        window.contentView = content
        backgrounds.append(content)

        let panel = NSView()
        panel.wantsLayer = true
        panel.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.2).cgColor
        panel.layer?.cornerRadius = 32
        panel.layer?.borderWidth = 1
        panel.layer?.borderColor = NSColor.white.withAlphaComponent(0.13).cgColor
        panel.layer?.shadowColor = NSColor.systemBlue.cgColor
        panel.layer?.shadowOpacity = 0.3
        panel.layer?.shadowRadius = 36
        panel.layer?.shadowOffset = .zero
        panel.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(panel)
        messagePanels.append(panel)

        let badge = NSTextField(labelWithString: "收到重要消息")
        badge.font = .systemFont(ofSize: 26, weight: .semibold)
        badge.textColor = NSColor(calibratedRed: 0.35, green: 0.76, blue: 1, alpha: 1)
        badge.alignment = .center

        let sender = NSTextField(labelWithString: message.sender)
        sender.font = .systemFont(ofSize: 38, weight: .bold)
        sender.textColor = .white
        sender.alignment = .center

        let body = NSTextField(wrappingLabelWithString: message.text)
        body.font = .systemFont(ofSize: Self.messageFontSize(for: message.text, in: window.frame.size), weight: .bold)
        body.textColor = .white
        body.alignment = .center
        body.maximumNumberOfLines = 0
        body.lineBreakMode = .byWordWrapping
        body.wantsLayer = true
        body.layer?.shadowColor = NSColor.systemBlue.cgColor
        body.layer?.shadowOpacity = 0.65
        body.layer?.shadowRadius = 18
        body.layer?.shadowOffset = .zero

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let time = NSTextField(labelWithString: formatter.string(from: message.sentAt))
        time.font = .systemFont(ofSize: 19)
        time.textColor = .secondaryLabelColor
        time.alignment = .center

        let hint = NSTextField(labelWithString: "按 ESC 退出")
        hint.font = .systemFont(ofSize: 21, weight: .medium)
        hint.textColor = NSColor.white.withAlphaComponent(0.72)
        hint.alignment = .center

        let accepted = NSButton(title: "收到", target: self, action: #selector(acceptMessage))
        accepted.bezelStyle = .rounded
        accepted.controlSize = .large
        accepted.font = .systemFont(ofSize: 18, weight: .semibold)
        let rejected = NSButton(title: "拒绝", target: self, action: #selector(rejectMessage))
        rejected.bezelStyle = .rounded
        rejected.controlSize = .large
        rejected.font = .systemFont(ofSize: 18, weight: .semibold)
        let responseRow = NSStackView(views: [accepted, rejected])
        responseRow.orientation = .horizontal
        responseRow.distribution = .fillEqually
        responseRow.spacing = 16
        responseRow.widthAnchor.constraint(equalToConstant: 360).isActive = true

        let stack = NSStackView(views: [badge, sender, body, time, responseRow, hint])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 22
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(40, after: sender)
        stack.setCustomSpacing(42, after: body)
        panel.addSubview(stack)

        NSLayoutConstraint.activate([
            panel.centerXAnchor.constraint(equalTo: content.centerXAnchor),
            panel.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            panel.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.88),
            panel.heightAnchor.constraint(lessThanOrEqualTo: content.heightAnchor, multiplier: 0.82),
            stack.leadingAnchor.constraint(equalTo: panel.leadingAnchor, constant: 64),
            stack.trailingAnchor.constraint(equalTo: panel.trailingAnchor, constant: -64),
            stack.topAnchor.constraint(equalTo: panel.topAnchor, constant: 48),
            stack.bottomAnchor.constraint(equalTo: panel.bottomAnchor, constant: -42),
            body.widthAnchor.constraint(lessThanOrEqualTo: content.widthAnchor, multiplier: 0.78)
        ])
    }

    @objc private func acceptMessage() {
        responseHandler(true)
        dismiss()
    }

    @objc private func rejectMessage() {
        responseHandler(false)
        dismiss()
    }

    private static func messageFontSize(for text: String, in size: NSSize) -> CGFloat {
        let count = text.count
        let scale = min(size.width / 1440, size.height / 900)
        let base: CGFloat
        switch count {
        case 0...8: base = 128
        case 9...24: base = 100
        case 25...60: base = 76
        default: base = 58
        }
        return max(52, min(156, base * max(0.9, scale)))
    }

    func present() {
        NSApp.activate(ignoringOtherApps: true)
        for window in screenWindows { window.orderFrontRegardless() }
        backgrounds.forEach { $0.startAnimating() }
        for (index, panel) in messagePanels.enumerated() {
            panel.alphaValue = 0
            panel.layer?.transform = CATransform3DMakeScale(0.84, 0.84, 1)
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.06) {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.48
                    context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                    panel.animator().alphaValue = 1
                }
                let scale = CABasicAnimation(keyPath: "transform.scale")
                scale.fromValue = 0.84
                scale.toValue = 1.0
                scale.duration = 0.52
                scale.timingFunction = CAMediaTimingFunction(name: .easeOut)
                panel.layer?.transform = CATransform3DIdentity
                panel.layer?.add(scale, forKey: "entranceScale")
            }
        }
        window?.makeKey()
    }

    @objc private func dismiss() {
        for window in screenWindows { window.orderOut(nil) }
        screenWindows.removeAll()
        close()
    }
}
