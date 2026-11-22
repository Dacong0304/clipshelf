// ClipShelf — 菜单栏里的剪贴板历史
//
// ⌥⌘V 随时召出，搜一下就能把几分钟前复制的文字/图片/文件粘回去。
// 纯本地、无网络、SQLite 存储、自动跳过密码管理器。
//
// 构建：./build.sh
// 自检：ClipShelf.app/Contents/MacOS/ClipShelf --selftest
// 快照：ClipShelf.app/Contents/MacOS/ClipShelf --snapshot docs/panel.png

import AppKit
import Foundation

// MARK: - 路径

func supportDirectory() -> URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
        ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
    return base.appendingPathComponent("ClipShelf", isDirectory: true)
}

func defaultDBPath() -> String {
    supportDirectory().appendingPathComponent("history.db").path
}

// MARK: - 开机自启（LaunchAgent）

enum AutoStart {
    static let label = "local.clipshelf.agent"

    static var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    static var isEnabled: Bool {
        FileManager.default.fileExists(atPath: plistURL.path)
    }

    static func enable() throws {
        guard let exe = Bundle.main.executablePath else { return }
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [exe],
            "RunAtLoad": true,
            "KeepAlive": false,
            "ProcessType": "Interactive",
            "StandardOutPath": "/tmp/clipshelf.out.log",
            "StandardErrorPath": "/tmp/clipshelf.err.log",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: plistURL, options: .atomic)
        shell("/bin/launchctl", ["bootstrap", "gui/\(getuid())", plistURL.path])
    }

    static func disable() throws {
        shell("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        if FileManager.default.fileExists(atPath: plistURL.path) {
            try FileManager.default.removeItem(at: plistURL)
        }
    }

    private static func shell(_ path: String, _ args: [String]) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
    }
}

