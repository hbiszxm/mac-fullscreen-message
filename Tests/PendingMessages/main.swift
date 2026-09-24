import Foundation

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let suiteName = "cn.local.fullscreen-message.tests.pending-messages.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }

func message(kind: String?, text: String, sentAt: Date = Date(), relatedID: UUID? = nil) -> WireMessage {
    WireMessage(id: UUID(), sender: "接待电脑", text: text, sentAt: sentAt, kind: kind,
                senderInstanceID: "sender-1", relatedMessageID: relatedID)
}

let store = PendingMessageStore(defaults: defaults)
expect(store.count == 0, "A new inbox should be empty")
let alert = message(kind: "alert", text: "上班")
let chat = message(kind: "chat", text: "临时聊天 👋", sentAt: Date(timeIntervalSince1970: 1))
let legacyAlert = message(kind: nil, text: "旧版全屏消息")
expect(store.add(alert), "Fullscreen messages should enter the inbox")
expect(store.add(chat), "Chat messages should enter the inbox")
expect(store.add(legacyAlert), "Legacy messages without a kind should be treated as alerts")
expect(store.messages.map(\.id) == [alert.id, chat.id, legacyAlert.id], "Inbox order should follow arrival, not sender clocks")
expect(store.chatMessages.map(\.id) == [chat.id], "Chat list should contain only chats")
expect(store.alertMessages.map(\.id) == [alert.id, legacyAlert.id], "Alert list should include legacy alerts")
expect(store.contains(id: chat.id), "Received message IDs should be tracked")

let duplicate = WireMessage(id: alert.id, sender: "Changed sender", text: "Changed content",
                            sentAt: Date(), kind: "chat", senderInstanceID: nil, relatedMessageID: nil)
expect(!store.add(duplicate), "Duplicate delivery must not create another unread item")
expect(store.messages[0].text == "上班", "Duplicate IDs must not overwrite the original message")
expect(!store.add(message(kind: "accepted", text: "收到", relatedID: alert.id)), "Acceptance responses must not become unread messages")
expect(!store.add(message(kind: "rejected", text: "拒绝", relatedID: alert.id)), "Rejection responses must not become unread messages")
expect(!store.add(message(kind: "unknown", text: "Unknown event")), "Unrecognized control events must not enter the inbox")
expect(store.count == 3, "Control events and duplicate packets must not increment the badge")

let restored = PendingMessageStore(defaults: UserDefaults(suiteName: suiteName)!)
expect(restored.messages.map(\.id) == [alert.id, chat.id, legacyAlert.id], "Unread messages and arrival order must survive restart")
let restoredChat = restored.chatMessages[0]
expect(restoredChat.sender == chat.sender && restoredChat.text == chat.text, "Sender and Unicode content must survive restart")
expect(restoredChat.senderInstanceID == chat.senderInstanceID && restoredChat.sentAt == chat.sentAt, "Sender identity and timestamp must survive restart")
expect(!restored.add(alert), "Restored inbox should still deduplicate previously received messages")

restored.removeChatMessages()
expect(restored.count == 2 && restored.chatMessages.isEmpty, "Reading chat should clear its unread messages")
expect(restored.alertMessages.map(\.id) == [alert.id, legacyAlert.id], "Reading chat must preserve unhandled fullscreen messages")
let afterChatRead = PendingMessageStore(defaults: defaults)
expect(afterChatRead.messages.map(\.id) == [alert.id, legacyAlert.id], "Chat read state should survive restart")
afterChatRead.remove(id: alert.id)
expect(!afterChatRead.contains(id: alert.id), "Handling an individual alert should clear its unread state")
expect(afterChatRead.messages.map(\.id) == [legacyAlert.id], "Handling one alert must preserve other pending messages")
afterChatRead.remove(id: UUID())
expect(afterChatRead.count == 1, "Removing an unknown ID should not modify the inbox")
afterChatRead.removeChatMessages()
expect(afterChatRead.count == 1, "Reading an empty chat should not modify alerts")
let afterAlertRead = PendingMessageStore(defaults: defaults)
expect(afterAlertRead.messages.map(\.id) == [legacyAlert.id], "Individual read state should survive restart")
afterAlertRead.remove(id: legacyAlert.id)
expect(PendingMessageStore(defaults: defaults).count == 0, "An empty inbox must remain empty after restart")

print("未读收件箱：混合消息、去重、回执排除、重启恢复、聊天已读隔离与逐条处理均通过")
