import AppKit
import Darwin

/// Route messages and monitors in this suite contain fixture data only.
func testRouteGuard() {
    func route(_ index: UInt16, _ flags: Int32 = RTF_UP) -> [UInt8] {
        var header = rt_msghdr2()
        var dst = sockaddr_in6()
        dst.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        dst.sin6_family = UInt8(AF_INET6)
        let mask = [UInt8](repeating: 0, count: 4)
        header.rtm_msglen = UInt16(MemoryLayout<rt_msghdr2>.size + MemoryLayout<sockaddr_in6>.size + mask.count)
        header.rtm_flags = flags
        header.rtm_index = index
        header.rtm_addrs = RTA_DST | RTA_NETMASK
        return withUnsafeBytes(of: header) { Array($0) } + withUnsafeBytes(of: dst) { Array($0) } + mask
    }
    func parse(_ bytes: [UInt8]) -> IncyTunnel.DefaultRoute {
        IncyTunnel.parseDefaultRoute(bytes[...], family: AF_INET6)
    }
    expect(parse([]) == .absent && parse(route(79, RTF_UP | RTF_IFSCOPE)) == .absent,
           "IPv6 unavailable and scoped-only routes are distinct from an active default")
    expect(parse(route(79)) == .interface(79) && parse(route(79) + route(79)) == .interface(79),
           "unique unscoped IPv6 default selected")
    expect(parse(route(79) + route(80)) == .unknown && parse(route(79) + [0]) == .unknown &&
           parse(Array(route(79).dropLast())) == .unknown, "ambiguous or truncated tables yield unknown")

    let ip = "192.0.2.19"
    let tunnel = IncyTunnel(pid: 901, started: 33, microseconds: 15, index: 79, name: "utun79", address: "198.18.0.2")
    let m = Monitor()
    var currentTunnel: IncyTunnel? = nil
    var defaultRoute = IncyTunnel.DefaultRoute.absent
    m.processGuard.snapshotProcesses = { [:] }
    m.runningApplications = { [] }; m.applicationURL = { _ in nil }
    m.readIncyTunnel = { currentTunnel }
    m.readIPv6Route = { defaultRoute }
    m.proxyAcceptsConnections = { _ in true }
    m.countryCache = [ip: "AT"]
    m.cfg.notifications = false
    m.cfg.guard.enabled = true
    m.cfg.guard.apps = [claudeCLITarget]
    m.cfg.guard.allow.ips = [ip, "2001:db8::42"]
    func reply(_ generation: Int, v6: Bool = false) {
        m.handleAnswers([ip, ip], additionalRoutes: v6 ? [ip, "2001:db8::42"] : [ip],
                        ipv6Confirmed: v6, generation: generation,
                        traceRoutes: Dictionary(uniqueKeysWithValues: Monitor.claudeHosts.map { ($0, ip) }),
                        systemSeen: true)
    }
    reply(m.beginRouteRound())
    expect(m.guardDecision?.allowed == false && !FileManager.default.fileExists(atPath: permitURL.path),
           "all IP probes passing without VPN cannot authorize even the first launch")
    currentTunnel = tunnel
    defaultRoute = .unknown
    reply(m.beginRouteRound(), v6: true)
    expect(m.guardDecision?.allowed == false, "unreadable IPv6 routing table holds even with successful probes")
    defaultRoute = .interface(80)
    reply(m.beginRouteRound(), v6: true)
    expect(m.guardDecision?.allowed == false, "IPv6 default outside TUN blocks an allowlisted v6 exit")
    defaultRoute = .absent
    reply(m.beginRouteRound(), v6: true)
    expect(m.guardDecision?.allowed == false, "reachable IPv6 without a tunnel default is not silently ignored")
    reply(m.beginRouteRound())
    reply(m.beginRouteRound())
    expect(m.guardDecision?.allowed == false && m.routeSummary.contains("2001:db8::42"),
           "silent IPv6 probes cannot undo a previously observed egress on the same tunnel")
    let restarted = Monitor()
    restarted.cfg = m.cfg
    restarted.runningApplications = { [] }; restarted.applicationURL = { _ in nil }
    restarted.processGuard.snapshotProcesses = { [:] }
    restarted.readIncyTunnel = { tunnel }; restarted.readIPv6Route = { .absent }
    restarted.proxyAcceptsConnections = { _ in false }
    restarted.handleAnswers([ip, ip], additionalRoutes: [ip], generation: restarted.beginRouteRound(),
                            traceRoutes: Dictionary(uniqueKeysWithValues: Monitor.claudeHosts.map { ($0, ip) }), systemSeen: true)
    expect(restarted.guardDecision?.allowed == false && restarted.routeSummary.contains("2001:db8::42"),
           "monitor restart cannot forget the intermittent IPv6 on the same tunnel")
    let generation = m.beginRouteRound()
    defaultRoute = .interface(79)
    reply(generation, v6: true)
    expect(m.guardDecision?.allowed == false, "changing v6 default during proof invalidates round")
    reply(m.beginRouteRound())
    expect(m.guardDecision?.allowed == false, "tunneled IPv6 requires an actual IPv6 probe")
    reply(m.beginRouteRound(), v6: true)
    expect(m.guardDecision?.allowed == true && m.mayThaw, "confirmed IPv4 and IPv6 on the same synthetic TUN")
    defaultRoute = .interface(80)
    expect(!m.mayThaw && m.decision()?.allowed == false, "different v6 route revokes permission before a network notification")
    defaultRoute = .absent
    let expired = m.beginRouteRound()
    m.proofStartUptime -= 12
    reply(expired)
    expect(m.guardDecision?.allowed == false, "elapsed monotonic deadline rejects round despite recent wall time")
    var serviceUp = false
    m.cfg.guard.vpn_service_id = "fixture-vpn"
    m.vpnConnected = { _ in serviceUp }
    let beforeConnected = m.beginRouteRound()
    serviceUp = true
    reply(beforeConnected)
    expect(m.guardDecision?.allowed == false, "system VPN connecting mid-round cannot use earlier probe results")
    let beforeSleep = m.beginRouteRound()
    m.willSleep(Notification(name: NSWorkspace.willSleepNotification))
    m.checkNow()
    reply(beforeSleep)
    expect(m.sleeping && !m.checking && !m.mayThaw && m.guardDecision?.allowed == false,
           "timer and stale replies cannot reopen access between willSleep and didWake")
}
