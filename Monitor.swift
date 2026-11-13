// Дозор: логика наблюдения за сетью и блокировки выбранных приложений.

import AppKit
import Network
import Combine
import SystemConfiguration

enum NetState: Equatable {
    case checking
    case ok(ip: String, country: String?)
    case mismatch([String])
    case offline
    case error(String)

    var title: String {
        switch self {
        case .checking: return "Проверяю IP…"
        case .ok: return "На связи"
        case .mismatch: return "Сервисы видят разные IP"
        case .offline: return "Нет интернета"
        case .error(let e): return "Ошибка: \(e)"
        }
    }
    var ip: String? { if case .ok(let ip, _) = self { return ip }; return nil }
    var country: String? { if case .ok(_, let c) = self { return c }; return nil }
}

struct LatencyStats {
    var last: Double?
    var avg: Double?
    var min: Double?
    var max: Double?
    var losses: Int
    var count: Int
}

final class Monitor: ObservableObject {
    @Published var cfg = Config()
    @Published var cfgError: String?
    @Published var state: NetState = .checking
    @Published var online = true
    @Published var interfaces: [String] = []
    @Published var events: [String] = []
    @Published var paused = false
    @Published var frozen: [pid_t: String] = [:]   // pid -> имя приложения
    @Published var latency: [String: [[Double]]] = [:] // имя -> [[unix-время, мс]]
    @Published var lastCheck: Date?
    @Published var startedAt = Date()

    var cfgMTime: Date?
    let pathMonitor = NWPathMonitor()
    var lastPathDesc = ""
    var lastIP: String?
    var countryCache: [String: String] = [:]
    var checking = false
    var checkTimer: Timer?
    var latencyTimer: Timer?
    var blockedSince: Date?
    var signalSources: [DispatchSourceSignal] = []
    let processGuard: ProcessGuard
    init(processGuard: ProcessGuard = ProcessGuard(stateURL: frozenURL)) { self.processGuard = processGuard }
    private var lastProxyUp: Bool?
    var proofStarted = Date.distantPast
    func clearLaunchPermit() { setLaunchPermit(cfg.guard.proxy_port, nil) }
    func invalidateProof() {
        verifiedAt = nil; confirmedRoutes = []; state = .checking; networkGeneration += 1; checking = false
        checkTasks.forEach { $0.cancel() }; checkTasks.removeAll()
        clearLaunchPermit()
    }
    func prepareForExit() {
        invalidateProof()
        processGuard.save()
    }
    var guardTimer: Timer?
    var networkStore: SCDynamicStore?
    var networkGeneration = 0
    var checkTasks: [URLSessionDataTask] = []
    var verifiedAt: TimeInterval?
    var proxyAcceptsConnections: (Int) -> Bool = Monitor.localProxyUp
    var vpnConnected: (String) -> Bool = { id in
        guard !id.isEmpty, let c = SCNetworkConnectionCreateWithServiceID(nil,id as CFString,nil,nil) else { return false }
        return SCNetworkConnectionGetStatus(c) == .connected
    }
    var mayThaw: Bool { vpnConnected(cfg.guard.vpn_service_id) }
    var routeIssue: String? {
        confirmedRoutes.first { !permittedIP($0) }.map { "Выход \($0) отсутствует в разрешённых IP" }
    }
    func permittedIP(_ address: String) -> Bool {
        cfg.guard.allow.ips.contains { ipMatches(address, rule: $0) }
    }

