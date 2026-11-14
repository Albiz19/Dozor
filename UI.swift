// Дозор: окно с боковым меню разделов.

import SwiftUI
import Charts
import AppKit

// MARK: - Разделы

enum Page: String, CaseIterable, Identifiable {
    case overview, protection, latency, log, settings
    var id: String { rawValue }
    var title: String {
        switch self {
        case .overview: return "Обзор"
        case .protection: return "Блокировка"
        case .latency: return "Задержка"
        case .log: return "Журнал"
        case .settings: return "Настройки"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .protection: return "lock.shield"
        case .latency: return "chart.xyaxis.line"
        case .log: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        }
    }
}

final class Navigation: ObservableObject {
    @Published var section: Page? = .overview
}

struct MainView: View {
    @ObservedObject var m: Monitor
    @ObservedObject var nav: Navigation

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $nav.section) { s in
                Label(s.title, systemImage: s.icon).tag(s)
            }
            .navigationSplitViewColumnWidth(min: 180, ideal: 200)
            .safeAreaInset(edge: .bottom) { SidebarStatus(m: m).padding(12) }
        } detail: {
            Group {
                switch nav.section ?? .overview {
                case .overview: OverviewView(m: m, nav: nav)
                case .protection: ProtectionView(m: m)
                case .latency: LatencyView(m: m)
                case .log: LogView(m: m)
                case .settings: SettingsView(m: m)
                }
            }
            .frame(minWidth: 560, minHeight: 460)
        }
        .navigationTitle(nav.section?.title ?? "Дозор")
    }
}

struct SidebarStatus: View {
    @ObservedObject var m: Monitor
    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(statusColor(m)).frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(m.state.ip.map { "\(m.state.country.map(flag) ?? "") \($0)" } ?? m.state.title)
                    .font(.caption).lineLimit(1)
                if !m.frozen.isEmpty {
                    Text("❄︎ заморожено: \(Set(m.frozen.values).count)").font(.caption2).foregroundStyle(.blue)
                }
            }
            Spacer()
        }
    }
}

func statusColor(_ m: Monitor) -> Color {
    if !m.frozen.isEmpty { return .blue }
    switch m.state {
    case .ok: return .green
    case .checking: return .orange
    default: return .red
    }
}

// MARK: - Общие элементы

struct Card<Content: View>: View {
    let title: String
    let icon: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline).foregroundStyle(.secondary)
            content
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.primary.opacity(0.08)))
    }
}

