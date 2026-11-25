import Foundation
import Network

struct WireMessage: Codable {
    let id: UUID
    let sender: String
    let text: String
    let sentAt: Date
    let kind: String?
    let senderInstanceID: String?
    let relatedMessageID: UUID?
}

struct Peer: Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint
    let instanceID: String?

    static func == (lhs: Peer, rhs: Peer) -> Bool { lhs.id == rhs.id }
    func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

enum MessageError: LocalizedError {
    case encodeFailed
    case messageTooLarge
    case connectionFailed(String)
    case noAcknowledgement

    var errorDescription: String? {
        switch self {
        case .encodeFailed: return "消息编码失败"
        case .messageTooLarge: return "消息过长（最多 256 KB）"
        case .connectionFailed(let detail): return "发送失败：\(detail)"
        case .noAcknowledgement: return "对方没有确认收到，请检查对方程序或网络"
        }
    }
}

final class LANMessenger {
    static let serviceType = "_fullscreenmsg._tcp"
    private let queue = DispatchQueue(label: "cn.local.fullscreen-message.network")
    private var cloud: CloudRelay?
    private let cloudEnabled: Bool
    private let localEnabled: Bool
    private let defaults: UserDefaults
    private var lanPeers: [Peer] = []
    private var cloudPeers: [Peer] = []
    private var listener: NWListener?
    private var browser: NWBrowser?
    private var seenMessageIDs: Set<UUID> = []
    private var advertisedPeerIDs: Set<String> = []
    private var dismissedPeerIDs: Set<String> = []
    private let instanceID: String
    private(set) var peers: [Peer] = []

    var displayName: String
    var onPeersChanged: (([Peer]) -> Void)?
    var onMessage: ((WireMessage) -> Void)?
    var onStatus: ((String) -> Void)?

    init(displayName: String, cloudEnabled: Bool = true, localEnabled: Bool = true, defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.localEnabled = localEnabled
        self.cloudEnabled = cloudEnabled
        self.displayName = displayName
        if let saved = defaults.string(forKey: "instanceID") {
            instanceID = saved
        } else {
            let created = String(UUID().uuidString.prefix(8))
            defaults.set(created, forKey: "instanceID")
            instanceID = created
        }
    }