    static func localProxyUp(_ port: Int) -> Bool {
        guard let number = UInt16(exactly: port), number > 0 else { return false }
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }; defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET); address.sin_port = number.bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        if connected == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var pollfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        var error: Int32 = 0, size = socklen_t(MemoryLayout<Int32>.size)
        return poll(&pollfd, 1, 25) == 1 && getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &size) == 0 && error == 0
    }

    static let claudeHosts = ["api.anthropic.com", "claude.ai"]
    static func traceIP(_ text: String) -> String? {
        let values = text.split(separator: "\n").filter { $0.hasPrefix("ip=") }.map { String($0.dropFirst(3)) }
        return values.count == 1 && isValidIP(values[0]) ? values[0] : nil
    }

    static func checkClaudeRoute(host: String, port: Int) -> String? {
        let task = Process(), output = Pipe()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        task.environment = ["PATH": "/usr/bin:/bin"]
        task.arguments = ["-q", "--silent", "--fail", "--max-time", "4", "--max-filesize", "16384",
                          "--noproxy", "", "--proxy", "http://127.0.0.1:\(port)", "https://\(host)/cdn-cgi/trace"]
        task.standardOutput = output; task.standardError = FileHandle.nullDevice
        guard (try? task.run()) != nil else { return nil }
        let data = output.fileHandleForReading.readDataToEndOfFile(); task.waitUntilExit()
        return task.terminationStatus == 0 ? traceIP(String(decoding: data, as: UTF8.self)) : nil
    }
    @Published var routeSummary = "Маршруты ещё не проверены"
    var confirmedRoutes: [String] = []

    let directSession: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.timeoutIntervalForResource = 6
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        c.connectionProxyDictionary = ["HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
                                      "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0]
        return URLSession(configuration: c)
    }()

    let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.timeoutIntervalForResource = 6
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: c)
    }()

    // MARK: Запуск

    func start() {
        processGuard.onError = { [weak self] in self?.log($0) }
        clearLaunchPermit()
        reloadConfig(force: true)
        resumeLeftovers()
        enforce()
        watchNetworkSettings()
        if let d = try? Data(contentsOf: latencyURL),
           let h = try? JSONDecoder().decode([String: [[Double]]].self, from: d) { latency = h }
        if let lines = try? String(contentsOf: logURL, encoding: .utf8) {
            events = Array(lines.split(separator: "\n").suffix(500).map(String.init))
        }

        pathMonitor.pathUpdateHandler = { [weak self] path in
            DispatchQueue.main.async { self?.pathChanged(path) }
        }
        pathMonitor.start(queue: .global())

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(appLaunched(_:)),
            name: NSWorkspace.didLaunchApplicationNotification, object: nil)

        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep(_:)), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake(_:)), name: NSWorkspace.didWakeNotification, object: nil)
        // Persist ownership across shutdown; only fresh route verification can release it.
        for sig in [SIGTERM, SIGINT, SIGHUP] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [weak self] in self?.prepareForExit(); exit(0) }
            src.resume()
            signalSources.append(src)
        }

        log("Дозор запущен")
        scheduleTimers()
        checkNow()
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in self?.measureLatency() }
    }

    @objc func willSleep(_ n: Notification) { invalidateProof(); state = .checking; enforce() }
    @objc func didWake(_ n: Notification) { networkChanged(reason: "Пробуждение: повторная проверка VPN") }

    func interval(for config: Config) -> Double { config.guard.enabled || !processGuard.records.isEmpty ? min(5,config.check_interval) : config.check_interval }

    func scheduleTimers() {
        checkTimer?.invalidate()
        checkTimer = Timer.scheduledTimer(withTimeInterval: interval(for:cfg), repeats: true) { [weak self] _ in
            self?.reloadConfig(force: false)
            self?.checkNow()
        }
        guardTimer?.invalidate()
        guardTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            self?.reloadConfig(force: false)
            self?.enforce()
        }
        latencyTimer?.invalidate()
        latencyTimer = Timer.scheduledTimer(withTimeInterval: cfg.latency_interval, repeats: true) { [weak self] _ in
            self?.measureLatency()
        }
    }

    func reloadConfig(force: Bool) {
        let m = configMTime()
        if !force && m == cfgMTime { return }
        let old = cfg
        let (c, e) = loadConfig()
        cfgMTime = configMTime()
        if let e {
            invalidateProof(); cfgError = e
            log(e)
            if !force { enforce() }
            return // Keep the last valid targets; malformed settings must not release them.
        }
        invalidateProof(); cfg = c; cfgError = nil
        if !force { log("Настройки перечитаны") }
        if !force && (interval(for:old) != interval(for:cfg) || old.latency_interval != cfg.latency_interval) {
            scheduleTimers()
        }
        if !force { enforce() }
    }

    /// Изменение настроек из окна: сохраняем файл и сразу применяем.
    func updateConfig(_ change: (inout Config) -> Void) {
        let old = cfg
        var c = cfg
        change(&c)
        invalidateProof(); cfg = c
        cfgError = nil
        saveConfig(c)
        cfgMTime = configMTime()
        if interval(for:old) != interval(for:c) || old.latency_interval != c.latency_interval { scheduleTimers() }
        enforce()
    }

    // MARK: Журнал и уведомления

    func log(_ msg: String) {
        let line = "\(timeFmt.string(from: Date())) \(msg)"
        events.append(line)
        if events.count > 500 { events.removeFirst(events.count - 500) }
        if let h = try? FileHandle(forWritingTo: logURL) {
            h.seekToEndOfFile(); h.write((line + "\n").data(using: .utf8)!); try? h.close()
        } else {
            try? (line + "\n").write(to: logURL, atomically: true, encoding: .utf8)
        }
    }

    func notify(_ msg: String) {
        log(msg)
        if cfg.notifications {
            let esc = msg.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            p.arguments = ["-e", "display notification \"\(esc)\" with title \"Дозор\""]
            try? p.run()
        }
        sendTelegram("Дозор: \(msg)")
    }

    let telegramClient = TelegramClient()
    var telegramSession = URLSession(configuration: .ephemeral)
    func sendTelegram(_ text: String, force: Bool = false, done: ((TelegramDelivery) -> Void)? = nil) {
        telegramClient.send(text, config: cfg.telegram, test: force, session: telegramSession) { [weak self] delivery in
            if delivery != .sent && delivery != .disabled { self?.log("Telegram: " + delivery.message) }
            done?(delivery)
        }
    }

    // MARK: Сеть

    func watchNetworkSettings() {
        var context = SCDynamicStoreContext(version: 0, info: Unmanaged.passUnretained(self).toOpaque(),
                                            retain: nil, release: nil, copyDescription: nil)
        networkStore = SCDynamicStoreCreate(nil, "Dozor" as CFString, { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<Monitor>.fromOpaque(info).takeUnretainedValue()
            monitor.networkChanged(reason: "Изменились маршруты, DNS или настройки прокси")
        }, &context)
        if let store = networkStore {
            let keys = ["State:/Network/Global/IPv4", "State:/Network/Global/IPv6",
                        "State:/Network/Global/Proxies", "State:/Network/Global/DNS"] as CFArray
            let patterns = ["State:/Network/Interface/.*/IPv4", "State:/Network/Interface/.*/IPv6"] as CFArray
            if !SCDynamicStoreSetNotificationKeys(store, keys, patterns) || !SCDynamicStoreSetDispatchQueue(store, .main) {
                log("Не удалось включить наблюдение за настройками сети; остаются NWPathMonitor и опрос IP")
            }
        } else { log("Наблюдение за настройками сети недоступно") }
    }

    func pathChanged(_ path: NWPath) {
        let names = path.availableInterfaces.map(\.name)
        let desc = path.debugDescription
        online = path.status == .satisfied
        interfaces = Array(Set(names)).sorted()
        guard desc != lastPathDesc else { return }
        lastPathDesc = desc
        networkChanged(reason: online ? "Сеть изменилась" : "Нет подключения к интернету")
    }

    func networkChanged(reason: String) {
        invalidateProof()
        routeSummary = "Проверка после изменения сети"
        state = online ? .checking : .offline
        log(reason)
        enforce() // Pause first; never wait for a network request before applying the guard.
        checkNow()
    }

    func checkNow() {
        if checking { return }
        if !online { invalidateProof(); state = .offline; enforce(); return }
        checking = true
        proofStarted = Date()
        networkGeneration += 1
        let generation = networkGeneration
        var seenHosts = Set<String>()
        let services = cfg.ip_services.compactMap(URL.init(string:)).filter { url in
            guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased(), url.user == nil, url.password == nil else { return false }
            return seenHosts.insert(host).inserted
        }
        let group = DispatchGroup()
        let lock = NSLock()
        var answers: [String] = [], extraRoutes: [String] = []
        var ipv6Confirmed = false
        var observedSystemRoute = false
        var traceRoutes: [String: String] = [:]
        let needsClaude = guardActive || !processGuard.records.isEmpty
        let proxyPort = cfg.guard.proxy_port
        let requireV6 = pathMonitor.currentPath.supportsIPv6
        for host in needsClaude ? Self.claudeHosts : [] {
            group.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { group.leave() }
                if let ip = Self.checkClaudeRoute(host: host, port: proxyPort) {
                    lock.lock(); traceRoutes[host] = ip; lock.unlock()
                }
            }
        }
        func fetch(_ url: URL, using session: URLSession, primary: Bool, ipv6: Bool = false) {
            group.enter()
            var request = URLRequest(url: url)
            request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
            let task = session.dataTask(with: request) { data, resp, _ in
                defer { group.leave() }
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200 else { return }
                let ip = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                guard isValidIP(ip), !ipv6 || ip.contains(":") else { return }
                lock.lock()
                if primary { answers.append(ip) } else { extraRoutes.append(ip) }
                if ipv6 { ipv6Confirmed = true } else if !primary { observedSystemRoute = true }
                lock.unlock()
            }
            checkTasks.append(task)
            task.resume()
        }
        // CLI tools may ignore the system proxy: confirm the direct route independently.
        for url in services { fetch(url, using: directSession, primary: true) }
        fetch(URL(string: "https://api.ipify.org")!, using: session, primary: false)
        fetch(URL(string: "https://api6.ipify.org")!, using: directSession, primary: false, ipv6: true)
        fetch(URL(string: "https://ipv6.icanhazip.com")!, using: directSession, primary: false, ipv6: true)
        group.notify(queue: .main) { [weak self] in
            guard let self, generation == self.networkGeneration else { return }
            self.checkTasks.removeAll()
            self.lastCheck = Date()
            self.handleAnswers(answers, additionalRoutes: extraRoutes, ipv6Confirmed: ipv6Confirmed, generation: generation, traceRoutes: traceRoutes, systemSeen: observedSystemRoute, requireV6: requireV6)
        }
    }

    func handleAnswers(_ answers: [String], additionalRoutes: [String] = [], ipv6Confirmed: Bool = false, generation: Int? = nil, traceRoutes: [String: String] = [:], systemSeen: Bool = false, requireV6: Bool = false) {
        let token = generation ?? networkGeneration
        guard token == networkGeneration, checking else { return }
        guard (!(guardActive || !processGuard.records.isEmpty) || proxyAcceptsConnections(cfg.guard.proxy_port)), online, cfgError == nil, (0...8).contains(Date().timeIntervalSince(proofStarted)) else {
            invalidateProof(); state = online ? .checking : .offline; enforce(); return
        }
        let counts = Dictionary(answers.filter(isValidIP).map { ($0, 1) }, uniquingKeysWith: +)
        if (guardActive || !processGuard.records.isEmpty) && (!Self.claudeHosts.allSatisfy({ traceRoutes[$0].map(isValidIP) == true }) || !systemSeen || (requireV6 && !ipv6Confirmed)) {
            state = .error("Не подтверждён маршрут Claude, системного прокси или доступного IPv6")
        } else if counts.isEmpty {
            state = online ? .error("прямой выход: сервисы IP не отвечают") : .offline
        } else if counts.count > 1 {
            let list = counts.keys.sorted()
            state = .mismatch(list)
        } else if let first = counts.first, first.value >= (guardActive || !processGuard.records.isEmpty ? max(2,cfg.min_agree) : cfg.min_agree) {
            let ip = first.key
            let routes = Array(Set([ip] + additionalRoutes.filter(isValidIP) + Array(traceRoutes.values))).sorted()
            confirmedRoutes = routes
            checking = false
            verifiedAt = ProcessInfo.processInfo.systemUptime
            routeSummary = "Проверенные выходы: " + routes.joined(separator: ", ") + (guardActive || !processGuard.records.isEmpty ? " · маршруты Claude проверены" : "")
            state = .ok(ip: ip, country: countryCache[ip])
            if lastIP != ip { lastIP = ip; log("IP: \(ip)") }
            enforce(freshGeneration: token)
            if countryCache[ip] == nil { lookupCountry(ip) { [weak self] cc in
                guard let self, token == self.networkGeneration, case .ok = self.state else { return }
                self.state = .ok(ip: ip, country: cc)
            } }
            return
        } else {
            state = .error("мало независимых подтверждений прямого IP")
        }
        invalidateProof()
        routeSummary = "Не удалось подтвердить разрешённые выходы"
        enforce()
    }

    func lookupCountry(_ ip: String, done: @escaping (String?) -> Void) {
        if let c = countryCache[ip] { done(c); return }
        let sources: [(String, (Data) -> String?)] = [
            ("https://ipinfo.io/\(ip)/country", { String(decoding: $0, as: UTF8.self) }),
            ("https://ipapi.co/\(ip)/country/", { String(decoding: $0, as: UTF8.self) }),
            ("https://api.country.is/\(ip)", {
                (try? JSONSerialization.jsonObject(with: $0) as? [String: Any])?["country"] as? String
            }),
        ]
        func attempt(_ i: Int) {
            guard i < sources.count, let url = URL(string: sources[i].0) else {
                DispatchQueue.main.async { done(nil) }; return
            }
            session.dataTask(with: url) { [weak self] data, resp, _ in
                if let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                   let raw = sources[i].1(data)?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased(),
                   raw.count == 2, raw.allSatisfy({ $0.isLetter }) {
                    DispatchQueue.main.async { self?.countryCache[ip] = raw; done(raw) }
                } else { attempt(i + 1) }
            }.resume()
        }
        attempt(0)
    }

    // MARK: Задержка

    func measureLatency() {
        for t in cfg.latency_targets {
            guard let url = URL(string: t.url) else { continue }
            var req = URLRequest(url: url); req.httpMethod = "HEAD"
            let start = Date()
            session.dataTask(with: req) { [weak self] _, resp, err in
                let ms = (err == nil && resp != nil) ? Date().timeIntervalSince(start) * 1000 : -1
                DispatchQueue.main.async {
                    guard let self else { return }
                    var h = self.latency[t.name] ?? []
                    h.append([Date().timeIntervalSince1970.rounded(), ms.rounded()])
                    if h.count > 2016 { h.removeFirst(h.count - 2016) }  // ~неделя при 5 мин
                    self.latency[t.name] = h
                    if let d = try? JSONEncoder().encode(self.latency) { try? d.write(to: latencyURL, options: .atomic) }
                }
            }.resume()
        }
    }

    func stats(_ name: String, since: Date) -> LatencyStats {
        let h = (latency[name] ?? []).filter { $0.count == 2 && $0[0] >= since.timeIntervalSince1970 }
        let ok = h.map { $0[1] }.filter { $0 >= 0 }
        return LatencyStats(
            last: h.last.flatMap { $0[1] >= 0 ? $0[1] : nil },
            avg: ok.isEmpty ? nil : ok.reduce(0, +) / Double(ok.count),
            min: ok.min(), max: ok.max(),
            losses: h.count - ok.count, count: h.count)
    }

    // MARK: Блокировка своих приложений

    var guardActive: Bool { cfg.guard.enabled && !cfg.guard.apps.isEmpty }

    /// Cached decisions can keep a running app running, but never release a stopped app.
    func decision(proxyUp: Bool? = nil) -> (allowed: Bool, reason: String)? {
        if let cfgError { return (false, cfgError) }
        guard online, case .ok(let ip, _) = state else { return (false, state.title) }
        guard let verifiedAt, ProcessInfo.processInfo.systemUptime - verifiedAt < 12,
              !confirmedRoutes.isEmpty, confirmedRoutes.contains(ip) else { return (false, "Требуется свежая проверка VPN") }
        if !cfg.guard.vpn_service_id.isEmpty && !mayThaw { return (false, "Служба VPN не подключена") }
        if let issue = routeIssue { return (false, issue) }
        guard proxyUp ?? proxyAcceptsConnections(cfg.guard.proxy_port) else { return (false, "Локальный прокси VPN недоступен") }
        return (true, "Прокси доступен, выходные IP подтверждены")
    }

    func matchedApps() -> [NSRunningApplication] {
        let pats = cfg.guard.apps.map { $0.lowercased() }.filter { !$0.isEmpty }
        let me = ProcessInfo.processInfo.processIdentifier
        return NSWorkspace.shared.runningApplications.filter { a in
            guard a.processIdentifier != me, a.processIdentifier > 1 else { return false }
            let bid = a.bundleIdentifier?.lowercased() ?? ""
            let name = a.localizedName?.lowercased() ?? ""
            let path = a.bundleURL?.path.lowercased() ?? ""
            return pats.contains { $0 == bid || $0 == name || (($0.contains("/") || $0.hasSuffix(".app")) && path.contains($0)) }
        }
    }

    func enforce(freshGeneration: Int? = nil) {
        guard guardActive || !processGuard.records.isEmpty else { clearLaunchPermit(); return }
        let up = proxyAcceptsConnections(cfg.guard.proxy_port) && (cfg.guard.vpn_service_id.isEmpty || mayThaw)
        if !up && lastProxyUp != false {
            invalidateProof()
            state = .error("Локальный прокси VPN недоступен")
        }
        lastProxyUp = up
        let verdict = decision(proxyUp: up)
        if verdict?.allowed == true && (processGuard.records.isEmpty || mayThaw) {
            // Only the completion of a new end-to-end check may send SIGCONT.
            if let generation = freshGeneration, generation == networkGeneration {
                if guardActive && !paused && cfg.guard.apps.contains(where: {
                    [claudeCLITarget, "com.anthropic.claude-code-url-handler"].contains($0.lowercased())
                }) { setLaunchPermit(cfg.guard.proxy_port, proofStarted.addingTimeInterval(10)) }
                if !processGuard.records.isEmpty {
                    let heldBeforeRelease = processGuard.records
                    var lostProof = false
                    processGuard.resumeVerified {
                        let allowed = self.mayThaw && self.proxyAcceptsConnections(self.cfg.guard.proxy_port) && generation == self.networkGeneration
                        if !allowed { lostProof = true }
                        return allowed
                    }
                    frozen = processGuard.names
                    if lostProof || !mayThaw || !proxyAcceptsConnections(cfg.guard.proxy_port) {
                        invalidateProof(); lastProxyUp = false; state = .error("Локальный прокси VPN недоступен")
                        for (pid, rec) in heldBeforeRelease where rec.identity.isCurrent { processGuard.records[pid] = rec }
                        freezeMatched(reason: state.title); return
                    }
                    if frozen.isEmpty { notify("Разморожено после проверки VPN") }
                }
                blockedSince = nil
            }
            return
        }
        clearLaunchPermit()
        if !guardActive || paused {
            if !processGuard.records.isEmpty { processGuard.freeze(roots: []); frozen = processGuard.names }
            return
        }
        if blockedSince == nil { blockedSince = Date() }
        freezeMatched(reason: verdict?.reason ?? "VPN не подтверждён")

        let g = cfg.guard
        if g.grace > 0, let since = blockedSince, Date().timeIntervalSince(since) >= g.grace {
            terminateFrozen()
        }
    }

    func matchedRoots(snapshot: [pid_t: LocalProcess]? = nil) -> [(LocalProcess, String, String)] {
        var roots = matchedApps().compactMap { app -> (LocalProcess, String, String)? in
            guard let p = LocalProcess.read(app.processIdentifier) else { return nil }
            let bid = app.bundleIdentifier?.lowercased() ?? ""
            let name = app.localizedName?.lowercased() ?? ""
            let path = app.bundleURL?.path.lowercased() ?? ""
            guard let target = cfg.guard.apps.map({ $0.lowercased() }).first(where: {
                $0 == bid || $0 == name || (($0.contains("/") || $0.hasSuffix(".app")) && path.contains($0))
            }) else { return nil }
            return (p, app.localizedName ?? app.bundleIdentifier ?? "Приложение", target)
        }
        let patterns = cfg.guard.apps.map { $0.lowercased() }
        let processes = snapshot ?? LocalProcess.snapshot()
        if patterns.contains("com.anthropic.claudefordesktop"),
           let bundle = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.anthropic.claudefordesktop") {
            let prefix = bundle.resolvingSymlinksInPath().path + "/"
            for process in processes.values where process.path.hasPrefix(prefix) {
                roots.append((process, "Claude", "com.anthropic.claudefordesktop"))
            }
        }
        if patterns.contains(claudeCLITarget) || patterns.contains("com.anthropic.claude-code-url-handler") {
            for p in processes.values where p.identity.pid != getpid() && p.isClaudeCLI {
                roots.append((p, "Claude Code (CLI)", patterns.contains(claudeCLITarget) ? claudeCLITarget : "com.anthropic.claude-code-url-handler"))
            }
        }
        return roots
    }

    func freezeMatched(reason: String) {
        let before = Set(processGuard.names.values)
        let roots = matchedRoots()
        let targets = Dictionary(roots.map { ($0.0.identity.pid, $0.2) }, uniquingKeysWith: { a, _ in a })
        processGuard.freeze(roots: roots.map { ($0.0, $0.1) }, targets: targets)
        frozen = processGuard.names
        let added = Set(frozen.values).subtracting(before).sorted()
        if !added.isEmpty { notify("Заморожено: \(added.joined(separator: ", ")) — \(reason)") }
    }

    func terminateFrozen() {
        for record in processGuard.records.values { record.identity.send(SIGKILL) }
    }

    func resumeLeftovers() {
        processGuard.recover()
        frozen = processGuard.names
    }

    @objc func appLaunched(_ n: Notification) {
        // Только что запущенное приложение из списка тоже замораживаем, если сейчас нельзя.
        enforce()
    }

    // MARK: Действия

    func togglePause() {
        invalidateProof(); paused.toggle()
        log(paused ? "Блокировка поставлена на паузу" : "Блокировка снова включена")
        enforce()
    }

    func allowCurrentIP() {
        guard let ip = state.ip, !cfg.guard.allow.ips.contains(ip) else { return }
        updateConfig { $0.guard.allow.ips.append(ip) }
        log("Разрешён IP \(ip)")
    }

    var launchAtLogin: Bool { FileManager.default.fileExists(atPath: launchAgentURL.path) }

    func setLaunchAtLogin(_ on: Bool) {
        objectWillChange.send()
        if !on {
            try? FileManager.default.removeItem(at: launchAgentURL)
            log("Автозапуск выключен")
            return
        }
        let exe = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let plist: [String: Any] = [
            "Label": "local.dozor",
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Interactive",
        ]
        try? FileManager.default.createDirectory(at: launchAgentURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let d = try? PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0) {
            try? d.write(to: launchAgentURL)
            log("Автозапуск включён")
        }
    }
}
