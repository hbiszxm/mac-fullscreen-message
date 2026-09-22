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
    private var sendToast: NSPanel?
    private var lastStatus = "正在启动…"
    private var activity: NSObjectProtocol?
    private let nameField = NSTextField()
    private let peerPopup = NSPopUpButton()
    private let messageView = NSTextView()
    private let statusLabel = NSTextField(labelWithString: "正在启动…")
    private let sendButton = NSButton(title: "发送全屏消息", target: nil, action: nil)
    private let saveButton = NSButton(title: "添加到快捷列表", target: nil, action: nil)
    private let homeUpdateButton = NSButton(title: "检查在线更新", target: nil, action: nil)
    private let homeLoginCheckbox = NSButton(checkboxWithTitle: "开机自动运行", target: nil, action: nil)
    private let restartCommandField = NSTextField(string: "pkill -x FullscreenMessage; open \"/Applications/全屏消息.app\"")
    private let copyRestartButton = NSButton(title: "复制命令", target: nil, action: nil)
    private let chatHistoryView = NSTextView()
    private let chatInputField = NSTextField()
    private let chatSendButton = NSButton(title: "发送聊天", target: nil, action: nil)
    private let defaultMessages = ["上班", "吸烟", "暗棋"]

    private var customMessages: [String] {
        get { UserDefaults.standard.stringArray(forKey: "customMessages") ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: "customMessages") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if CommandLine.arguments.contains("--unregister-login-item") {
            if #available(macOS 13.0, *) { try? SMAppService.mainApp.unregister() }
            NSApp.terminate(nil)
            return
        }
        createStatusItem()
        createComposerWindow()
        configureMessenger()
        enableLoginItemOnFirstInstalledLaunch()
        activity = ProcessInfo.processInfo.beginActivity(options: [.automaticTerminationDisabled, .suddenTerminationDisabled], reason: "持续接收局域网消息")
        if CommandLine.arguments.contains("--show-home") { showHome() }
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

        let home = NSMenuItem(title: "显示首页", action: #selector(showHome), keyEquivalent: "")
        home.target = self
        statusMenu.addItem(home)
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
        if !peers.isEmpty {
            let removeRoot = NSMenuItem(title: "移除电脑", action: nil, keyEquivalent: "")
            let removeMenu = NSMenu(title: "移除电脑")
            for peer in peers {
                let item = NSMenuItem(title: peer.name, action: #selector(removePeer(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = peer.id
                removeMenu.addItem(item)
            }
            removeRoot.submenu = removeMenu
            statusMenu.addItem(removeRoot)
        }
        let update = NSMenuItem(title: "检查在线更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        statusMenu.addItem(update)
        let login = NSMenuItem(title: "开机自动运行", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        if #available(macOS 13.0, *) {
            let state: NSControl.StateValue = SMAppService.mainApp.status == .enabled ? .on : .off
            login.state = state
            homeLoginCheckbox.state = state
        }
        statusMenu.addItem(login)
        statusMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出全屏消息", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        statusMenu.addItem(quit)
    }

    private func createComposerWindow() {
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 720, height: 900),
                          styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "全屏消息"
        window.center()
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 660, height: 820)
        let root = NSView()
        window.contentView = root

        let title = NSTextField(labelWithString: "全屏消息")
        title.font = .systemFont(ofSize: 28, weight: .bold)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let subtitle = NSTextField(wrappingLabelWithString: "V\(version) · 自动发现同一局域网内运行“全屏消息”的 Mac，无需配对。")
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
        scroll.heightAnchor.constraint(equalToConstant: 145).isActive = true
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
        homeUpdateButton.target = self
        homeUpdateButton.action = #selector(checkForUpdates)
        homeUpdateButton.bezelStyle = .rounded
        homeUpdateButton.controlSize = .large
        homeLoginCheckbox.target = self
        homeLoginCheckbox.action = #selector(toggleLoginItem(_:))
        restartCommandField.isEditable = false
        restartCommandField.isSelectable = true
        restartCommandField.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        restartCommandField.toolTip = "点击后可以选择并复制重启命令"
        copyRestartButton.target = self
        copyRestartButton.action = #selector(copyRestartCommand)
        copyRestartButton.bezelStyle = .rounded
        chatHistoryView.isEditable = false
        chatHistoryView.isSelectable = true
        chatHistoryView.font = .systemFont(ofSize: 14)
        chatHistoryView.textContainerInset = NSSize(width: 10, height: 9)
        chatHistoryView.string = "临时聊天记录将在这里显示。\n"
        let chatScroll = NSScrollView()
        chatScroll.hasVerticalScroller = true
        chatScroll.borderType = .bezelBorder
        chatScroll.documentView = chatHistoryView
        chatScroll.heightAnchor.constraint(equalToConstant: 125).isActive = true
        chatInputField.placeholderString = "输入聊天内容，按回车发送"
        chatInputField.target = self
        chatInputField.action = #selector(sendChatMessage)
        chatSendButton.target = self
        chatSendButton.action = #selector(sendChatMessage)
        chatSendButton.bezelStyle = .rounded
        chatSendButton.widthAnchor.constraint(equalToConstant: 110).isActive = true
        chatSendButton.isEnabled = false
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
        let settingsLabel = label("设置")
        let settingsRow = NSStackView(views: [homeLoginCheckbox, homeUpdateButton])
        settingsRow.orientation = .horizontal
        settingsRow.distribution = .fillEqually
        settingsRow.spacing = 12
        let restartLabel = label("重启命令")
        let restartRow = NSStackView(views: [restartCommandField, copyRestartButton])
        restartRow.orientation = .horizontal
        restartRow.spacing = 10
        restartCommandField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        copyRestartButton.widthAnchor.constraint(equalToConstant: 110).isActive = true
        let chatLabel = label("临时聊天")
        let chatInputRow = NSStackView(views: [chatInputField, chatSendButton])
        chatInputRow.orientation = .horizontal
        chatInputRow.spacing = 10
        chatInputField.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let stack = NSStackView(views: [title, subtitle, grid, messageLabel, scroll, buttonRow, chatLabel, chatScroll, chatInputRow, settingsLabel, settingsRow, restartLabel, restartRow, statusLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 13
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setCustomSpacing(22, after: subtitle)
        stack.setCustomSpacing(5, after: messageLabel)
        stack.setCustomSpacing(20, after: buttonRow)
        stack.setCustomSpacing(5, after: chatLabel)
        stack.setCustomSpacing(8, after: chatScroll)
        stack.setCustomSpacing(20, after: chatInputRow)
        stack.setCustomSpacing(5, after: settingsLabel)
        stack.setCustomSpacing(15, after: settingsRow)
        stack.setCustomSpacing(5, after: restartLabel)
        root.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 32),
            stack.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -32),
            stack.topAnchor.constraint(equalTo: root.topAnchor, constant: 28),
            scroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            chatScroll.widthAnchor.constraint(equalTo: stack.widthAnchor),
            chatInputRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            chatInputRow.heightAnchor.constraint(equalToConstant: 36),
            settingsRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            settingsRow.heightAnchor.constraint(equalToConstant: 42),
            restartRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            restartRow.heightAnchor.constraint(equalToConstant: 34)
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
        messenger.onMessage = { [weak self] message in
            if message.kind == "chat" { self?.showIncomingChat(message) }
            else { self?.showIncoming(message) }
        }
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
            chatSendButton.isEnabled = false
        } else {
            peerPopup.addItem(withTitle: "所有电脑（\(peers.count) 台）")
            peers.forEach { peerPopup.addItem(withTitle: $0.name) }
            peerPopup.isEnabled = true
            sendButton.isEnabled = true
            chatSendButton.isEnabled = true
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
                let targetNames = targets.map(\.name).joined(separator: "、")
                self.showSendToast(message: text, recipients: targetNames, failures: failures)
                if failures == 0 { self.messageView.string = "" }
                if failures > 0 { NSSound.beep() }
            }
        }
    }

    @objc private func sendCustomMessage() {
        let text = messageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = peerPopup.indexOfSelectedItem
        guard !text.isEmpty, !peers.isEmpty, index >= 0 else { NSSound.beep(); return }
        if index == 0 {
            send(text, to: peers)
        } else {
            let peerIndex = index - 1
            guard peers.indices.contains(peerIndex) else { NSSound.beep(); return }
            send(text, to: [peers[peerIndex]])
        }
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

    @objc private func sendChatMessage() {
        let text = chatInputField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let index = peerPopup.indexOfSelectedItem
        guard !text.isEmpty, !peers.isEmpty, index >= 0 else { NSSound.beep(); return }
        let targets: [Peer]
        if index == 0 {
            targets = peers
        } else {
            let peerIndex = index - 1
            guard peers.indices.contains(peerIndex) else { NSSound.beep(); return }
            targets = [peers[peerIndex]]
        }
        chatSendButton.isEnabled = false
        var remaining = targets.count
        var failures = 0
        for peer in targets {
            messenger.send(text: text, kind: "chat", to: peer.endpoint) { [weak self] result in
                guard let self else { return }
                if case .failure = result { failures += 1 }
                remaining -= 1
                guard remaining == 0 else { return }
                self.chatSendButton.isEnabled = !self.peers.isEmpty
                let targetNames = targets.map(\.name).joined(separator: "、")
                if failures == 0 {
                    self.appendChatLine(sender: "我 → \(targetNames)", text: text, incoming: false)
                    self.chatInputField.stringValue = ""
                    self.setStatus("聊天消息已送达", success: true)
                    self.showSendToast(message: text, recipients: targetNames, failures: 0)
                } else {
                    self.setStatus("聊天发送失败：\(failures) 台未确认", success: false)
                    self.showSendToast(message: text, recipients: targetNames, failures: failures)
                }
            }
        }
    }

    private func showIncomingChat(_ message: WireMessage) {
        appendChatLine(sender: message.sender, text: message.text, incoming: true)
        setStatus("收到 \(message.sender) 的聊天消息", success: true)
        NSSound(named: "Glass")?.play()
        showHome()
        window.makeFirstResponder(chatInputField)
    }

    private func appendChatLine(sender: String, text: String, incoming: Bool) {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        let header = "[\(formatter.string(from: Date()))] \(sender)\n"
        let entry = NSMutableAttributedString(string: header, attributes: [
            .font: NSFont.systemFont(ofSize: 13, weight: .semibold),
            .foregroundColor: incoming ? NSColor.systemBlue : NSColor.systemGreen
        ])
        entry.append(NSAttributedString(string: "\(text)\n\n", attributes: [
            .font: NSFont.systemFont(ofSize: 14),
            .foregroundColor: NSColor.labelColor
        ]))
        chatHistoryView.textStorage?.append(entry)
        chatHistoryView.scrollToEndOfDocument(nil)
    }

    @objc private func deleteCustomMessage(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        customMessages = customMessages.filter { $0 != text }
        setStatus("已删除快捷消息", success: true)
    }

    @objc private func removePeer(_ sender: NSMenuItem) {
        guard let peerID = sender.representedObject as? String,
              let peer = peers.first(where: { $0.id == peerID }) else { return }
        messenger.dismissPeer(id: peerID)
        setStatus("已移除 \(peer.name)，对方重启后会重新上线", success: true)
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
        showHome()
        window.makeFirstResponder(messageView)
    }

    @objc private func showHome() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func toggleLoginItem(_ sender: Any) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { setStatus("开机启动设置失败：\(error.localizedDescription)", success: false) }
        rebuildStatusMenu()
    }

    @objc private func copyRestartCommand() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(restartCommandField.stringValue, forType: .string)
        setStatus("重启命令已复制", success: true)
    }

    private func enableLoginItemOnFirstInstalledLaunch() {
        guard #available(macOS 13.0, *), Bundle.main.bundlePath.hasPrefix("/Applications/") else { return }
        guard !UserDefaults.standard.bool(forKey: "didConfigureLoginItem") else { return }
        try? SMAppService.mainApp.register()
        UserDefaults.standard.set(true, forKey: "didConfigureLoginItem")
    }

    @objc private func quitApp() { NSApp.terminate(nil) }

    @objc private func checkForUpdates() {
        setStatus("正在检查更新…")
        UpdateManager.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .upToDate(let version):
                self.setStatus("当前已是最新版 V\(version)", success: true)
                self.showUpdateAlert(title: "已经是最新版", message: "当前版本 V\(version)，无需更新。")
            case .available(let release):
                self.setStatus("正在下载 V\(release.version)…")
                UpdateManager.download(release) { [weak self] downloadResult in
                    guard let self else { return }
                    switch downloadResult {
                    case .success(let packageURL):
                        self.setStatus("正在后台安装 V\(release.version)…")
                        UpdateManager.installSilently(packageURL: packageURL) { [weak self] installResult in
                            guard let self else { return }
                            switch installResult {
                            case .success:
                                self.setStatus("更新完成，正在重新启动…", success: true)
                            case .failure(let error):
                                self.setStatus("自动更新失败", success: false)
                                self.showUpdateAlert(title: "自动更新失败", message: error.localizedDescription)
                            }
                        }
                    case .failure(let error):
                        self.setStatus("更新下载失败", success: false)
                        self.showUpdateAlert(title: "下载失败", message: error.localizedDescription)
                    }
                }
            case .failure(let error):
                self.setStatus("检查更新失败", success: false)
                self.showUpdateAlert(title: "检查更新失败", message: error.localizedDescription)
            }
        }
    }

    private func showUpdateAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.addButton(withTitle: "确定")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }

    private func showSendToast(message: String, recipients: String, failures: Int) {
        sendToast?.orderOut(nil)

        let size = NSSize(width: 390, height: 168)
        let screen = NSScreen.main ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let finalOrigin = NSPoint(x: visible.maxX - size.width - 24, y: visible.maxY - size.height - 24)
        let panel = NSPanel(contentRect: NSRect(origin: NSPoint(x: finalOrigin.x + 24, y: finalOrigin.y), size: size),
                            styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.ignoresMouseEvents = true

        let card = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        card.material = .hudWindow
        card.blendingMode = .behindWindow
        card.state = .active
        card.wantsLayer = true
        card.layer?.cornerRadius = 18
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor.white.withAlphaComponent(0.16).cgColor
        panel.contentView = card

        let icon = NSTextField(labelWithString: failures == 0 ? "✓" : "!")
        icon.font = .systemFont(ofSize: 26, weight: .bold)
        let accentColor: NSColor = failures == 0 ? .systemGreen : .systemOrange
        icon.textColor = accentColor
        icon.alignment = .center
        icon.wantsLayer = true
        icon.layer?.backgroundColor = accentColor.withAlphaComponent(0.16).cgColor
        icon.layer?.cornerRadius = 19
        icon.translatesAutoresizingMaskIntoConstraints = false

        let title = NSTextField(labelWithString: failures == 0 ? "消息发送成功" : "消息发送未完成")
        title.font = .systemFont(ofSize: 18, weight: .bold)
        title.textColor = .labelColor

        let recipient = NSTextField(wrappingLabelWithString: failures == 0 ? "已发送给：\(recipients)" : "\(failures) 台电脑未确认收到")
        recipient.font = .systemFont(ofSize: 13, weight: .medium)
        recipient.textColor = .secondaryLabelColor
        recipient.maximumNumberOfLines = 2

        let previewText = message.count > 42 ? String(message.prefix(42)) + "…" : message
        let preview = NSTextField(wrappingLabelWithString: previewText)
        preview.font = .systemFont(ofSize: 15)
        preview.textColor = .labelColor
        preview.maximumNumberOfLines = 2

        let textStack = NSStackView(views: [title, recipient, preview])
        textStack.orientation = .vertical
        textStack.alignment = .leading
        textStack.spacing = 7
        textStack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(icon)
        card.addSubview(textStack)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: 20),
            icon.topAnchor.constraint(equalTo: card.topAnchor, constant: 21),
            icon.widthAnchor.constraint(equalToConstant: 38),
            icon.heightAnchor.constraint(equalToConstant: 38),
            textStack.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 14),
            textStack.trailingAnchor.constraint(equalTo: card.trailingAnchor, constant: -20),
            textStack.topAnchor.constraint(equalTo: card.topAnchor, constant: 20),
            textStack.bottomAnchor.constraint(lessThanOrEqualTo: card.bottomAnchor, constant: -18)
        ])

        sendToast = panel
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.25
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().alphaValue = 1
            panel.animator().setFrameOrigin(finalOrigin)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.2) { [weak self, weak panel] in
            guard let panel, panel === self?.sendToast else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.25
                panel.animator().alphaValue = 0
            }, completionHandler: {
                panel.orderOut(nil)
                if self?.sendToast === panel { self?.sendToast = nil }
            })
        }
    }

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
