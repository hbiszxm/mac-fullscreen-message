import Foundation

/// Local device labels. Discovery identity and network endpoints remain unchanged.
final class PeerNameStore {
    private let defaults: UserDefaults
    private let storageKey = "peerDisplayNamesV1"
    private var names: [String: String]

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        names = defaults.dictionary(forKey: storageKey) as? [String: String] ?? [:]
    }

    func displayName(for peer: Peer) -> String {
        names[key(for: peer)] ?? peer.name
    }

    func renamed(_ peers: [Peer]) -> [Peer] {
        peers.map { peer in
            Peer(id: peer.id, name: displayName(for: peer), endpoint: peer.endpoint, instanceID: peer.instanceID)
        }
    }

    @discardableResult
    func setName(_ name: String, for peer: Peer) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        names[key(for: peer)] = trimmed
        defaults.set(names, forKey: storageKey)
        return true
    }

    func resetName(for peer: Peer) {
        names.removeValue(forKey: key(for: peer))
        defaults.set(names, forKey: storageKey)
    }

    private func key(for peer: Peer) -> String {
        if let instanceID = peer.instanceID, !instanceID.isEmpty {
            return "instance:\(instanceID)"
        }
        return "peer:\(peer.id)"
    }
}
