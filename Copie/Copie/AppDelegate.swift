import Cocoa
import ApplicationServices
import ServiceManagement   // 新增

// MARK: - Parallels Desktop detection
private let parallelsBundlePrefixes: [String] = [
    "com.parallels.desktop",   // Control Center & App Store edition
    "com.parallels.vm",        // VM processes (Intel/Apple Silicon)
    "com.parallels.winapp"     // Coherence‑mode WinAppHelper
]

@inline(__always)
func isParallelsFrontmost() -> Bool {
    guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier else { return false }
    return parallelsBundlePrefixes.contains { id.hasPrefix($0) }
}

// MARK: - App entry
@main
class AppDelegate: NSObject, NSApplicationDelegate {
    private let tap = EventTap()
    private var statusItem: NSStatusItem!
    private var autoLaunchItem: NSMenuItem!

    func applicationDidFinishLaunching(_ n: Notification) {
        // ① 先检查 / 触发辅助功能权限；拿到权限后再启动 EventTap
        ensureAXPermissionThenStartTap()

        // ② 创建菜单栏图标
        prepareStatusItem()
    }

    // MARK: - 权限
    /// 若当前未获辅助功能权限，则弹窗提示并轮询，直到拿到权限后启动 EventTap
    private func ensureAXPermissionThenStartTap() {
        // 直接调用带 Prompt 的 API
        let opts: CFDictionary = [
            kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
        ] as CFDictionary

        // 已获授权 → 直接启动
        if AXIsProcessTrustedWithOptions(opts) {
            tap.start()
            return
        }

        // 未授权 → 弹自定义对话框并打开系统设置
        showAccessibilityAlert()

        // 轮询等待用户开启开关后启动
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] timer in
            guard let self = self else { timer.invalidate(); return }
            if AXIsProcessTrusted() {
                timer.invalidate()
                self.tap.start()
            }
        }
    }

    /// 弹窗提示用户去系统设置里开启辅助功能权限，并可一键跳转
    private func showAccessibilityAlert() {
        DispatchQueue.main.async {
            let alert = NSAlert()
            alert.messageText = "Copie 需要“辅助功能”权限"
            alert.informativeText = "请点击“打开设置”，然后在左侧“辅助功能”里把 Copie 的开关打开。完成后返回 Copie 即可正常使用。"
            alert.addButton(withTitle: "打开设置")
            alert.addButton(withTitle: "稍后再说")

            if alert.runModal() == .alertFirstButtonReturn,
               let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }
    }

    // MARK: - 菜单栏
    private func prepareStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let btn = statusItem.button {
            btn.image = NSImage(
                systemSymbolName: "doc.on.clipboard.fill",
                accessibilityDescription: "Copie"
            ) ?? NSImage(named: "FallbackTemplate")          // 兜底图片
            btn.image?.isTemplate = true
        }
        statusItem.menu = buildMenu()
    }

    // 菜单栏下拉
    private func buildMenu() -> NSMenu {
        let m = NSMenu()

        // 开机自启菜单项
        autoLaunchItem = NSMenuItem(
            title: "Launch at Login",
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        autoLaunchItem.target = self
        autoLaunchItem.state = isLaunchAtLoginEnabled ? .on : .off
        m.addItem(autoLaunchItem)

        m.addItem(.separator())
        m.addItem(withTitle: "Quit Copie", action: #selector(NSApp.terminate(_:)), keyEquivalent: "q")
        return m
    }

    // 检查是否开机自启
    var isLaunchAtLoginEnabled: Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        } else {
            return false
        }
    }

    // 切换开机自启
    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        if #available(macOS 13.0, *) {
            let appService = SMAppService.mainApp
            do {
                if appService.status == .enabled {
                    try appService.unregister()
                } else {
                    try appService.register()
                }
                sender.state = appService.status == .enabled ? .on : .off
            } catch {
                Notifier.shared.show(text: "切换自启失败：\(error.localizedDescription)")
            }
        } else {
            Notifier.shared.show(text: "当前系统不支持自动开机（需要 macOS 13+）")
        }
    }
}

// MARK: - 核心动作
final class CopieActions {
    static let shared = CopieActions()

    // ⌘ + keyCode
    private func sendShortcut(_ key: CGKeyCode) {
        guard let src = CGEventSource(stateID: .combinedSessionState) else { return }
        let loc: CGEventTapLocation = .cghidEventTap
        func evt(_ keyDown: Bool) -> CGEvent { .init(keyboardEventSource: src, virtualKey: key,    keyDown: keyDown)! }
        func cmd(_ keyDown: Bool) -> CGEvent { .init(keyboardEventSource: src, virtualKey: 0x37, keyDown: keyDown)! }
        [cmd(true), evt(true), evt(false), cmd(false)].forEach {
            $0.flags = .maskCommand; $0.post(tap: loc)
        }
    }

    /// AHK 脚本同款逻辑：双 ⌘C + 延时 + 每 50 字换行 + HUD
    func performCopy() {
        let pb = NSPasteboard.general
        let oldCount = pb.changeCount

        // Some apps update the pasteboard asynchronously. Poll briefly instead
        // of assuming that 100 ms is always enough.
        func showCopiedText(attemptsRemaining: Int) {
            if pb.changeCount != oldCount,
               let txt = pb.string(forType: .string),
               !txt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                let step = 50
                var wrapped = ""
                var i = txt.startIndex
                while i < txt.endIndex {
                    let end = txt.index(i, offsetBy: step, limitedBy: txt.endIndex) ?? txt.endIndex
                    wrapped += String(txt[i..<end]) + "\n"
                    i = end
                }
                Notifier.shared.show(text: wrapped)
                return
            }

            guard attemptsRemaining > 0 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                showCopiedText(attemptsRemaining: attemptsRemaining - 1)
            }
        }

        sendShortcut(0x08) // 'c'
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10) {
            self.sendShortcut(0x08) // 第二次
            showCopiedText(attemptsRemaining: 20)
        }
    }

    func performPaste() { sendShortcut(0x09) } // 'v'
}

