import Foundation

final class QuickMessageOrderStore {
    private let defaults: UserDefaults
    private let key = "quickMessageOrderV1"
    init(defaults: UserDefaults = .standard) { self.defaults = defaults }

    func messages(available: [String]) -> [String] {
        let saved = defaults.stringArray(forKey: key) ?? []
        let valid = Set(available)
        var seen = Set<String>()
        let ordered = (saved + available).filter { valid.contains($0) && seen.insert($0).inserted }
        if ordered != saved { defaults.set(ordered, forKey: key) }
        return ordered
    }

    @discardableResult
    func move(_ message: String, to target: String, available: [String]) -> Bool {
        var ordered = messages(available: available)
        guard message != target, let from = ordered.firstIndex(of: message),
              let to = ordered.firstIndex(of: target) else { return false }
        ordered.remove(at: from)
        ordered.insert(message, at: to)
        defaults.set(ordered, forKey: key)
        return true
    }
}
