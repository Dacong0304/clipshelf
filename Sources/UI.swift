// ClipShelf · 面板（召出后的搜索与选择界面）
//
// 交互沿用大家熟悉的那一套：顶部搜索、列表即时过滤、↑↓ 移动、⏎ 粘回
// 刚才那个 App、⌘C 只复制不粘贴、⌘P 置顶、⌘⌫ 删除、esc 收起。
// 键盘事件走 NSEvent 本地监听，比在 SwiftUI 里抢焦点稳。

import AppKit
import SwiftUI

// MARK: - 视图模型

final class AppModel: ObservableObject {
    let store: Store

    @Published var query: String = "" { didSet { applyFilter() } }
    @Published var items: [ClipItem] = []
    @Published var selection: Int64?
    @Published var total: Int = 0
    @Published var isPaused: Bool = false
    @Published var showToken: Int = 0

    private var all: [ClipItem] = []

    init(store: Store) {
        self.store = store
    }

    var selectedItem: ClipItem? {
        guard let id = selection else { return nil }
        return items.first { $0.id == id }
    }

    func reload(keepSelection: Bool = true) {
        all = store.fetch()
        total = all.count
        if keepSelection, let id = selection, all.contains(where: { $0.id == id }) {
            applyFilter(preserving: id)
        } else {
            selection = nil
            applyFilter(preserving: nil)
        }
    }

    func applyFilter(preserving: Int64? = nil) {
        let tokens = query.lowercased()
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)

        var filtered = all
        if !tokens.isEmpty {
            filtered = all.filter { item in
                let blob = item.searchBlob
                return tokens.allSatisfy { blob.contains($0) }
            }
        }
        items = filtered

        if let wanted = preserving ?? selection, filtered.contains(where: { $0.id == wanted }) {
            selection = wanted
        } else {
            selection = filtered.first?.id
        }
    }

    func moveSelection(_ delta: Int) {
        guard !items.isEmpty else { return }
        let idx = items.firstIndex { $0.id == selection } ?? -1
        let next = min(max(idx + delta, 0), items.count - 1)
        selection = items[next].id
    }

    func remove(_ item: ClipItem) {
        try? store.delete(id: item.id)
        reload(keepSelection: false)
    }

    func togglePin(_ item: ClipItem) {
        try? store.setPin(id: item.id, pinned: !item.pinned)
        let pinnedID = item.pinned ? nil : item.id
        reload(keepSelection: false)
        if let pinnedID, items.contains(where: { $0.id == pinnedID }) {
            selection = pinnedID
        }
    }
}

// MARK: - 小工具

private struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .popover
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = blending
        v.state = .active
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
        v.blendingMode = blending
    }
}

func relativeTime(_ ts: Double) -> String {
    let date = Date(timeIntervalSince1970: ts)
    let delta = Date().timeIntervalSince(date)
    if delta < 45 { return "刚刚" }
    if delta < 3600 { return "\(max(1, Int(delta / 60))) 分钟前" }

    let cal = Calendar.current
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_CN")
    if cal.isDateInToday(date) {
        f.dateFormat = "今天 HH:mm"
    } else if cal.isDateInYesterday(date) {
        f.dateFormat = "昨天 HH:mm"
    } else {
        f.dateFormat = "M月d日 HH:mm"
    }
    return f.string(from: date)
}

private func kindTint(_ kind: ClipKind) -> Color {
    switch kind {
    case .text: return .accentColor
    case .image: return .purple
    case .files: return .teal
    }
}

private func metaText(_ item: ClipItem) -> String {
    var parts: [String] = []
    if !item.source.isEmpty { parts.append(item.source) }
    parts.append(relativeTime(item.used))
    parts.append(item.sizeText)
    return parts.joined(separator: "  ·  ")
}

// MARK: - 行

private struct ClipRow: View {
    let item: ClipItem
    let selected: Bool
    let onTap: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(kindTint(item.kind).opacity(0.16))
                Image(systemName: item.kind.symbol)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(kindTint(item.kind))
            }
            .frame(width: 26, height: 26)

            VStack(alignment: .leading, spacing: 3) {
                Text(item.preview)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)

                Text(metaText(item))
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            if item.pinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                    .padding(.top, 2)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(height: 64, alignment: .top)
        .background {
            if selected {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(Color.accentColor.opacity(0.16))
            }
        }
        .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .onTapGesture(perform: onTap)
    }
}

// MARK: - 键盘提示

private struct KeyHint: View {
    let key: String
    let text: String

    var body: some View {
        HStack(spacing: 3) {
            Text(key)
                .font(.system(size: 9, weight: .semibold, design: .rounded))
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3, style: .continuous)
                        .fill(Color.primary.opacity(0.08))
                )
            Text(text).font(.system(size: 10))
        }
        .foregroundStyle(.secondary)
    }
}

// MARK: - 面板

struct PanelView: View {
    @ObservedObject var model: AppModel
    var onCommit: (ClipItem, Bool) -> Void
    var onPin: (ClipItem) -> Void
    var onDelete: (ClipItem) -> Void

