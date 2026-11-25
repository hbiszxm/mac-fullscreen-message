import Foundation
import Network
import Security
import CryptoKit

struct RelayPacket: Codable {
    struct Device: Codable { let id: String; let name: String }
    var type: String
    var id: String? = nil
    var name: String? = nil
    var deviceKey: String? = nil
    var to: String? = nil
    var requestID: UUID? = nil
    var message: WireMessage? = nil
    var peers: [Device]? = nil
    var ok: Bool? = nil
    var error: String? = nil
}

final class CloudRelay {
    static let endpointType = "_fsmcloud._tcp"
    static let host = "18.0.2.83"
    static let port: UInt16 = 18443
    static let certificateSHA256 = "e4ad457fd869c0a7c7e655eb953b3d8a46c26deeea92cb7c5d7e299159856f17"
    private let queue = DispatchQueue(label: "cn.local.fullscreen-message.cloud")
    private let id: String, name: String, key: String
    private let host: String, port: UInt16, pin: String
    private var connection: NWConnection?
    private var generation = 0
    private var stopped = true
    private var authenticated = false
    private var retry = 0
    private var lastReceived = Date()
    private var pending: [UUID: (Result<Void, Error>) -> Void] = [:]
    var onPeersChanged: (([Peer]) -> Void)?
    var onMessage: ((WireMessage) -> Bool)?
    var onStatus: ((String) -> Void)?

