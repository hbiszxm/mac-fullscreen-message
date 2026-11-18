// Appended to an isolated AppDelegate copy; never starts networking or displays alerts.
extension AppDelegate {
    func runInboxStateTests() {
        inboxExpect(messenger == nil && pendingStore.count == 0, "Start with an isolated empty inbox")
        statusItem = NSStatusBar.system.statusItem(withLength: 0)
        statusItem.isVisible = false
        statusItem.menu = statusMenu
        nameField.stringValue = "隔离测试"
        defer {
            presentationAvailability.stop()
            NSStatusBar.system.removeStatusItem(statusItem)
        }
        presentationAvailability.start { [weak self] in self?.presentationAvailabilityChanged($0) }
        let first = WireMessage(id: UUID(), sender: "测试设备", text: "全屏消息", sentAt: Date(), kind: "alert", senderInstanceID: "test", relatedMessageID: nil)
        showIncoming(first)
        showIncoming(first)
        inboxExpect(pendingStore.count == 1 && statusBadgeView.unreadCount == 1 && activeAlert == nil, "Locked messages must persist once and badge without presentation")
        presentationAvailability.setAvailability(true)
        inboxExpect(activeAlert == nil, "Unlock must not automatically show backlog")
        viewNextPendingAlert()
        inboxExpect(activeAlertID == first.id && pendingStore.count == 1, "Presentation alone must not mark handled")
        let controller = activeAlert!
        presentationAvailability.setAvailability(false)
        controller.simulateEscape()
        inboxExpect(pendingStore.count == 1 && inboxTestResponses.isEmpty, "Suspension must not reject the message")
        presentationAvailability.setAvailability(true)
        viewNextPendingAlert()
        activeAlert?.simulateEscape()
        inboxExpect(pendingStore.count == 0 && inboxTestResponses.last?.0 == first.id, "ESC must handle only its message")
        inboxExpect(PendingMessageStore(defaults: inboxTestDefaults).count == 0, "Handled state must survive restart")
        runSenderAliasTests()
        runResponseFeedbackTests()
        runDefaultSelectionTests()
        runSendingStateTests()
        runLiveAlertQueueTests()
        runRemovedFeaturesTests()
        print("全屏收件集成：锁屏角标、去重、解锁保留、挂起、逐条处理与持久化均通过")
    }

    func runRemovedFeaturesTests() {
        inboxTestDefaults.set(Data("old history".utf8), forKey: "messageHistoryV1")
        clearRetiredData()
        inboxExpect(inboxTestDefaults.object(forKey: "messageHistoryV1") == nil, "Retired history must be removed")
        createComposerWindow()
        window.contentView?.layoutSubtreeIfNeeded()
        func text(_ view: NSView) -> [String] {
            var result = view.subviews.flatMap(text)
            if let field = view as? NSTextField { result.append(field.stringValue) }
            if let button = view as? NSButton { result.append(button.title) }
            return result
        }
        rebuildStatusPopover()
        let labels = text(window.contentView!) + text(statusPopover.contentViewController!.view)
        inboxExpect(!labels.contains { $0.contains("聊天") || $0.contains("会话") || $0.contains("历史") }, "Home and menu must have no retired feature controls")
        inboxExpect(labels.contains("发送全屏消息") && labels.contains("检查更新"), "Primary features must remain available")
        let stack = window.contentView!.subviews.first!
        inboxExpect(stack.frame.minY >= 0, "Home content must fit after removing retired sections")
        window.close()
        print("功能移除：菜单与首页无聊天/历史入口，旧历史清理，界面完整显示")
    }
}