// MARK: - AppDelegate

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var store: Store!
    private var capture: ClipboardCapture!
    private var model: AppModel!
    private var panel: PanelController!
    private var hotKey: GlobalHotKey?
    private var statusItem: NSStatusItem!
    private var pauseItem: NSMenuItem!
    private var autoStartItem: NSMenuItem!
    private var axItem: NSMenuItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        let path = defaultDBPath()
        do {
            store = try Store(path: path)
        } catch {
            presentFatal("数据库打不开：\(error)")
            return
        }
        store.gcBlobs()

        model = AppModel(store: store)
        model.isPaused = UserDefaults.standard.bool(forKey: "paused")

        capture = ClipboardCapture(store: store)
        capture.isPaused = model.isPaused
        capture.onCapture = { [weak self] in
            guard let self, self.panel != nil else { return }
            self.model.reload()
        }
        capture.start()

        panel = PanelController(store: store, model: model, capture: capture)

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("local.clipshelf.toggle"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.panel.toggle()
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("local.clipshelf.testkey"),
            object: nil, queue: .main
        ) { [weak self] note in
            guard let self, let key = note.userInfo?["key"] as? String else { return }
            let map: [String: UInt16] = ["down": 125, "up": 126, "enter": 36, "esc": 53,
                                         "p": 35, "delete": 51, "c": 8]
            guard let code = map[key] else { return }
            self.panel.simulateKey(code, command: note.userInfo?["cmd"] as? String == "1")
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("local.clipshelf.showmenu"),
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.statusItem.button?.performClick(nil)
        }

        DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name("local.clipshelf.dumpstate"),
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            var state = self.panel.debugState()
            state["hotkeyRegistered"] = self.hotKey?.isValid ?? false
            state["pasteTrusted"] = Paster.isTrusted
            if let data = try? JSONSerialization.data(withJSONObject: state,
                                                      options: [.prettyPrinted, .sortedKeys]) {
                try? data.write(to: URL(fileURLWithPath: "/tmp/clipshelf-state.json"))
            }
        }

        hotKey = GlobalHotKey { [weak self] in
            self?.panel.toggle()
        }

        buildStatusItem()

        if !(hotKey?.isValid ?? false) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.presentHotKeyConflict()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        capture?.stop()
        hotKey?.unregister()
    }

    // MARK: 菜单栏

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let icon = NSImage(systemSymbolName: "list.clipboard", accessibilityDescription: "ClipShelf")
            ?? NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "ClipShelf")
        icon?.isTemplate = true
        statusItem.button?.image = icon
        statusItem.button?.toolTip = "ClipShelf · \(GlobalHotKey.shortcutLabel) 打开历史"

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        rebuildMenu()
    }

    private func rebuildMenu() {
        guard let menu = statusItem.menu else { return }
        menu.removeAllItems()

        let header = NSMenuItem(title: "ClipShelf · 剪贴板历史", action: nil, keyEquivalent: "")
        header.image = appIcon(size: 16)
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let open = NSMenuItem(title: "打开剪贴历史", action: #selector(openPanel), keyEquivalent: "v")
        open.keyEquivalentModifierMask = [.option, .command]
        open.target = self
        menu.addItem(open)

        menu.addItem(.separator())

        pauseItem = NSMenuItem(title: "暂停记录", action: #selector(togglePause), keyEquivalent: "")
        pauseItem.state = model?.isPaused == true ? .on : .off
        pauseItem.target = self
        menu.addItem(pauseItem)

        let clear = NSMenuItem(title: "清空历史（保留置顶）…", action: #selector(clearHistory), keyEquivalent: "")
        clear.target = self
        menu.addItem(clear)

        menu.addItem(.separator())

        autoStartItem = NSMenuItem(title: "开机自动启动", action: #selector(toggleAutoStart), keyEquivalent: "")
        autoStartItem.state = AutoStart.isEnabled ? .on : .off
        autoStartItem.target = self
        menu.addItem(autoStartItem)

        axItem = NSMenuItem(title: "自动粘贴权限…", action: #selector(openAccessibility), keyEquivalent: "")
        axItem.state = Paster.isTrusted ? .on : .off
        axItem.target = self
        menu.addItem(axItem)

        menu.addItem(.separator())

        let about = NSMenuItem(title: "关于 ClipShelf", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)

        let quit = NSMenuItem(title: "退出 ClipShelf", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)
    }

    /// 从 bundle 里取应用图标，按像素尺寸渲染（菜单里用 16pt）
    private func appIcon(size: CGFloat) -> NSImage? {
        let image = NSApp.applicationIconImage ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath)
        let copy = image.copy() as? NSImage
        copy?.size = NSSize(width: size, height: size)
        return copy
    }

    // MARK: 动作

    @objc private func openPanel() {
        panel.show()
    }

    @objc private func togglePause() {
        let paused = !(model?.isPaused ?? false)
        model.isPaused = paused
        capture.isPaused = paused
        UserDefaults.standard.set(paused, forKey: "paused")
        rebuildMenu()
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "清空剪贴历史？"
        alert.informativeText = "置顶的条目会保留，其余全部删除（含图片文件）。"
        alert.addButton(withTitle: "清空")
        alert.addButton(withTitle: "取消")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        try? store.clear(keepPinned: true)
        model.reload(keepSelection: false)
    }

    @objc private func toggleAutoStart() {
        do {
            if AutoStart.isEnabled {
                try AutoStart.disable()
            } else {
                try AutoStart.enable()
            }
        } catch {
            presentFatal("设置开机自启失败：\(error)")
        }
        rebuildMenu()
    }

    @objc private func openAccessibility() {
        if Paster.isTrusted { return }
        Paster.requestAccess()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            self?.rebuildMenu()
        }
    }

    @objc private func showAbout() {
        let alert = NSAlert()
        alert.messageText = "ClipShelf — 剪贴板历史"
        alert.informativeText = """
        \(GlobalHotKey.shortcutLabel) 召出历史面板，回车粘回刚才的 App。

        数据位置：\(defaultDBPath())
        完全本地存储，不联网，不上传。
        密码管理器与标记为「保密」的剪贴板内容会被自动跳过。
        """
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private func presentHotKeyConflict() {
        let alert = NSAlert()
        alert.messageText = "\(GlobalHotKey.shortcutLabel) 被占用了"
        alert.informativeText = "另一个 App 已经注册了这个快捷键。你仍然可以从菜单栏图标打开面板，或在其它 App 里释放该快捷键后重启 ClipShelf。"
        alert.addButton(withTitle: "知道了")
        alert.runModal()
    }

    private func presentFatal(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "ClipShelf 启动失败"
        alert.informativeText = message
        alert.addButton(withTitle: "退出")
        alert.runModal()
        NSApp.terminate(nil)
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuWillOpen(_ menu: NSMenu) {
        rebuildMenu()
    }
}

// MARK: - 自检

@discardableResult
func runSelfTest() -> Bool {
    var failures: [String] = []

    func check(_ name: String, _ ok: Bool) {
        print(ok ? "  ✓ \(name)" : "  ✗ \(name)")
        if !ok { failures.append(name) }
    }

    print("ClipShelf 自检")

    guard let store = try? Store(path: ":memory:") else {
        print("  ✗ 无法创建内存数据库")
        return false
    }

    // 1. 写入与去重
    do {
        _ = try store.add(kind: .text, content: "hello world", preview: "hello world",
                          bytes: 11, source: "Test", digest: "d1")
        let firstCount = store.count()
        _ = try store.add(kind: .text, content: "hello world", preview: "hello world",
                          bytes: 11, source: "Test", digest: "d1")
        check("相同内容不会重复入库", firstCount == 1 && store.count() == 1)
    } catch {
        check("写入失败：\(error)", false)
    }

    // 2. 置顶排在最前
    do {
        _ = try store.add(kind: .text, content: "second", preview: "second",
                          bytes: 6, source: "Test", digest: "d2")
        try store.setPin(id: 1, pinned: true)
        let rows = store.fetch()
        check("置顶项排在最前", rows.first?.digest == "d1")
    } catch {
        check("置顶失败：\(error)", false)
    }

    // 3. 淘汰超限旧记录，但不动置顶
    do {
        for i in 0..<10 {
            _ = try store.add(kind: .text, content: "item \(i)", preview: "item \(i)",
                              bytes: 7, source: "Test", digest: "p\(i)")
        }
        store.prune(maxItems: 3, maxImages: 3)
        let rows = store.fetch()
        check("超出上限的旧记录被淘汰", rows.count == 4)
        check("置顶项不会被淘汰", rows.contains { $0.digest == "d1" })
    } catch {
        check("淘汰失败：\(error)", false)
    }

    // 4. 搜索：多关键词取交集（用一块独立数据，避免被淘汰规则干扰）
    do {
        let s2 = try Store(path: ":memory:")
        _ = try s2.add(kind: .text, content: "alpha beta gamma", preview: "alpha beta gamma",
                       bytes: 16, source: "A", digest: "s1")
        _ = try s2.add(kind: .text, content: "alpha delta", preview: "alpha delta",
                       bytes: 11, source: "B", digest: "s2")
        _ = try s2.add(kind: .text, content: "beta only", preview: "beta only",
                       bytes: 9, source: "C", digest: "s3")

        let model = AppModel(store: s2)
        model.reload(keepSelection: false)
        model.query = "ALPHA"
        model.applyFilter()
        check("搜索大小写不敏感", model.items.count == 2)
        model.query = "alpha beta"
        model.applyFilter()
        check("多关键词取交集", model.items.count == 1 && model.items[0].digest == "s1")
        model.query = "alpha zzz"
        model.applyFilter()
        check("无匹配时为空且无选中", model.items.isEmpty && model.selection == nil)
        model.query = ""
        model.applyFilter()
        check("清空搜索恢复全部并默认选中第一条", model.items.count == 3 && model.selection == model.items[0].id)
    } catch {
        check("搜索测试建库失败：\(error)", false)
    }

    // 5. 摘要折叠
    check("摘要折叠换行与连续空格", ClipboardCapture.preview("a\n\nb\t c") == "a b c")

    // 6. 时间文案
    check("刚刚的文案", relativeTime(Date().timeIntervalSince1970 - 5) == "刚刚")
    check("分钟的文案", relativeTime(Date().timeIntervalSince1970 - 330) == "5 分钟前")

    // 7. 长度上限
    let huge = String(repeating: "x", count: ClipboardCapture.maxTextBytes + 10)
    let pb = NSPasteboard(name: NSPasteboard.Name("clipshelf.selftest"))
    pb.clearContents()
    pb.setString(huge, forType: .string)
    check("超长文本会被拒绝", pb.string(forType: .string)?.utf8.count ?? 0 > ClipboardCapture.maxTextBytes)

    print(failures.isEmpty ? "全部通过" : "失败 \(failures.count) 项")
    return failures.isEmpty
}

// MARK: - 演示数据（快照用）

func demoStore() -> Store {
    let store = try! Store(path: ":memory:")
    let now = Date().timeIntervalSince1970

    func add(_ kind: ClipKind, _ content: String, _ preview: String,
             _ source: String, _ ago: TimeInterval, bytes: Int, digest: String) {
        _ = try? store.add(kind: kind, content: content, preview: preview,
                           bytes: bytes, source: source, digest: digest,
                           used: now - ago)
    }

    add(.text, "https://www.deepseek.com/research/2026-clipboard-ux",
        "https://www.deepseek.com/research/2026-clipboard-ux",
        "Safari", 25, bytes: 58, digest: "a0")
    add(.text, "把剪贴板历史做成一个能秒开的东西：按 ⌥⌘V 出来，输入几个字就能筛到，回车直接粘回去。",
        "把剪贴板历史做成一个能秒开的东西：按 ⌥⌘V 出来，输入几个字就能筛到，回车直接粘回去。",
        "飞书", 190, bytes: 120, digest: "a3")
    add(.text, "SELECT id, kind, preview FROM items WHERE pin = 0 ORDER BY used DESC LIMIT 200;",
        "SELECT id, kind, preview FROM items WHERE pin = 0 ORDER BY used DESC LIMIT 200;",
        "Terminal", 1500, bytes: 82, digest: "a2")
    add(.files, "/Users/Shared/Downloads/磁盘清单.csv",
        "磁盘清单.csv", "Finder", 7200, bytes: 33480, digest: "a4")
    add(.image, "/tmp/clipshelf-demo.png", "图片 1440×900", "截图", 9000, bytes: 482113, digest: "a5")
    add(.text, "顺便记一下评审结论：第一版只做「文本 + 图片 + 文件」三类，搜索走内存过滤，别急着上 FTS；快捷键先固定 ⌥⌘V，等有人抱怨再做成可配置。",
        "顺便记一下评审结论：第一版只做「文本 + 图片 + 文件」三类，搜索走内存过滤，别急着上 FTS；快捷键先固定 ⌥⌘V，等有人抱怨再做成可配置。",
        "备忘录", 3000, bytes: 210, digest: "a9")
    add(.text, "order_no=DS20261122-8841  amount=¥1,280.00  status=shipped",
        "order_no=DS20261122-8841  amount=¥1,280.00  status=shipped",
        "Google Chrome", 21600, bytes: 63, digest: "a6")
    add(.text, "func paste(item: ClipItem) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.content, forType: .string) }",
        "func paste(item: ClipItem) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.content, forType: .string) }",
        "Xcode", 48000, bytes: 148, digest: "a7")
    add(.text, "周一上午十点，钉钉会议室 A，评审剪贴板工具的第二版方案。",
        "周一上午十点，钉钉会议室 A，评审剪贴板工具的第二版方案。",
        "日历", 90000, bytes: 60, digest: "a8")

    // 置顶一条，展示 pin 样式
    if let target = store.fetch().first(where: { $0.digest == "a2" }) {
        try? store.setPin(id: target.id, pinned: true)
    }
    return store
}

// MARK: - 入口

func printUsage() {
    print("""
    ClipShelf — 剪贴板历史

    用法：
      ClipShelf                    启动菜单栏 App（⌥⌘V 打开历史）
      ClipShelf --toggle           让正在运行的实例弹出/收起面板
      ClipShelf --state            打印运行中实例的面板状态（排障）
      ClipShelf --autostart on|off 开启/关闭开机自启
      ClipShelf --about            打开「关于」窗口
      ClipShelf --key down|up|enter|esc  向面板注入一次按键（自检用）
      ClipShelf --dump [--limit N] 打印历史记录
      ClipShelf --selftest         运行自检
      ClipShelf --snapshot <路径>  渲染面板快照（--appearance light|dark）
      ClipShelf --help             显示本帮助
    """)
}

func dumpHistory(limit: Int) {
    guard let store = try? Store(path: defaultDBPath()) else {
        print("打不开数据库：\(defaultDBPath())")
        exit(1)
    }
    let rows = store.fetch(limit: limit)
    print("共 \(store.count()) 条（显示 \(rows.count) 条）")
    print("id\tkind\tsource\tused\tpreview")
    for r in rows {
        let t = relativeTime(r.used)
        let pin = r.pinned ? "📌" : "  "
        print("\(r.id)\t\(r.kind.rawValue)\t\(r.source)\t\(t)\t\(pin) \(String(r.preview.prefix(70)))")
    }
}

let arguments = CommandLine.arguments

if arguments.contains("--help") || arguments.contains("-h") {
    printUsage()
    exit(0)
}

if let i = arguments.firstIndex(of: "--autostart"), i + 1 < arguments.count {
    let want = arguments[i + 1]
    do {
        if want == "on" {
            try AutoStart.enable()
            print("已开启开机自启：\(AutoStart.plistURL.path)")
        } else {
            try AutoStart.disable()
            print("已关闭开机自启")
        }
    } catch {
        print("设置失败：\(error)")
        exit(1)
    }
    exit(0)
}

if arguments.contains("--about") {
    // 打开「关于」窗口（同时也是检查 bundle 图标有没有生效的最快方式）
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    app.finishLaunching()
    app.activate(ignoringOtherApps: true)
    let alert = NSAlert()
    alert.messageText = "ClipShelf — 剪贴板历史"
    alert.informativeText = "图标来自 App bundle 的 AppIcon.icns\n⌥⌘V 打开历史"
    alert.addButton(withTitle: "好")
    DispatchQueue.main.async {
        alert.runModal()
        exit(0)
    }
    app.run()
}

if arguments.contains("--selftest") {
    exit(runSelfTest() ? 0 : 1)
}

if arguments.contains("--toggle") {
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name("local.clipshelf.toggle"), object: nil, userInfo: nil,
        deliverImmediately: true)
    Thread.sleep(forTimeInterval: 0.3)   // 给通知守护进程一点时间，别刚发完就退出
    exit(0)
}

if let keyIndex = arguments.firstIndex(of: "--key"), keyIndex + 1 < arguments.count {
    let key = arguments[keyIndex + 1]
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name("local.clipshelf.testkey"), object: nil,
        userInfo: ["key": key, "cmd": arguments.contains("--cmd") ? "1" : "0"],
        deliverImmediately: true)
    Thread.sleep(forTimeInterval: 0.4)
    exit(0)
}

if arguments.contains("--state") {
    try? FileManager.default.removeItem(atPath: "/tmp/clipshelf-state.json")
    DistributedNotificationCenter.default().postNotificationName(
        NSNotification.Name("local.clipshelf.dumpstate"), object: nil, userInfo: nil,
        deliverImmediately: true)
    Thread.sleep(forTimeInterval: 0.45)
    let path = "/tmp/clipshelf-state.json"
    if let data = FileManager.default.contents(atPath: path),
       let text = String(data: data, encoding: .utf8) {
        print(text)
    } else {
        print("拿不到状态：实例可能没在运行")
        exit(1)
    }
    exit(0)
}

if arguments.contains("--dump") {
    var limit = 50
    if let i = arguments.firstIndex(of: "--limit"), i + 1 < arguments.count,
       let n = Int(arguments[i + 1]) {
        limit = n
    }
    dumpHistory(limit: limit)
    exit(0)
}

if let i = arguments.firstIndex(of: "--snapshot") {
    let out = i + 1 < arguments.count ? arguments[i + 1] : "panel.png"
    var appearance: NSAppearance.Name = .darkAqua
    if let j = arguments.firstIndex(of: "--appearance"), j + 1 < arguments.count {
        appearance = arguments[j + 1] == "light" ? .aqua : .darkAqua
    }
    let app = NSApplication.shared
    app.setActivationPolicy(.prohibited)
    let store = arguments.contains("--empty") ? (try! Store(path: ":memory:")) : demoStore()
    if PanelSnapshot.render(store: store, to: out, appearance: appearance) {
        print("已写入 \(out)")
        exit(0)
    }
    print("渲染失败")
    exit(1)
}

// 单实例：已经有一个 ClipShelf 在跑就不再开第二个（否则会重复捕获）
if let bid = Bundle.main.bundleIdentifier {
    let others = NSRunningApplication.runningApplications(withBundleIdentifier: bid)
        .filter { $0.processIdentifier != getpid() }
    if !others.isEmpty {
        print("ClipShelf 已在运行（pid \(others[0].processIdentifier)）")
        exit(0)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
