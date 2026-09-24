import AppKit

extension NSView {
    /// Includes clipping, window occlusion and the visible desktop, not just focus.
    var isFullyVisibleInActiveWindow: Bool {
        guard let window, window.isKeyWindow, window.isVisible,
              window.occlusionState.contains(.visible), !isHiddenOrHasHiddenAncestor,
              bounds.width > 0, bounds.height > 0,
              visibleRect.width >= bounds.width - 1, visibleRect.height >= bounds.height - 1 else { return false }
        let screenRect = window.convertToScreen(convert(bounds, to: nil))
        let visibleArea = NSScreen.screens.reduce(CGFloat.zero) { area, screen in
            let intersection = screenRect.intersection(screen.visibleFrame)
            return area + (intersection.isNull ? 0 : intersection.width * intersection.height)
        }
        return visibleArea >= screenRect.width * screenRect.height - 1
    }
}

/// The same compact conversation stays in the status panel; no secondary window.
final class InlineChatView: NSView, NSTextViewDelegate {
    private let unreadLabel = NSTextField(labelWithString: "")
    private let recipientsLabel = NSTextField(labelWithString: "先选择上方接收电脑")
    private let transcript = NSTextView()
    private let historyScroll = NSScrollView()
    private let input = PopoverMessageTextView()
    private let privacy = PrivacyChatView()
    private let sendButton = PopoverButton(title: "发送", target: nil, action: nil)
    private var hasRecipients = false
    private var sending = false
    private var windowObserver: NSObjectProtocol?
    var onSend: ((String) -> Void)?
    var onRead: (() -> Void)?
    var draft: String { input.string }
    var inputHasFocus: Bool { window?.firstResponder === input }
    var isReadable: Bool {
        privacy.isRevealed && historyScroll.isFullyVisibleInActiveWindow
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        let title = NSTextField(labelWithString: "临时会话")
        title.font = .systemFont(ofSize: 12, weight: .semibold)
        title.textColor = .secondaryLabelColor
        unreadLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        unreadLabel.textColor = .systemRed
        let header = NSStackView(views: [title, unreadLabel])
        header.orientation = .horizontal
        header.distribution = .fill
        header.spacing = 8
        title.setContentHuggingPriority(.defaultLow, for: .horizontal)
        recipientsLabel.font = .systemFont(ofSize: 10)
        recipientsLabel.textColor = .secondaryLabelColor
        recipientsLabel.lineBreakMode = .byTruncatingTail

        transcript.isEditable = false
        transcript.isSelectable = true
        transcript.isRichText = true
        transcript.drawsBackground = false
        transcript.isVerticallyResizable = true
        transcript.isHorizontallyResizable = false
        transcript.textContainer?.widthTracksTextView = true
        transcript.textContainerInset = NSSize(width: 8, height: 6)
        historyScroll.documentView = transcript
        historyScroll.hasVerticalScroller = true
        historyScroll.scrollerStyle = .overlay
        historyScroll.drawsBackground = false
        historyScroll.borderType = .noBorder
        historyScroll.heightAnchor.constraint(equalToConstant: 72).isActive = true

        input.isRichText = false
        input.drawsBackground = false
        input.isVerticallyResizable = true
        input.isHorizontallyResizable = false
        input.textContainer?.widthTracksTextView = true
        input.font = .systemFont(ofSize: 13)
        input.textColor = .labelColor
        input.textContainerInset = NSSize(width: 7, height: 6)
        input.allowsUndo = true
        input.delegate = self
        input.setAccessibilityLabel("临时会话输入框")
        input.toolTip = "在这里输入聊天消息，回车发送，Shift＋回车换行"
        input.onSubmit = { [weak self] in self?.send() }
        input.onFocusChange = { [weak self] active in self?.privacy.keyboardActive = active }
        let edit = NSMenu(title: "编辑")
        for (title, selector, key) in [("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"),
                                        ("剪切", #selector(NSText.cut(_:)), "x"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
            edit.addItem(NSMenuItem(title: title, action: selector, keyEquivalent: key))
        }
        input.menu = edit
        let inputScroll = NSScrollView()
        inputScroll.documentView = input
        inputScroll.hasVerticalScroller = true
        inputScroll.scrollerStyle = .overlay
        inputScroll.drawsBackground = false
        inputScroll.borderType = .noBorder
        let inputFrame = PopoverEditorFrame()
        inputFrame.addSubview(inputScroll)
        inputScroll.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            inputScroll.leadingAnchor.constraint(equalTo: inputFrame.leadingAnchor, constant: 2),
            inputScroll.trailingAnchor.constraint(equalTo: inputFrame.trailingAnchor, constant: -2),
            inputScroll.topAnchor.constraint(equalTo: inputFrame.topAnchor, constant: 2),
            inputScroll.bottomAnchor.constraint(equalTo: inputFrame.bottomAnchor, constant: -2)
        ])
        sendButton.target = self
        sendButton.action = #selector(send)
        sendButton.symbolName = "paperplane.fill"
        sendButton.primary = true
        sendButton.widthAnchor.constraint(equalToConstant: 80).isActive = true
        let inputRow = NSStackView(views: [inputFrame, sendButton])
        inputRow.orientation = .horizontal
        inputRow.alignment = .centerY
        inputRow.spacing = 8
        inputRow.heightAnchor.constraint(equalToConstant: 36).isActive = true
        inputFrame.heightAnchor.constraint(equalTo: inputRow.heightAnchor).isActive = true
        sendButton.heightAnchor.constraint(equalTo: inputRow.heightAnchor).isActive = true
        inputFrame.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let chatContent = NSStackView(views: [historyScroll, inputRow])
        chatContent.orientation = .vertical
        chatContent.alignment = .leading
        chatContent.spacing = 6
        historyScroll.widthAnchor.constraint(equalTo: chatContent.widthAnchor).isActive = true
        inputRow.widthAnchor.constraint(equalTo: chatContent.widthAnchor).isActive = true
        privacy.addSubview(chatContent)
        chatContent.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            chatContent.leadingAnchor.constraint(equalTo: privacy.leadingAnchor),
            chatContent.trailingAnchor.constraint(equalTo: privacy.trailingAnchor),
            chatContent.topAnchor.constraint(equalTo: privacy.topAnchor),
            chatContent.bottomAnchor.constraint(equalTo: privacy.bottomAnchor)
        ])
        privacy.keepShieldOnTop()
        privacy.onInteraction = { [weak self] in self?.onRead?() }
        let stack = NSStackView(views: [header, recipientsLabel, privacy])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 5
        [header, recipientsLabel, privacy].forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor), stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        updateSendButton()
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) }
        windowObserver = nil
        if let window {
            windowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                self?.conceal()
            }
        }
    }
    deinit { if let windowObserver { NotificationCenter.default.removeObserver(windowObserver) } }

    func setRecipients(_ names: [String]) {
        hasRecipients = !names.isEmpty
        recipientsLabel.stringValue = names.isEmpty ? "先选择上方接收电脑" : "发给：" + names.joined(separator: "、")
        recipientsLabel.toolTip = recipientsLabel.stringValue
        updateSendButton()
    }
    func setUnreadCount(_ count: Int) { unreadLabel.stringValue = count > 0 ? "\(count) 条未读" : "" }
    func setTranscript(_ value: NSAttributedString) {
        if value.length == 0 {
            transcript.string = "点击下方输入框，开始临时聊天。"
            transcript.textColor = .secondaryLabelColor
            transcript.font = .systemFont(ofSize: 12)
        } else {
            transcript.textStorage?.setAttributedString(value)
        }
        transcript.scrollToEndOfDocument(nil)
    }
    func focusInput() {
        guard let window else { return }
        if window.makeFirstResponder(input) { privacy.keyboardActive = true }
    }
    func conceal() { privacy.conceal() }
    func finishSending(_ text: String, success: Bool) {
        sending = false
        if success && input.string.trimmingCharacters(in: .whitespacesAndNewlines) == text { input.string = "" }
        updateSendButton()
    }
    func textDidBeginEditing(_ notification: Notification) { privacy.keyboardActive = true }
    func textDidEndEditing(_ notification: Notification) { privacy.keyboardActive = false }
    func textDidChange(_ notification: Notification) { updateSendButton(); onRead?() }
    private func updateSendButton() {
        sendButton.isEnabled = hasRecipients && !sending && !input.string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        sendButton.needsDisplay = true
    }
    @objc private func send() {
        let text = input.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard hasRecipients, !sending, !text.isEmpty else { return }
        sending = true
        updateSendButton()
        onSend?(text)
    }
}