struct Pill: View {
    let text: String
    let color: Color
    var body: some View {
        Text(text).font(.caption.weight(.semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Capsule().fill(color.opacity(0.18)))
            .foregroundStyle(color)
    }
}

func fmtMs(_ v: Double?) -> String { v.map { "\(Int($0)) мс" } ?? "—" }

// MARK: - Приложения на компьютере

struct InstalledApp: Identifiable, Hashable {
    let id: String      // bundle id
    let name: String
    let url: URL
}

enum AppCatalog {
    static func scan(roots overrideRoots: [String]? = nil, cliPaths overrideCLI: [String]? = nil) -> [InstalledApp] {
        let fm = FileManager.default
        let roots = overrideRoots ?? ["/Applications", "/System/Applications", "/System/Applications/Utilities",
                     "/Applications/Utilities", fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var seen = Set<String>()
        var out: [InstalledApp] = []
        func add(_ url: URL) {
            guard let b = Bundle(url: url), let bid = b.bundleIdentifier,
                  bid != "local.dozor", !seen.contains(bid) else { return }
            seen.insert(bid)
            let name = (b.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
                ?? (b.object(forInfoDictionaryKey: "CFBundleName") as? String)
                ?? url.deletingPathExtension().lastPathComponent
            // Имя как в Finder (локализованное), иначе из Info.plist.
            let shown = (fm.displayName(atPath: url.path) as NSString).deletingPathExtension
            out.append(InstalledApp(id: bid, name: shown.isEmpty ? name : shown, url: url))
        }
        for root in roots {
            guard let items = try? fm.contentsOfDirectory(at: URL(fileURLWithPath: root), includingPropertiesForKeys: [.isDirectoryKey]) else { continue }
            for u in items {
                if u.pathExtension == "app" { add(u) }
                else if (try? u.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                        let sub = try? fm.contentsOfDirectory(at: u, includingPropertiesForKeys: nil) {
                    for s in sub where s.pathExtension == "app" { add(s) }  // папки вроде /Applications/Setapp
                }
            }
        }
        let cliCandidates = overrideCLI ?? ["/usr/local/bin/claude", "/opt/homebrew/bin/claude",
                             fm.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/claude").path,
                             fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/local/claude").path]
        let cliPath = cliCandidates.first { fm.isExecutableFile(atPath: $0) } ?? "/usr/local/bin/claude"
        out.append(InstalledApp(id: claudeCLITarget, name: "Claude Code (CLI)", url: URL(fileURLWithPath: cliPath)))
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func icon(for url: URL) -> NSImage {
        let i = NSWorkspace.shared.icon(forFile: url.path)
        i.size = NSSize(width: 32, height: 32)
        return i
    }

    /// Имя и значок для записи из списка блокировки (bundle id, имя или путь).
    static func resolve(_ pattern: String, in apps: [InstalledApp]) -> (name: String, icon: NSImage?) {
        if let a = apps.first(where: { $0.id.lowercased() == pattern.lowercased() || $0.name.lowercased() == pattern.lowercased() }) {
            return (a.name, icon(for: a.url))
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: pattern) {
            return (url.deletingPathExtension().lastPathComponent, icon(for: url))
        }
        return (pattern, nil)
    }
}

final class AppCatalogModel: ObservableObject {
    @Published var apps: [InstalledApp] = []
    @Published var loading = false
    func load() {
        if loading { return }
        loading = true
        DispatchQueue.global(qos: .userInitiated).async {
            let list = AppCatalog.scan()
            DispatchQueue.main.async { self.apps = list; self.loading = false }
        }
    }
}

// MARK: - Обзор

struct OverviewView: View {
    @ObservedObject var m: Monitor
    @ObservedObject var nav: Navigation

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                hero
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 16) {
                    Card(title: "Сеть", icon: "wifi") {
                        row("Интернет", m.online ? "есть" : "нет")
                        row("Интерфейсы", m.interfaces.isEmpty ? "—" : m.interfaces.joined(separator: ", "))
                        row("Последняя проверка", m.lastCheck.map { timeOnly($0) } ?? "—")
                        row("Проверка каждые", "\(Int(m.interval(for:m.cfg))) с")
                    }
                    Card(title: "Блокировка", icon: "lock.shield") {
                        guardSummary
                    }
                    Card(title: "Задержка", icon: "chart.xyaxis.line") {
                        ForEach(m.cfg.latency_targets, id: \.name) { t in
                            let s = m.stats(t.name, since: Date().addingTimeInterval(-3600))
                            HStack {
                                Text(t.name)
                                Spacer()
                                Text(fmtMs(s.last)).monospacedDigit()
                                    .foregroundStyle(s.last == nil ? .red : (s.last ?? 0) > 500 ? .orange : .primary)
                            }
                        }
                        Button("Подробнее") { nav.section = .latency }.buttonStyle(.link)
                    }
                    Card(title: "Последние события", icon: "clock") {
                        ForEach(Array(m.events.suffix(5).reversed().enumerated()), id: \.offset) { _, e in
                            Text(e).font(.caption).lineLimit(2).foregroundStyle(.secondary)
                        }
                        Button("Весь журнал") { nav.section = .log }.buttonStyle(.link)
                    }
                }
            }
            .padding(20)
        }
    }

    var hero: some View {
        HStack(spacing: 20) {
            Text(m.state.country.map(flag) ?? (m.online ? "🌐" : "⚠️")).font(.system(size: 64))
            VStack(alignment: .leading, spacing: 6) {
                Text(m.state.ip ?? m.state.title)
                    .font(.system(size: 30, weight: .semibold, design: .monospaced))
                    .textSelection(.enabled)
                if let cc = m.state.country { Text(countryName(cc)).font(.title3).foregroundStyle(.secondary) }
                HStack {
                    Pill(text: m.state.title, color: statusColor(m))
                    if !m.frozen.isEmpty { Pill(text: "❄︎ " + Set(m.frozen.values).sorted().joined(separator: ", "), color: .blue) }
                }
            }
            Spacer()
            Button { m.checkNow(); m.measureLatency() } label: { Label("Проверить", systemImage: "arrow.clockwise") }
                .controlSize(.large)
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16).fill(
            LinearGradient(colors: [statusColor(m).opacity(0.18), statusColor(m).opacity(0.04)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)))
    }

    @ViewBuilder var guardSummary: some View {
        let state = m.protectionStatus
        Label(state.title, systemImage: state.symbol).font(.headline).foregroundStyle(state.color)
        Text(m.protectionDetail).font(.callout).foregroundStyle(.secondary)
        Button("Настроить блокировку") { nav.section = .protection }.buttonStyle(.link)
    }

    func row(_ k: String, _ v: String) -> some View {
        HStack { Text(k).foregroundStyle(.secondary); Spacer(); Text(v).lineLimit(1) }
    }
}

func timeOnly(_ d: Date) -> String {
    let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f.string(from: d)
}

// MARK: - Блокировка

struct ProtectionView: View {
    @ObservedObject var m: Monitor
    @StateObject var catalog = AppCatalogModel()
    @State var showPicker = false
    @StateObject var systemFilter = FilterController()
    @State private var showRoutes = false
    @State var newIP = ""

