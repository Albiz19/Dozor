import Foundation
import NetworkExtension
import SystemExtensions
import Security
import AppKit

final class FilterController: NSObject, ObservableObject, OSSystemExtensionRequestDelegate {
    static let identifier = "local.dozor.filter"
    @Published var status = "Статус системного фильтра не проверен"
    @Published var busy = false
    private var parameters: [String: Any] = [:]
    var canInstall: Bool {
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task,"com.apple.developer.system-extension.install" as CFString,nil) as? Bool == true
    }
    static func configurationStatus(provider: String?, enabled: Bool, sockets: Bool, port: Int?) -> String {
        guard provider == identifier else { return "Конфигурация фильтра Dozor отсутствует" }
        guard enabled, sockets else { return "Фильтрация сокетов Dozor выключена в настройках macOS" }
        guard let port, (1...65535).contains(port) else { return "В конфигурации фильтра указан неверный порт" }
        return "В настройках macOS включена фильтрация сокетов Dozor. Разрешён локальный TCP-порт \(port)."
    }

    func refreshStatus() {
        guard canInstall, !busy else { return }
        busy = true
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { error in DispatchQueue.main.async {
            defer { self.busy = false }
            if let error { self.status = error.localizedDescription; return }
            let config = manager.providerConfiguration
            self.status = Self.configurationStatus(provider: config?.filterDataProviderBundleIdentifier,
                                                   enabled: manager.isEnabled, sockets: config?.filterSockets == true,
                                                   port: config?.vendorConfiguration?["port"] as? Int)
        } }
    }
    func apply(_ cfg: GuardConfig) {
        guard canInstall, !busy, (1...65535).contains(cfg.proxy_port) else { return }
        var urls = Set<String>(), cli = false
        let catalog = AppCatalog.scan()
        for target in cfg.apps {
            if [claudeCLITarget,"com.anthropic.claude-code-url-handler"].contains(target.lowercased()) { cli = true }
            if target.lowercased() == claudeCLITarget { continue }
            if let url = catalog.first(where: { $0.id.caseInsensitiveCompare(target) == .orderedSame || $0.name.caseInsensitiveCompare(target) == .orderedSame })?.url
                ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier:target) {
                urls.insert(url.resolvingSymlinksInPath().path)
            } else if target.hasPrefix("/") && FileManager.default.fileExists(atPath:target) {
                urls.insert(URL(fileURLWithPath:target).resolvingSymlinksInPath().path)
            } else if target.lowercased() != "com.anthropic.claude-code-url-handler" {
                status = "Не удалось определить путь приложения: " + target; return
            }
        }
        parameters = ["port": cfg.proxy_port, "bundles": urls.sorted(), "cli": cli, "monitor": Bundle.main.executableURL?.resolvingSymlinksInPath().path ?? ""]
        busy = true; status = "Запрос активации фильтра…"
        let request = OSSystemExtensionRequest.activationRequest(forExtensionWithIdentifier:Self.identifier, queue:.main)
        request.delegate = self; OSSystemExtensionManager.shared.submitRequest(request)
    }
    func requestNeedsUserApproval(_ request: OSSystemExtensionRequest) { status = "Подтвердите системное расширение в настройках macOS" }
    func request(_ request: OSSystemExtensionRequest, actionForReplacingExtension existing: OSSystemExtensionProperties, withExtension ext: OSSystemExtensionProperties) -> OSSystemExtensionRequest.ReplacementAction { .replace }
    func request(_ request: OSSystemExtensionRequest, didFailWithError error: Error) { busy = false; status = error.localizedDescription }
    func request(_ request: OSSystemExtensionRequest, didFinishWithResult result: OSSystemExtensionRequest.Result) {
        guard result == .completed else { busy = false; status = "macOS требует перезапуск"; return }
        let manager = NEFilterManager.shared()
        manager.loadFromPreferences { error in DispatchQueue.main.async {
            if let error { self.busy = false; self.status = error.localizedDescription; return }
            let config = NEFilterProviderConfiguration()
            config.filterSockets = true; config.filterDataProviderBundleIdentifier = Self.identifier
            config.vendorConfiguration = self.parameters
            manager.providerConfiguration = config; manager.localizedDescription = "Дозор"; manager.isEnabled = true
            manager.saveToPreferences { error in DispatchQueue.main.async {
                self.busy = false; self.status = error?.localizedDescription ?? "Конфигурация фильтра сохранена в macOS"
            } }
        } }
    }
}
