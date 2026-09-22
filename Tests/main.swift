import Foundation

let receiver = LANMessenger(displayName: "可靠性测试接收端")
let sender = LANMessenger(displayName: "可靠性测试发送端")
var receivedText: String?
var sendResult: Result<Void, Error>?
var didStartSend = false

receiver.onMessage = { message in receivedText = message.text }
sender.onPeersChanged = { peers in
    guard !didStartSend, let peer = peers.first(where: { $0.name == "可靠性测试接收端" }) else { return }
    didStartSend = true
    sender.send(text: "自动发现、发送、确认测试", to: peer.endpoint) { result in sendResult = result }
}

receiver.start()
sender.start()
let deadline = Date().addingTimeInterval(12)
while Date() < deadline, (sendResult == nil || receivedText == nil) {
    RunLoop.main.run(until: Date().addingTimeInterval(0.05))
}
receiver.stop()
sender.stop()

guard receivedText == "自动发现、发送、确认测试" else {
    fputs("未收到测试消息\n", stderr)
    exit(1)
}
guard case .success? = sendResult else {
    fputs("发送端未收到确认\n", stderr)
    exit(2)
}
print("自动发现、发送、接收和确认均成功")
