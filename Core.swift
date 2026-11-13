// Дозор: настройки, пути и вспомогательные функции.

import AppKit
import Network

// MARK: - Пути

let supportDir: URL = {
    let u = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Dozor", isDirectory: true)
    try? FileManager.default.createDirectory(at: u, withIntermediateDirectories: true)
    return u
}()
let configURL = supportDir.appendingPathComponent("config.json")
let logURL = supportDir.appendingPathComponent("dozor.log")
let latencyURL = supportDir.appendingPathComponent("latency.json")
let frozenURL = supportDir.appendingPathComponent("frozen.json")
let permitURL = supportDir.appendingPathComponent("cli.permit")
func setLaunchPermit(_ port: Int, _ until: Date?) {
    guard let until else { try? FileManager.default.removeItem(at: permitURL); return }
    // Use uptime and issuer PID so neither a clock adjustment nor a crashed monitor extends a lease.
    let remaining = until.timeIntervalSinceNow
    guard remaining > 0, remaining <= 10 else { try? FileManager.default.removeItem(at: permitURL); return }
    let identity = ProcessIdentity.read(getpid())
    guard let identity else { try? FileManager.default.removeItem(at: permitURL); return }
    let content = "\(port) \(ProcessInfo.processInfo.systemUptime + remaining) \(until.timeIntervalSince1970) \(getpid()) \(identity.seconds) \(identity.microseconds)\n"
    try? content.write(to: permitURL, atomically: true, encoding: .utf8)
}
let launchAgentURL = FileManager.default.homeDirectoryForCurrentUser
    .appendingPathComponent("Library/LaunchAgents/local.dozor.plist")

// MARK: - Настройки

struct AllowRules: Codable {
    var ips: [String] = []
    var countries: [String] = []
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        ips = try c.decodeIfPresent([String].self, forKey: .ips) ?? []
        countries = try c.decodeIfPresent([String].self, forKey: .countries) ?? []
    }
}

struct GuardConfig: Codable {
    var enabled = false
    var vpn_service_id = ""
    var proxy_port = 10808
    var apps: [String] = []            // bundle id, имя приложения или часть пути
    var allow = AllowRules()
    var block_when_offline = true
    var freeze_on_network_change = true
    var grace: Double = 0              // сек. в заморозке, после которых закрыть; 0 — не закрывать
    var close_timeout: Double = 5
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = GuardConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? def.enabled
        vpn_service_id = try c.decodeIfPresent(String.self, forKey: .vpn_service_id) ?? def.vpn_service_id
        proxy_port = try c.decodeIfPresent(Int.self, forKey: .proxy_port) ?? def.proxy_port
        apps = try c.decodeIfPresent([String].self, forKey: .apps) ?? def.apps
        allow = try c.decodeIfPresent(AllowRules.self, forKey: .allow) ?? def.allow
        block_when_offline = try c.decodeIfPresent(Bool.self, forKey: .block_when_offline) ?? def.block_when_offline
        freeze_on_network_change = try c.decodeIfPresent(Bool.self, forKey: .freeze_on_network_change) ?? def.freeze_on_network_change
        grace = try c.decodeIfPresent(Double.self, forKey: .grace) ?? def.grace
        close_timeout = try c.decodeIfPresent(Double.self, forKey: .close_timeout) ?? def.close_timeout
    }
}

struct Target: Codable { var name: String; var url: String }

struct TelegramConfig: Codable {
    var enabled = false
    var bot_token = ""
    var chat_id = ""
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        bot_token = try c.decodeIfPresent(String.self, forKey: .bot_token) ?? ""
        chat_id = try c.decodeIfPresent(String.self, forKey: .chat_id) ?? ""
    }
}

struct Config: Codable {
    var check_interval: Double = 5
    var ip_services: [String] = [
        "https://api.ipify.org",
        "https://ipv4.icanhazip.com",
        "https://v4.ident.me",
        "https://checkip.amazonaws.com",
        "https://ipinfo.io/ip",
    ]
    var min_agree = 2
    var menubar = "ip"                 // ip | country | icon
    var notifications = true
    var latency_interval: Double = 300
    var latency_targets: [Target] = [
        Target(name: "Google", url: "https://www.google.com/generate_204"),
        Target(name: "Cloudflare", url: "https://1.1.1.1/cdn-cgi/trace"),
        Target(name: "GitHub", url: "https://github.com"),
    ]
    var `guard` = GuardConfig()
    var telegram = TelegramConfig()

    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        let def = Config()
        check_interval = max(3, try c.decodeIfPresent(Double.self, forKey: .check_interval) ?? def.check_interval)
        ip_services = try c.decodeIfPresent([String].self, forKey: .ip_services) ?? def.ip_services
        min_agree = max(1, try c.decodeIfPresent(Int.self, forKey: .min_agree) ?? def.min_agree)
        menubar = try c.decodeIfPresent(String.self, forKey: .menubar) ?? def.menubar
        notifications = try c.decodeIfPresent(Bool.self, forKey: .notifications) ?? def.notifications
        latency_interval = max(30, try c.decodeIfPresent(Double.self, forKey: .latency_interval) ?? def.latency_interval)
        latency_targets = try c.decodeIfPresent([Target].self, forKey: .latency_targets) ?? def.latency_targets
        `guard` = try c.decodeIfPresent(GuardConfig.self, forKey: .guard) ?? def.guard
        telegram = try c.decodeIfPresent(TelegramConfig.self, forKey: .telegram) ?? def.telegram
    }
}

