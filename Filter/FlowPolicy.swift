import Foundation

/// A protected process may open exactly one kind of IP socket: TCP to its configured local proxy.
/// The rule does not relax when an IP probe succeeds or while the monitor app is closed.
struct FlowPolicy {
    let port: Int
    static func isVendor(_ name: String?) -> Bool {
        guard let name else { return false }
        let host = name.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return ["anthropic.com", "claude.ai", "claude.com", "anthropic.ai", "claudeusercontent.com", "claudemcpcontent.com"].contains {
            host == $0 || host.hasSuffix("." + $0)
        }
    }
    func permits(protected: Bool, hostname: String?, tcp: Bool, address: String?, destinationPort: Int?) -> Bool {
        guard protected || Self.isVendor(hostname) else { return true }
        return (1...65535).contains(port) && tcp && destinationPort == port && address == "127.0.0.1"
    }
}
