import Foundation

/// Received fullscreen messages remain unread until the user handles them.
/// Keep the full payload so pending messages survive an application update or restart.
final class PendingMessageStore {
    private let key = "pendingMessagesV1"
    private let defaults: UserDefaults
    private(set) var messages: [WireMessage] = []

    var count: Int { messages.count }
    var alertMessages: [WireMessage] { messages.filter { $0.kind == nil || $0.kind == "alert" } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        guard let data = defaults.data(forKey: key),
              let saved = try? JSONDecoder().decode([WireMessage].self, from: data) else { return }
        var seen: Set<UUID> = []
        messages = saved.filter { Self.isInboxMessage($0) && seen.insert($0.id).inserted }
        if messages.count != saved.count { save(messages) }
    }

    func contains(id: UUID) -> Bool {
        messages.contains { $0.id == id }
    }

    @discardableResult
    func add(_ message: WireMessage) -> Bool {
        guard Self.isInboxMessage(message), !contains(id: message.id) else { return false }
        return save(messages + [message])
    }

    func remove(id: UUID) {
        guard contains(id: id) else { return }
        save(messages.filter { $0.id != id })
    }

    private static func isInboxMessage(_ message: WireMessage) -> Bool {
        message.kind == nil || message.kind == "alert"
    }

    @discardableResult
    private func save(_ updated: [WireMessage]) -> Bool {
        guard let data = try? JSONEncoder().encode(updated) else { return false }
        defaults.set(data, forKey: key)
        messages = updated
        return true
    }
}
