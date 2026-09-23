import Foundation

struct MessageHistoryEntry: Codable {
    let id: UUID
    let date: Date
    let direction: String
    let sender: String
    let recipients: String
    let text: String
    var status: String
}

final class MessageHistoryStore {
    private let key = "messageHistoryV1"
    private(set) var entries: [MessageHistoryEntry] = []
    var onChange: (() -> Void)?

    init() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let saved = try? JSONDecoder().decode([MessageHistoryEntry].self, from: data) else { return }
        entries = saved
    }

    func add(_ entry: MessageHistoryEntry) {
        entries.append(entry)
        if entries.count > 500 { entries.removeFirst(entries.count - 500) }
        save()
    }

    func update(id: UUID, status: String) {
        guard let index = entries.lastIndex(where: { $0.id == id }) else { return }
        entries[index].status = status
        save()
    }

    func formattedText() -> String {
        guard !entries.isEmpty else { return "暂无消息历史。" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return entries.reversed().map { entry in
            "[\(formatter.string(from: entry.date))] \(entry.direction)\n发送者：\(entry.sender)\n接收者：\(entry.recipients)\n内容：\(entry.text)\n状态：\(entry.status)"
        }.joined(separator: "\n\n────────────────────\n\n")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) { UserDefaults.standard.set(data, forKey: key) }
        onChange?()
    }
}