extension AppDelegate {
    func runSenderAliasTests() {
        presentationAvailability.setAvailability(false)
        let peer = Peer(id: "alias-peer", name: "MacBook Air", endpoint: .hostPort(host: "127.0.0.1", port: 1), instanceID: "alias-device")
        peerNameStore.setName("办公室同事", for: peer)
        let message = WireMessage(id: UUID(), sender: "MacBook Air", text: "备注显示测试", sentAt: Date(),
                                  kind: "alert", senderInstanceID: "alias-device", relatedMessageID: nil)
        showIncoming(message)
        inboxExpect(lastStatus.contains("办公室同事"), "Incoming status must show the alias")
        inboxExpect(pendingStore.alertMessages.first { $0.id == message.id }?.sender == "MacBook Air", "Pending storage must retain the original sender")
        peerNameStore.setName("更新后的备注", for: peer)
        presentationAvailability.setAvailability(true)
        FullScreenAlertController.canCreate = true
        FullScreenAlertController.presentationSucceeds = true
        presentPendingAlert(message)
        inboxExpect(activeAlert?.senderDisplayName == "更新后的备注", "Fullscreen presentation must use the current alias even without discovery")
        activeAlert?.simulateEscape()
        inboxExpect(inboxTestResponses.last?.0 == message.id, "Alias presentation must retain the response message identity")
        print("备注集成：全屏展示、接收提示、使用备注；待处理原始消息与回复身份保留")
    }
}

extension AppDelegate {
    func runResponseFeedbackTests() {
        let peer = Peer(id: "response-peer", name: "MacBook Air", endpoint: .hostPort(host: "127.0.0.1", port: 1), instanceID: "response-device")
        peerNameStore.setName("小刘", for: peer)
        for accepted in [true, false] {
            let id = UUID()
            let response = WireMessage(id: UUID(), sender: peer.name, text: accepted ? "收到" : "拒绝", sentAt: Date(),
                                       kind: accepted ? "accepted" : "rejected", senderInstanceID: peer.instanceID, relatedMessageID: id)
            handleMessageResponse(response)
            let expected = accepted ? "小刘 已收到" : "小刘 已拒绝"
            inboxExpect(inboxTestLastToast?.title == expected && lastStatus == expected, "Receipt title and status must use local alias")
            inboxExpect(inboxTestLastToast?.accepted == accepted, "Receipt must select its explicit accepted/rejected style")
            inboxExpect(inboxTestLastToast?.message == "", "Receipts must not rely on stored history")
        }
        print("回执集成：本机备注、收到/拒绝样式、无历史依赖均通过")
    }
}

extension AppDelegate {
    func runDefaultSelectionTests() {
        statusItem.menu = nil
        peers = []
        selectedPopoverPeerIDs = []
        let a = Peer(id: "default-a", name: "设备 A", endpoint: .hostPort(host: "127.0.0.1", port: 1), instanceID: "default-a")
        let b = Peer(id: "default-b", name: "设备 B", endpoint: .hostPort(host: "127.0.0.1", port: 2), instanceID: "default-b")
        let c = Peer(id: "default-c", name: "设备 C", endpoint: .hostPort(host: "127.0.0.1", port: 3), instanceID: "default-c")
        updatePeers([a, b])
        inboxExpect(selectedPopoverPeerIDs == [a.id, b.id] && menuSendButton.isEnabled, "Initially online devices must be selected and ready to send")
        func devices(_ view: NSView) -> [DeviceChoiceButton] {
            (view as? DeviceChoiceButton).map { [$0] } ?? view.subviews.flatMap(devices)
        }
        let buttons = devices(statusPopover.contentViewController!.view)
        inboxExpect(buttons.count == 2 && buttons.allSatisfy { $0.isChosen }, "Initial device backgrounds must show selection")
        togglePopoverPeer(buttons.first { $0.peerID == a.id }!)
        updatePeers([b, a])
        inboxExpect(selectedPopoverPeerIDs == [b.id], "Discovery refresh must preserve a manual deselection")
        peerNameStore.setName("设备备注", for: a)
        updatePeers([a, b, c])
        inboxExpect(selectedPopoverPeerIDs == [b.id, c.id], "New devices must be selected without reselecting renamed devices")
        updatePeers([a, c])
        inboxExpect(selectedPopoverPeerIDs == [c.id], "Offline devices must leave the selection")
        updatePeers([a, b, c])
        inboxExpect(selectedPopoverPeerIDs == [b.id, c.id], "A reconnected device must be selected by default")
        updatePeers([])
        inboxExpect(selectedPopoverPeerIDs.isEmpty && !menuSendButton.isEnabled, "Empty discovery must clear selection and disable sending")
        print("默认选择：首次上线、背景选中、新设备、手动取消保留、离线清理和重新上线均通过")
    }
}