    @FocusState private var searchFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.5)
            list
            Divider().opacity(0.5)
            footer
        }
        .frame(width: PanelMetrics.width, height: PanelMetrics.height)
        .background {
            ZStack {
                VisualEffectView()
                Color(nsColor: .windowBackgroundColor).opacity(0.55)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        }
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10), lineWidth: 1)
        )
        .onAppear { focusSearch() }
        .onChange(of: model.showToken) { _, _ in focusSearch() }
    }

    private func focusSearch() {
        DispatchQueue.main.async { searchFocused = true }
    }

    // 顶部：搜索框 + 计数
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.secondary)

            TextField("搜索剪贴历史", text: $model.query)
                .textFieldStyle(.plain)
                .font(.system(size: 13.5))
                .focused($searchFocused)
                .onSubmit { commit(paste: true) }

            if !model.query.isEmpty {
                Button {
                    model.query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }

            if model.isPaused {
                Text("已暂停")
                    .font(.system(size: 9.5, weight: .semibold))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1.5)
                    .background(Capsule().fill(Color.orange.opacity(0.2)))
                    .foregroundStyle(.orange)
            }

            Text("\(model.total) 条")
                .font(.system(size: 10.5).monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12)
        .frame(height: 42)
    }

    // 中部：列表
    private var list: some View {
        Group {
            if model.items.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(spacing: 1) {
                            ForEach(model.items) { item in
                                ClipRow(item: item, selected: item.id == model.selection) {
                                    model.selection = item.id
                                    onCommit(item, true)
                                }
                                .id(item.id)
                            }
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 5)
                    }
                    .scrollIndicators(.hidden)
                    .onChange(of: model.selection) { _, new in
                        guard let new else { return }
                        withAnimation(.easeOut(duration: 0.12)) {
                            proxy.scrollTo(new, anchor: .center)
                        }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity)
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: model.query.isEmpty ? "doc.on.clipboard" : "magnifyingglass")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(model.query.isEmpty ? "还没有剪贴记录" : "没有匹配的记录")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            Text(model.query.isEmpty ? "复制任意文本、图片或文件，会立刻出现在这里" : "试试更短的关键词，多个词之间是「同时包含」")
                .font(.system(size: 10.5))
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // 底部：快捷键
    private var footer: some View {
        HStack(spacing: 12) {
            KeyHint(key: "↑↓", text: "选择")
            KeyHint(key: "⏎", text: "粘贴")
            KeyHint(key: "⌘C", text: "仅复制")
            KeyHint(key: "⌘P", text: "置顶")
            KeyHint(key: "⌘⌫", text: "删除")
            Spacer()
            KeyHint(key: "esc", text: "收起")
        }
        .padding(.horizontal, 12)
        .frame(height: 30)
    }

    private func commit(paste: Bool) {
        guard let item = model.selectedItem else { return }
        onCommit(item, paste)
    }
}

enum PanelMetrics {
    static let width: CGFloat = 640
    static let height: CGFloat = 470
}

// MARK: - 面板窗口

