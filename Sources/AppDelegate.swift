import AppKit
import ServiceManagement

private final class SendChoice: NSObject {
    let text: String
    let peerID: String?
    init(text: String, peerID: String?) { self.text = text; self.peerID = peerID }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSTextFieldDelegate {
    private var statusItem: NSStatusItem!
    private let statusMenu = NSMenu()
    private var window: NSWindow!
    private var messenger: LANMessenger!
    private var peers: [Peer] = []
    private var alerts: [FullScreenAlertController] = []
    private var lastStatus = "正在启动…"
    private var activity: NSObjectProtocol?
    private let nameField = NSTextField()
    private let peerPopup = NSPopUpButton()
    private let messageView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "正在启动…")
    private let sendButton = NSButton(title: "发送全屏消息", target: nil, action: nil)
    private let saveButton = NSButton(title: "添加到快捷列表", target: nil, action: nil)
    private let defaultMessages = ["上班", "吸烟", "暗棋"]

    private var customMessages: [String] {
        get { UserDefaults.standard.stringArray(forKey: "customMessages") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "customMessages") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        createStatusItem()
        createComposerWindow()
        configureMessenger()
        enableLoginItemOnFirstInstalledLaunch()
        activity = ProcessInfo.processInfo.beginActivity(options: [.automaticTerminationDisabled, .suddenTerminationDisabled], reason: "持续接收局域网消息")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.title = "上班"
        statusItem.button?.font = .systemFont(ofSize: 13, weight: .bold)
        statusItem.button?.toolTip = "全屏消息"
        statusItem.menu = statusMenu
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        statusMenu.removeAllItems()
        let online = NSMenuItem(title: peers.isEmpty ? "未发现其他电脑" : "在线电脑：\(peers.count) 台", action: nil, keyEquivalent: "")
        online.isEnabled = false
        statusMenu.addItem(online)
        let recent = NSMenuItem(title: "状态：\(lastStatus)", action: nil, keyEquivalent: "")
        recent.isEnabled = false
        statusMenu.addItem(recent)
        statusMenu.addItem(.separator())

        for text in defaultMessages + customMessages {
            let root = NSMenuItem(title: "发送：\(text)", action: nil, keyEquivalent: "")
            let submenu = NSMenu(title: text)
            if peers.count > 1 {
                let all = NSMenuItem(title: "所有电脑", action: #selector(sendChoice(_:)), keyEquivalent: "")
                all.target = self
                all.representedObject = SendChoice(text: text, peerID: nil)
                submenu.addItem(all)
                submenu.addItem(.separator())
            }
            for peer in peers {
                let item = NSMenuItem(title: peer.name, action: #selector(sendChoice(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = SendChoice(text: text, peerID: peer.id)
                submenu.addItem(item)
            }
            if peers.isEmpty {
                let none = NSMenuItem(title: "暂无在线电脑", action: nil, keyEquivalent: "")
                none.isEnabled = false
                submenu.addItem(none)
            }
            root.submenu = submenu
            statusMenu.addItem(root)
        }

        statusMenu.addItem(.separator())
        let custom = NSMenuItem(title: "发送自定义消息…", action: #selector(showComposer), keyEquivalent: "")
        custom.target = self
        statusMenu.addItem(custom)
        if !customMessages.isEmpty {
            let deleteRoot = NSMenuItem(title: "删除快捷消息", action: nil, keyEquivalent: "")
            let deleteMenu = NSMenu(title: "删除快捷消息")
            for text in customMessages {
                let item = NSMenuItem(title: text, action: #selector(deleteCustomMessage(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = text
                deleteMenu.addItem(item)
            }
            deleteRoot.submenu = deleteMenu
            statusMenu.addItem(deleteRoot)
        }
        let login = NSMenuItem(title: "开机自动运行", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        if #available(macOS 13.0, *) { login.state = SMAppService.mainApp.status == .enabled ? .on : .off }
        statusMenu.addItem(login)
        statusMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出全屏消息", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        statusMenu.addItem(quit)
    }

    private func createComposerWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "发送自定义消息"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 540, height: 480)
        let root = NSView()
        window.contentView = root

        let title = NSTextField(labelWithString: "发送自定义消息")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let subtitle = NSTextField(wrappingLabelWithString: "自动发现同一局域网内运行“全屏消息”的 Mac，无需配对。")
        subtitle.textColor = .secondaryLabelColor
        nameField.stringValue = UserDefaults.standard.string(forKey: "displayName") ?? Host.current().localizedName ?? "我的 Mac"
        nameField.placeholderString = "本机名称"
        nameField.delegate = self
        peerPopup.addItem(withTitle: "正在查找电脑…")
        peerPopup.isEnabled = false

        messageView.font = .systemFont(ofSize: 18)
        messageView.isRichText = false
        messageView.textContainerInset = NSSize(width: 12, height: 12)
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        scroll.documentView = messageView
        scroll.heightAnchor.constraint(equalToConstant: 180).isActive = true
        sendButton.target = self
        sendButton.action = #selector(sendCustomMessage)
        sendButton.bezelStyle = .rounded
        sendButton.controlSize = .large
        sendButton.font = .systemFont(ofSize: 17, weight: .semibold)
        sendButton.isEnabled = false
        sendButton.heightAnchor.constraint(equalToConstant: 46).isActive = true
        saveButton.target = self
        saveButton.action = #selector(saveCustomMessage)
        saveButton.bezelStyle = .rounded
        saveButton.controlSize = .large
        saveButton.font = .systemFont(ofSize: 15, weight: .medium)
        saveButton.heightAnchor.constraint(equalToConstant: 46).isActive = true
        statusLabel.textColor = .secondaryLabelColor

        let grid = NSGridView(views: [[label("本机名称"), nameField], [label("接收电脑"), peerPopup]])
        grid.rowSpacing = 12
        grid.columnSpacing = 14
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 420
        let messageLabel = label("消息内容")
        let buttonRow = NSStackView(views: [saveButton, sendButton])
        buttonRow.orientation = .horizontal
        buttonRow.distribution = .fillEqually
        buttonRow.spacing = 12
        let stack = NSStackView(views: [title, subtitle, grid, messageLabel, scroll, buttonRow, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(5, after: messageLabel)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])
    }

    private func label(_ text: String) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = .systemFont(ofSize: 14, weight: .medium)
        return field
    }

    private func configureMessenger() {
        messenger = LANMessenger(displayName: nameField.stringValue)
        messenger.onPeersChanged = { [weak self] peers in self?.updatePeers(peers) }
        messenger.onMessage = { [weak self] message in self?.showIncoming(message) }
        messenger.onStatus = { [weak self] text in self?.setStatus(text) }
        messenger.start()
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        let name = nameField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        UserDefaults.standard.set(name, forKey: "displayName")
        messenger.displayName = name
        messenger.start()
    }

    private func updatePeers(_ peers: [Peer]) {
        self.peers = peers
        peerPopup.removeAllItems()
        if peers.isEmpty {
            peerPopup.addItem(withTitle: "暂未发现其他电脑")
            peerPopup.isEnabled = false
            sendButton.isEnabled = false
        } else {
            peers.forEach { peerPopup.addItem(withTitle: $0.name) }
            peerPopup.isEnabled = true
            sendButton.isEnabled = true
        }
        rebuildStatusMenu()
    }

    @objc private func sendChoice(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SendChoice else { return }
        let targets = choice.peerID == nil ? peers : peers.filter { $0.id == choice.peerID }
        send(choice.text, to: targets)
    }

    private func send(_ text: String, to targets: [Peer]) {
        guard !targets.isEmpty else { setStatus("没有发现接收电脑", success: false); NSSound.beep(); return }
        setStatus("正在发送…")
        var remaining = targets.count
        var failures = 0
        for peer in targets {
            messenger.send(text: text, to: peer.endpoint) { [weak self] result in
                if case .failure = result { failures += 1 }
                remaining -= 1
                guard remaining == 0, let self else { return }
                self.setStatus(failures == 0 ? "对方已确认收到" : "发送失败：\(failures) 台未确认", success: failures == 0)
                if failures == 0 { self.messageView.string = "" }
                if failures > 0 { NSSound.beep() }
            }
        }
    }

    @objc private func sendCustomMessage() {
        let text = messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = peerPopup.indexOfSelectedItem
        guard !text.isEmpty, peers.indices.contains(index) else { NSSound.beep(); return }
        send(text, to: [peers[index]])
    }

    @objc private func saveCustomMessage() {
        let text = messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { setStatus("请先输入消息内容", success: false); NSSound.beep(); return }
        guard !defaultMessages.contains(text), !customMessages.contains(text) else {
            setStatus("快捷列表中已经有这条消息", success: false)
            NSSound.beep()
            return
        }
        var messages = customMessages
        messages.append(text)
        customMessages = messages
        rebuildStatusMenu()
        setStatus("已添加到快捷列表", success: true)
    }

    @objc private func deleteCustomMessage(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        customMessages = customMessages.filter { $0 != text }
        setStatus("已删除快捷消息", success: true)
    }

    private func showIncoming(_ message: WireMessage) {
        setStatus("已收到来自 \(message.sender) 的消息", success: true)
        NSSound(named: "Glass")?.play()
        let alert = FullScreenAlertController(message: message)
        alerts.append(alert)
        alert.present()
        alerts = alerts.filter { $0.window?.isVisible == true }
    }

    @objc private func showComposer() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleLoginItem(_ sender: NSMenuItem) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { setStatus("开机启动设置失败：\(error.localizedDescription)", success: false) }
        rebuildStatusMenu()
    }

    private func enableLoginItemOnFirstInstalledLaunch() {
        guard #available(macOS 13.0, *), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        guard !UserDefaults.standard.bool(forKey: "didConfigureLoginItem") else { return }
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: "didConfigureLoginItem")
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    private func setStatus(_ text: String, success: Bool? = nil) {
        lastStatus = text
        statusLabel.stringValue = text
        if success == true { statusItem.button?.title = "上班 ✓" }
        if success == false { statusItem.button?.title = "上班 !" }
        rebuildStatusMenu()
        if success != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 4) { [weak self] in
                self?.statusItem.button?.title = "上班"
            }
        }
    }
}
