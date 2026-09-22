import Foundation
import Network

struct WireMessage: Codable {
    let id: UUID
    let sender: String
    let text: String
    let sentAt: Date
}

struct Peer: Hashable {
    let id: String
    let name: String
    let endpoint: NWEndpoint

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

    init(displayName: String) {
        self.displayName = displayName
        if let saved = UserDefaults.standard.string(forKey: "instanceID") {
            instanceID = saved
        } else {
            let created = String(UUID().uuidString.prefix(8))
            UserDefaults.standard.set(created, forKey: "instanceID")
            instanceID = created
        }
    }

    func start() {
        stop()
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
                return Peer(id: String(describing: result.endpoint), name: self.visibleName(from: name), endpoint: result.endpoint)
            }
            let currentIDs = Set(discoveredPeers.map(\.id))
            let wentOffline = self.advertisedPeerIDs.subtracting(currentIDs)
            self.dismissedPeerIDs.subtract(wentOffline)
            self.advertisedPeerIDs = currentIDs
            let newPeers = discoveredPeers
                .filter { !self.dismissedPeerIDs.contains($0.id) }
                .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            self.peers = newPeers
            DispatchQueue.main.async { self.onPeersChanged?(newPeers) }
        }
        browser.stateUpdateHandler = { [weak self] state in
            if case .failed(let error) = state {
                DispatchQueue.main.async { self?.onStatus?("发现设备失败：\(error.localizedDescription)") }
            }
        }
        browser.start(queue: queue)
        self.browser = browser
    }

    private var serviceName: String { "\(displayName)〔\(instanceID)〕" }

    private func visibleName(from serviceName: String) -> String {
        guard let marker = serviceName.range(of: "〔", options: .backwards) else { return serviceName }
        return String(serviceName[..<marker.lowerBound])
    }

    func stop() {
        listener?.cancel()
        browser?.cancel()
        listener = nil
        browser = nil
        peers = []
        advertisedPeerIDs = []
        dismissedPeerIDs = []
    }

    func dismissPeer(id: String) {
        queue.async {
            self.dismissedPeerIDs.insert(id)
            let visiblePeers = self.peers.filter { $0.id != id }
            self.peers = visiblePeers
            DispatchQueue.main.async { self.onPeersChanged?(visiblePeers) }
        }
    }

    func send(text: String, to endpoint: NWEndpoint, completion: @escaping (Result<Void, Error>) -> Void) {
        let message = WireMessage(id: UUID(), sender: displayName, text: text, sentAt: Date())
        guard let body = try? JSONEncoder().encode(message) else {
            completion(.failure(MessageError.encodeFailed)); return
        }
        guard body.count <= 262_144 else {
            completion(.failure(MessageError.messageTooLarge)); return
        }
        var length = UInt32(body.count).bigEndian
        var packet = Data(bytes: &length, count: 4)
        packet.append(body)

        sendPacket(packet, to: endpoint, attempt: 1, completion: completion)
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
                    let isNew = self.seenMessageIDs.insert(message.id).inserted
                    if self.seenMessageIDs.count > 500 { self.seenMessageIDs.removeAll(keepingCapacity: true) }
                    connection.send(content: Data("OK".utf8), completion: .contentProcessed { _ in connection.cancel() })
                    if isNew { DispatchQueue.main.async { self.onMessage?(message) } }
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
