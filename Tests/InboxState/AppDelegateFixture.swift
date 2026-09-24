// Appended to a temporary copy of AppDelegate.swift so private access remains
// limited to this integration fixture and never changes the shipping source.
extension AppDelegate {
    func runInboxStateTests() {
        precondition(Thread.isMainThread)
        inboxExpect(messenger == nil, "The fixture must not create a messenger")
        inboxExpect(pendingStore.count == 0 && historyStore.entries.isEmpty, "Test defaults must start empty")
        statusItem = NSStatusBar.system.statusItem(withLength: 0)
        statusItem.isVisible = false
        // The legacy menu path avoids constructing/opening an actual popover.
        statusItem.menu = statusMenu
        nameField.stringValue = "隔离收件箱测试"
        defer {
            presentationAvailability.stop()
            NSStatusBar.system.removeStatusItem(statusItem)
        }

        guard let screen = NSScreen.screens.first else { fatalError("This AppKit fixture needs a GUI screen") }
        let testWindow = InboxReadableWindow(
            contentRect: NSRect(x: screen.visibleFrame.midX - 150, y: screen.visibleFrame.midY - 100,
                               width: 300, height: 200),
            styleMask: .borderless, backing: .buffered, defer: false)
        testWindow.isReleasedWhenClosed = false
        window = testWindow
        chatPrivacyView.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
        testWindow.contentView?.addSubview(chatPrivacyView)
        let historyScroll = NSScrollView(frame: NSRect(x: 20, y: 20, width: 240, height: 100))
        historyScroll.documentView = chatHistoryView
        chatPrivacyView.addSubview(historyScroll)
        chatPrivacyView.keepShieldOnTop()
        testWindow.contentView?.layoutSubtreeIfNeeded()

        presentationAvailability.start { [weak self] available in
            self?.presentationAvailabilityChanged(available)
        }
        func message(_ kind: String, _ text: String) -> WireMessage {
            WireMessage(id: UUID(), sender: "测试发送设备", text: text, sentAt: Date(),
                        kind: kind, senderInstanceID: "inbox-test-sender", relatedMessageID: nil)
        }
        func assertCount(_ expected: Int, _ context: String) {
            inboxExpect(pendingStore.count == expected, "\(context): pending count mismatch")
            inboxExpect(statusBadgeView.unreadCount == expected, "\(context): badge mismatch")
            inboxExpect(PendingMessageStore(defaults: inboxTestDefaults).count == expected,
                        "\(context): restored unread state mismatch")
            inboxExpect(messenger == nil, "No messenger may be started by this scenario")
        }

        let firstAlert = message("alert", "锁屏全屏消息")
        let firstChat = message("chat", "锁屏临时聊天")
        showIncoming(firstAlert)
        showIncomingChat(firstChat)
        assertCount(2, "Blocked alert plus chat")
        inboxExpect(activeAlert == nil && FullScreenAlertController.creationCount == 0,
                    "Blocked messages must not construct full-screen UI")
        showIncoming(firstAlert)
        showIncomingChat(firstChat)
        assertCount(2, "Duplicate UUIDs")
        inboxExpect(historyStore.entries.count == 2, "Duplicate UUIDs must not duplicate history")

        testWindow.simulatedReadable = true
        chatPrivacyView.keyboardActive = true
        clearUnreadChatIfVisible()
        assertCount(2, "A readable-looking chat must remain unread while session is blocked")
        presentationAvailability.setAvailability(true)
        assertCount(2, "Unlocking")
        inboxExpect(FullScreenAlertController.presentationCount == 0, "Unlocking must not auto-present")
        chatPrivacyView.conceal()
        clearUnreadChatIfVisible()
        assertCount(2, "Concealed chat")

        chatPrivacyView.keyboardActive = true
        inboxExpect(historyScroll.isFullyVisibleInActiveWindow, "Simulated chat must satisfy the real visibility checks")
        clearUnreadChatIfVisible()
        assertCount(1, "Read chat only")
        inboxExpect(pendingStore.contains(id: firstAlert.id) && pendingStore.chatMessages.isEmpty,
                    "Reading chat must leave pending alerts intact")
        inboxExpect(historyStore.entries.first { $0.id == firstChat.id }?.status == "已读",
                    "Reading chat must update history")

        viewNextPendingAlert()
        guard let firstController = activeAlert else { fatalError("Explicit open must create the pending alert") }
        inboxExpect(firstController.isPresented && activeAlertID == firstAlert.id, "Pending alert must be presented")
        assertCount(1, "Presentation alone")
        presentationAvailability.setAvailability(false)
        assertCount(1, "Locking during presentation")
        inboxExpect(activeAlert == nil && FullScreenAlertController.suspensionCount == 1,
                    "Locking must suspend, not acknowledge, the presented alert")
        firstController.simulateEscape()
        assertCount(1, "A suspended controller cannot dismiss pending unread state")
        presentationAvailability.setAvailability(true)
        assertCount(1, "Unlocking after suspension")
        inboxExpect(FullScreenAlertController.presentationCount == 1, "Unlock must not reopen the suspended alert")

        let secondAlert = message("alert", "第二条全屏消息")
        showIncoming(secondAlert)
        assertCount(2, "Two pending alerts")
        guard let secondController = activeAlert else { fatalError("The new alert should be presented") }
        secondController.simulateEscape()
        assertCount(1, "ESC clears one alert")
        inboxExpect(pendingStore.contains(id: firstAlert.id) && !pendingStore.contains(id: secondAlert.id),
                    "ESC must remove only its own alert")
        viewNextPendingAlert()
        guard let reopened = activeAlert else { fatalError("The original alert must still be openable") }
        showIncoming(firstAlert)
        assertCount(1, "Duplicate active alert")
        reopened.simulateEscape()
        reopened.simulateEscape()
        assertCount(0, "Repeated ESC")

        FullScreenAlertController.presentationSucceeds = false
        let failedPresentation = message("alert", "窗口未成功显示")
        showIncoming(failedPresentation)
        assertCount(1, "Failed presentation")
        inboxExpect(activeAlert == nil, "Failed presentations must release the active controller")
        FullScreenAlertController.canCreate = false
        showIncoming(message("alert", "无可用屏幕"))
        assertCount(2, "No available screen")
        inboxExpect(activeAlert == nil, "No-screen initialization must leave the message pending")
        inboxExpect(inboxTestSoundCount == 3, "Only successful simulated presentations should request a sound")
        print("AppDelegate 收件箱集成：锁屏双类型角标、重复去重、解锁保留、聊天单独已读、展示不清数、挂起保留、ESC 单条处理、展示失败/无屏幕保留、持久化恢复均通过")
    }
}
