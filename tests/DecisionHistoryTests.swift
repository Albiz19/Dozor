import Foundation

func testDecisionHistory() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: dir) }
    let file = dir.appendingPathComponent("decisions.json")
    let h = DecisionHistory(file: file)
    let t = Date(timeIntervalSince1970: 123)
    let allow = DecisionHistory.Decision(.allow, reason: "fixture", addresses: ["198.51.100.4", "2001:db8::1", "198.51.100.4"],
                                         rules: ["invalid/secret", "198.51.100.0/24", "2001:db8::1"])
    h.record(allow, at: t)
    h.record(allow, at: t.addingTimeInterval(30))
    h.flush()
    let restored = DecisionHistory(file: file)
    expect(restored.entries.count == 1 && restored.entries.first?.date == t, "history persists first transition timestamp without repeated poll events")
    expect(restored.entries.first?.decision.matches == ["198.51.100.4 → 198.51.100.0/24", "2001:db8::1"],
           "history records matching CIDR and exact IPv6 only")
    let attr = try FileManager.default.attributesOfItem(atPath: file.path)
    expect(attr[.posixPermissions] as? Int == 0o600, "decision history is owner-only")
    restored.record(.init(.block, reason: "VPN отключён"))
    restored.record(.init(.paused, reason: "Пауза"))
    for i in 0..<DecisionHistory.limit {
        restored.record(.init(.block, reason: "fixture \(i)"))
    }
    restored.flush()
    let trimmed = DecisionHistory(file: file)
    expect(trimmed.entries.count == DecisionHistory.limit && trimmed.entries.first?.decision.reason == "fixture 0", "old decisions evicted on disk")
    try Data([1, 2, 3]).write(to: file)
    let corrupt = DecisionHistory(file: file)
    corrupt.record(allow)
    corrupt.flush()
    expect(DecisionHistory(file: file).entries.first?.decision == allow, "history recovers from malformed local file")
}
