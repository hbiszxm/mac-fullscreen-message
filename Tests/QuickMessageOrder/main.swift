import Foundation
let suite = "cn.local.fullscreen-message.tests.order.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suite)!
defer { defaults.removePersistentDomain(forName: suite) }
func expect(_ condition: @autoclosure () -> Bool, _ message: String) { precondition(condition(), message) }
let available = ["上班", "吸烟", "暗棋", "开会", "下班", "吃饭"]
let store = QuickMessageOrderStore(defaults: defaults)
expect(store.messages(available: available) == available, "Initial order must preserve defaults and favorites")
expect(store.move("上班", to: "开会", available: available), "Move across rows")
let moved = ["吸烟", "暗棋", "开会", "上班", "下班", "吃饭"]
expect(QuickMessageOrderStore(defaults: defaults).messages(available: available) == moved, "Restart must retain order")
expect(store.move("吃饭", to: "吸烟", available: available), "Move last to first")
expect(store.messages(available: available).first == "吃饭", "Move must insert at the target slot")
expect(!store.move("不存在", to: "上班", available: available) && !store.move("上班", to: "上班", available: available), "Invalid or same-target drops must be ignored")
let deleted = available.filter { $0 != "开会" }
expect(!store.messages(available: deleted).contains("开会"), "Deleted favorites must be removed")
expect(store.messages(available: deleted + ["开会"]).last == "开会", "New or re-added favorites go at the end")
expect(Set(store.messages(available: available + ["上班"])).count == 6, "Repeated inputs must not duplicate shortcuts")
print("PASS: ordering across rows, both directions, persistence, deletion, additions and invalid drops")
