import Foundation
func expect(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
let suite = "cn.local.fullscreen-message.tests.pending.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
func packet(_ kind: String?) -> WireMessage {
    WireMessage(id: UUID(), sender: "测试", text: "消息", sentAt: Date(), kind: kind, senderInstanceID: "test", relatedMessageID: nil)
}
let a = packet("alert"), b = packet(nil), chat = packet("chat")
defaults.set(try! JSONEncoder().encode([a, chat, b, a]), forKey: "pendingMessagesV1")
let store = PendingMessageStore(defaults: defaults)
expect(store.messages.map(\.id) == [a.id, b.id], "Migration must drop retired chat and preserve pending alerts in order")
let saved = try! JSONDecoder().decode([WireMessage].self, from: defaults.data(forKey: "pendingMessagesV1")!)
expect(saved.map(\.id) == [a.id, b.id], "Retired chats must be removed from persistent data")
expect(!store.add(chat) && !store.add(packet("accepted")) && !store.add(a), "Chat, receipts and duplicates must not enter the inbox")
store.remove(id: a.id)
expect(PendingMessageStore(defaults: defaults).messages.map(\.id) == [b.id], "Handling one alert must preserve the others after restart")
store.remove(id: UUID())
expect(store.count == 1, "Unknown IDs must not clear alerts")
store.remove(id: b.id)
expect(PendingMessageStore(defaults: defaults).count == 0, "Handled messages must not remain as history")
print("未读迁移：清理旧聊天、保留全屏、去重、逐条处理、重启恢复与清空均通过")
