import Foundation
import Network

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let suiteName = "cn.local.fullscreen-message.tests.peer-names.\(UUID().uuidString)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }

let original = Peer(id: "original-advertisement", name: "MacBook Air",
                    endpoint: .hostPort(host: "127.0.0.1", port: 10001), instanceID: "device-1")
let store = PeerNameStore(defaults: defaults)
expect(store.displayName(for: original) == "MacBook Air", "Default device name should be unchanged")
expect(store.setName("  接待电脑 \n", for: original), "A nonempty device name should be accepted")
expect(store.displayName(for: original) == "接待电脑", "Device name should be trimmed")
expect(!store.setName(" \n\t ", for: original), "Blank names should be rejected")
expect(store.displayName(for: original) == "接待电脑", "Blank input must preserve the previous name")

let restored = PeerNameStore(defaults: UserDefaults(suiteName: suiteName)!)
let rediscovered = Peer(id: "new-advertisement", name: "New system name",
                        endpoint: .hostPort(host: "127.0.0.2", port: 10002), instanceID: "device-1")
expect(restored.displayName(for: rediscovered) == "接待电脑", "Alias should persist and follow the instance ID")
let renamed = restored.renamed([rediscovered])[0]
expect(renamed.name == "接待电脑", "Returned peer should use the local alias")
expect(renamed.id == rediscovered.id, "Renaming must preserve discovery identity")
expect(renamed.endpoint == rediscovered.endpoint, "Renaming must preserve the current network endpoint")
expect(renamed.instanceID == rediscovered.instanceID, "Renaming must preserve the instance ID")
expect(rediscovered.name == "New system name", "Renaming must not modify the original peer")

let legacy = Peer(id: "device-1", name: "Legacy computer",
                  endpoint: .hostPort(host: "127.0.0.3", port: 10003), instanceID: nil)
expect(restored.displayName(for: legacy) == "Legacy computer", "Instance IDs and fallback IDs must not collide")
expect(restored.setName("备用电脑", for: legacy), "Devices without an instance ID should support aliases")
let fallbackReload = PeerNameStore(defaults: UserDefaults(suiteName: suiteName)!)
expect(fallbackReload.displayName(for: legacy) == "备用电脑", "Fallback peer-ID aliases should persist")
expect(fallbackReload.displayName(for: rediscovered) == "接待电脑", "Fallback aliases must not change instance aliases")
fallbackReload.resetName(for: rediscovered)
expect(fallbackReload.displayName(for: rediscovered) == "New system name", "Reset should restore the discovered name")
expect(PeerNameStore(defaults: defaults).displayName(for: rediscovered) == "New system name", "Reset should persist")

print("设备名称：持久化、稳定身份、地址保留、空名称拒绝与恢复默认均通过")

func message(sender: String = "MacBook Air", id: String? = "device-1") -> WireMessage {
    WireMessage(id: UUID(), sender: sender, text: "上班", sentAt: Date(), kind: "alert",
                senderInstanceID: id, relatedMessageID: nil)
}
let incoming = message()
expect(store.displayName(for: incoming) == "接待电脑", "Incoming messages must resolve saved aliases without online discovery")
expect(store.displayName(for: message(sender: "Changed system name")) == "接待电脑", "A changed system name must keep the same alias")
expect(store.displayName(for: message(id: "another-device")) == "MacBook Air", "Identical system names must not share aliases")
expect(store.displayName(for: message(id: nil)) == "MacBook Air", "Legacy messages without identity must keep the original name")
expect(store.displayName(for: message(id: "")) == "MacBook Air", "Empty identities must keep the original name")
store.setName("新备注", for: original)
expect(store.displayName(for: incoming) == "新备注", "Unread messages must use the latest alias at presentation time")
expect(PeerNameStore(defaults: defaults).displayName(for: incoming) == "新备注", "Incoming aliases must survive restart")
store.resetName(for: original)
expect(store.displayName(for: incoming) == "MacBook Air", "Reset must restore the original sender name")
expect(incoming.sender == "MacBook Air" && incoming.senderInstanceID == "device-1", "Presentation must not mutate wire identity")
print("消息备注：离线匹配、重启保留、备注修改、同名设备隔离、旧消息回退与原身份保留均通过")
