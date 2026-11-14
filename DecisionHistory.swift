// Local history of policy changes. A decision describes the guard, not a packet.
import Foundation
import Combine
import Darwin

final class DecisionHistory: ObservableObject {
    enum Verdict: String, Codable {
        case allow, block, paused, inactive

        var title: String {
            switch self {
            case .allow: return "Разрешено"
            case .block: return "Заблокировано политикой"
            case .paused: return "На паузе"
            case .inactive: return "Блокировка не активна"
            }
        }
    }

    struct Decision: Equatable, Codable {
        var verdict: Verdict
        var reason: String
        var matches: [String]

        init(_ verdict: Verdict, reason: String, addresses: [String] = [], rules: [String] = []) {
            self.verdict = verdict
            self.reason = String(reason.prefix(240))
            // Store only IPs and CIDRs that the policy actually matched.
            matches = Array(Set(addresses)).sorted().prefix(16).compactMap { address in
                guard let rule = rules.first(where: { $0.utf8.count <= 50 && ipMatches(address, rule: $0) }) else { return nil }
                return address == rule ? address : "\(address) → \(rule)"
            }
        }
    }

    struct Entry: Identifiable, Codable {
        let id: UUID
        let date: Date
        let decision: Decision
    }

    static let limit = 100
    let file: URL
    @Published private(set) var entries: [Entry] = []
    @Published private(set) var saveFailed = false
    private let writer = DispatchQueue(label: "local.dozor.decision-history", qos: .utility)

    init(file: URL = supportDir.appendingPathComponent("decisions.json")) {
        self.file = file
        if let handle = try? FileHandle(forReadingFrom: file) {
            defer { try? handle.close() }
            let maxBytes = 1_000_000
            if let data = try? handle.read(upToCount: maxBytes + 1), data.count <= maxBytes,
               let decoded = try? JSONDecoder().decode([Entry].self, from: data) {
                entries = Array(decoded.suffix(Self.limit))
            }
        }
    }

    func record(_ decision: Decision, at date: Date = Date()) {
        guard entries.last?.decision != decision else { return }
        entries.append(Entry(id: UUID(), date: date, decision: decision))
        if entries.count > Self.limit { entries.removeFirst(entries.count - Self.limit) }
        let snapshot = entries, destination = file
        writer.async { [weak self] in
            let failed = !Self.persist(snapshot, to: destination)
            DispatchQueue.main.async {
                guard let self, self.saveFailed != failed else { return }
                self.saveFailed = failed
            }
        }
    }

    // Drain pending writes when the app exits or a test reopens the file.
    func flush() { writer.sync {} }

    private static func persist(_ entries: [Entry], to destination: URL) -> Bool {
        let temp = destination.deletingLastPathComponent().appendingPathComponent(".decisions-" + UUID().uuidString)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard fd >= 0 else { return false }
        defer { unlink(temp.path) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: JSONEncoder().encode(entries))
            try handle.close()
            return rename(temp.path, destination.path) == 0
        } catch { return false }
    }
}
