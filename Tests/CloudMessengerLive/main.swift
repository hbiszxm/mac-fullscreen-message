import Foundation
import Darwin
setbuf(stdout, nil)
func wait(_ reason: String, seconds: TimeInterval = 15, until check: () -> Bool) {
 let end = Date().addingTimeInterval(seconds)
 while !check() && Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
 precondition(check(), reason)
}
let aSuite = "cn.local.fullscreen-message.cloudtest." + UUID().uuidString
let bSuite = "cn.local.fullscreen-message.cloudtest." + UUID().uuidString
let ad = UserDefaults(suiteName: aSuite)!, bd = UserDefaults(suiteName: bSuite)!
ad.set(UUID().uuidString, forKey: "instanceID"); bd.set(UUID().uuidString, forKey: "instanceID")
defer { ad.removePersistentDomain(forName: aSuite); bd.removePersistentDomain(forName: bSuite) }
let aid = ad.string(forKey: "instanceID")!, bid = bd.string(forKey: "instanceID")!
print("TEST_DEVICE_IDS", aid, bid)
let a = LANMessenger(displayName: "云端集成 A", localEnabled: false, defaults: ad)
let b = LANMessenger(displayName: "云端集成 B", localEnabled: false, defaults: bd)
var ap: [Peer] = [], bp: [Peer] = [], received: [WireMessage] = [], replies: [WireMessage] = []
a.onPeersChanged = { ap = $0 }; b.onPeersChanged = { bp = $0 }
a.onMessage = { replies.append($0) }; b.onMessage = { received.append($0) }
var readyCount = 0
a.onStatus = { if $0 == "云网络已连接" { readyCount += 1 } }
b.onStatus = { if $0 == "云网络已连接" { readyCount += 1 } }
a.start(); b.start()
wait("Cloud-only production messenger discovers devices") { ap.contains { $0.instanceID == bid } && bp.contains { $0.instanceID == aid } }
let endpoint = ap.first { $0.instanceID == bid }!.endpoint
let id = UUID()
var sends = 0
for _ in 0..<2 {
 a.send(text: "生产入口云端测试", messageID: id, to: endpoint) { if case .success = $0 { sends += 1 } }
}
wait("Both attempts get ACK but display once") { sends == 2 && received.count == 1 }
precondition(received[0].senderInstanceID == aid && received[0].sender == "云端集成 A")
var receipt = false
b.respond(to: received[0], accepted: false) { if case .success = $0 { receipt = true } }
wait("Production response returns over relay") { receipt && replies.count == 1 }
precondition(replies[0].kind == "rejected" && replies[0].relatedMessageID == id)
a.dismissPeer(id: "device:" + bid)
wait("Dismiss hides cloud device locally") { !ap.contains { $0.instanceID == bid } }
b.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
b.start()
wait("Peer restart restores a dismissed cloud device") { ap.contains { $0.instanceID == bid } }
if let signal = ProcessInfo.processInfo.environment["CLOUD_RESTART_SIGNAL"] {
    let previous = readyCount
    try! Data("ready".utf8).write(to: URL(fileURLWithPath: signal))
    wait("Both clients automatically reconnect after server restart", seconds: 40) {
        readyCount >= previous + 2 && ap.contains { $0.instanceID == bid } && bp.contains { $0.instanceID == aid }
    }
    var recovered = false
    a.send(text: "服务恢复测试", to: ap.first { $0.instanceID == bid }!.endpoint) {
        if case .success = $0 { recovered = true }
    }
    wait("Reconnected session can actually deliver") { recovered && received.count == 2 }
    print("PASS: server restart triggers automatic reconnect and successful subsequent delivery")
} else {
    // Keep a real idle session longer than the server's lease, proving automatic heartbeat.
    RunLoop.main.run(until: Date().addingTimeInterval(37))
    precondition(ap.contains { $0.instanceID == bid } && bp.contains { $0.instanceID == aid }, "Heartbeat retains live idle devices")
}
a.stop(); b.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.3))
print("PASS: cloud-only production discovery, send, receiver deduplication, receipt routing, dismiss/rejoin and idle heartbeat")
