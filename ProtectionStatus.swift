// Presentation shared by the menu bar, overview and protection controls.
import SwiftUI

enum ProtectionStatus: Equatable {
    case off, noTargets, watching, checking, paused, holding, blocked

    var title: String {
        switch self {
        case .off: return "Блокировка выключена"
        case .noTargets: return "Выберите приложения"
        case .watching: return "Блокировка включена"
        case .checking: return "Проверяем сеть"
        case .paused: return "Блокировка на паузе"
        case .holding: return "Процессы заморожены"
        case .blocked: return "Выход не разрешён"
        }
    }

    var symbol: String {
        switch self {
        case .off, .noTargets: return "shield"
        case .watching: return "checkmark.shield.fill"
        case .checking: return "clock"
        case .paused: return "pause.circle.fill"
        case .holding: return "snowflake"
        case .blocked: return "exclamationmark.shield.fill"
        }
    }

    var color: Color {
        switch self {
        case .off, .noTargets: return .secondary
        case .watching: return .teal
        case .checking: return .secondary
        case .paused: return .orange
        case .holding: return .blue
        case .blocked: return .red
        }
    }
}

extension Monitor {
    var protectionStatus: ProtectionStatus {
        if !frozen.isEmpty { return .holding }
        if !cfg.guard.enabled { return .off }
        if cfg.guard.apps.isEmpty { return .noTargets }
        if paused { return .paused }
        if cfgError != nil || !online { return .blocked }
        switch state {
        case .checking: return .checking
        case .ok:
            guard let guardDecision else { return .checking }
            return guardDecision.allowed ? .watching : .blocked
        default: return .blocked
        }
    }

    var protectionDetail: String {
        switch protectionStatus {
        case .off: return "Дозор продолжает следить за сетью."
        case .noTargets: return "Добавьте приложения, которые нужно останавливать при смене IP."
        case .watching: return "При смене выхода Дозор остановит выбранные приложения и их дочерние процессы."
        case .checking: return "Дозор проверяет, совпадает ли маршрут с разрешённым."
        case .paused: return "Новые процессы могут работать при смене IP."
        case .holding:
            var parts = ["Заморожено процессов: \(frozen.count)."]
            if paused && guardActive { parts.append("Новые процессы могут работать.") }
            if case .error(let reason) = state { parts.append(reason) }
            else if case .mismatch = state { parts.append(state.title) }
            else if let reason = routeIssue { parts.append(reason) }
            else if case .ok = state, cfg.guard.vpn_service_id.isEmpty && verifiedTunnel == nil {
                parts.append("Для разморозки нужен активный TUN incy или выбранная системная служба VPN.")
            } else { parts.append("Дозор подтверждает VPN и разрешённые выходные адреса.") }
            return parts.joined(separator: " ")
        case .blocked:
            if let cfgError { return cfgError }
            if !online { return "Нет подключения к сети." }
            if case .ok = state { return guardDecision?.reason ?? state.title }
            return state.title
        }
    }

    var pauseActionTitle: String { paused ? "Возобновить блокировку" : "Приостановить блокировку" }
    var pauseActionDetail: String {
        paused
            ? "Дозор снова будет останавливать выбранные приложения при смене IP."
            : "На паузе новые процессы смогут работать при смене IP. Уже замороженные дождутся проверки VPN."
    }
}

struct ProtectionControls: View {
    @ObservedObject var m: Monitor

    var body: some View {
        let state = m.protectionStatus
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: state.symbol)
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(state.color)
                    .frame(width: 42, height: 42)
                    .background(state.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 4) {
                    Text(state.title).font(.title3.weight(.semibold))
                    Text(m.protectionDetail).font(.callout).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Toggle("Автоматическая блокировка", isOn: Binding(
                    get: { m.cfg.guard.enabled },
                    set: { enabled in m.updateConfig { $0.guard.enabled = enabled } }))
                    .toggleStyle(.switch).labelsHidden()
                    .help("Включить автоматическую блокировку выбранных приложений")
            }
            if m.guardActive {
                Button(action: m.togglePause) {
                    HStack(spacing: 12) {
                        Image(systemName: m.paused ? "play.fill" : "pause.fill")
                            .font(.system(size: 17, weight: .semibold))
                            .frame(width: 30)
                            .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(m.pauseActionTitle).font(.headline)
                            Text(m.pauseActionDetail).font(.callout)
                                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 4)
                    }
                    .padding(.horizontal, 14).padding(.vertical, 12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                }
                .buttonStyle(ProtectionActionStyle(resuming: m.paused))
                .accessibilityLabel(m.pauseActionTitle).accessibilityHint(m.pauseActionDetail)
            }
        }
        .padding(.vertical, 5)
    }
}

private struct ProtectionActionStyle: ButtonStyle {
    let resuming: Bool
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        let tint = resuming ? Color.teal : Color.orange
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        configuration.label
            .foregroundStyle(.primary)
            .background(tint.opacity(configuration.isPressed ? 0.26 : scheme == .dark ? 0.14 : 0.10), in: shape)
            .overlay(shape.strokeBorder(tint.opacity(0.36)))
    }
}

struct StatusMenuHeader: View {
    @ObservedObject var m: Monitor
    var body: some View {
        let state = m.protectionStatus
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 7) {
                Image(systemName: state.symbol).foregroundStyle(state.color)
                Text(state.title).font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Дозор").font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            Text(m.state.ip ?? m.state.title)
                .font(m.state.ip == nil ? .headline : .system(size: 21, weight: .medium, design: .monospaced))
                .lineLimit(2).fixedSize(horizontal: false, vertical: true)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                if let country = m.state.country { Text("\(flag(country))  \(countryName(country))") }
                else { Text(m.state.ip == nil ? "Внешний IP не определён" : "Внешний IP") }
                Spacer()
                if let last = m.lastCheck {
                    Label(last.formatted(date: .omitted, time: .shortened), systemImage: "clock")
                        .help("Последняя проверка сети")
                }
            }.font(.caption).foregroundStyle(.secondary)
            if [.holding, .blocked, .paused].contains(state) {
                Text(m.protectionDetail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.horizontal, 15).padding(.vertical, 9)
        .frame(width: 318, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}
