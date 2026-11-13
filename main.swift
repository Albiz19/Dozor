// Дозор — монитор сети для macOS: окно с разделами, значок в Доке и в строке меню.
// Показывает внешний IP и страну, ведёт журнал смены сети, меряет задержку до сайтов
// и (по желанию) замораживает выбранные вами приложения, пока IP не из разрешённого списка.

import AppKit
import SwiftUI
import Combine

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let m = Monitor()
    let nav = Navigation()
    let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    let menu = NSMenu()
    var window: NSWindow?
    var bag: Set<AnyCancellable> = []

    func applicationDidFinishLaunching(_ n: Notification) {
        NSApp.applicationIconImage = makeAppIcon(size: 512)
        statusItem.button?.image = NSImage(systemSymbolName: "network", accessibilityDescription: "Дозор")
        statusItem.button?.image?.isTemplate = true
        statusItem.button?.imagePosition = .imageLeading
        menu.delegate = self
        statusItem.menu = menu

        m.objectWillChange
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in DispatchQueue.main.async { self?.updateStatusItem() } }
            .store(in: &bag)

        m.start()
        updateStatusItem()
        showWindow()
    }

    func applicationWillTerminate(_ n: Notification) { m.prepareForExit(); m.log("Дозор остановлен") }

    // Закрытие окна не завершает приложение: оно продолжает работать в строке меню и Доке.
    func applicationShouldTerminateAfterLastWindowClosed(_ s: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ s: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showWindow(); return true
    }

    func showWindow(_ page: Page? = nil) {
        if let page { nav.section = page }
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Дозор"
            w.contentView = NSHostingView(rootView: MainView(m: m, nav: nav))
            w.setFrameAutosaveName("DozorMain")
            w.isReleasedWhenClosed = false
            w.toolbarStyle = .unified
            w.center()
            window = w
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Строка меню

    func updateStatusItem() {
        guard let b = statusItem.button else { return }
        var text = ""
        let mode = m.cfg.menubar
        switch m.state {
        case .ok(let ip, let cc):
            let f = cc.map(flag) ?? "🌐"
            text = mode == "icon" ? "" : mode == "country" ? f : "\(f) \(ip)"
        case .checking: text = mode == "icon" ? "" : "…"
        case .offline: text = "нет сети"
        case .mismatch: text = "⚠︎ разные IP"
        case .error: text = mode == "icon" ? "" : "⚠︎"
        }
        if m.paused { text = "Пауза " + text }; if !m.frozen.isEmpty { text = "❄︎ " + text }
        let t = text.isEmpty ? "" : " " + text
        if b.title != t { b.title = t }
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        func info(_ s: String) { let i = NSMenuItem(title: s, action: nil, keyEquivalent: ""); i.isEnabled = false; menu.addItem(i) }
        func item(_ s: String, _ sel: Selector, on: Bool = false, key: String = "") {
            let i = NSMenuItem(title: s, action: sel, keyEquivalent: key); i.target = self
            i.state = on ? .on : .off; menu.addItem(i)
        }

        switch m.state {
        case .ok(let ip, let cc):
            info("IP: \(ip)")
            if let cc { info("Страна: \(flag(cc)) \(countryName(cc))") }
        default: info(m.state.title)
        }
        if (m.guardActive || !m.frozen.isEmpty), let d = m.decision() {
            info(!m.frozen.isEmpty ? "Удерживается заморозка" : d.allowed ? "Приложения работают: \(d.reason)" : "Выход запрещён: \(d.reason)")
        }
        if !m.frozen.isEmpty { info("❄︎ " + Set(m.frozen.values).sorted().joined(separator: ", ")) }

        menu.addItem(.separator())
        item("Открыть Дозор", #selector(openMain), key: "o")
        item("Выбрать приложения…", #selector(openProtection))
        if m.guardActive { item("Пауза блокировки", #selector(togglePause), on: m.paused) }
        item("Проверить сейчас", #selector(checkNow), key: "r")
        item("Настройки…", #selector(openSettings), key: ",")
        menu.addItem(.separator())
        item("Выйти", #selector(quit), key: "q")
    }

    @objc func openMain() { showWindow() }
    @objc func openProtection() { showWindow(.protection) }
    @objc func openSettings() { showWindow(.settings) }
    @objc func togglePause() { m.togglePause() }
    @objc func checkNow() { m.checkNow(); m.measureLatency() }
    @objc func quit() { NSApp.terminate(nil) }
}

/// Значок приложения: рисуем сами, чтобы не таскать файлы картинок.
func makeAppIcon(size: CGFloat) -> NSImage {
    NSImage(size: NSSize(width: size, height: size), flipped: false) { r in
        let inset = r.insetBy(dx: size * 0.09, dy: size * 0.09)
        let path = NSBezierPath(roundedRect: inset, xRadius: size * 0.2, yRadius: size * 0.2)
        NSGradient(colors: [NSColor(red: 0.10, green: 0.72, blue: 0.62, alpha: 1),
                            NSColor(red: 0.09, green: 0.36, blue: 0.80, alpha: 1)])?.draw(in: path, angle: -60)
        // Draw the project's own shield at every icon size.
        let shield = NSBezierPath()
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint { NSPoint(x: x * size, y: y * size) }
        shield.move(to: point(0.5, 0.77))
        shield.line(to: point(0.73, 0.68))
        shield.line(to: point(0.73, 0.51))
        shield.curve(to: point(0.5, 0.24), controlPoint1: point(0.73, 0.39), controlPoint2: point(0.63, 0.29))
        shield.curve(to: point(0.27, 0.51), controlPoint1: point(0.37, 0.29), controlPoint2: point(0.27, 0.39))
        shield.line(to: point(0.27, 0.68))
        shield.close()
        shield.lineWidth = size * 0.038
        shield.lineJoinStyle = .round
        NSColor.white.setStroke()
        shield.stroke()
        let gate = NSBezierPath()
        gate.move(to: point(0.5, 0.67)); gate.line(to: point(0.5, 0.35))
        gate.lineWidth = size * 0.033; gate.lineCapStyle = .round; gate.stroke()
        return true
    }
}

// MARK: - Точка входа

// `--make-icon <путь.png> <размер>` — служебный режим для build.sh: сохранить значок в PNG.
if CommandLine.arguments.count == 4, CommandLine.arguments[1] == "--make-icon",
   let px = Double(CommandLine.arguments[3]) {
    let img = makeAppIcon(size: CGFloat(px))
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(px), pixelsHigh: Int(px), bitsPerSample: 8,
                               samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    rep.size = NSSize(width: px, height: px)
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    img.draw(in: NSRect(x: 0, y: 0, width: px, height: px))
    NSGraphicsContext.restoreGraphicsState()
    try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
    exit(0)
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
