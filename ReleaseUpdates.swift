import AppKit
import Combine

struct PublicRelease: Decodable {
    let tag_name: String
    let draft: Bool
    let prerelease: Bool
    var assets: [UpdateAsset]? = nil

    static func components(_ value: String) -> [Int]? {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count) else { return nil }
        var numbers: [Int] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }), let n = Int(part) else { return nil }
            numbers.append(n)
        }
        if numbers.count == 2 { numbers.append(0) }
        return numbers
    }

    func newer(than installed: String) throws -> Bool {
        guard !draft, !prerelease, tag_name.hasPrefix("v"),
              let remote = Self.components(String(tag_name.dropFirst())), let local = Self.components(installed)
        else { throw URLError(.cannotParseResponse) }
        return local.lexicographicallyPrecedes(remote)
    }
}

@MainActor
final class ReleaseUpdates: ObservableObject {
    @Published var message = ""
    @Published var releaseURL: URL?
    @Published var checking = false

    @Published private(set) var installing = false
    @Published private(set) var candidate: AppUpdate?

    func install() async {
        guard !installing, !checking else { return }
        if candidate == nil { await check() }
        guard let update = candidate, !installing else { return }
        let app = Bundle.main.bundleURL.standardizedFileURL
        let acceptable = ["/Applications/Dozor.app",
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications/Dozor.app").path]
        guard acceptable.contains(app.path), app.resolvingSymlinksInPath().path == app.path else {
            message = "Для обновления переместите Dozor в папку «Программы» и откройте его оттуда."
            return
        }
        installing = true
        defer { installing = false }
        do {
            message = "Скачиваем версию " + update.version + "…"
            let (file, response) = try await URLSession.shared.download(from: update.url)
            defer { try? FileManager.default.removeItem(at: file) }
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateFailure("GitHub не отдал архив обновления.") }
            message = "Проверяем и устанавливаем обновление…"
            let staged = try await Task.detached(priority: .userInitiated) {
                try update.stage(archive: file, replacing: app)
            }.value
            try AppUpdate.handoff(staged: staged, app: app)
            NSApp.terminate(nil)
        } catch {
            message = "Обновление не установлено. " + error.localizedDescription
        }
    }

    func check() async {
        guard !checking, !installing else { return }
        checking = true; candidate = nil; releaseURL = nil; message = "Проверка на GitHub…"
        defer { checking = false }
        do {
            let endpoint = URL(string: "https://api.github.com/repos/Albiz19/Dozor/releases/latest")!
            var request = URLRequest(url: endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  let installed = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
            else { throw URLError(.badServerResponse) }
            let release = try JSONDecoder().decode(PublicRelease.self, from: data)
            if try release.newer(than: installed) {
                releaseURL = URL(string: "https://github.com/Albiz19/Dozor/releases/tag/\(release.tag_name)")
                do { candidate = try AppUpdate(release: release, installed: installed) }
                catch { message = error.localizedDescription; return }
                message = "Доступна версия \(release.tag_name)"
            } else { message = "Установлена актуальная версия \(installed)" }
        } catch { message = "Не удалось проверить обновления. Повторите позже." }
    }
}
