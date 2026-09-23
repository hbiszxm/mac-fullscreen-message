import Foundation

let receiver = LANMessenger(displayName: "可靠性测试接收端")
let sender = LANMessenger(displayName: "可靠性测试发送端")
var receivedText: String?
var receivedKind: String?
var sendResult: Result<Void, Error>?
var didStartSend = false
var receiverPeerID: String?
var peerWasRemoved = false
var peerCameBack = false
var responseReceived = false

receiver.onMessage = { message in
    receivedText = message.text
    receivedKind = message.kind
    if message.kind == "alert" {
        receiver.respond(to: message, accepted: true) { _ in }
    }
}
sender.onMessage = { message in
    if message.kind == "accepted", message.relatedMessageID != nil { responseReceived = true }
}
sender.onPeersChanged = { peers in
    if let receiverPeerID {
        if peers.allSatisfy({ $0.id != receiverPeerID }) { peerWasRemoved = true }
        if peerWasRemoved, peers.contains(where: { $0.id == receiverPeerID }) { peerCameBack = true }
    }
    guard !didStartSend, let peer = peers.first(where: { $0.name == "可靠性测试接收端" }) else { return }
    receiverPeerID = peer.id
    didStartSend = true
    sender.send(text: "自动发现、发送、确认测试", to: peer.endpoint) { result in sendResult = result }
}

receiver.start()
sender.start()
let deadline = Date().addingTimeInterval(12)
while Date() < deadline, (sendResult == nil || receivedText == nil || !responseReceived) {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
guard receivedText == "自动发现、发送、确认测试" else {
    fputs("未收到测试消息\n", stderr)
    exit(1)
}
guard case .success? = sendResult else {
    fputs("发送端未收到确认\n", stderr)
    exit(2)
}
guard responseReceived else {
    fputs("接收方处理结果未返回发送方\n", stderr)
    exit(7)
}

receivedText = nil
receivedKind = nil
sendResult = nil
if let peer = sender.peers.first(where: { $0.id == receiverPeerID }) {
    sender.send(text: "临时聊天测试", kind: "chat", to: peer.endpoint) { result in sendResult = result }
}
let chatDeadline = Date().addingTimeInterval(6)
while Date() < chatDeadline, (sendResult == nil || receivedText == nil) {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
guard receivedText == "临时聊天测试", receivedKind == "chat", case .success? = sendResult else {
    fputs("临时聊天发送或类型识别失败\n", stderr)
    exit(3)
}

guard let receiverPeerID else { exit(6) }
sender.dismissPeer(id: receiverPeerID)
let removeDeadline = Date().addingTimeInterval(2)
while Date() < removeDeadline, !peerWasRemoved {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
guard peerWasRemoved else {
    fputs("指定电脑未从列表移除\n", stderr)
    exit(4)
}

receiver.stop()
RunLoop.main.run(until: Date().addingTimeInterval(0.5))
receiver.start()
let returnDeadline = Date().addingTimeInterval(8)
while Date() < returnDeadline, !peerCameBack {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
receiver.stop()
sender.stop()
guard peerCameBack else {
    fputs("接收端重启后未重新上线\n", stderr)
    exit(5)
}
print("自动发现、全屏消息、临时聊天、处理结果返回、确认、移除和重启重新上线均成功")