    var body: some View {
        Form {
            Section {
                ProtectionControls(m: m)
            }

            Section("Выбранные приложения · \(m.cfg.guard.apps.count)") {
                if m.cfg.guard.apps.isEmpty {
                    Text("Добавьте приложения для автоматической блокировки.").foregroundStyle(.secondary)
                }
                ForEach(m.cfg.guard.apps, id: \.self) { p in
                    let r = AppCatalog.resolve(p, in: catalog.apps)
                    HStack {
                        if p == claudeCLITarget {
                            Image(systemName: "terminal.fill").font(.title2).frame(width: 32, height: 32)
                        } else if let i = r.icon { Image(nsImage: i) }
                        else { Image(systemName: "app.dashed").frame(width: 32) }
                        VStack(alignment: .leading) {
                            Text(r.name)
                            if p == claudeCLITarget { Text("Командная строка и дочерние процессы").font(.caption).foregroundStyle(.secondary) }
                            else if r.name != p { Text(p).font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        Button(role: .destructive) { m.updateConfig { $0.guard.apps.removeAll { $0 == p } } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }.buttonStyle(.plain)
                         .accessibilityLabel("Убрать из списка: \(r.name)")
                    }
                }
                Button { showPicker = true } label: { Label("Выбрать приложения…", systemImage: "plus.circle") }
            }

            VPNProfilesSection(m: m)

            Section {
                DisclosureGroup("Последняя проверка маршрутов", isExpanded: $showRoutes) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(m.state.title)
                        if !m.confirmedRoutes.isEmpty {
                            ForEach(m.confirmedRoutes, id: \.self) { ip in
                                Label(ip, systemImage: m.permittedIP(ip) ? "checkmark.circle" : "exclamationmark.circle")
                                    .font(.system(.callout, design: .monospaced))
                                    .accessibilityLabel(ip + (m.permittedIP(ip) ? " разрешён" : " отсутствует в списке"))
                            }
                        }
                        if let issue = m.routeIssue { Text(issue).foregroundStyle(.red) }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                chips(m.cfg.guard.allow.ips, label: { $0 }) { ip in
                    m.updateConfig { $0.guard.allow.ips.removeAll { $0 == ip } }
                }
                HStack {
                    TextField("IP или подсеть, например 203.0.113.0/24", text: $newIP).onSubmit(addIP)
                    Button("Добавить", action: addIP).disabled(newIP.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                if let ip = m.state.ip, !m.cfg.guard.allow.ips.contains(ip) {
                    Button("Разрешить текущий IP \(ip)") { m.allowCurrentIP() }
                }
            } header: { Text("Разрешённые IP") } footer: {
                Text("Для возобновления нужны доступный VPN-прокси и подтверждение всех выходных IP.")
            }

            Section("Поведение") {
                TextField("Идентификатор системной службы VPN", text: bind(\.guard.vpn_service_id))
                Text("Для incy в режиме TUN оставьте поле пустым. Для других VPN укажите системную службу. Обычного прокси для разморозки недостаточно.").font(.caption)
                TextField("TCP-порт локального HTTP-прокси VPN", value: bind(\.guard.proxy_port), format: .number.grouping(.never))
                Text("При тайм-ауте процессы завершаются принудительно в замороженном состоянии. Несохранённая работа может быть потеряна.").font(.caption)
                Picker("Если разрешённый IP не появился", selection: bind(\.guard.grace)) {
                    Text("Оставить замороженными").tag(0.0)
                    Text("Закрыть через 1 минуту").tag(60.0)
                    Text("Закрыть через 5 минут").tag(300.0)
                    Text("Закрыть через 15 минут").tag(900.0)
                    if ![0.0, 60, 300, 900].contains(m.cfg.guard.grace) {
                        Text("Закрыть через \(Int(m.cfg.guard.grace)) с").tag(m.cfg.guard.grace)
                    }
                }
            }
            Section("Системный сетевой фильтр") {
                Text("Для выбранных приложений разрешает только TCP к локальному порту VPN. Изменив список или порт, примените правила заново. Для ранее открытых соединений перезапустите защищаемые приложения.")
                if systemFilter.canInstall {
                    Button("Применить правила в macOS") { systemFilter.apply(m.cfg.guard) }.disabled(systemFilter.busy || m.cfg.guard.apps.isEmpty)
                    Button("Проверить конфигурацию фильтра") { systemFilter.refreshStatus() }.disabled(systemFilter.busy)
                    Text(systemFilter.status)
                } else { Text("Эта сборка не подписана для активации системного фильтра.").foregroundStyle(.secondary) }
            }
            Section("Защищённый запуск Claude Code") {
                Text("Команда для Terminal требует действующего локального HTTP-прокси. Режим incy TUN сам по себе разрешения для этой команды не выдаёт.")
                Text("\"\(Bundle.main.bundlePath)/Contents/MacOS/dozor-run\" \(m.cfg.guard.proxy_port) \"$(command -v claude)\"").textSelection(.enabled).font(.system(.caption, design: .monospaced))
            }
        }
        .formStyle(.grouped)
        .onAppear { catalog.load(); systemFilter.refreshStatus() }
        .sheet(isPresented: $showPicker) { AppPicker(m: m, catalog: catalog, isPresented: $showPicker) }
    }

    func bind<T>(_ kp: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { m.cfg[keyPath: kp] }, set: { v in m.updateConfig { $0[keyPath: kp] = v } })
    }

    func chips(_ items: [String], label: @escaping (String) -> String, remove: @escaping (String) -> Void) -> some View {
        Group {
            if items.isEmpty { Text("Пусто").foregroundStyle(.secondary) }
            ForEach(items, id: \.self) { it in
                HStack {
                    Text(label(it))
                    Spacer()
                    Button { remove(it) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain)
                }
            }
        }
    }

    func addIP() {
        let ip = newIP.trimmingCharacters(in: .whitespaces)
        guard !ip.isEmpty, !m.cfg.guard.allow.ips.contains(ip) else { return }
        m.updateConfig { $0.guard.allow.ips.append(ip) }
        newIP = ""
    }
}

extension Monitor {
    func applyProfile(_ id: UUID) -> Bool {
        guard cfgError == nil, cfgMTime == configMTime() else { return false }
        var next = cfg
        guard next.guard.activateProfile(id), saveConfig(next) else { return false }
        reloadConfig(force: true)
        enforce()
        checkNow()
        return cfgError == nil
    }

    // Editing the profile library does not change the live network rules.
    func storeProfiles(_ profiles: [VPNProfile]) -> Bool {
        guard cfgError == nil, configMTime() == cfgMTime else { return false }
        var next = cfg
        next.guard.profiles = profiles
        guard saveConfig(next) else { return false }
        cfg = next
        cfgMTime = configMTime()
        return true
    }
}

private struct VPNProfilesSection: View {
    @ObservedObject var m: Monitor
    @State private var name = ""
    @State private var error: String?

    var body: some View {
        Section {
            ForEach(m.cfg.guard.profiles) { profile in
                HStack {
                    VStack(alignment: .leading) {
                        Text(profile.name)
                        Text((profile.vpnServiceID.isEmpty ? "incy TUN" : profile.vpnServiceID)
                             + " · порт \(profile.proxyPort) · "
                             + (profile.ips.isEmpty ? "выход запрещён" : profile.ips.joined(separator: ", ")))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if profile.matches(m.cfg.guard) {
                        Image(systemName: "checkmark").accessibilityLabel("Соответствует текущим настройкам")
                    } else {
                        Button("Применить") {
                            guard profile.validSettings else { error = "Проверьте IP и порт в сохранённом профиле."; return }
                            error = m.applyProfile(profile.id) ? nil : "Не удалось применить профиль к файлу настроек."
                        }
                    }
                    Button(role: .destructive) {
                        if m.storeProfiles(m.cfg.guard.profiles.filter { $0.id != profile.id }) {
                            error = nil
                        } else { error = "Не удалось обновить файл настроек." }
                    } label: { Image(systemName: "trash") }
                        .accessibilityLabel("Удалить профиль " + profile.name)
                }
            }
            HStack {
                TextField("Название, например «Рабочий VPN»", text: $name).onSubmit(save)
                Button("Сохранить текущие настройки", action: save)
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        } header: { Text("Профили VPN") } footer: {
            Text("Профиль запоминает разрешённые IP, порт прокси и службу VPN. После переключения Дозор заново проверит сеть.")
        }
    }

    private func save() {
        var rules = m.cfg.guard
        guard rules.saveProfile(named: name) else {
            error = "Укажите уникальное название до 80 символов, корректные IP и порт от 1 до 65535."
            return
        }
        guard m.storeProfiles(rules.profiles) else { error = "Не удалось сохранить профиль в файл настроек."; return }
        name = ""; error = nil
    }
}

struct AppPicker: View {
    @ObservedObject var m: Monitor
    @ObservedObject var catalog: AppCatalogModel
    @Binding var isPresented: Bool
    @State var query = ""
    @State var onlyRunning = false

    var filtered: [InstalledApp] {
        var running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        if onlyRunning && LocalProcess.snapshot().values.contains(where: { $0.isClaudeCLI }) { running.insert(claudeCLITarget) }
        return catalog.apps.filter { a in
            (query.isEmpty || a.name.localizedCaseInsensitiveContains(query) || a.id.localizedCaseInsensitiveContains(query))
            && (!onlyRunning || running.contains(a.id))
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text("Выберите приложения").font(.title2.weight(.semibold))
                Spacer()
                Text("Выбрано: \(m.cfg.guard.apps.count)").foregroundStyle(.secondary)
            }.padding()
            HStack {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск по названию", text: $query).textFieldStyle(.plain)
                Toggle("Только запущенные", isOn: $onlyRunning).toggleStyle(.checkbox)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
            .padding(.horizontal)

            if catalog.loading && catalog.apps.isEmpty {
                ProgressView("Ищу приложения…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(filtered) { a in
                    Toggle(isOn: Binding(
                        get: { m.cfg.guard.apps.contains(a.id) },
                        set: { on in m.updateConfig { c in
                            if on { if !c.guard.apps.contains(a.id) { c.guard.apps.append(a.id) } }
                            else { c.guard.apps.removeAll { $0 == a.id } }
                        } })) {
                        HStack {
                            Image(nsImage: AppCatalog.icon(for: a.url))
                            VStack(alignment: .leading) {
                                Text(a.name)
                                Text(a.id).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                    .padding(.vertical, 2)
                }
            }

            HStack {
                Text("Заморозка процессов не блокирует трафик на уровне сети.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Готово") { isPresented = false }.keyboardShortcut(.defaultAction)
            }.padding()
        }
        .frame(width: 520, height: 560)
        .onAppear { catalog.load() }
    }
}

// MARK: - Задержка

struct LatencyPoint: Identifiable {
    let id: Int
    let name: String
    let date: Date
    let ms: Double
}

struct LatencyView: View {
    @ObservedObject var m: Monitor
    @State var range: Double = 86400

    var since: Date { Date().addingTimeInterval(-range) }

    var points: [LatencyPoint] {
        var out: [LatencyPoint] = []
        var i = 0
        for t in m.cfg.latency_targets {
            for p in m.latency[t.name] ?? [] where p.count == 2 && p[1] >= 0 && p[0] >= since.timeIntervalSince1970 {
                out.append(LatencyPoint(id: i, name: t.name, date: Date(timeIntervalSince1970: p[0]), ms: p[1]))
                i += 1
            }
        }
        return out
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Picker("", selection: $range) {
                        Text("Час").tag(3600.0)
                        Text("Сутки").tag(86400.0)
                        Text("Неделя").tag(604800.0)
                    }.pickerStyle(.segmented).frame(width: 260)
                    Spacer()
                    Button { m.measureLatency() } label: { Label("Замерить сейчас", systemImage: "stopwatch") }
                }
                Card(title: "Время ответа", icon: "chart.xyaxis.line") {
                    let pts = points
                    if pts.isEmpty {
                        Text("Пока нет замеров за этот период").foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, minHeight: 220)
                    } else {
                        Chart(pts) { p in
                            LineMark(x: .value("Время", p.date), y: .value("мс", p.ms))
                                .foregroundStyle(by: .value("Сайт", p.name))
                                .interpolationMethod(.monotone)
                            if pts.count < 60 {
                                PointMark(x: .value("Время", p.date), y: .value("мс", p.ms))
                                    .foregroundStyle(by: .value("Сайт", p.name)).symbolSize(16)
                            }
                        }
                        .chartYAxisLabel("мс")
                        .frame(height: 260)
                    }
                }
                Card(title: "Сводка", icon: "tablecells") {
                    Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                        GridRow {
                            Text("Сайт"); Text("Сейчас"); Text("Среднее"); Text("Мин"); Text("Макс"); Text("Потери")
                        }.font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        ForEach(m.cfg.latency_targets, id: \.name) { t in
                            let s = m.stats(t.name, since: since)
                            GridRow {
                                Text(t.name)
                                Text(fmtMs(s.last)); Text(fmtMs(s.avg)); Text(fmtMs(s.min)); Text(fmtMs(s.max))
                                Text(s.count == 0 ? "—" : "\(s.losses) из \(s.count)")
                                    .foregroundStyle(s.losses > 0 ? .orange : .primary)
                            }.monospacedDigit()
                        }
                    }
                }
            }
            .padding(20)
        }
    }
}

// MARK: - Журнал

struct LogView: View {
    @ObservedObject var m: Monitor
    @State private var query = ""
    @State private var showDecisions = true

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Журнал", selection: $showDecisions) {
                    Text("Решения").tag(true)
                    Text("События").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 190)
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Поиск", text: $query).textFieldStyle(.plain)
                if !showDecisions { Button("Открыть файл") { NSWorkspace.shared.open(logURL) } }
            }
            .padding(10)
            Divider()
            if showDecisions {
                Decisions(history: m.decisionHistory, query: query)
            } else {
                let items = Array(m.events.reversed().filter { query.isEmpty || $0.localizedCaseInsensitiveContains(query) }.enumerated())
                List(items, id: \.offset) { _, e in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: icon(for: e)).foregroundStyle(color(for: e)).frame(width: 18)
                        Text(String(e.prefix(19))).font(.system(.caption, design: .monospaced)).foregroundStyle(.secondary)
                        Text(String(e.dropFirst(20))).textSelection(.enabled)
                    }
                }
            }
        }
    }

    private struct Decisions: View {
        @ObservedObject var history: DecisionHistory
        let query: String

        var body: some View {
            let visible = history.entries.reversed().filter { entry in
                let fields = [entry.decision.verdict.title, entry.decision.reason, timeFmt.string(from: entry.date)] + entry.decision.matches
                return query.isEmpty || fields.contains { $0.localizedCaseInsensitiveContains(query) }
            }
            if history.saveFailed {
                Text("Не удалось сохранить историю решений на диске.").foregroundStyle(.secondary)
            }
            if visible.isEmpty {
                Text(query.isEmpty ? "Решений пока нет" : "Совпадений нет")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List(visible) { entry in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(entry.decision.verdict.title).font(.headline)
                            Spacer()
                            Text(timeFmt.string(from: entry.date)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        Text(entry.decision.reason)
                        if !entry.decision.matches.isEmpty {
                            Text("Выход и правило: " + entry.decision.matches.joined(separator: ", "))
                                .font(.caption.monospaced()).foregroundStyle(.secondary)
                        }
                    }.textSelection(.enabled).padding(.vertical, 2)
                }
            }
        }
    }

    func icon(for e: String) -> String {
        if e.contains("Заморожено") { return "snowflake" }
        if e.contains("Разморожено") { return "sun.max" }
        if e.contains("Новый IP") || e.contains(" IP: ") { return "globe" }
        if e.contains("Нет подключения") { return "wifi.slash" }
        if e.contains("Сеть изменилась") { return "arrow.triangle.2.circlepath" }
        if e.contains("разные IP") || e.contains("ошибка") { return "exclamationmark.triangle" }
        return "circle.fill"
    }

    func color(for e: String) -> Color {
        if e.contains("Заморожено") { return .blue }
        if e.contains("Разморожено") { return .green }
        if e.contains("Нет подключения") || e.contains("разные IP") || e.contains("ошибка") { return .red }
        return .secondary
    }
}

