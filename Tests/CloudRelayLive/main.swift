import Foundation
import Network
import Darwin
setbuf(stdout, nil)

func expect(_ value: @autoclosure () -> Bool, _ reason: String) { precondition(value(), reason) }
func wait(_ reason: String, seconds: TimeInterval = 15, until check: () -> Bool) {
    let end = Date().addingTimeInterval(seconds)
    while !check() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
    expect(check(), reason)
}
let aID = UUID().uuidString, bID = UUID().uuidString
print("TEST_DEVICE_IDS \(aID) \(bID)")
let aKey = UUID().uuidString, bKey = UUID().uuidString
let a = CloudRelay(id: aID, name: "云端测试 A", key: aKey)
let b = CloudRelay(id: bID, name: "云端测试 B", key: bKey)
var aPeers: [Peer] = [], bPeers: [Peer] = [], aMessages: [WireMessage] = [], bMessages: [WireMessage] = []
a.onPeersChanged = { aPeers = $0 }; b.onPeersChanged = { bPeers = $0 }
a.onMessage = { aMessages.append($0); return true }
b.onMessage = { bMessages.append($0); return true }
a.onStatus = { print("A", $0) }; b.onStatus = { print("B", $0) }
a.start(); b.start()
wait("Cloud devices discover each other") { aPeers.contains { $0.instanceID == bID } && bPeers.contains { $0.instanceID == aID } }
let original = WireMessage(id: UUID(), sender: "伪造名称", text: "云端路径测试", sentAt: Date(), kind: "alert", senderInstanceID: "伪造身份", relatedMessageID: nil)
var delivered = false
a.send(original, to: bID) { result in if case .success = result { delivered = true } }
wait("Remote receiver ACK must complete sender") { delivered && bMessages.count == 1 }
expect(bMessages[0].sender == "云端测试 A" && bMessages[0].senderInstanceID == aID, "Relay enforces registered sender identity")
for accepted in [true, false] {
    var replied = false
    let message = WireMessage(id: UUID(), sender: "云端测试 B", text: accepted ? "收到" : "拒绝", sentAt: Date(), kind: accepted ? "accepted" : "rejected", senderInstanceID: bID, relatedMessageID: original.id)
    b.send(message, to: aID) { if case .success = $0 { replied = true } }
    wait("Receipt must return to original sender") { replied && aMessages.contains { $0.id == message.id } }
    expect(aMessages.last!.relatedMessageID == original.id, "Receipt correlation remains intact")
}
var burst = 0
for _ in 0..<12 {
    a.send(WireMessage(id: UUID(), sender: "A", text: "连续全屏消息", sentAt: Date(), kind: "alert", senderInstanceID: aID, relatedMessageID: nil), to: bID) {
        if case .success = $0 { burst += 1 }
    }
}
wait("Rapid messages all arrive and ACK") { burst == 12 && bMessages.count == 13 }
expect(Set(bMessages.map(\.id)).count == 13, "Burst identities remain distinct")
b.stop()
wait("Disconnect removes device from online list", seconds: 5) { !aPeers.contains { $0.instanceID == bID } }
var offlineFailed = false
a.send(original, to: bID) { if case .failure = $0 { offlineFailed = true } }
wait("Offline must fail instead of claiming delivery") { offlineFailed }
b.start()
wait("Restart rejoins automatically") { aPeers.contains { $0.instanceID == bID } }
b.onMessage = { _ in false }
var noAckFailed = false
let begun = Date()
a.send(original, to: bID) { if case .failure = $0 { noAckFailed = true } }
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
expect(!noAckFailed, "Server does not claim receipt before application acceptance")
wait("Missing recipient ACK times out", seconds: 14) { noAckFailed }
expect(Date().timeIntervalSince(begun) >= 9, "Recipient acknowledgement timeout was exercised")
let impostor = CloudRelay(id: aID, name: "冒用身份测试", key: UUID().uuidString)
var rejected = false
impostor.onStatus = { if $0.contains("身份无效") { rejected = true } }
impostor.start()
wait("Wrong device secret is rejected") { rejected }
impostor.stop()
expect(aPeers.contains { $0.instanceID == bID }, "Identity rejection does not replace real session")
let badPin = CloudRelay(id: UUID().uuidString, name: "证书测试", key: UUID().uuidString, pin: String(repeating: "0", count: 64))
var badPinReady = false
badPin.onStatus = { if $0 == "云网络已连接" { badPinReady = true } }
badPin.start()
RunLoop.main.run(until: Date().addingTimeInterval(3))
expect(!badPinReady, "Wrong certificate pin must not connect")
badPin.stop(); a.stop(); b.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
print("PASS: live server discovery, TLS pinning, alert ACK, accepted/rejected receipts, burst, offline, reconnect, no-ACK timeout and identity protection; no Bonjour used")