func loadConfig() -> (Config, String?) {
    if !FileManager.default.fileExists(atPath: configURL.path),
       !FileManager.default.fileExists(atPath: logURL.path),
       !FileManager.default.fileExists(atPath: frozenURL.path) { saveConfig(Config()) }
    do {
        let data = try Data(contentsOf: configURL)
        return (try JSONDecoder().decode(Config.self, from: data), nil)
    }
    catch { return (Config(), "ошибка в config.json: \(error.localizedDescription)") }
}

func saveConfig(_ cfg: Config) {
    let enc = JSONEncoder()
    enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    guard let data = try? enc.encode(cfg) else { return }
    // The JSON may include a bot token. Preserve owner-only access across atomic replacements.
    let temp = supportDir.appendingPathComponent(".config-" + UUID().uuidString)
    guard FileManager.default.createFile(atPath: temp.path, contents: nil, attributes: [.posixPermissions: 0o600]) else { return }
    defer { try? FileManager.default.removeItem(at: temp) }
    do {
        let handle = try FileHandle(forWritingTo: temp)
        defer { try? handle.close() }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        guard rename(temp.path, configURL.path) == 0 else { return }
    } catch { return }
}

func configMTime() -> Date? {
    (try? FileManager.default.attributesOfItem(atPath: configURL.path))?[.modificationDate] as? Date
}

// MARK: - Утилиты

let timeFmt: DateFormatter = {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm:ss"; return f
}()

func flag(_ code: String) -> String {
    let base: UInt32 = 127397
    var s = ""
    for v in code.uppercased().unicodeScalars {
        if let u = UnicodeScalar(base + v.value) { s.unicodeScalars.append(u) }
    }
    return s
}

func countryName(_ code: String) -> String {
    Locale(identifier: "ru_RU").localizedString(forRegionCode: code) ?? code
}

func ipv4ToUInt(_ s: String) -> UInt32? {
    let parts = s.split(separator: ".")
    guard parts.count == 4 else { return nil }
    var v: UInt32 = 0
    for p in parts { guard let b = UInt8(p) else { return nil }; v = v << 8 | UInt32(b) }
    return v
}

func ipBytes(_ s: String) -> [UInt8]? {
    // inet_pton consumes a C string: reject embedded NUL before bridging Swift input.
    guard !s.isEmpty, s.utf8.count <= 45, !s.utf8.contains(0) else { return nil }
    var v4 = in_addr(), v6 = in6_addr()
    if s.withCString({ inet_pton(AF_INET, $0, &v4) }) == 1 { return withUnsafeBytes(of: &v4) { Array($0) } }
    if s.withCString({ inet_pton(AF_INET6, $0, &v6) }) == 1 { return withUnsafeBytes(of: &v6) { Array($0) } }
    return nil
}

func ipMatches(_ ip: String, rule: String) -> Bool {
    let parts = rule.split(separator: "/", omittingEmptySubsequences: false)
    guard (1...2).contains(parts.count), let address = ipBytes(ip), let network = ipBytes(String(parts[0])),
          address.count == network.count else { return false }
    if parts.count == 1 { return address == network }
    guard !parts[1].isEmpty, parts[1].utf8.allSatisfy({ (48...57).contains($0) }), let bits = Int(parts[1]), (0...address.count * 8).contains(bits) else { return false }
    for index in address.indices {
        let remaining = min(8, max(0, bits - index * 8))
        let mask: UInt8 = remaining == 0 ? 0 : UInt8(0xff << (8 - remaining) & 0xff)
        if address[index] & mask != network[index] & mask { return false }
    }
    return true
}

func isValidIP(_ s: String) -> Bool { ipBytes(s) != nil }

/// Only the configured HTTPS origin may attest an egress address. Redirects are
/// not independent witnesses, even when the original URLs had different hosts.
final class ProbePolicy: NSObject, URLSessionTaskDelegate {
    static let shared = ProbePolicy()
    static func sources(_ strings: [String]) -> [URL] {
        var seen = Set<String>()
        return strings.compactMap(URL.init(string:)).filter { url in
            guard url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
                  var host = url.host?.lowercased(), !host.isEmpty else { return false }
            if host.hasSuffix(".") { host.removeLast() }
            return !host.isEmpty && seen.insert(host).inserted
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