// MARK: - HUD 提示
final class Notifier {
    static let shared = Notifier()
    private var window: NSWindow?

    func show(text: String) {
        window?.orderOut(nil)

        // label，保证自动换行
        let displayText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let label = NSTextField(labelWithString: displayText)
        label.font = .systemFont(ofSize: 18, weight: .semibold)
        label.textColor = .white
        label.alignment = .left
        label.lineBreakMode = .byCharWrapping
        label.maximumNumberOfLines = 0
        label.backgroundColor = .clear
        label.isBezeled = false
        label.drawsBackground = false
        label.sizeToFit()

        // window
        let pad: CGFloat = 24
        let size = NSSize(width: label.frame.width + pad * 2,
                          height: label.frame.height + pad * 2)
        let win = NSWindow(contentRect: .init(origin: .zero, size: size),
                           styleMask: .borderless, backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear    // 关键！彻底透明

        win.level = .floating
        win.hasShadow = true
        win.ignoresMouseEvents = true

        // container view + 圆角 + 半透明
        let v = NSView(frame: .init(origin: .zero, size: size))
        v.wantsLayer = true
        v.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.70).cgColor // 半透明
        v.layer?.cornerRadius = 20
        v.layer?.masksToBounds = true
        label.frame.origin = .init(x: pad, y: pad)
        v.addSubview(label)
        win.contentView = v

        // near cursor
        var p = NSEvent.mouseLocation
        p.x += 10; p.y -= size.height + 20

        // Clamp position so that the HUD stays fully inside the visible part of the screen
        if let scr = NSScreen.screens.first(where: { $0.frame.contains(p) }) ?? NSScreen.main {
            let xf = scr.visibleFrame
            // Shift left if the window would spill over the right edge
            if p.x + size.width > xf.maxX {
                p.x = xf.maxX - size.width - 10
            }
            // Shift right if the window would spill over the left edge
            if p.x < xf.minX {
                p.x = xf.minX + 10
            }
            // Shift up if the window would spill below the bottom edge
            if p.y < xf.minY {
                p.y = xf.minY + 10
            }
            // Shift down if the window would spill above the top edge
            if p.y + size.height > xf.maxY {
                p.y = xf.maxY - size.height - 10
            }
        }

        win.setFrameOrigin(p)

        win.alphaValue = 0
        win.orderFront(nil)
        NSAnimationContext.runAnimationGroup({ $0.duration = 0.15
            win.animator().alphaValue = 1
        })
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.3
                win.animator().alphaValue = 0
            }) { win.orderOut(nil) }
        }
        window = win
    }
}

// MARK: - 全局鼠标监听
final class EventTap {
    private var tap: CFMachPort?
    private var quickCopyArmed = false   // 下一次右键是否触发快速复制
    private var armedAt: CFTimeInterval = 0

    func start() {
        // 监控：拖选、右键、鼠标中键
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)    |
            (1 << CGEventType.leftMouseDragged.rawValue) |
            (1 << CGEventType.rightMouseDown.rawValue)  |
            (1 << CGEventType.rightMouseUp.rawValue)    |
            (1 << CGEventType.otherMouseDown.rawValue)  |
            (1 << CGEventType.otherMouseUp.rawValue)

        let cb: CGEventTapCallBack = { _, t, e, refcon in
            guard let p = refcon else { return Unmanaged.passUnretained(e) }
            let selfRef = Unmanaged<EventTap>.fromOpaque(p).takeUnretainedValue()
            return selfRef.handle(event: e, type: t) ? Unmanaged.passUnretained(e) : nil
        }

        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                options: .defaultTap, eventsOfInterest: mask,
                                callback: cb,
                                userInfo: UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque()))
        guard let tap else { print("⚠️ EventTap failed."); return }
        let src = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    // 返回 true = 继续给系统；false = 吞掉
    private func handle(event: CGEvent, type: CGEventType) -> Bool {
        // macOS disables slow event taps. Re-enable immediately so the app does
        // not silently stop responding until it is relaunched.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }

        // 如果前台是 Parallels Desktop，完全放行，避免拦截其快捷键
        if isParallelsFrontmost() { return true }

        switch type {

        case .leftMouseDown:
            quickCopyArmed = false
            return true

        case .leftMouseDragged:               // 拖动选择中
            quickCopyArmed = true
            armedAt = CACurrentMediaTime()
            return true

        case .rightMouseDown:
            // Do not let an old drag swallow an unrelated right-click later.
            if quickCopyArmed && CACurrentMediaTime() - armedAt > 3.0 {
                quickCopyArmed = false
            }
            return quickCopyArmed ? false : true   // 若已选中，吞掉菜单

        case .rightMouseUp:
            if quickCopyArmed {
                CopieActions.shared.performCopy()
                quickCopyArmed = false
                return false
            }
            return true

        case .otherMouseDown where event.getIntegerValueField(.mouseEventButtonNumber) == 2:
            CopieActions.shared.performPaste()
            return false
        case .otherMouseUp where event.getIntegerValueField(.mouseEventButtonNumber) == 2:
            return false

        default:
            return true
        }
    }
}
