// ClipShelf · 全局热键 + 粘贴注入
//
// 热键用 Carbon 的 RegisterEventHotKey：不需要辅助功能权限，也不抢系统焦点，
// 只是把「按键事件」交给我们。粘贴注入是另一件事 —— 模拟 ⌘V 必须走
// CGEvent，需要用户在「辅助功能」里授权；没授权就降级成「已复制，请按 ⌘V」。

import AppKit
import Carbon.HIToolbox

// MARK: - 全局热键

final class GlobalHotKey {
    private var hotKeyRef: EventHotKeyRef?
    private var handlerRef: EventHandlerRef?
    private let action: () -> Void
    private(set) var isValid = false

    private static let signature: OSType = 0x43534846 // "CSHF"

    init(keyCode: UInt32 = UInt32(kVK_ANSI_V),
         modifiers: UInt32 = UInt32(cmdKey | optionKey),
         action: @escaping () -> Void) {
        self.action = action
        install(keyCode: keyCode, modifiers: modifiers)
    }

    deinit { unregister() }

    private func install(keyCode: UInt32, modifiers: UInt32) {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))

        let callback: EventHandlerUPP = { _, _, userData in
            guard let userData else { return OSStatus(eventNotHandledErr) }
            let me = Unmanaged<GlobalHotKey>.fromOpaque(userData).takeUnretainedValue()
            me.action()
            return noErr
        }

        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec,
                            Unmanaged.passUnretained(self).toOpaque(), &handlerRef)

        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let status = RegisterEventHotKey(keyCode, modifiers, id,
                                         GetApplicationEventTarget(), 0, &hotKeyRef)
        isValid = status == noErr
        if !isValid {
            NSLog("ClipShelf: 全局热键注册失败（可能被其它 App 占用）status=\(status)")
        }
    }

    func unregister() {
        if let ref = hotKeyRef { UnregisterEventHotKey(ref); hotKeyRef = nil }
        if let h = handlerRef { RemoveEventHandler(h); handlerRef = nil }
        isValid = false
    }

    /// 供菜单里显示，例如 "⌥⌘V"
    static var shortcutLabel: String { "⌥⌘V" }
}

// MARK: - 粘贴注入

enum Paster {
    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// 弹系统引导（用户会被带到「隐私与安全性 › 辅助功能」）
    static func requestAccess() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// 向当前前台应用发一次 ⌘V
    static func sendCommandV() {
        guard isTrusted else { return }
        let source = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = CGKeyCode(kVK_ANSI_V)
        let down = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}

// MARK: - 轻量提示条

/// 无权限时用一条 1.2 秒的浮层提示「已复制」，不打断用户
enum Toast {
    private static var current: NSWindow?

    static func show(_ text: String, seconds: TimeInterval = 1.3) {
        current?.orderOut(nil)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 12.5, weight: .medium)
        label.textColor = .labelColor
        label.alignment = .center
        label.sizeToFit()

        let padding: CGFloat = 18
        let w = label.frame.width + padding * 2
        let h: CGFloat = 34

        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: w, height: h),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        panel.ignoresMouseEvents = true

        let blur = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: w, height: h))
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = h / 2
        blur.layer?.masksToBounds = true

        label.frame = NSRect(x: padding, y: (h - label.frame.height) / 2,
                             width: label.frame.width, height: label.frame.height)
        blur.addSubview(label)
        panel.contentView = blur

        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - w / 2, y: f.minY + 120))
        }
        panel.orderFrontRegardless()
        current = panel

        DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
            panel.orderOut(nil)
        }
    }
}