final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class PanelController: NSObject {
    private let panel: KeyablePanel
    private let model: AppModel
    private let store: Store
    private let capture: ClipboardCapture
    private var keyMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var previousApp: NSRunningApplication?
    private var lastShowAt: TimeInterval = 0

    init(store: Store, model: AppModel, capture: ClipboardCapture) {
        self.store = store
        self.model = model
        self.capture = capture

        let rect = NSRect(x: 0, y: 0, width: PanelMetrics.width, height: PanelMetrics.height)
        panel = KeyablePanel(contentRect: rect,
                             styleMask: [.borderless, .fullSizeContentView],
                             backing: .buffered, defer: false)
        super.init()

        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = false
        panel.animationBehavior = .utilityWindow

        let root = PanelView(
            model: model,
            onCommit: { [weak self] item, paste in self?.commit(item, paste: paste) },
            onPin: { [weak self] item in self?.model.togglePin(item) },
            onDelete: { [weak self] item in self?.model.remove(item) }
        )
        let host = NSHostingView(rootView: root)
        host.frame = rect
        host.wantsLayer = true
        panel.contentView = host

        installKeyMonitor()
        installResignObserver()
    }

    deinit {
        if let m = keyMonitor { NSEvent.removeMonitor(m) }
        if let o = resignObserver { NotificationCenter.default.removeObserver(o) }
    }

    // MARK: 显示 / 收起

    func toggle() {
        if panel.isVisible { hide() } else { show() }
    }

    func show() {
        previousApp = NSWorkspace.shared.frontmostApplication
        if previousApp?.bundleIdentifier == Bundle.main.bundleIdentifier {
            previousApp = nil
        }
        model.query = ""
        model.reload(keepSelection: false)
        model.showToken += 1
        position()
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        lastShowAt = Date().timeIntervalSince1970
    }

    func hide() {
        panel.orderOut(nil)
        restoreFocus()
    }

    private func restoreFocus() {
        guard let app = previousApp, !app.isTerminated,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        app.activate(options: [])
    }

    private func position() {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
            ?? NSScreen.screens.first
        guard let screen else { return }
        let f = screen.visibleFrame
        let x = f.midX - PanelMetrics.width / 2
        let y = f.maxY - PanelMetrics.height - 40
        panel.setFrame(NSRect(x: x, y: y, width: PanelMetrics.width, height: PanelMetrics.height),
                       display: false)
    }

    /// 自检：构造 NSEvent 后直接交给按键处理函数（不依赖窗口是否活跃）
    @discardableResult
    func simulateKey(_ keyCode: UInt16, command: Bool = false) -> Bool {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: command ? [.command] : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode
        ) else { return false }
        return handle(event) == nil
    }

    /// 自检/自动化：合成一次按键，走的是和真人一样的 NSEvent 派发路径
    func postSyntheticKey(_ keyCode: UInt16, command: Bool = false) {
        guard let event = NSEvent.keyEvent(
            with: .keyDown, location: .zero,
            modifierFlags: command ? [.command] : [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: panel.windowNumber, context: nil,
            characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: keyCode
        ) else { return }
        NSApp.postEvent(event, atStart: false)
    }

    /// 排障：把面板当前状态写成字典，配合 `ClipShelf --state` 使用
    func debugState() -> [String: Any] {
        var state: [String: Any] = [
            "visible": panel.isVisible,
            "isKeyWindow": panel.isKeyWindow,
            "appActive": NSApp.isActive,
            "panelFrame": NSStringFromRect(panel.frame),
            "level": panel.level.rawValue,
            "items": model.items.count,
            "total": model.total,
            "selection": model.selection ?? -1,
            "query": model.query,
            "capturePaused": model.isPaused,
        ]
        if let responder = panel.firstResponder {
            state["firstResponder"] = String(describing: type(of: responder))
        }
        if let screen = panel.screen ?? NSScreen.main {
            state["panelScreen"] = NSStringFromRect(screen.frame)
        }
        return state
    }

    // MARK: 提交

    private func commit(_ item: ClipItem, paste: Bool) {
        putOnPasteboard(item)
        capture.noteSelfWrite(NSPasteboard.general.changeCount)
        _ = store.touch(id: item.id)

        hide()

        guard paste else {
            Toast.show("已复制到剪贴板")
            return
        }

        if Paster.isTrusted {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.14) {
                Paster.sendCommandV()
            }
        } else {
            Toast.show("已复制 · 按 ⌘V 粘贴（可在菜单里授权自动粘贴）")
        }
    }

    private func putOnPasteboard(_ item: ClipItem) {
        let pb = NSPasteboard.general
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.content, forType: .string)
        case .image:
            if let data = FileManager.default.contents(atPath: item.content) {
                pb.setData(data, forType: .png)
            }
        case .files:
            let urls = item.content
                .split(separator: "\n")
                .map { NSURL(fileURLWithPath: String($0)) }
            pb.writeObjects(urls)
        }
    }

    // MARK: 键盘

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self, self.panel.isVisible, self.panel.isKeyWindow else { return event }
            return self.handle(event)
        }
    }

    func handle(_ event: NSEvent) -> NSEvent? {
        let cmd = event.modifierFlags.contains(.command)
        let shift = event.modifierFlags.contains(.shift)

        switch event.keyCode {
        case 53: // esc
            hide()
            return nil
        case 125: // ↓
            model.moveSelection(1)
            return nil
        case 126: // ↑
            model.moveSelection(-1)
            return nil
        case 36, 76: // return / enter
            guard let item = model.selectedItem else { return nil }
            commit(item, paste: !shift)
            return nil
        case 51: // delete
            if cmd, let item = model.selectedItem {
                model.remove(item)
                return nil
            }
            return event
        case 35: // P
            if cmd, let item = model.selectedItem {
                model.togglePin(item)
                return nil
            }
            return event
        case 8: // C
            if cmd, let item = model.selectedItem {
                commit(item, paste: false)
                return nil
            }
            return event
        default:
            return event
        }
    }

    // MARK: 失焦即收起

    private func installResignObserver() {
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            // 刚弹出时可能有一瞬间的失活，忽略
            if Date().timeIntervalSince1970 - self.lastShowAt < 0.25 { return }
            self.hide()
        }
    }
}

// MARK: - 快照（给 README 和自检用）

enum PanelSnapshot {
    static func render(store: Store, to path: String, appearance: NSAppearance.Name = .darkAqua) -> Bool {
        let model = AppModel(store: store)
        model.reload(keepSelection: false)

        let view = PanelView(model: model,
                             onCommit: { _, _ in },
                             onPin: { _ in },
                             onDelete: { _ in })

        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: PanelMetrics.width, height: PanelMetrics.height)
        host.appearance = NSAppearance(named: appearance)

        let window = NSWindow(contentRect: host.frame,
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: appearance)
        window.contentView = host
        window.setIsVisible(true)
        window.orderFrontRegardless()

        host.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.35))
        host.layoutSubtreeIfNeeded()

        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            window.orderOut(nil)
            return false
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            window.orderOut(nil)
            return false
        }
        window.orderOut(nil)
        do {
            try png.write(to: URL(fileURLWithPath: path))
            return true
        } catch {
            NSLog("snapshot write failed: \(error)")
            return false
        }
    }
}
