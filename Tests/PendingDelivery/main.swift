import Foundation
import Network

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

func waitUntil(timeout: TimeInterval, _ condition: () -> Bool) -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    return condition()
}

/// Resolve only this test's advertised listener, then connect using loopback.
final class LocalListenerDiscovery: NSObject, NetServiceBrowserDelegate, NetServiceDelegate {
    let browser = NetServiceBrowser()
    private let uniqueName: String
    private var service: NetService?
    private(set) var port: NWEndpoint.Port?

    init(uniqueName: String) {
        self.uniqueName = uniqueName
        super.init()
        browser.delegate = self
    }

    func start() {
        browser.searchForServices(ofType: LANMessenger.serviceType, inDomain: "local.")
    }

    func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService, moreComing: Bool) {
        guard service.name.hasPrefix(uniqueName + "〔"), self.service == nil else { return }
        self.service = service
        service.delegate = self
        service.resolve(withTimeout: 3)
    }

    func netServiceDidResolveAddress(_ sender: NetService) {
        port = NWEndpoint.Port(rawValue: UInt16(sender.port))
    }
}

/// The raw client observes acknowledgements on its own queue, independently of
/// the receiver's main-thread delivery callback and the application's send API.
final class RawDelivery {
    let wrotePacket = DispatchSemaphore(value: 0)
    let finished = DispatchSemaphore(value: 0)
    private let connection: NWConnection
    private let lock = NSLock()
    private var storedResult: (acknowledged: Bool, persisted: Bool, error: String)?

    var result: (acknowledged: Bool, persisted: Bool, error: String)? {
        lock.lock()
        defer { lock.unlock() }
        return storedResult
    }

    init(message: WireMessage, port: NWEndpoint.Port, suiteName: String) throws {
        connection = NWConnection(host: .ipv4(.loopback), port: port, using: .tcp)
        let body = try JSONEncoder().encode(message)
        var length = UInt32(body.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(body)
        connection.stateUpdateHandler = { [self] state in
            switch state {
            case .ready:
                connection.send(content: packet, completion: .contentProcessed { [self] error in
                    wrotePacket.signal()
                    if let error {
                        finish(acknowledged: false, persisted: false, error: error.localizedDescription)
                        return
                    }
                    connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { [self] data, _, _, error in
                        let restored = PendingMessageStore(defaults: UserDefaults(suiteName: suiteName)!)
                        finish(acknowledged: error == nil && data == Data("OK".utf8),
                               persisted: restored.contains(id: message.id),
                               error: error?.localizedDescription ?? "")
                    }
                })
            case .failed(let error):
                wrotePacket.signal()
                finish(acknowledged: false, persisted: false, error: error.localizedDescription)
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "pending-delivery.raw-client.\(UUID().uuidString)"))
    }

    private func finish(acknowledged: Bool, persisted: Bool, error: String) {
        lock.lock()
        guard storedResult == nil else { lock.unlock(); return }
        storedResult = (acknowledged, persisted, error)
        lock.unlock()
        connection.cancel()
        finished.signal()
    }

    func cancel() { connection.cancel() }
}

let testID = UUID().uuidString
let suiteName = "cn.local.fullscreen-message.tests.pending-delivery.\(testID)"
let defaults = UserDefaults(suiteName: suiteName)!
defer { defaults.removePersistentDomain(forName: suiteName) }
let inbox = PendingMessageStore(defaults: defaults)
let receiverName = "UnreadTest-\(testID.prefix(8))"
let receiver = LANMessenger(displayName: receiverName)
var deliveryCounts: [UUID: Int] = [:]
receiver.onMessage = { message in
    // Deliberately create no window: lock screen or failed presentation must
    // still leave a durable unread item before the sender sees its receipt.
    inbox.add(message)
    deliveryCounts[message.id, default: 0] += 1
}
receiver.start()
defer { receiver.stop() }
let discovery = LocalListenerDiscovery(uniqueName: receiverName)
discovery.start()
defer { discovery.browser.stop() }
expect(waitUntil(timeout: 8) { discovery.port != nil }, "Could not resolve the isolated local test listener")
let port = discovery.port!

func makeMessage(kind: String, text: String) -> WireMessage {
    WireMessage(id: UUID(), sender: "Local test", text: text, sentAt: Date(), kind: kind,
                senderInstanceID: "test-sender", relatedMessageID: nil)
}

let firstAlert = makeMessage(kind: "alert", text: "未能弹出的全屏消息")
let first = try RawDelivery(message: firstAlert, port: port, suiteName: suiteName)
defer { first.cancel() }
expect(first.wrotePacket.wait(timeout: .now() + 3) == .success, "Raw client could not write the first message")
// Keep main-thread delivery blocked briefly while the listener and raw client
// are free to run. The previous implementation sent OK during this interval.
expect(first.finished.wait(timeout: .now() + 0.35) == .timedOut, "Delivery was acknowledged before main-thread persistence")
expect(inbox.count == 0, "The test must block delivery until its main run loop resumes")
expect(waitUntil(timeout: 4) { first.result != nil }, "No receipt after the receiver resumed")
expect(first.result!.acknowledged && first.result!.persisted, "An OK receipt must follow persistence of the full message")
expect(inbox.count == 1 && inbox.alertMessages.first?.id == firstAlert.id, "An unpresented alert must remain unread")

func deliver(_ message: WireMessage) throws {
    let client = try RawDelivery(message: message, port: port, suiteName: suiteName)
    defer { client.cancel() }
    expect(waitUntil(timeout: 4) { client.result != nil }, "Timed out waiting for a local message receipt")
    let result = client.result!
    expect(result.acknowledged && result.persisted, "Message must be persisted before OK: \(result.error)")
}

try deliver(firstAlert)
expect(deliveryCounts[firstAlert.id] == 1 && inbox.count == 1, "Retransmitting one UUID must not redeliver or duplicate its unread item")
let chat = makeMessage(kind: "chat", text: "临时聊天")
let secondAlert = makeMessage(kind: "alert", text: "第二条全屏消息")
try deliver(chat)
try deliver(secondAlert)
expect(inbox.count == 3 && inbox.chatMessages.count == 1 && inbox.alertMessages.count == 2,
       "Mixed incoming messages must contribute to the same unread badge")
inbox.removeChatMessages()
expect(inbox.messages.map(\.id) == [firstAlert.id, secondAlert.id], "Reading chat must preserve both unpresented alerts")
expect(PendingMessageStore(defaults: defaults).count == 2, "Unread alerts must survive a store restart")
inbox.remove(id: firstAlert.id)
let restored = PendingMessageStore(defaults: UserDefaults(suiteName: suiteName)!)
expect(restored.messages.map(\.id) == [secondAlert.id], "Handling one alert must persist without clearing the other")

print("本机未读交付：持久化先于 OK、重复包去重、未展示全屏保留、聊天独立已读和重启恢复均通过")
