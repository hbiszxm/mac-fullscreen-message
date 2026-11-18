import AppKit
import ServiceManagement

private final class SendChoice: NSObject {
    let text: String
    let peerID: String?
    init(text: String, peerID: String?) { self.text = text; self.peerID = peerID }
}

private final class PayloadButton: PopoverButton {
    var payload = ""
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private var statusItem: NSStatusItem!
    private let statusBadgeView = StatusUnreadBadgeView()
    private let statusMenu = NSMenu()
    private var messenger: LANMessenger!
    private var peers: [Peer] = []
    private var activeAlert: FullScreenAlertController?
    private var activeAlertID: UUID?
    // Only alerts received during an available session are auto-advanced.
    private var liveAlertQueue: [UUID] = []
    private var alertAdvanceToken: UUID?
    private var pendingAlertButton: NSButton?
    private let pendingStore = PendingMessageStore()
    private let presentationAvailability = PresentationAvailability()
    private let sendToasts = SendToastStack()
    private var lastStatus = "正在启动…"
    private var activity: NSObjectProtocol?
    private var automaticUpdateTimer: Timer?
    private var updateInProgress = false
    private let restartCommand = "pkill -x FullscreenMessage; open \"/Applications/全屏消息.app\""
    private let uninstallCommand = "curl -fsSL \"https://github.com/hbiszxm/mac-fullscreen-message/releases/latest/download/uninstall.sh?cache=$(date +%s)\" | /bin/bash"
    private let menuMessageView = PopoverMessageTextView()
    private let menuSendButton = PopoverButton(title: "发送", target: nil, action: nil)
    private let menuFavoriteButton = PopoverButton(title: "收藏", target: nil, action: nil)
    private let customMessagePopover = NSPopover()
    private let statusPopover = NSPopover()
    private let popoverPeerPopup = NSPopUpButton()
    private var menuSelectedPeerID: String?
    private var selectedPopoverPeerIDs: Set<String> = []
    private let installCommand = "curl -fsSL \"https://github.com/hbiszxm/mac-fullscreen-message/releases/latest/download/install-latest.sh?cache=$(date +%s)\" | /bin/bash"
    private let defaultMessages = ["上班", "吸烟", "暗棋"]
    private let peerNameStore = PeerNameStore()
    private var advertisedPeers: [Peer] = []
    private var popoverQuickButtons: [QuickMessageButton] = []
    private let quickMessageOrder = QuickMessageOrderStore()
    private var quickMessageDragging = false
    private var refreshAfterQuickDrag = false
    private var orderedQuickMessages: [String] {
        quickMessageOrder.messages(available: defaultMessages + customMessages)
    }

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
        clearRetiredData()
        refreshUnreadIndicators()
        presentationAvailability.start { [weak self] available in
            self?.presentationAvailabilityChanged(available)
        }
        configureMessenger()
        enableLoginItemOnFirstInstalledLaunch()
        activity = ProcessInfo.processInfo.beginActivity(options: [.automaticTerminationDisabled, .suddenTerminationDisabled], reason: "持续接收局域网消息")
        startAutomaticUpdates()
    }

    func applicationWillTerminate(_ notification: Notification) { presentationAvailability.stop() }

    private func clearRetiredData() {
        UserDefaults.standard.removeObject(forKey: "messageHistoryV1")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    private func createStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageOnly
            button.imageScaling = .scaleNone
            statusBadgeView.frame = button.bounds
            statusBadgeView.autoresizingMask = [.width, .height]
            statusBadgeView.setAccessibilityElement(false)
            button.addSubview(statusBadgeView)
        }
        updateStatusItemIcon()
        statusItem.button?.target = self
        statusItem.button?.action = #selector(toggleStatusPopover)
        rebuildStatusMenu()
    }

    private func rebuildStatusMenu() {
        if statusItem.menu == nil {
            rebuildStatusPopover()
            return
        }
        statusMenu.removeAllItems()
        for text in orderedQuickMessages {
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
        addCustomMessageTargetMenu()
        addInlineMessageComposer()
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
        statusMenu.addItem(.separator())
        addMoreMenu()
    }

    @objc private func toggleStatusPopover() {
        guard let button = statusItem.button else { return }
        if statusPopover.isShown { statusPopover.performClose(nil); return }
        rebuildStatusPopover()
        NSApp.activate(ignoringOtherApps: true)
        statusPopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            self.statusPopover.contentViewController?.view.window?.makeFirstResponder(self.menuMessageView)
        }
    }

    private func rebuildStatusPopover() {
        guard !quickMessageDragging else { refreshAfterQuickDrag = true; return }
        let restoreEditorFocus = menuMessageView.window?.firstResponder === menuMessageView
        let selection = menuMessageView.selectedRange()
        statusPopover.delegate = self
        statusPopover.behavior = .transient
        statusPopover.animates = true
        var width: CGFloat = 280
        let panelInset: CGFloat = 12
        let contentWidth = width - 2 * panelInset
        let screen = statusItem.button?.window?.screen ?? NSScreen.main
        let availableHeight = max(280, (screen?.visibleFrame.height ?? 800) - 40)
        var rowHeights: [NSLayoutConstraint] = []
        var columns: [(NSStackView, CGFloat)] = []
        func row(_ views: [NSView]) -> NSStackView {
            let row = NSStackView(views: views)
            row.orientation = .horizontal
            row.alignment = .centerY
            row.distribution = .fillEqually
            row.spacing = 8
            let height = row.heightAnchor.constraint(equalToConstant: 34)
            height.isActive = true
            rowHeights.append(height)
            views.forEach { $0.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true }
            return row
        }
        func column(_ views: [NSView], spacing: CGFloat = 8) -> NSStackView {
            let stack = NSStackView(views: views)
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = spacing
            columns.append((stack, spacing))
            views.forEach { $0.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
            return stack
        }
        func heading(_ title: String) -> NSTextField {
            let label = NSTextField(labelWithString: title)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.textColor = .secondaryLabelColor
            return label
        }
        func button(_ title: String, symbol: String, action: Selector) -> PopoverButton {
            let button = PopoverButton(title: title, target: self, action: action)
            button.symbolName = symbol
            return button
        }
        func command(_ title: String, symbol: String, value: String) -> PayloadButton {
            let button = PayloadButton(title: title, target: self, action: #selector(copyPayloadCommand(_:)))
            button.payload = value
            button.symbolName = symbol
            return button
        }
        func separator() -> NSView {
            let line = NSBox()
            line.boxType = .separator
            line.heightAnchor.constraint(equalToConstant: 1).isActive = true
            return line
        }

        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? ""
        let versionLabel = heading("V\(version)")
        versionLabel.alignment = .right
        let header = column([versionLabel])

        selectedPopoverPeerIDs.formIntersection(Set(peers.map(\.id)))
        var deviceRows: [NSView] = []
        if peers.isEmpty {
            deviceRows.append(heading("暂无在线电脑"))
        } else {
            for start in stride(from: 0, to: peers.count, by: 2) {
                var devices: [NSView] = []
                for index in start..<min(start + 2, peers.count) {
                    let peer = peers[index]
                    let device = DeviceChoiceButton(title: peer.name, target: self, action: #selector(togglePopoverPeer(_:)))
                    device.peerID = peer.id
                    device.isChosen = selectedPopoverPeerIDs.contains(peer.id)
                    device.leadingAligned = true
                    device.symbolName = "laptopcomputer"
                    device.toolTip = "\(peer.name) · 右键重命名或删除"
                    let menu = NSMenu()
                    for (title, action) in [("重命名", #selector(renamePeer(_:))), ("删除", #selector(removePeer(_:)))] {
                        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                        item.target = self
                        item.representedObject = peer.id
                        menu.addItem(item)
                    }
                    device.menu = menu
                    devices.append(device)
                }
                if devices.count == 1 { devices.append(NSView()) }
                deviceRows.append(row(devices))
            }
        }
        let devices = column(deviceRows)

        popoverQuickButtons.removeAll()
        var quickRows: [NSView] = []
        let messages = orderedQuickMessages
        for start in stride(from: 0, to: messages.count, by: 3) {
            var buttons: [NSView] = []
            for index in start..<min(start + 3, messages.count) {
                let text = messages[index]
                let quick = QuickMessageButton(title: text, target: self, action: #selector(sendQuickMessageFromPopover(_:)))
                quick.messageText = text
                quick.toolTip = "\(text) · 拖动调整顺序，点击发送"
                quick.onDragBegan = { [weak self] in
                    self?.quickMessageDragging = true
                    self?.statusPopover.behavior = .applicationDefined
                }
                quick.onMove = { [weak self] source, target in
                    guard let self else { return }
                    if self.quickMessageOrder.move(source, to: target, available: self.defaultMessages + self.customMessages) {
                        self.refreshAfterQuickDrag = true
                    }
                }
                quick.onDragEnded = { [weak self] in
                    guard let self else { return }
                    self.quickMessageDragging = false
                    self.statusPopover.behavior = .transient
                    if self.refreshAfterQuickDrag {
                        self.refreshAfterQuickDrag = false
                        DispatchQueue.main.async { [weak self] in self?.rebuildStatusPopover() }
                    }
                }
                quick.isEnabled = !selectedPopoverPeerIDs.isEmpty
                if customMessages.contains(text) {
                    let menu = NSMenu()
                    let remove = NSMenuItem(title: "删除收藏", action: #selector(deleteCustomMessage(_:)), keyEquivalent: "")
                    remove.target = self
                    remove.representedObject = text
                    menu.addItem(remove)
                    quick.menu = menu
                }
                popoverQuickButtons.append(quick)
                buttons.append(quick)
            }
            while buttons.count < 3 { buttons.append(NSView()) }
            quickRows.append(row(buttons))
        }
        let shortcuts = column([heading("快捷消息"), column(quickRows)])

        configurePopoverMessageEditorIfNeeded()
        let editor = NSScrollView()
        editor.borderType = .noBorder
        editor.hasVerticalScroller = true
        editor.scrollerStyle = .overlay
        editor.documentView = menuMessageView
        editor.drawsBackground = false
        editor.translatesAutoresizingMaskIntoConstraints = false
        let editorFrame = PopoverEditorFrame()
        editorFrame.addSubview(editor)
        let editorHeight = editorFrame.heightAnchor.constraint(equalToConstant: 76)
        NSLayoutConstraint.activate([
            editorHeight,
            editor.leadingAnchor.constraint(equalTo: editorFrame.leadingAnchor, constant: 3),
            editor.trailingAnchor.constraint(equalTo: editorFrame.trailingAnchor, constant: -3),
            editor.topAnchor.constraint(equalTo: editorFrame.topAnchor, constant: 3),
            editor.bottomAnchor.constraint(equalTo: editorFrame.bottomAnchor, constant: -3)
        ])
        menuFavoriteButton.target = self
        menuFavoriteButton.action = #selector(favoriteInlineMenuMessage)
        menuFavoriteButton.symbolName = "star"
        menuSendButton.target = self
        menuSendButton.action = #selector(sendInlineMenuMessage)
        menuSendButton.symbolName = "paperplane.fill"
        menuSendButton.primary = true
        menuSendButton.isEnabled = !selectedPopoverPeerIDs.isEmpty
        let composer = column([heading("自定义消息"), editorFrame, row([menuFavoriteButton, menuSendButton])])

        var pendingViews: [NSView] = []
        pendingAlertButton = nil
        if !pendingStore.alertMessages.isEmpty {
            let pending = button("待查看全屏消息 · \(pendingStore.alertMessages.count) 条", symbol: "envelope.badge", action: #selector(viewNextPendingAlert))
            pending.heightAnchor.constraint(equalToConstant: 34).isActive = true
            pendingAlertButton = pending
            pendingViews.append(pending)
        }
        let management = button("检查更新", symbol: "arrow.triangle.2.circlepath", action: #selector(checkForUpdates))
        let commands = row([
            command("复制重启命令", symbol: "arrow.clockwise", value: restartCommand),
            command("复制卸载命令", symbol: "trash", value: uninstallCommand)
        ])
        let login = button("开机自动运行", symbol: "circle", action: #selector(toggleLoginItem(_:)))
        if #available(macOS 13.0, *), SMAppService.mainApp.status == .enabled { login.symbolName = "checkmark.circle" }
        let footer = row([login, button("退出全屏消息", symbol: "power", action: #selector(quitApp))])
        let utilities = column(pendingViews + [management, commands, footer])
        var stack = column([header, devices, shortcuts, composer, separator(), utilities], spacing: 12)
        let columnWidth = stack.widthAnchor.constraint(equalToConstant: contentWidth)
        columnWidth.isActive = true
        var height = ceil(stack.fittingSize.height) + 2 * panelInset
        if height > availableHeight {
            // Fit the controls themselves instead of clipping a scrolling document.
            rowHeights.forEach { $0.constant = 30 }
            columns.forEach { $0.0.spacing = max(4, $0.1 - 4) }
            editorHeight.constant = 56
            height = ceil(stack.fittingSize.height) + 2 * panelInset
        }
        if height > availableHeight, (screen?.visibleFrame.width ?? 1440) >= 800 {
            // Short screens keep every section on the same panel, side by side.
            let sections = [header, devices, shortcuts, composer, utilities]
            for section in sections {
                stack.removeArrangedSubview(section)
                section.removeFromSuperview()
            }
            let left = column([devices, shortcuts, composer], spacing: 8)
            let right = column([utilities], spacing: 8)
            let body = NSStackView(views: [left, right])
            body.orientation = .horizontal
            body.alignment = .top
            body.distribution = .fillEqually
            body.spacing = 16
            left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
            width = 2 * contentWidth + 2 * panelInset + 16
            columnWidth.isActive = false
            stack = column([header, body], spacing: 10)
            stack.widthAnchor.constraint(equalToConstant: width - 2 * panelInset).isActive = true
            height = ceil(stack.fittingSize.height) + 2 * panelInset
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = PopoverBackgroundView(frame: NSRect(x: 0, y: 0, width: width, height: height))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: panelInset),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: panelInset),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -panelInset),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -panelInset)
        ])
        let controller = NSViewController()
        controller.view = container
        statusPopover.contentViewController = controller
        statusPopover.contentSize = container.frame.size
        container.layoutSubtreeIfNeeded()
        if restoreEditorFocus {
            menuMessageView.setSelectedRange(selection)
            container.window?.makeFirstResponder(menuMessageView)
            DispatchQueue.main.async { [weak self, weak container] in
                guard let self, let container, self.statusPopover.contentViewController?.view === container else { return }
                container.window?.makeFirstResponder(self.menuMessageView)
            }
        }
    }

    private func configurePopoverMessageEditorIfNeeded() {
        menuMessageView.font = .systemFont(ofSize: 14)
        menuMessageView.isRichText = false
        menuMessageView.isVerticallyResizable = true
        menuMessageView.isHorizontallyResizable = false
        menuMessageView.backgroundColor = .textBackgroundColor
        menuMessageView.drawsBackground = false
        menuMessageView.allowsUndo = true
        menuMessageView.textColor = .labelColor
        menuMessageView.textContainerInset = NSSize(width: 8, height: 7)
        menuMessageView.textContainer?.widthTracksTextView = true
        if menuMessageView.menu == nil {
            let editMenu = NSMenu(title: "编辑")
            for (title, action, key) in [("剪切", #selector(NSText.cut(_:)), "x"), ("复制", #selector(NSText.copy(_:)), "c"), ("粘贴", #selector(NSText.paste(_:)), "v"), ("全选", #selector(NSText.selectAll(_:)), "a")] {
                editMenu.addItem(NSMenuItem(title: title, action: action, keyEquivalent: key))
            }
            menuMessageView.menu = editMenu
        }
    }

    @objc private func sendQuickMessageFromPopover(_ sender: QuickMessageButton) {
        let targets = peers.filter { selectedPopoverPeerIDs.contains($0.id) }
        send(sender.messageText, to: targets)
    }

    @objc private func togglePopoverPeer(_ sender: DeviceChoiceButton) {
        if selectedPopoverPeerIDs.contains(sender.peerID) {
            selectedPopoverPeerIDs.remove(sender.peerID)
        } else {
            selectedPopoverPeerIDs.insert(sender.peerID)
        }
        sender.isChosen = selectedPopoverPeerIDs.contains(sender.peerID)
        menuSendButton.isEnabled = !selectedPopoverPeerIDs.isEmpty
        menuSendButton.needsDisplay = true
        for button in popoverQuickButtons {
            button.isEnabled = !selectedPopoverPeerIDs.isEmpty
            button.needsDisplay = true
        }
    }

    @objc private func renamePeer(_ sender: NSMenuItem) {
        guard let peerID = sender.representedObject as? String,
              let peer = advertisedPeers.first(where: { $0.id == peerID }) else { return }
        statusPopover.performClose(nil)
        let alert = NSAlert()
        alert.messageText = "重命名设备"
        alert.informativeText = "设置这台电脑上显示的设备名称。"
        let name = NSTextField(string: peerNameStore.displayName(for: peer))
        name.frame = NSRect(x: 0, y: 0, width: 300, height: 26)
        alert.accessoryView = name
        alert.addButton(withTitle: "保存")
        alert.addButton(withTitle: "取消")
        alert.window.initialFirstResponder = name
        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            if peerNameStore.setName(name.stringValue, for: peer) {
                updatePeers(advertisedPeers)
                setStatus("已重命名为 \(peerNameStore.displayName(for: peer))", success: true)
            } else {
                setStatus("名称不能为空", success: false)
            }
        }
        toggleStatusPopover()
    }

    private func addMoreMenu() {
        let root = NSMenuItem(title: "更多", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "更多")

        let update = NSMenuItem(title: "检查更新…", action: #selector(checkForUpdates), keyEquivalent: "")
        update.target = self
        submenu.addItem(update)
        let login = NSMenuItem(title: "开机自动运行", action: #selector(toggleLoginItem(_:)), keyEquivalent: "")
        login.target = self
        if #available(macOS 13.0, *) {
            let state: NSControl.StateValue = SMAppService.mainApp.status == .enabled ? .on : .off
            login.state = state
        }
        submenu.addItem(login)
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
            submenu.addItem(removeRoot)
        }
        submenu.addItem(.separator())

        let commands: [(String, String)] = [
            ("复制安装/更新命令", installCommand),
            ("复制重启命令", restartCommand),
            ("复制卸载命令", uninstallCommand)
        ]
        for (title, command) in commands {
            let item = NSMenuItem(title: title, action: #selector(copyMenuCommand(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = command
            submenu.addItem(item)
        }
        submenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出全屏消息", action: #selector(quitApp), keyEquivalent: "q")
        quit.target = self
        submenu.addItem(quit)
        root.submenu = submenu
        statusMenu.addItem(root)
    }

    @objc private func copyMenuCommand(_ sender: NSMenuItem) {
        guard let command = sender.representedObject as? String else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(command, forType: .string)
        setStatus("命令已复制", success: true)
    }

    @objc private func copyPayloadCommand(_ sender: PayloadButton) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(sender.payload, forType: .string)
        setStatus("命令已复制", success: true)
        rebuildStatusPopover()
    }

    @objc private func removePeerButton(_ sender: PayloadButton) {
        guard let peer = peers.first(where: { $0.id == sender.payload }) else { return }
        messenger.dismissPeer(id: peer.id)
        setStatus("已移除 \(peer.name)，对方重启后会重新上线", success: true)
        rebuildStatusPopover()
    }

    @objc private func deleteCustomMessageButton(_ sender: PayloadButton) {
        customMessages = customMessages.filter { $0 != sender.payload }
        setStatus("已删除快捷消息", success: true)
        rebuildStatusMenu()
    }

    private func addCustomMessageTargetMenu() {
        if let selected = menuSelectedPeerID, !peers.contains(where: { $0.id == selected }) {
            menuSelectedPeerID = nil
        }
        let root = NSMenuItem(title: "选择自定义消息接收电脑", action: nil, keyEquivalent: "")
        let submenu = NSMenu(title: "选择接收电脑")
        let all = NSMenuItem(title: "所有电脑", action: #selector(selectInlineMessageTarget(_:)), keyEquivalent: "")
        all.target = self
        all.representedObject = NSNull()
        all.state = menuSelectedPeerID == nil ? .on : .off
        submenu.addItem(all)
        if !peers.isEmpty { submenu.addItem(.separator()) }
        for peer in peers {
            let item = NSMenuItem(title: peer.name, action: #selector(selectInlineMessageTarget(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = peer.id
            item.state = menuSelectedPeerID == peer.id ? .on : .off
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

    @objc private func selectInlineMessageTarget(_ sender: NSMenuItem) {
        menuSelectedPeerID = sender.representedObject as? String
        rebuildStatusMenu()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.12) { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    private func addInlineMessageComposer() {
        let item = NSMenuItem(title: "写自定义消息…", action: #selector(showCustomMessageEditor), keyEquivalent: "")
        item.target = self
        item.isEnabled = !peers.isEmpty
        statusMenu.addItem(item)
    }

    @objc private func showCustomMessageEditor() {
        if customMessagePopover.contentViewController == nil { buildCustomMessagePopover() }
        popoverPeerPopup.removeAllItems()
        popoverPeerPopup.addItem(withTitle: "所有电脑（\(peers.count) 台）")
        peers.forEach { popoverPeerPopup.addItem(withTitle: $0.name) }
        if let selectedID = menuSelectedPeerID,
           let index = peers.firstIndex(where: { $0.id == selectedID }) {
            popoverPeerPopup.selectItem(at: index + 1)
        } else {
            popoverPeerPopup.selectItem(at: 0)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, let button = self.statusItem.button else { return }
            NSApp.activate(ignoringOtherApps: true)
            self.customMessagePopover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                self.customMessagePopover.contentViewController?.view.window?.makeFirstResponder(self.menuMessageView)
            }
        }
    }

    private func buildCustomMessagePopover() {
        customMessagePopover.behavior = .transient
        customMessagePopover.animates = true

        menuMessageView.font = .systemFont(ofSize: 14)
        menuMessageView.isRichText = false
        menuMessageView.textContainerInset = NSSize(width: 8, height: 7)
        menuMessageView.isVerticallyResizable = true
        menuMessageView.isHorizontallyResizable = false
        menuMessageView.textContainer?.widthTracksTextView = true
        menuMessageView.toolTip = "支持粘贴、复制、剪切和全选"
        let editMenu = NSMenu(title: "编辑")
        for (title, action, key) in [
            ("剪切", #selector(NSText.cut(_:)), "x"),
            ("复制", #selector(NSText.copy(_:)), "c"),
            ("粘贴", #selector(NSText.paste(_:)), "v"),
            ("全选", #selector(NSText.selectAll(_:)), "a")
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
            editMenu.addItem(item)
        }
        menuMessageView.menu = editMenu
        let messageScroll = NSScrollView()
        messageScroll.borderType = .noBorder
        messageScroll.hasVerticalScroller = true
        messageScroll.documentView = menuMessageView
        messageScroll.wantsLayer = true
        messageScroll.layer?.cornerRadius = 10
        messageScroll.layer?.borderWidth = 1
        messageScroll.layer?.borderColor = NSColor.separatorColor.cgColor
        messageScroll.layer?.masksToBounds = true
        messageScroll.backgroundColor = .controlBackgroundColor
        messageScroll.translatesAutoresizingMaskIntoConstraints = false
        messageScroll.heightAnchor.constraint(equalToConstant: 92).isActive = true
        messageScroll.widthAnchor.constraint(equalToConstant: 330).isActive = true
        popoverPeerPopup.target = self
        popoverPeerPopup.action = #selector(selectPopoverMessageTarget)
        menuSendButton.target = self
        menuSendButton.action = #selector(sendInlineMenuMessage)
        menuSendButton.bezelStyle = .rounded
        menuSendButton.controlSize = .small
        menuFavoriteButton.target = self
        menuFavoriteButton.action = #selector(favoriteInlineMenuMessage)
        menuFavoriteButton.bezelStyle = .rounded
        menuFavoriteButton.controlSize = .small

        let title = NSTextField(labelWithString: "自定义全屏消息")
        title.font = .systemFont(ofSize: 16, weight: .bold)
        let targetLabel = NSTextField(labelWithString: "接收电脑")
        targetLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let targetRow = NSStackView(views: [targetLabel, popoverPeerPopup])
        targetRow.orientation = .horizontal
        targetRow.alignment = .centerY
        targetRow.spacing = 10
        popoverPeerPopup.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttonRow = NSStackView(views: [menuFavoriteButton, menuSendButton])
        buttonRow.orientation = .horizontal
        buttonRow.alignment = .centerY
        buttonRow.spacing = 8
        buttonRow.distribution = .fillEqually
        buttonRow.widthAnchor.constraint(equalToConstant: 180).isActive = true
        let stack = NSStackView(views: [title, targetRow, messageScroll, buttonRow])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.translatesAutoresizingMaskIntoConstraints = false
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 370, height: 220))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -20),
            stack.topAnchor.constraint(equalTo: container.topAnchor, constant: 18),
            stack.bottomAnchor.constraint(equalTo: container.bottomAnchor, constant: -18),
            targetRow.widthAnchor.constraint(equalTo: stack.widthAnchor),
            buttonRow.trailingAnchor.constraint(equalTo: stack.trailingAnchor)
        ])
        let controller = NSViewController()
        controller.view = container
        customMessagePopover.contentViewController = controller
        customMessagePopover.contentSize = container.frame.size
    }

    @objc private func selectPopoverMessageTarget() {
        let index = popoverPeerPopup.indexOfSelectedItem
        if index <= 0 {
            menuSelectedPeerID = nil
        } else if peers.indices.contains(index - 1) {
            menuSelectedPeerID = peers[index - 1].id
        }
        if !statusPopover.isShown { rebuildStatusMenu() }
    }

    @objc private func sendInlineMenuMessage() {
        let text = menuMessageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { setStatus("请先输入消息内容", success: false); return }
        let targets = peers.filter { selectedPopoverPeerIDs.contains($0.id) }
        guard !targets.isEmpty else { setStatus("请选择接收电脑", success: false); return }
        send(text, to: targets) { [weak self] success in
            guard let self, success,
                  self.menuMessageView.string.trimmingCharacters(in: .whitespacesAndNewlines) == text else { return }
            self.menuMessageView.string = ""
        }
    }

    @objc private func favoriteInlineMenuMessage() {
        let text = menuMessageView.string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard addCustomMessage(text) else { return }
        menuMessageView.string = ""
        statusPopover.performClose(nil)
        setStatus("已收藏到快捷消息", success: true)
    }

    private var configuredDisplayName: String {
        let saved = UserDefaults.standard.string(forKey: "displayName")?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let saved, !saved.isEmpty { return saved }
        return Host.current().localizedName ?? "我的 Mac"
    }

    private func configureMessenger() {
        messenger = LANMessenger(displayName: configuredDisplayName)
        messenger.onPeersChanged = { [weak self] peers in self?.updatePeers(peers) }
        messenger.onMessage = { [weak self] message in
            switch message.kind {
            case "accepted", "rejected": self?.handleMessageResponse(message)
            case nil, "alert": self?.showIncoming(message)
            default: break
            }
        }
        messenger.onStatus = { [weak self] text in self?.setStatus(text) }
        messenger.start()
    }

    private func updatePeers(_ discoveredPeers: [Peer]) {
        let previousIDs = Set(peers.map(\.id))
        advertisedPeers = discoveredPeers
        let peers = peerNameStore.renamed(discoveredPeers)
        self.peers = peers
        let onlineIDs = Set(peers.map(\.id))
        selectedPopoverPeerIDs.formIntersection(onlineIDs)
        // Select newly online devices without undoing manual choices on refresh.
        selectedPopoverPeerIDs.formUnion(onlineIDs.subtracting(previousIDs))
        rebuildStatusMenu()
    }

    @objc private func sendChoice(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? SendChoice else { return }
        let targets = choice.peerID == nil ? peers : peers.filter { $0.id == choice.peerID }
        send(choice.text, to: targets)
    }

    private func send(_ text: String, to targets: [Peer], completion: ((Bool) -> Void)? = nil) {
        guard !targets.isEmpty else {
            setStatus("请选择接收电脑", success: false)
            completion?(false)
            return
        }
        setStatus("正在发送…")
        var remaining = targets.count
        var failures = 0
        var failureDetails: [String] = []
        for peer in targets {
            let messageID = UUID()
            messenger.send(text: text, messageID: messageID, to: peer.endpoint) { [weak self] result in
                guard let self else { return }
                switch result {
                case .failure(let error):
                    failures += 1
                    failureDetails.append("\(peer.name)：\(error.localizedDescription)")
                case .success: break
                }
                remaining -= 1
                guard remaining == 0 else { return }
                self.setStatus(failures == 0 ? "已送达，等待对方处理" : "发送失败：\(failureDetails.joined(separator: "；"))", success: failures == 0)
                let targetNames = targets.map(\.name).joined(separator: "、")
                self.showSendToast(message: text, recipients: targetNames, failures: failures)
                completion?(failures == 0)
                if failures > 0 { NSSound.beep() }
            }
        }
    }

    private func addCustomMessage(_ text: String) -> Bool {
        guard !text.isEmpty else { setStatus("请先输入消息内容", success: false); NSSound.beep(); return false }
        guard !defaultMessages.contains(text), !customMessages.contains(text) else {
            setStatus("快捷列表中已经有这条消息", success: false)
            NSSound.beep()
            return false
        }
        var messages = customMessages
        messages.append(text)
        customMessages = messages
        return true
    }

    private func refreshUnreadIndicators() {
        pendingAlertButton?.title = "待查看全屏消息 · \(pendingStore.alertMessages.count) 条"
        pendingAlertButton?.isEnabled = !pendingStore.alertMessages.isEmpty
        updateStatusItemIcon()
    }

    @objc private func deleteCustomMessage(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        customMessages = customMessages.filter { $0 != text }
        setStatus("已删除快捷消息", success: true)
        rebuildStatusMenu()
    }

    @objc private func removePeer(_ sender: NSMenuItem) {
        guard let peerID = sender.representedObject as? String,
              let peer = peers.first(where: { $0.id == peerID }) else { return }
        selectedPopoverPeerIDs.remove(peerID)
        messenger.dismissPeer(id: peerID)
        updatePeers(advertisedPeers.filter { $0.id != peerID })
        setStatus("已移除 \(peer.name)，对方重启后会重新上线", success: true)
    }

    private func showIncoming(_ message: WireMessage) {
        guard pendingStore.add(message) else { return }
        refreshUnreadIndicators()
        setStatus("收到 \(peerNameStore.displayName(for: message)) 的全屏消息，等待查看")
        if presentationAvailability.canPresent {
            liveAlertQueue.append(message.id)
            presentNextLiveAlert()
        }
    }

    private func presentationAvailabilityChanged(_ available: Bool) {
        if !available {
            liveAlertQueue.removeAll()
            alertAdvanceToken = nil
            activeAlert?.suspend()
            activeAlert = nil
            activeAlertID = nil
            statusPopover.performClose(nil)
        }
        // Unlocking never implies reading and does not unexpectedly cover the desktop.
        refreshUnreadIndicators()
    }

    @objc private func viewNextPendingAlert() {
        guard let message = pendingStore.alertMessages.first else { return }
        guard presentationAvailability.canPresent else { return }
        statusPopover.performClose(nil)
        if let activeAlert, activeAlert.isPresented { activeAlert.present(); return }
        alertAdvanceToken = nil
        liveAlertQueue.removeAll { $0 == message.id }
        presentPendingAlert(message)
    }

    private func presentNextLiveAlert() {
        guard activeAlert == nil, alertAdvanceToken == nil,
              presentationAvailability.canPresent else { return }
        while !liveAlertQueue.isEmpty {
            let id = liveAlertQueue.removeFirst()
            guard let message = pendingStore.alertMessages.first(where: { $0.id == id }) else { continue }
            presentPendingAlert(message)
            if activeAlert != nil { return }
        }
    }

    private func scheduleNextLiveAlert() {
        guard !liveAlertQueue.isEmpty else { return }
        let token = UUID()
        alertAdvanceToken = token
        // Let the previous windows close and the response keystroke finish.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.alertAdvanceToken == token else { return }
            self.alertAdvanceToken = nil
            self.presentNextLiveAlert()
        }
    }

    private func presentPendingAlert(_ message: WireMessage) {
        guard presentationAvailability.canPresent,
              let alert = FullScreenAlertController(message: message, senderDisplayName: peerNameStore.displayName(for: message), responseHandler: { [weak self] accepted in
                  self?.finishPendingAlert(message, accepted: accepted)
              }) else { return }
        activeAlert = alert
        activeAlertID = message.id
        if alert.present() { NSSound(named: "Glass")?.play() }
        else {
            alert.suspend()
            activeAlert = nil
            activeAlertID = nil
        }
    }

    private func finishPendingAlert(_ message: WireMessage, accepted: Bool) {
        guard pendingStore.contains(id: message.id) else { return }
        pendingStore.remove(id: message.id)
        liveAlertQueue.removeAll { $0 == message.id }
        if activeAlertID == message.id { activeAlert = nil; activeAlertID = nil }
        refreshUnreadIndicators()
        setStatus(pendingStore.alertMessages.isEmpty ? "全屏消息已处理" : "还有 \(pendingStore.alertMessages.count) 条全屏消息待查看")
        scheduleNextLiveAlert()
        messenger.respond(to: message, accepted: accepted) { [weak self] result in
            if case .failure(let error) = result {
                self?.setStatus("处理结果返回失败：\(error.localizedDescription)", success: false)
            } else {
                self?.setStatus(accepted ? "已向发送者返回：收到" : "已向发送者返回：拒绝", success: true)
            }
        }
    }

    private func handleMessageResponse(_ message: WireMessage) {
        guard message.relatedMessageID != nil else { return }
        let accepted = message.kind == "accepted"
        let name = peerNameStore.displayName(for: message)
        let result = "\(name) \(accepted ? "已收到" : "已拒绝")"
        setStatus(result, success: accepted)
        showSendToast(message: "", recipients: name, failures: 0,
                      titleOverride: result, detailOverride: "全屏消息回执", responseAccepted: accepted)
    }

    @objc private func toggleLoginItem(_ sender: Any) {
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

    @objc private func checkForUpdates() {
        performUpdateCheck(interactive: true)
    }

    private func startAutomaticUpdates() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.performUpdateCheck(interactive: false)
        }
        automaticUpdateTimer = Timer.scheduledTimer(withTimeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in
            self?.performUpdateCheck(interactive: false)
        }
    }

    private func performUpdateCheck(interactive: Bool) {
        guard !updateInProgress else { return }
        updateInProgress = true
        setStatus("正在检查更新…")
        UpdateManager.check { [weak self] result in
            guard let self else { return }
            switch result {
            case .upToDate(let version):
                self.updateInProgress = false
                self.setStatus("当前已是最新版 V\(version)", success: true)
                if interactive {
                    self.showUpdateAlert(title: "已经是最新版", message: "当前版本 V\(version)，无需更新。")
                }
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
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
                            case .failure(let error):
                                self.updateInProgress = false
                                self.setStatus("自动更新失败", success: false)
                                if interactive {
                                    self.showUpdateAlert(title: "自动更新失败", message: error.localizedDescription)
                                }
                            }
                        }
                    case .failure(let error):
                        self.updateInProgress = false
                        self.setStatus("更新下载失败", success: false)
                        if interactive {
                            self.showUpdateAlert(title: "下载失败", message: error.localizedDescription)
                        }
                    }
                }
            case .failure(let error):
                self.updateInProgress = false
                self.setStatus("检查更新失败", success: false)
                if interactive {
                    self.showUpdateAlert(title: "检查更新失败", message: error.localizedDescription)
                }
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

    private func showSendToast(message: String, recipients: String, failures: Int, titleOverride: String? = nil, detailOverride: String? = nil, responseAccepted: Bool? = nil) {
        let card = SendToastView(message: message, recipients: recipients, failures: failures,
                                 titleOverride: titleOverride, detailOverride: detailOverride, responseAccepted: responseAccepted)
        sendToasts.show(card)
    }

    private func setStatus(_ text: String, success: Bool? = nil) {
        lastStatus = text
        updateStatusItemIcon()
        // Keep editor focus and button identity stable while sends complete.
        if statusItem.menu != nil { rebuildStatusMenu() }
    }

    private func updateStatusItemIcon() {
        guard let button = statusItem.button else { return }
        let count = pendingStore.count
        statusItem.length = StatusItemLogo.imageWidth(for: count) + 12
        button.title = ""
        button.image = StatusItemLogo.templateImage(unreadCount: count)
        statusBadgeView.unreadCount = count
        let description = count > 0 ? "全屏消息，\(count) 条未读" : "全屏消息"
        button.toolTip = "\(description)\n\(lastStatus)"
        button.setAccessibilityLabel(description)
    }
}
