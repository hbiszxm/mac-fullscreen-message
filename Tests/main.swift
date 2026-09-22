import Foundation

let receiver = LANMessenger(displayName: "可靠性测试接收端")
let sender = LANMessenger(displayName: "可靠性测试发送端")
var receivedText: String?
var sendResult: Result<Void, Error>?
var didStartSend = false
var receiverPeerID: String?
var peerWasRemoved = false
var peerCameBack = false

receiver.onMessage = { message in receivedText = message.text }
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
while Date() < deadline, (sendResult == nil || receivedText == nil) {
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

guard let receiverPeerID else { exit(3) }
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
print("自动发现、发送、确认、移除和重启重新上线均成功")