    func start() {
        stop()
        if cloudEnabled { startCloud() }
        guard localEnabled else { return }
        do {
            let listener = try NWListener(using: .tcp)
            listener.service = NWListener.Service(name: serviceName, type: Self.serviceType)
            listener.newConnectionHandler = { [weak self] connection in self?.accept(connection) }
            listener.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready: self?.onStatus?("已就绪，等待消息")
                    case .failed(let error): self?.onStatus?("监听失败：\(error.localizedDescription)")
                    default: break
                    }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            onStatus?("无法启动接收服务：\(error.localizedDescription)")
        }

        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = true
        let browser = NWBrowser(for: .bonjour(type: Self.serviceType, domain: nil), using: parameters)
        browser.browseResultsChangedHandler = { [weak self] results, _ in
            guard let self else { return }
            let ownName = self.serviceName
            let discoveredPeers = results.compactMap { result -> Peer? in
                guard case let .service(name, _, _, _) = result.endpoint, name != ownName else { return nil }
                return Peer(id: self.instanceID(from: name).map { "device:\($0)" } ?? String(describing: result.endpoint), name: self.visibleName(from: name), endpoint: result.endpoint, instanceID: self.instanceID(from: name))
            }
            self.lanPeers = discoveredPeers
            self.publishPeers()

        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                DispatchQueue.main.async { self?.onStatus?("发现设备失败：\(error.localizedDescription)") }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private func startCloud() {
        let key: String
        if let saved = defaults.string(forKey: "cloudDeviceKeyV1") { key = saved }
        else {
            key = UUID().uuidString + UUID().uuidString
            defaults.set(key, forKey: "cloudDeviceKeyV1")
        }
        let relay = CloudRelay(id: instanceID, name: displayName, key: key)
        cloud = relay
        relay.onPeersChanged = { [weak self, weak relay] peers in
            guard let self, relay === self.cloud else { return }
            self.queue.async { self.cloudPeers = peers; self.publishPeers() }
        }
        relay.onStatus = { [weak self, weak relay] text in
            guard let self, relay === self.cloud else { return }
            self.onStatus?(text)
        }
        relay.onMessage = { [weak self, weak relay] message in
            guard let self, relay === self.cloud else { return false }
            return self.deliver(message)
        }
        relay.start()
    }

    private func publishPeers() {
        var merged = Dictionary(lanPeers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for peer in cloudPeers { merged[peer.id] = peer }
        let ids = Set(merged.keys)
        dismissedPeerIDs.subtract(advertisedPeerIDs.subtracting(ids))
        advertisedPeerIDs = ids
        let visible = merged.values.filter { !dismissedPeerIDs.contains($0.id) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        DispatchQueue.main.async { [weak self] in
            self?.peers = visible
            self?.onPeersChanged?(visible)
        }
    }

    private func deliver(_ message: WireMessage) -> Bool {
        guard message.kind == nil || ["alert", "accepted", "rejected"].contains(message.kind!) else { return false }
        if seenMessageIDs.contains(message.id) { return true }
        guard let onMessage else { return false }
        onMessage(message)
        if seenMessageIDs.count >= 500 { seenMessageIDs.removeAll(keepingCapacity: true) }
        seenMessageIDs.insert(message.id)
        return true
    }

    private var serviceName: String { "\(displayName)〔\(instanceID)〕" }

    private func visibleName(from serviceName: String) -> String {
        guard let marker = serviceName.range(of: "〔", options: .backwards) else { return serviceName }
        return String(serviceName[..<marker.lowerBound])
    }

    private func instanceID(from serviceName: String) -> String? {
        guard let start = serviceName.range(of: "〔", options: .backwards),
              let end = serviceName.range(of: "〕", range: start.upperBound..<serviceName.endIndex) else { return nil }
        return String(serviceName[start.upperBound..<end.lowerBound])
    }

    func stop() {
        cloud?.stop(); cloud = nil
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        peers = []
        queue.async {
            self.lanPeers = []; self.cloudPeers = []
            self.advertisedPeerIDs = []; self.dismissedPeerIDs = []
        }
    }

    func dismissPeer(id: String) {
        queue.async {
            self.dismissedPeerIDs.insert(id)
            self.publishPeers()
        }
    }

    func send(text: String, kind: String = "alert", messageID: UUID = UUID(), relatedMessageID: UUID? = nil, to endpoint: NWEndpoint, completion: @escaping (Result<Void, Error>) -> Void) {
        let message = WireMessage(id: messageID, sender: displayName, text: text, sentAt: Date(), kind: kind, senderInstanceID: instanceID, relatedMessageID: relatedMessageID)
        guard let body = try? JSONEncoder().encode(message) else {
            completion(.failure(MessageError.encodeFailed)); return
        }
        guard body.count <= 262_144 else {
            completion(.failure(MessageError.messageTooLarge)); return
        }
        var length = UInt32(body.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(body)

        if case let .service(target, type, _, _) = endpoint, type == CloudRelay.endpointType {
            let relay = cloud
            guard let relay else { completion(.failure(MessageError.connectionFailed("云网络尚未连接"))); return }
            relay.send(message, to: target) { [weak self] result in
                guard let self else { return }
                if case .failure = result {
                    self.queue.async {
                        if let local = self.lanPeers.first(where: { $0.instanceID == target }) {
                            self.sendPacket(packet, to: local.endpoint, attempt: 1, completion: completion)
                        } else { DispatchQueue.main.async { completion(result) } }
                    }
                } else { completion(result) }
            }
            return
        }
        sendPacket(packet, to: endpoint, attempt: 1, completion: completion)
    }

    func respond(to message: WireMessage, accepted: Bool, completion: @escaping (Result<Void, Error>) -> Void) {
        guard let senderID = message.senderInstanceID,
              let peer = peers.first(where: { $0.instanceID == senderID }) else {
            completion(.failure(MessageError.connectionFailed("找不到发送者，无法返回处理结果")))
            return
        }
        send(text: accepted ? "收到" : "拒绝", kind: accepted ? "accepted" : "rejected", relatedMessageID: message.id, to: peer.endpoint, completion: completion)
    }

    private func sendPacket(_ packet: Data, to endpoint: NWEndpoint, attempt: Int, completion: @escaping (Result<Void, Error>) -> Void) {
        let connection = NWConnection(to: endpoint, using: .tcp)
        var didFinish = false
        func finish(_ result: Result<Void, Error>) {
            guard !didFinish else { return }
            didFinish = true
            connection.cancel()
            switch result {
            case .success:
                DispatchQueue.main.async { completion(.success(())) }
            case .failure where attempt < 3:
                self.queue.asyncAfter(deadline: .now() + 0.8) {
                    self.sendPacket(packet, to: endpoint, attempt: attempt + 1, completion: completion)
                }
            case .failure(let error):
                DispatchQueue.main.async { completion(.failure(error)) }
            }
        }
        let timeout = DispatchWorkItem { finish(.failure(MessageError.noAcknowledgement)) }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: packet, completion: .contentProcessed { error in
                    if let error { finish(.failure(MessageError.connectionFailed(error.localizedDescription))) }
                    else {
                        connection.receive(minimumIncompleteLength: 2, maximumLength: 2) { data, _, _, error in
                            if error == nil, data == Data("OK".utf8) { finish(.success(())) }
                            else { finish(.failure(MessageError.noAcknowledgement)) }
                        }
                    }
                })
            case .failed(let error): finish(.failure(MessageError.connectionFailed(error.localizedDescription)))
            case .cancelled: break
            default: break
            }
        }
        connection.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 4, execute: timeout)
    }

    private func accept(_ connection: NWConnection) {
        connection.stateUpdateHandler = { state in
            if case .ready = state { self.receiveExactly(4, from: connection) { header in
                guard let header, header.count == 4 else { connection.cancel(); return }
                let size = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
                guard size > 0, size <= 262_144 else { connection.cancel(); return }
                self.receiveExactly(Int(size), from: connection) { body in
                    guard let body,
                          let message = try? JSONDecoder().decode(WireMessage.self, from: body) else {
                        connection.cancel(); return
                    }
                    guard message.kind == nil || ["alert", "accepted", "rejected"].contains(message.kind!) else {
                        connection.send(content: Data("NO".utf8), completion: .contentProcessed { _ in connection.cancel() })
                        return
                    }
                    DispatchQueue.main.async {
                        // The receiver persists unread messages synchronously. Confirm delivery
                        // only after that handler returns, including when a retry arrives first.
                        guard self.deliver(message) else { connection.cancel(); return }
                        connection.send(content: Data("OK".utf8), completion: .contentProcessed { _ in connection.cancel() })
                    }
                }
            }}
        }
        connection.start(queue: queue)
    }

    private func receiveExactly(_ count: Int, from connection: NWConnection, accumulated: Data = Data(), completion: @escaping (Data?) -> Void) {
        if accumulated.count >= count { completion(accumulated); return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: count - accumulated.count) { data, _, _, error in
            guard error == nil, let data, !data.isEmpty else { completion(nil); return }
            var next = accumulated
            next.append(data)
            self.receiveExactly(count, from: connection, accumulated: next, completion: completion)
        }
    }
}