    init(id: String, name: String, key: String, host: String = CloudRelay.host,
         port: UInt16 = CloudRelay.port, pin: String = CloudRelay.certificateSHA256) {
        self.id = id; self.name = String(name.prefix(120)); self.key = key
        self.host = host; self.port = port; self.pin = pin
    }
    func start() { queue.async { self.stopped = false; self.connect() } }
    func stop() {
        queue.async {
            self.stopped = true
            self.disconnect("云网络已断开", reconnect: false)
        }
    }
    private func connect() {
        guard !stopped else { return }
        generation += 1
        let ticket = generation
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        sec_protocol_options_set_tls_resumption_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_tls_tickets_enabled(tls.securityProtocolOptions, false)
        sec_protocol_options_set_peer_authentication_required(tls.securityProtocolOptions, true)
        var certificateVerified = false
        let expected = pin
        sec_protocol_options_set_verify_block(tls.securityProtocolOptions, { _, trust, done in
            let reference = sec_trust_copy_ref(trust).takeRetainedValue()
            guard let cert = (SecTrustCopyCertificateChain(reference) as? [SecCertificate])?.first else { done(false); return }
            let digest = SHA256.hash(data: SecCertificateCopyData(cert) as Data).map { String(format: "%02x", $0) }.joined()
            guard digest == expected else { done(false); return }
            SecTrustSetAnchorCertificates(reference, [cert] as CFArray)
            SecTrustSetAnchorCertificatesOnly(reference, true)
            SecTrustSetPolicies(reference, SecPolicyCreateBasicX509())
            certificateVerified = SecTrustEvaluateWithError(reference, nil)
            done(certificateVerified)
        }, queue)
        let conn = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!, using: NWParameters(tls: tls))
        connection = conn
        conn.stateUpdateHandler = { [weak self, weak conn] state in
            guard let self, let conn, conn === self.connection, ticket == self.generation else { return }
            switch state {
            case .ready:
                guard certificateVerified else { self.disconnect("云网络证书校验失败"); return }
                self.lastReceived = Date()
                self.write(RelayPacket(type: "hello", id: self.id, name: self.name, deviceKey: self.key))
                self.readHeader(conn, ticket: ticket)
                self.heartbeat(ticket)
            case .failed, .waiting: self.disconnect("云网络连接中断，正在重连")
            default: break
            }
        }
        conn.start(queue: queue)
        queue.asyncAfter(deadline: .now() + 12) { [weak self] in
            guard let self, self.generation == ticket, !self.authenticated else { return }
            self.disconnect("云网络连接超时，正在重连")
        }
    }
    private func heartbeat(_ ticket: Int) {
        queue.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.generation == ticket, !self.stopped else { return }
            if Date().timeIntervalSince(self.lastReceived) > 30 { self.disconnect("云网络心跳超时，正在重连"); return }
            self.write(RelayPacket(type: "ping"))
            self.heartbeat(ticket)
        }
    }
    private func disconnect(_ reason: String, reconnect: Bool = true) {
        generation += 1
        let ticket = generation
        connection?.stateUpdateHandler = nil
        connection?.cancel(); connection = nil; authenticated = false
        let callbacks = Array(pending.values); pending.removeAll()
        DispatchQueue.main.async { [weak self] in
            self?.onPeersChanged?([]); self?.onStatus?(reason)
            callbacks.forEach { $0(.failure(MessageError.connectionFailed(reason))) }
        }
        guard reconnect, !stopped else { return }
        let delay = min(30.0, pow(2, Double(min(retry, 5))))
        retry += 1
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == ticket, !self.stopped else { return }
            self.connect()
        }
    }
    func send(_ message: WireMessage, to target: String, completion: @escaping (Result<Void, Error>) -> Void) {
        queue.async { [self] in
            guard self.authenticated else {
                DispatchQueue.main.async { completion(.failure(MessageError.connectionFailed("云网络尚未连接"))) }; return
            }
            let request = UUID()
            self.pending[request] = completion
            self.write(RelayPacket(type: "send", to: target, requestID: request, message: message))
            self.queue.asyncAfter(deadline: .now() + 12) { [weak self] in
                guard let callback = self?.pending.removeValue(forKey: request) else { return }
                DispatchQueue.main.async { callback(.failure(MessageError.noAcknowledgement)) }
            }
        }
    }
    private func write(_ packet: RelayPacket) {
        guard let conn = connection, let body = try? JSONEncoder().encode(packet) else { return }
        var count = UInt32(body.count).bigEndian
        var data = Data(bytes: &count, count: 4); data.append(body)
        conn.send(content: data, completion: .contentProcessed { [weak self, weak conn] error in
            guard let self, conn === self.connection else { return }
            if error != nil { self.disconnect("云网络发送失败，正在重连") }
        })
    }
    private func readHeader(_ conn: NWConnection, ticket: Int) {
        read(4, conn, ticket: ticket) { [weak self] header in
            guard let self else { return }
            let count = header.reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
            guard count > 0, count <= 300000 else { self.disconnect("云网络数据无效"); return }
            self.read(Int(count), conn, ticket: ticket) { [weak self] body in
                guard let self else { return }
                guard let packet = try? JSONDecoder().decode(RelayPacket.self, from: body) else { self.disconnect("云网络数据无效"); return }
                self.lastReceived = Date()
                self.handle(packet, ticket: ticket)
                if self.generation == ticket { self.readHeader(conn, ticket: ticket) }
            }
        }
    }
    private func read(_ size: Int, _ conn: NWConnection, ticket: Int, bytes: Data = Data(), done: @escaping (Data) -> Void) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: size - bytes.count) { [weak self] data, _, complete, error in
            guard let self, self.generation == ticket else { return }
            guard error == nil, let data, !data.isEmpty else { self.disconnect("云网络已断开，正在重连"); return }
            var result = bytes; result.append(data)
            if result.count == size { done(result) }
            else if complete { self.disconnect("云网络数据中断") }
            else { self.read(size, conn, ticket: ticket, bytes: result, done: done) }
        }
    }
    private func handle(_ packet: RelayPacket, ticket: Int) {
        switch packet.type {
        case "ready":
            authenticated = true; retry = 0
            DispatchQueue.main.async { [weak self] in self?.onStatus?("云网络已连接") }
        case "peers":
            let peers = (packet.peers ?? []).filter { $0.id != id }.map {
                Peer(id: "device:\($0.id)", name: $0.name, endpoint: .service(name: $0.id, type: Self.endpointType, domain: "relay", interface: nil), instanceID: $0.id)
            }
            DispatchQueue.main.async { [weak self] in self?.onPeersChanged?(peers) }
        case "message":
            guard let message = packet.message, let request = packet.requestID else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.onMessage?(message) == true else { return }
                self.queue.async { if self.generation == ticket { self.write(RelayPacket(type: "ack", requestID: request)) } }
            }
        case "result":
            guard let request = packet.requestID, let callback = pending.removeValue(forKey: request) else { return }
            let result: Result<Void, Error> = packet.ok == true ? .success(()) : .failure(MessageError.connectionFailed(packet.error ?? "对方未确认收到"))
            DispatchQueue.main.async { callback(result) }
        case "error": disconnect(packet.error ?? "云网络身份校验失败")
        default: break
        }
    }
}