// MARK: - Настройки

struct SettingsView: View {
    @ObservedObject var m: Monitor
    @State var newTargetName = ""
    @State var newTargetURL = ""
    @State var newService = ""
    @StateObject private var updates = ReleaseUpdates()
    @State var tgResult: String?

    var body: some View {
        Form {
            Section("Общее") {
                Toggle("Запускать при входе в систему", isOn: Binding(get: { m.launchAtLogin }, set: { m.setLaunchAtLogin($0) }))
                Toggle("Перезапускать Дозор после сбоя", isOn: bind(\.crash_recovery))
                Text("После сбоя наблюдатель перезапустит эту копию Дозора. Пока Дозор закрыт, новые процессы не замораживаются. После трёх быстрых сбоев откройте его вручную.").font(.caption)
                if let error = m.recoveryError { Text(error).foregroundStyle(.red) }
                Toggle("Показывать уведомления", isOn: bind(\.notifications))
                Picker("В строке меню", selection: bind(\.menubar)) {
                    Text("Флаг и IP").tag("ip")
                    Text("Только флаг").tag("country")
                    Text("Только значок").tag("icon")
                }
            }

            Section {
                Picker("Проверять IP каждые", selection: bind(\.check_interval)) {
                    ForEach([5.0, 10, 30, 60, 300], id: \.self) { Text(secs($0)).tag($0) }
                    if ![5.0, 10, 30, 60, 300].contains(m.cfg.check_interval) {
                        Text(secs(m.cfg.check_interval)).tag(m.cfg.check_interval)
                    }
                }
                Text("При включённой защите интервал не больше 5 с, а кворум — минимум два разных HTTPS-хоста.").font(.caption).foregroundStyle(.secondary)
                Stepper("Подтверждений IP: \(m.cfg.min_agree)", value: bind(\.min_agree), in: 1...max(1, m.cfg.ip_services.count))
                ForEach(m.cfg.ip_services, id: \.self) { s in
                    HStack {
                        Text(s).font(.system(.body, design: .monospaced))
                        Spacer()
                        Button { m.updateConfig { $0.ip_services.removeAll { $0 == s } } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }.buttonStyle(.plain).disabled(m.cfg.ip_services.count <= 1)
                    }
                }
                HStack {
                    TextField("https://… (сервис, отдающий IP текстом)", text: $newService)
                    Button("Добавить") {
                        let s = newService.trimmingCharacters(in: .whitespaces)
                        guard s.hasPrefix("http"), !m.cfg.ip_services.contains(s) else { return }
                        m.updateConfig { $0.ip_services.append(s) }; newService = ""
                    }
                }
            } header: { Text("Проверка IP") } footer: {
                Text("IP считается верным, когда столько сервисов назвали один и тот же адрес.")
            }

            Section("Замер задержки") {
                Picker("Замерять каждые", selection: bind(\.latency_interval)) {
                    ForEach([60.0, 300, 900, 3600], id: \.self) { Text(secs($0)).tag($0) }
                    if ![60.0, 300, 900, 3600].contains(m.cfg.latency_interval) {
                        Text(secs(m.cfg.latency_interval)).tag(m.cfg.latency_interval)
                    }
                }
                ForEach(m.cfg.latency_targets, id: \.name) { t in
                    HStack {
                        Text(t.name)
                        Text(t.url).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        Spacer()
                        Button { m.updateConfig { $0.latency_targets.removeAll { $0.name == t.name } } } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }.buttonStyle(.plain)
                    }
                }
                HStack {
                    TextField("Название", text: $newTargetName).frame(width: 140)
                    TextField("https://сайт", text: $newTargetURL)
                    Button("Добавить") {
                        let n = newTargetName.trimmingCharacters(in: .whitespaces)
                        var u = newTargetURL.trimmingCharacters(in: .whitespaces)
                        if !u.hasPrefix("http") { u = "https://" + u }
                        guard !n.isEmpty, URL(string: u) != nil, !m.cfg.latency_targets.contains(where: { $0.name == n }) else { return }
                        m.updateConfig { $0.latency_targets.append(Target(name: n, url: u)) }
                        newTargetName = ""; newTargetURL = ""
                    }
                }
            }

            Section {
                Toggle("Сообщать о заморозке и разморозке в Telegram", isOn: bind(\.telegram.enabled))
                SecureField("Токен бота", text: bind(\.telegram.bot_token))
                TextField("Chat ID", text: bind(\.telegram.chat_id))
                HStack {
                    Button("Отправить тестовое сообщение") {
                        tgResult = "Отправляю…"
                        m.sendTelegram("Дозор: тестовое сообщение", force: true) { delivery in
                            tgResult = delivery.message
                        }
                    }
                    if let r = tgResult { Text(r).foregroundStyle(.secondary) }
                }
            } header: { Text("Telegram") } footer: {
                Text("Создайте бота у @BotFather, отправьте ему /start и укажите chat.id из getUpdates. При отсутствии сети сбой отправки попадёт в журнал.")
            }

            Section("Обновления") {
                Button("Проверить обновления") { Task { await updates.check() } }.disabled(updates.checking)
                if !updates.message.isEmpty { Text(updates.message) }
                if let url = updates.releaseURL { Link("Открыть выпуск на GitHub", destination: url) }
            }

            Section("Файлы") {
                HStack {
                    Button("Файл настроек") { NSWorkspace.shared.open(configURL) }
                    Button("Журнал") { NSWorkspace.shared.open(logURL) }
                    Button("Показать папку") { NSWorkspace.shared.activateFileViewerSelecting([configURL]) }
                }
                if let e = m.cfgError { Text(e).foregroundStyle(.red) }
            }
        }
        .formStyle(.grouped)
    }

    func bind<T>(_ kp: WritableKeyPath<Config, T>) -> Binding<T> {
        Binding(get: { m.cfg[keyPath: kp] }, set: { v in m.updateConfig { $0[keyPath: kp] = v } })
    }

    func secs(_ s: Double) -> String {
        s < 60 ? "\(Int(s)) с" : s < 3600 ? "\(Int(s / 60)) мин" : "\(Int(s / 3600)) ч"
    }
}
