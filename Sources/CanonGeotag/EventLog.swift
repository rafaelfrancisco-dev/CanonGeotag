import Foundation

nonisolated struct LogEntry: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    let date: Date
    let message: String
}

/// Persistent ring buffer of app events, so background launches and
/// connections can be inspected later (no debugger is attached then).
actor EventLog {
    static let capacity = 500

    private let url: URL
    private var entries: [LogEntry]?

    init(fileName: String = "events.json") {
        let directory = URL.applicationSupportDirectory
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appending(path: fileName)
    }

    func load() -> [LogEntry] {
        if let entries { return entries }
        let loaded = (try? Data(contentsOf: url)).flatMap { try? JSONDecoder().decode([LogEntry].self, from: $0) } ?? []
        entries = loaded
        return loaded
    }

    func append(_ entry: LogEntry) {
        var all = load()
        all.append(entry)
        if all.count > Self.capacity { all.removeFirst(all.count - Self.capacity) }
        entries = all
        save(all)
    }

    func clear() {
        entries = []
        save([])
    }

    private func save(_ entries: [LogEntry]) {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
