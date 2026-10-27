// Real sender actions with delayed transport completions, isolated from peers.
extension AppDelegate {
    func runSendingStateTests() {
        statusItem.menu = nil
        let peer = Peer(id: "test-peer", name: "测试电脑", endpoint: .hostPort(host: "127.0.0.1", port: 1), instanceID: "test-peer")
        peers = [peer]
        selectedPopoverPeerIDs = [peer.id]
        peerPopup.removeAllItems()
        peerPopup.addItem(withTitle: "所有电脑（1 台）")
        peerPopup.selectItem(at: 0)
        rebuildStatusPopover()
        let panel = statusPopover.contentViewController

        messageView.string = "第一条"
        sendCustomMessage()
        inboxExpect(inboxTestSends.count == 1, "The first click must send")
        messageView.string = "正在写第二条"
        inboxTestSends[0].completion(.success(()))
        inboxExpect(messageView.string == "正在写第二条", "Completion of the first send must not erase the second draft")
        inboxExpect(statusPopover.contentViewController === panel, "Status updates must not replace controls during a click")
        sendCustomMessage()
        inboxExpect(inboxTestSends.count == 2 && inboxTestSends[1].text == "正在写第二条", "Second click must send the new draft")
        historyStore.update(id: inboxTestSends[1].id, status: "对方已收到")
        inboxTestSends[1].completion(.success(()))
        inboxExpect(historyStore.entries.first { $0.id == inboxTestSends[1].id }?.status == "对方已收到",
                    "A late transport callback must not overwrite a human response")
        inboxExpect(messageView.string.isEmpty, "Clear only the draft that was sent successfully")

        messageView.string = "首页未发送的草稿"
        let quick = popoverQuickButtons[0]
        quick.performClick(nil)
        quick.performClick(nil)
        inboxExpect(inboxTestSends.count == 4 && inboxTestSends[2].id != inboxTestSends[3].id,
                    "Two rapid shortcut clicks must each send a new message")
        inboxTestSends[3].completion(.success(()))
        inboxTestSends[2].completion(.failure(MessageError.connectionFailed("测试连接失败")))
        inboxExpect(messageView.string == "首页未发送的草稿", "Shortcut results must not clear the home draft")
        inboxExpect(lastStatus.contains("测试连接失败"), "A failed click must expose its actual failure")
        inboxExpect(historyStore.entries.first { $0.id == inboxTestSends[2].id }?.status.contains("测试连接失败") == true,
                    "History must retain the failure reason")

        menuMessageView.string = "菜单第一条"
        sendInlineMenuMessage()
        inboxExpect(menuMessageView.string == "菜单第一条", "Do not discard the menu draft before delivery")
        menuMessageView.string = "菜单第二条"
        inboxTestSends[4].completion(.success(()))
        inboxExpect(menuMessageView.string == "菜单第二条", "An old completion must preserve the new menu draft")
        sendInlineMenuMessage()
        inboxTestSends[5].completion(.failure(MessageError.noAcknowledgement))
        inboxExpect(menuMessageView.string == "菜单第二条", "Failed delivery must leave the draft available to retry")
        sendInlineMenuMessage()
        inboxTestSends[6].completion(.success(()))
        inboxExpect(menuMessageView.string.isEmpty, "Successful retry clears only its own draft")
        sendInlineMenuMessage()
        inboxExpect(lastStatus.contains("输入消息"), "Empty clicks need visible feedback")
        selectedPopoverPeerIDs = []
        menuMessageView.string = "尚未选择设备"
        sendInlineMenuMessage()
        inboxExpect(lastStatus.contains("选择接收电脑"), "Missing recipients need visible feedback")
        inboxExpect(inboxTestSends.count == 7, "Invalid clicks must not send anything")
        print("发送集成：连续点击、回调乱序、新草稿保留、失败重试、菜单控件稳定及错误提示均通过")
    }
}

extension AppDelegate {
    func runLiveAlertQueueTests() {
        FullScreenAlertController.canCreate = true
        FullScreenAlertController.presentationSucceeds = true
        func packet() -> WireMessage {
            WireMessage(id: UUID(), sender: "隔离测试", text: "连续消息", sentAt: Date(),
                        kind: "alert", senderInstanceID: "test-sender", relatedMessageID: nil)
        }
        func drain() { RunLoop.main.run(until: Date().addingTimeInterval(0.35)) }
        let a = packet(), b = packet(), c = packet(), d = packet()
        showIncoming(a)
        showIncoming(b)
        showIncoming(c)
        inboxExpect(activeAlertID == a.id, "New arrivals must not replace the active message")
        activeAlert?.simulateEscape()
        showIncoming(d)
        inboxExpect(activeAlert == nil, "The response transition must not let a new arrival jump the queue")
        drain()
        inboxExpect(activeAlertID == b.id, "Second message must automatically appear next")
        activeAlert?.simulateEscape()
        drain()
        inboxExpect(activeAlertID == c.id, "Third message must follow in order")
        activeAlert?.simulateEscape()
        presentationAvailability.setAvailability(false)
        drain()
        presentationAvailability.setAvailability(true)
        drain()
        inboxExpect(activeAlert == nil && pendingStore.contains(id: d.id), "Locking must cancel auto-advance but retain unread messages")
        inboxExpect(inboxTestResponses.suffix(3).map { $0.0 } == [a.id, b.id, c.id], "Each queued message must receive exactly one response")
        print("连续收件：同文不同 ID、按序展示、过渡期新消息、锁屏取消与未读保留均通过")
    }
}
