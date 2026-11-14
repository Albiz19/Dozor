import Foundation

func testProfiles() throws {
    var config = try JSONDecoder().decode(Config.self, from: Data(#"{"guard":{"enabled":true,"apps":["org.test.uninstalled"],"allow":{"ips":["192.0.2.9","2001:db8::/64"],"countries":["AT"]},"proxy_port":4101,"vpn_service_id":"fixture-a","grace":60}}"#.utf8))
    expect(config.guard.profiles.isEmpty && config.guard.enabled, "legacy config retains guard settings with an empty profile library")
    config.telegram.bot_token = "fixture-secret"
    expect(config.guard.saveProfile(named: " Office ") && config.guard.profiles.first?.name == "Office",
           "save captures current route settings with a stable ID")
    let a = config.guard.profiles[0]
    let profileFields = try JSONSerialization.jsonObject(with: JSONEncoder().encode(a)) as! [String: Any]
    expect(Set(profileFields.keys) == ["id","name","ips","proxyPort","vpnServiceID"], "profile data contains only routing fields, name and ID")
    expect(!config.guard.saveProfile(named: "office") && !config.guard.saveProfile(named: " "), "duplicate and empty profile names rejected")
    config.guard.proxy_port = 0
    expect(!config.guard.saveProfile(named: "Invalid"), "invalid proxy port rejected")
    config.guard.proxy_port = 4102
    config.guard.allow.ips = ["192.0.2.1/99"]
    expect(!config.guard.saveProfile(named: "Invalid"), "invalid profile CIDR rejected")
    config.guard.allow.ips = []; config.guard.vpn_service_id = ""
    expect(config.guard.saveProfile(named: "Home") && !a.matches(config.guard), "empty allowlist is saved explicitly without granting access")
    let b = config.guard.profiles[1]
    let decoded = try JSONDecoder().decode(Config.self, from: JSONEncoder().encode(config))
    expect(decoded.guard.profiles == [a,b], "profile IDs and both sets of rules survive a config round trip")
    let m = Monitor()
    m.cfg = decoded
    m.paused = true; m.online = false; m.cfg.notifications = false
    m.runningApplications = { [] }; m.applicationURL = { _ in nil }
    m.processGuard.snapshotProcesses = { [:] }
    m.readIncyTunnel = { nil }; m.proxyAcceptsConnections = { _ in false }; m.vpnConnected = { _ in false }
    m.cfgMTime = configMTime()
    let old = m.beginRouteRound()
    m.verifiedAt = ProcessInfo.processInfo.systemUptime
    m.state = .ok(ip: "192.0.2.9", country: nil)
    precondition(m.applyProfile(a.id))
    m.handleAnswers(["192.0.2.9","192.0.2.9"], generation: old)
    expect(m.cfg.guard.profiles[0].matches(m.cfg.guard) && m.cfg.guard.allow.ips == a.ips,
           "activating profile replaces IP allowlist, proxy port and VPN service")
    expect(m.networkGeneration != old && m.verifiedAt == nil && m.guardDecision?.allowed == false && !m.mayThaw,
           "profile switch while offline invalidates cached proof and rejects delayed completion")
    expect(m.cfg.guard.enabled && m.paused && m.cfg.guard.apps == ["org.test.uninstalled"] &&
           m.cfg.guard.allow.countries == ["AT"] && m.cfg.guard.grace == 60 && m.cfg.telegram.bot_token == "fixture-secret",
           "activation preserves app targets, guard settings, pause and Telegram")
    let beforeDelete = m.networkGeneration
    expect(m.storeProfiles([b]) && a.matches(m.cfg.guard) && m.networkGeneration == beforeDelete,
           "deleting an active preset preserves current network rules and proof generation")
    let restored = loadConfig()
    expect(restored.1 == nil && restored.0.guard.profiles == [b] && a.matches(restored.0.guard),
           "restart restores remaining profiles and latest activated settings")
    var copy = m.cfg.guard
    expect(!copy.activateProfile(a.id) && a.matches(copy), "activating deleted profile leaves existing rules unchanged")
}
