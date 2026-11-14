import AppKit
import CryptoKit
import Darwin
import Security

struct UpdateAsset: Decodable {
    let name: String
    let digest: String?
    let size: Int
}

struct AppUpdate {
    let version: String
    let url: URL
    let digest: String
    let size: Int

    init(release: PublicRelease, installed: String) throws {
        guard try release.newer(than: installed) else { throw UpdateFailure("Установлена актуальная версия") }
        version = String(release.tag_name.dropFirst())
        let name = "Dozor-\(version)-macOS-arm64.zip"
        let matches = release.assets?.filter { $0.name == name } ?? []
        guard matches.count == 1, let asset = matches.first,
              (1...64*1024*1024).contains(asset.size), let hash = asset.digest,
              hash.hasPrefix("sha256:"), hash.utf8.count == 71,
              hash.dropFirst(7).utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
        else { throw UpdateFailure("В выпуске отсутствует проверяемый архив для macOS.") }
        size = asset.size
        digest = String(hash.dropFirst(7))
        url = URL(string: "https://github.com/Albiz19/Dozor/releases/download/\(release.tag_name)/\(name)")!
    }

    func stage(archive: URL, replacing app: URL) throws -> URL {
        let fm = FileManager.default
        guard (try archive.resourceValues(forKeys: [.fileSizeKey])).fileSize == size else {
            throw UpdateFailure("Размер скачанного архива отличается от указанного в выпуске.")
        }
        let data = try Data(contentsOf: archive, options: .mappedIfSafe)
        guard SHA256.hash(data: data).map({ String(format:"%02x", $0) }).joined() == digest else {
            throw UpdateFailure("Контрольная сумма архива не совпадает с опубликованной.")
        }
        let folder = app.deletingLastPathComponent().appendingPathComponent(".dozor-update-" + UUID().uuidString)
        try fm.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions:0o700])
        do {
            try Self.run("/usr/bin/ditto", ["-x", "-k", archive.path, folder.path])
            let staged = folder.appendingPathComponent("Dozor.app")
            let plist = staged.appendingPathComponent("Contents/Info.plist")
            guard let info = try PropertyListSerialization.propertyList(from: Data(contentsOf: plist), format: nil) as? [String:Any],
                  info["CFBundleIdentifier"] as? String == "local.dozor",
                  info["CFBundleExecutable"] as? String == "Dozor",
                  info["CFBundleShortVersionString"] as? String == version,
                  staged.resolvingSymlinksInPath().standardizedFileURL.path == staged.standardizedFileURL.path
            else { throw UpdateFailure("В архиве отсутствует ожидаемая версия Dozor.") }
            try Self.run("/usr/bin/codesign", ["--verify","--deep","--strict",staged.path])
            if let team = try Self.teamID(app) {
                guard try Self.teamID(staged) == team else { throw UpdateFailure("Команда разработчика в подписи изменилась.") }
            }
            return staged
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
    }

    static func teamID(_ app: URL) throws -> String? {
        var code: SecStaticCode?, info: CFDictionary?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess
        else { throw UpdateFailure("Не удалось прочитать данные подписи приложения.") }
        return (info as NSDictionary?)?[kSecCodeInfoTeamIdentifier] as? String
    }

    static func run(_ executable: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateFailure("Проверка или распаковка пакета не удалась.") }
    }

    static func exchange(_ a: URL, _ b: URL) throws {
        guard renamex_np(a.path, b.path, UInt32(RENAME_SWAP)) == 0 else {
            throw UpdateFailure("macOS не разрешила заменить приложение. Проверьте права на папку «Программы».")
        }
    }

    // Launch the old helper before swapping. It only restarts if it receives
    // the commit byte. A failed swap leaves the current instance running.
    static func handoff(staged: URL, app: URL) throws {
        let pipe = Pipe(), helper = Process()
        helper.executableURL = app.appendingPathComponent("Contents/MacOS/dozor-update")
        helper.arguments = [String(getpid()), app.path, staged.path]
        helper.standardInput = pipe
        var canCleanStage = true
        defer {
            try? pipe.fileHandleForWriting.close()
            if canCleanStage { try? FileManager.default.removeItem(at: staged.deletingLastPathComponent()) }
        }
        guard fcntl(pipe.fileHandleForWriting.fileDescriptor, F_SETNOSIGPIPE, 1) == 0 else {
            throw UpdateFailure("Не удалось подготовить перезапуск Dozor.")
        }
        try helper.run()
        try exchange(staged, app)
        canCleanStage = false
        do { try pipe.fileHandleForWriting.write(contentsOf: Data([1])) }
        catch {
            try exchange(staged, app)
            canCleanStage = true
            throw error
        }
    }
}

struct UpdateFailure: LocalizedError {
    let errorDescription: String?
    init(_ description: String) { self.errorDescription = description }
}
