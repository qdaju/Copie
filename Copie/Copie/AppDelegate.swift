import Cocoa
import ApplicationServices
import ServiceManagement   // 新增
import QuartzCore

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

private enum AppLanguage: String {
    case chinese = "zh"
    case english = "en"
}

private enum CopieSettings {
    static let holdDurationKey = "selectAllHoldDuration"
    static let selectAllEnabledKey = "selectAllEnabled"
    static let defaultHoldDuration: TimeInterval = 0.5
    static let minimumHoldDuration: TimeInterval = 0.2
    static let maximumHoldDuration: TimeInterval = 2.0

    static var holdDuration: TimeInterval {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: holdDurationKey) != nil else {
            return defaultHoldDuration
        }
        return Swift.min(
            Swift.max(defaults.double(forKey: holdDurationKey), minimumHoldDuration),
            maximumHoldDuration
        )
    }

    static var isSelectAllEnabled: Bool {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: selectAllEnabledKey) != nil else {
            return true
        }
        return defaults.bool(forKey: selectAllEnabledKey)
    }

}

private final class HoldDurationSlider: NSSlider {
    private var dragStartValue: Double?
    private var isMouseDragging = false

    override func mouseDown(with event: NSEvent) {
        dragStartValue = doubleValue
        isMouseDragging = true
        super.mouseDown(with: event)
        isMouseDragging = false
        dragStartValue = nil
    }

    override func scrollWheel(with event: NSEvent) {
        let delta = abs(event.scrollingDeltaY) >= abs(event.scrollingDeltaX)
            ? event.scrollingDeltaY
            : event.scrollingDeltaX
        guard delta != 0 else { return }

        let direction = delta > 0 ? 1.0 : -1.0
        let nextValue = Swift.min(
            Swift.max(doubleValue + direction * 0.1, minValue),
            maxValue
        )
        guard nextValue != doubleValue else { return }

        doubleValue = nextValue
        _ = sendAction(action, to: target)
    }

    override func sendAction(_ action: Selector?, to target: Any?) -> Bool {
        if isMouseDragging,
           let startValue = dragStartValue,
           abs(doubleValue - startValue) > 0.0001 {
            let roundedValue = (doubleValue * 10).rounded() / 10
            if abs(roundedValue - startValue) < 0.0001 {
                doubleValue = Swift.min(
                    Swift.max(startValue + (doubleValue > startValue ? 0.1 : -0.1), minValue),
                    maxValue
                )
            }
        }
        return super.sendAction(action, to: target)
    }
}

private final class RollingValueLabel: NSTextField {
    private var displayedValue: Double?

    func update(value: Double, text: String, animated: Bool = true) {
        guard let previousValue = displayedValue else {
            displayedValue = value
            stringValue = text
            wantsLayer = true
            layer?.masksToBounds = true
            return
        }
        guard abs(value - previousValue) > 0.0001 else { return }

        if animated && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            let transition = CATransition()
            transition.type = .push
            transition.subtype = value > previousValue ? .fromBottom : .fromTop
            transition.duration = 0.16
            transition.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer?.add(transition, forKey: "rollingValue")
        }

        displayedValue = value
        stringValue = text
    }
}

// MARK: - App entry
@main
class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let tap = EventTap()
    private var statusItem: NSStatusItem!
    private var autoLaunchItem: NSMenuItem!
    private weak var holdDurationValueLabel: RollingValueLabel?
    private var featureGuidePanel: NSPanel?
    private var shouldPresentFeatureGuideAfterMenuCloses = false
    private var featureGuidePresentationWorkItem: DispatchWorkItem?
    private var language: AppLanguage = {
        guard let rawValue = UserDefaults.standard.string(forKey: "appLanguage"),
              let savedLanguage = AppLanguage(rawValue: rawValue) else { return .chinese }
        return savedLanguage
    }()

    func applicationDidFinishLaunching(_ n: Notification) {
        // ① 先检查 / 触发辅助功能权限；拿到权限后再启动 EventTap
        ensureAXPermissionThenStartTap()

        // ② 创建菜单栏图标
        prepareStatusItem()

        #if DEBUG
        if CommandLine.arguments.contains("--show-feature-guide") {
            DispatchQueue.main.async { [weak self] in
                self?.showFeatureGuide(NSMenuItem())
            }
        }
        #endif
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
            alert.messageText = self.localized(chinese: "Copie 需要“辅助功能”权限", english: "Copie needs Accessibility permission")
            alert.informativeText = self.localized(
                chinese: "请点击“打开设置”，然后在左侧“辅助功能”里把 Copie 的开关打开。完成后返回 Copie 即可正常使用。",
                english: "Click “Open Settings”, enable Copie under Accessibility, then return to Copie to continue."
            )
            alert.addButton(withTitle: self.localized(chinese: "打开设置", english: "Open Settings"))
            alert.addButton(withTitle: self.localized(chinese: "稍后再说", english: "Later"))

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
            let icon = NSImage(named: "MenuBarIcon") ?? NSImage(
                systemSymbolName: "c.circle.fill",
                accessibilityDescription: "Copie"
            )
            icon?.size = NSSize(width: 18, height: 18)
            icon?.isTemplate = true
            icon?.accessibilityDescription = "Copie"
            btn.image = icon
            btn.imagePosition = .imageOnly
            btn.toolTip = "Copie"
        }
        statusItem.menu = buildMenu()
    }

    // 菜单栏下拉
    private func buildMenu() -> NSMenu {
        let m = NSMenu()
        m.delegate = self

        m.addItem(makeHoldDurationMenuItem())
        let selectAllItem = NSMenuItem(
            title: localized(chinese: "输入框长按全选", english: "Hold to Select All in Text Fields"),
            action: #selector(toggleSelectAll(_:)),
            keyEquivalent: ""
        )
        selectAllItem.target = self
        selectAllItem.state = CopieSettings.isSelectAllEnabled ? .on : .off
        m.addItem(selectAllItem)
        m.addItem(.separator())

        // 开机自启菜单项
        autoLaunchItem = NSMenuItem(
            title: localized(chinese: "登录时启动", english: "Launch at Login"),
            action: #selector(toggleLaunchAtLogin(_:)),
            keyEquivalent: ""
        )
        autoLaunchItem.target = self
        autoLaunchItem.state = isLaunchAtLoginEnabled ? .on : .off
        m.addItem(autoLaunchItem)

        let featureGuideItem = NSMenuItem(
            title: localized(chinese: "功能说明", english: "Features"),
            action: #selector(showFeatureGuide(_:)),
            keyEquivalent: ""
        )
        featureGuideItem.target = self
        m.addItem(featureGuideItem)

        let languageMenu = NSMenu()
        let chineseItem = NSMenuItem(title: "中文", action: #selector(changeLanguage(_:)), keyEquivalent: "")
        chineseItem.representedObject = AppLanguage.chinese.rawValue
        chineseItem.state = language == .chinese ? .on : .off
        chineseItem.target = self
        languageMenu.addItem(chineseItem)

        let englishItem = NSMenuItem(title: "English", action: #selector(changeLanguage(_:)), keyEquivalent: "")
        englishItem.representedObject = AppLanguage.english.rawValue
        englishItem.state = language == .english ? .on : .off
        englishItem.target = self
        languageMenu.addItem(englishItem)

        let languageItem = NSMenuItem(title: "语言 / Language", action: nil, keyEquivalent: "")
        languageItem.submenu = languageMenu
        m.addItem(languageItem)

        m.addItem(.separator())
        let quitItem = NSMenuItem(title: "Quit Copie", action: #selector(quitCopie(_:)), keyEquivalent: "q")
        quitItem.target = self
        m.addItem(quitItem)
        return m
    }

    @objc private func quitCopie(_ sender: NSMenuItem) {
        NSApp.terminate(sender)
    }

    private func makeHoldDurationMenuItem() -> NSMenuItem {
        let menuItem = NSMenuItem()
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 280, height: 62))

        let titleLabel = NSTextField(labelWithString: localized(chinese: "触发时长", english: "Trigger Duration"))
        titleLabel.font = .systemFont(ofSize: 13, weight: .medium)
        titleLabel.frame = NSRect(x: 14, y: 36, width: 170, height: 18)
        container.addSubview(titleLabel)

        let valueLabel = RollingValueLabel(labelWithString: "")
        valueLabel.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        valueLabel.alignment = .right
        valueLabel.frame = NSRect(x: 190, y: 36, width: 76, height: 18)
        valueLabel.update(
            value: CopieSettings.holdDuration,
            text: formattedHoldDuration(CopieSettings.holdDuration),
            animated: false
        )
        container.addSubview(valueLabel)
        holdDurationValueLabel = valueLabel

        let slider = HoldDurationSlider(frame: .zero)
        slider.doubleValue = CopieSettings.holdDuration
        slider.minValue = CopieSettings.minimumHoldDuration
        slider.maxValue = CopieSettings.maximumHoldDuration
        slider.target = self
        slider.action = #selector(changeHoldDuration(_:))
        slider.isContinuous = true
        slider.frame = NSRect(x: 12, y: 7, width: 256, height: 24)
        container.addSubview(slider)

        menuItem.view = container
        return menuItem
    }

    @objc private func changeHoldDuration(_ sender: NSSlider) {
        let roundedValue = (sender.doubleValue * 10).rounded() / 10
        sender.doubleValue = roundedValue
        UserDefaults.standard.set(roundedValue, forKey: CopieSettings.holdDurationKey)
        holdDurationValueLabel?.update(
            value: roundedValue,
            text: formattedHoldDuration(roundedValue)
        )
    }

    @objc private func toggleSelectAll(_ sender: NSMenuItem) {
        let isEnabled = !CopieSettings.isSelectAllEnabled
        UserDefaults.standard.set(isEnabled, forKey: CopieSettings.selectAllEnabledKey)
        sender.state = isEnabled ? .on : .off
        tap.setSelectAllEnabled(isEnabled)
    }

    private func formattedHoldDuration(_ value: TimeInterval) -> String {
        let number = String(format: "%.1f", value)
        return language == .chinese ? "\(number) 秒" : "\(number) s"
    }

    @objc private func showFeatureGuide(_ sender: NSMenuItem) {
        if featureGuidePanel == nil {
            let duration = String(format: "%.1f", CopieSettings.holdDuration)
            featureGuidePanel = makeFeatureGuidePanel(duration: duration)
        }

        if sender.menu != nil {
            shouldPresentFeatureGuideAfterMenuCloses = true
            // menuDidClose is normally immediate, but keep a short fallback for
            // cases where menu tracking ends without delivering the delegate call.
            scheduleFeatureGuidePresentation(after: 0.12)
        } else if let panel = featureGuidePanel {
            presentFeatureGuidePanel(panel)
        }
    }

    func menuDidClose(_ menu: NSMenu) {
        guard shouldPresentFeatureGuideAfterMenuCloses else { return }
        shouldPresentFeatureGuideAfterMenuCloses = false
        scheduleFeatureGuidePresentation(after: 0)
    }

    private func scheduleFeatureGuidePresentation(after delay: TimeInterval) {
        featureGuidePresentationWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self, let panel = self.featureGuidePanel else { return }
            self.shouldPresentFeatureGuideAfterMenuCloses = false
            self.presentFeatureGuidePanel(panel)
        }
        featureGuidePresentationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func makeFeatureGuidePanel(duration: String) -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 400, height: 420),
            styleMask: [.titled, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = false
        panel.collectionBehavior = [.transient, .moveToActiveSpace]
        panel.animationBehavior = .none
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true

        let background = NSVisualEffectView()
        background.material = .popover
        background.blendingMode = .behindWindow
        background.state = .active
        panel.contentView = background

        let appIcon = NSImageView(image: NSApplication.shared.applicationIconImage)
        appIcon.translatesAutoresizingMaskIntoConstraints = false

        let heading = NSTextField(
            labelWithString: localized(chinese: "Copie 功能说明", english: "Copie Features")
        )
        heading.font = .systemFont(ofSize: 15, weight: .semibold)
        heading.alignment = .center
        heading.translatesAutoresizingMaskIntoConstraints = false

        let features = makeFeatureGuideView(duration: duration)
        features.translatesAutoresizingMaskIntoConstraints = false

        let closeButton = NSButton(
            title: localized(chinese: "知道了", english: "Got it"),
            target: self,
            action: #selector(dismissFeatureGuide(_:))
        )
        closeButton.bezelStyle = .rounded
        closeButton.controlSize = .large
        closeButton.keyEquivalent = "\r"
        closeButton.translatesAutoresizingMaskIntoConstraints = false

        [appIcon, heading, features, closeButton].forEach(background.addSubview)
        NSLayoutConstraint.activate([
            appIcon.topAnchor.constraint(equalTo: background.topAnchor, constant: 26),
            appIcon.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            appIcon.widthAnchor.constraint(equalToConstant: 58),
            appIcon.heightAnchor.constraint(equalToConstant: 58),

            heading.topAnchor.constraint(equalTo: appIcon.bottomAnchor, constant: 12),
            heading.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            heading.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),

            features.topAnchor.constraint(equalTo: heading.bottomAnchor, constant: 18),
            features.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            features.widthAnchor.constraint(equalToConstant: 360),
            features.heightAnchor.constraint(equalToConstant: 220),

            closeButton.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 20),
            closeButton.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -20),
            closeButton.bottomAnchor.constraint(equalTo: background.bottomAnchor, constant: -18),
            closeButton.heightAnchor.constraint(equalToConstant: 34)
        ])
        return panel
    }

    private func presentFeatureGuidePanel(_ panel: NSPanel) {
        guard featureGuidePanel === panel else { return }

        NSApp.activate(ignoringOtherApps: true)
        panel.center()

        if panel.isVisible {
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            return
        }

        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            panel.alphaValue = 1
            panel.makeKeyAndOrderFront(nil)
            panel.orderFrontRegardless()
            return
        }

        let finalFrame = panel.frame
        var initialFrame = finalFrame
        initialFrame.origin.y -= 8
        panel.alphaValue = 0
        panel.setFrame(initialFrame, display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(
                controlPoints: 0.22,
                0.80,
                0.20,
                1.00
            )
            panel.animator().alphaValue = 1
            panel.animator().setFrame(finalFrame, display: true)
        }
    }

    @objc private func dismissFeatureGuide(_ sender: NSButton) {
        guard let panel = featureGuidePanel else { return }

        featureGuidePresentationWorkItem?.cancel()
        shouldPresentFeatureGuideAfterMenuCloses = false
        // Release ownership immediately so a fast subsequent menu click creates a
        // fresh panel instead of reviving one whose close animation is still running.
        featureGuidePanel = nil

        let finish = { [weak panel] in
            panel?.orderOut(nil)
            panel?.alphaValue = 1
        }
        guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            finish()
            return
        }

        var finalFrame = panel.frame
        finalFrame.origin.y -= 6
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().alphaValue = 0
            panel.animator().setFrame(finalFrame, display: true)
        } completionHandler: {
            finish()
        }
    }

    private func makeFeatureGuideView(duration: String) -> NSView {
        let features: [(symbol: String, title: String, detail: String)] = [
            (
                "slider.horizontal.3",
                localized(chinese: "调整触发时长", english: "Adjust Trigger Duration"),
                localized(chinese: "拖动滑杆，或悬停后滚动滚轮。", english: "Drag the slider, or hover and use the scroll wheel.")
            ),
            (
                "text.cursor",
                localized(chinese: "输入框长按全选", english: "Hold to Select All"),
                localized(
                    chinese: "在菜单中开启后，在输入框内按住左键 \(duration) 秒并保持不动，即可全选。",
                    english: "Enable it in the menu, then hold still in a text field for \(duration) seconds to select all."
                )
            ),
            (
                "doc.on.doc",
                localized(chinese: "右键快速复制", english: "Right-click to Copy"),
                localized(chinese: "拖动选中文字，然后点击右键。", english: "Select text by dragging, then right-click.")
            ),
            (
                "clipboard",
                localized(chinese: "中键粘贴", english: "Middle-click to Paste"),
                localized(chinese: "点击鼠标中键，粘贴剪贴板内容。", english: "Click the middle mouse button to paste.")
            ),
            (
                "power",
                localized(chinese: "登录时启动", english: "Launch at Login"),
                localized(chinese: "可随时在菜单中开启或关闭。", english: "Turn it on or off from the menu.")
            )
        ]

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 360, height: 220))
        let featureStack = NSStackView()
        featureStack.orientation = .vertical
        featureStack.alignment = .leading
        featureStack.spacing = 10
        featureStack.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(featureStack)

        for feature in features {
            let icon = NSImageView()
            icon.image = NSImage(
                systemSymbolName: feature.symbol,
                accessibilityDescription: feature.title
            )
            icon.contentTintColor = .controlAccentColor
            icon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 15, weight: .medium)
            icon.translatesAutoresizingMaskIntoConstraints = false

            let title = NSTextField(labelWithString: feature.title)
            title.font = .systemFont(ofSize: 13, weight: .semibold)
            title.textColor = .labelColor

            let detail = NSTextField(wrappingLabelWithString: feature.detail)
            detail.font = .systemFont(ofSize: 11.5, weight: .regular)
            detail.textColor = .secondaryLabelColor
            detail.maximumNumberOfLines = 2

            let textStack = NSStackView(views: [title, detail])
            textStack.orientation = .vertical
            textStack.alignment = .leading
            textStack.spacing = 2

            let row = NSStackView(views: [icon, textStack])
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = 11
            featureStack.addArrangedSubview(row)

            NSLayoutConstraint.activate([
                icon.widthAnchor.constraint(equalToConstant: 20),
                icon.heightAnchor.constraint(equalToConstant: 20),
                textStack.widthAnchor.constraint(equalToConstant: 329)
            ])
        }

        NSLayoutConstraint.activate([
            featureStack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            featureStack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            featureStack.topAnchor.constraint(equalTo: container.topAnchor, constant: 4),
            featureStack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor)
        ])
        return container
    }

    @objc private func changeLanguage(_ sender: NSMenuItem) {
        guard let rawValue = sender.representedObject as? String,
              let selectedLanguage = AppLanguage(rawValue: rawValue) else { return }
        language = selectedLanguage
        UserDefaults.standard.set(selectedLanguage.rawValue, forKey: "appLanguage")
        statusItem.menu = buildMenu()
    }

    private func localized(chinese: String, english: String) -> String {
        language == .chinese ? chinese : english
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
                let prefix = localized(chinese: "切换登录时启动失败：", english: "Could not change Launch at Login: ")
                Notifier.shared.show(text: prefix + error.localizedDescription)
            }
        } else {
            Notifier.shared.show(text: localized(chinese: "当前系统不支持登录时启动（需要 macOS 13+）", english: "Launch at Login requires macOS 13 or later"))
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

    func performSelectAll() { sendShortcut(0x00) } // 'a'
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
    private var selectAllHoldDuration: TimeInterval { CopieSettings.holdDuration }
    private let syntheticMouseEventTag: Int64 = 0x434F504945
    private var tap: CFMachPort?
    private var quickCopyArmed = false   // 下一次右键是否触发快速复制
    private var armedAt: CFTimeInterval = 0
    private var leftMouseDownLocation: CGPoint?
    private var leftMouseHeld = false
    private var selectAllTriggered = false
    private var longPressWorkItem: DispatchWorkItem?
    private var longPressGeneration = 0
    private var suppressPhysicalLeftMouseUp = false
    private var mouseSuppressionGeneration = 0

    func start() {
        // 监控：左键长按/拖选、右键、鼠标中键
        let mask: CGEventMask =
            (1 << CGEventType.leftMouseDown.rawValue)    |
            (1 << CGEventType.leftMouseUp.rawValue)      |
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

    func setSelectAllEnabled(_ isEnabled: Bool) {
        guard !isEnabled else { return }
        cancelSelectAll()
        selectAllTriggered = false
    }

    // 返回 true = 继续给系统；false = 吞掉
    private func handle(event: CGEvent, type: CGEventType) -> Bool {
        // macOS disables slow event taps. Re-enable immediately so the app does
        // not silently stop responding until it is relaunched.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return true
        }

        // Pass through the synthetic mouse-up generated by the long-press
        // gesture, then suppress the matching physical drag/up events.
        if type == .leftMouseUp,
           event.getIntegerValueField(.eventSourceUserData) == syntheticMouseEventTag {
            return true
        }
        if suppressPhysicalLeftMouseUp {
            if type == .leftMouseDown || type == .leftMouseDragged { return false }
            if type == .leftMouseUp {
                clearPhysicalMouseSuppression()
                return false
            }
        }

        // 如果前台是 Parallels Desktop，完全放行，避免拦截其快捷键
        if isParallelsFrontmost() { return true }

        switch type {

        case .leftMouseDown:
            quickCopyArmed = false
            leftMouseDownLocation = event.location
            leftMouseHeld = true
            selectAllTriggered = false
            if CopieSettings.isSelectAllEnabled {
                scheduleSelectAll()
            }
            return true

        case .leftMouseDragged:               // 拖动选择中
            guard let downLocation = leftMouseDownLocation else { return true }
            if hasMouseMoved(from: downLocation, to: event.location) {
                cancelSelectAll()
                quickCopyArmed = true
                armedAt = CACurrentMediaTime()
            }
            return true

        case .leftMouseUp:
            cancelSelectAll()
            leftMouseHeld = false
            leftMouseDownLocation = nil
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

    private func hasMouseMoved(from start: CGPoint, to current: CGPoint) -> Bool {
        abs(current.x - start.x) > 0.5 || abs(current.y - start.y) > 0.5
    }

    private func scheduleSelectAll() {
        longPressWorkItem?.cancel()
        longPressGeneration += 1
        let generation = longPressGeneration

        let workItem = DispatchWorkItem { [weak self] in
            guard let self,
                  self.longPressGeneration == generation,
                  self.leftMouseHeld,
                  !self.selectAllTriggered,
                  CopieSettings.isSelectAllEnabled else { return }

            self.longPressWorkItem = nil
            guard let location = self.leftMouseDownLocation,
                  self.isEditableTextInput(at: location) else { return }

            self.selectAllTriggered = true
            self.releaseMouseAndSelectAll()
        }
        longPressWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + selectAllHoldDuration, execute: workItem)
    }

    private func isEditableTextInput(at location: CGPoint) -> Bool {
        let systemWideElement = AXUIElementCreateSystemWide()
        var hitElement: AXUIElement?
        guard AXUIElementCopyElementAtPosition(
            systemWideElement,
            Float(location.x),
            Float(location.y),
            &hitElement
        ) == .success,
        let hitElement else {
            return isWeChatTextInput(at: location)
        }

        var currentElement: AXUIElement? = hitElement
        for _ in 0..<8 {
            guard let element = currentElement else { break }

            if isEditableTextInput(element) {
                return true
            }

            var parentValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                element,
                kAXParentAttribute as CFString,
                &parentValue
            ) == .success,
            let parentValue,
            CFGetTypeID(parentValue) == AXUIElementGetTypeID() else { break }

            currentElement = unsafeBitCast(parentValue, to: AXUIElement.self)
        }
        return isWeChatTextInput(at: location)
    }

    /// WeChat 4.x draws its search field and chat composer itself and returns
    /// `kAXErrorNotImplemented` for element-at-position queries. Its top-level
    /// window geometry is still exposed, so narrowly recognize only those two
    /// editable areas in the frontmost WeChat window.
    private func isWeChatTextInput(at location: CGPoint) -> Bool {
        guard let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier == "com.tencent.xinWeChat" else { return false }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        let windows: [AXUIElement]
        var focusedWindowValue: CFTypeRef?
        if AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedWindowAttribute as CFString,
            &focusedWindowValue
        ) == .success,
        let focusedWindowValue,
        CFGetTypeID(focusedWindowValue) == AXUIElementGetTypeID() {
            windows = [unsafeBitCast(focusedWindowValue, to: AXUIElement.self)]
        } else {
            var windowsValue: CFTypeRef?
            guard AXUIElementCopyAttributeValue(
                appElement,
                kAXWindowsAttribute as CFString,
                &windowsValue
            ) == .success,
            let allWindows = windowsValue as? [AXUIElement] else { return false }
            windows = allWindows
        }

        for window in windows {
            guard let frame = frame(of: window),
                  frame.width > 500,
                  frame.height > 400,
                  frame.contains(location) else { continue }

            let windowTitle = stringAttribute(kAXTitleAttribute, of: window) ?? ""
            if windowTitle == "微信 (窗口)" {
                let navigationSearchField = CGRect(
                    x: frame.minX + frame.width * 0.165,
                    y: frame.minY + 3,
                    width: frame.width * 0.22,
                    height: 38
                )
                let pageSearchField = CGRect(
                    x: frame.minX + frame.width * 0.085,
                    y: frame.minY + 60,
                    width: frame.width * 0.56,
                    height: 50
                )
                return navigationSearchField.contains(location)
                    || pageSearchField.contains(location)
            }

            guard windowTitle == "微信" else { return false }
            let leftPanelsWidth = min(300, frame.width * 0.38)
            let composerHeight = min(150, frame.height * 0.24)
            let bottomToolbarHeight: CGFloat = 38
            let isInComposer = location.x >= frame.minX + leftPanelsWidth
                && location.y >= frame.maxY - composerHeight
                && location.y <= frame.maxY - bottomToolbarHeight
            let searchField = CGRect(
                x: frame.minX + 65,
                y: frame.minY + 8,
                width: min(195, frame.width * 0.25),
                height: 40
            )
            return isInComposer || searchField.contains(location)
        }
        return false
    }

    private func frame(of element: AXUIElement) -> CGRect? {
        var rawPosition: CFTypeRef?
        var rawSize: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &rawPosition
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &rawSize
        ) == .success,
        let rawPosition,
        let rawSize,
        CFGetTypeID(rawPosition) == AXValueGetTypeID(),
        CFGetTypeID(rawSize) == AXValueGetTypeID() else { return nil }

        let positionValue = unsafeBitCast(rawPosition, to: AXValue.self)
        let sizeValue = unsafeBitCast(rawSize, to: AXValue.self)
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionValue, .cgPoint, &position),
              AXValueGetValue(sizeValue, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func isEditableTextInput(_ element: AXUIElement) -> Bool {
        guard let role = stringAttribute(kAXRoleAttribute, of: element) else { return false }
        let textRoles = [
            kAXTextFieldRole as String,
            kAXTextAreaRole as String,
            kAXComboBoxRole as String
        ]
        let isSearchField = stringAttribute(kAXSubroleAttribute, of: element) == "AXSearchField"
        guard textRoles.contains(role) || isSearchField else { return false }

        if let enabled = boolAttribute(kAXEnabledAttribute, of: element), !enabled {
            return false
        }

        for attribute in [kAXValueAttribute, kAXSelectedTextRangeAttribute] {
            var settable = DarwinBoolean(false)
            if AXUIElementIsAttributeSettable(
                element,
                attribute as CFString,
                &settable
            ) == .success,
            settable.boolValue {
                return true
            }
        }
        return false
    }

    private func stringAttribute(_ attribute: String, of element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? String
    }

    private func boolAttribute(_ attribute: String, of element: AXUIElement) -> Bool? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }
        return value as? Bool
    }

    private func releaseMouseAndSelectAll() {
        guard let downLocation = leftMouseDownLocation,
              let source = CGEventSource(stateID: .combinedSessionState),
              let mouseUp = CGEvent(
                mouseEventSource: source,
                mouseType: .leftMouseUp,
                mouseCursorPosition: CGEvent(source: nil)?.location ?? downLocation,
                mouseButton: .left
              ) else {
            CopieActions.shared.performSelectAll()
            return
        }

        suppressPhysicalLeftMouseUp = true
        mouseSuppressionGeneration += 1
        let suppressionGeneration = mouseSuppressionGeneration
        leftMouseHeld = false
        leftMouseDownLocation = nil
        longPressGeneration += 1

        mouseUp.setIntegerValueField(.eventSourceUserData, value: syntheticMouseEventTag)
        mouseUp.post(tap: .cghidEventTap)

        // Give the target app one run-loop turn to finish handling mouse-up.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            CopieActions.shared.performSelectAll()
        }
        monitorPhysicalMouseRelease(generation: suppressionGeneration)
    }

    private func monitorPhysicalMouseRelease(generation: Int) {
        guard suppressPhysicalLeftMouseUp,
              mouseSuppressionGeneration == generation else { return }

        if !CGEventSource.buttonState(.hidSystemState, button: .left) {
            clearPhysicalMouseSuppression()
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.01) { [weak self] in
            self?.monitorPhysicalMouseRelease(generation: generation)
        }
    }

    private func clearPhysicalMouseSuppression() {
        suppressPhysicalLeftMouseUp = false
        mouseSuppressionGeneration += 1
        cancelSelectAll()
        leftMouseHeld = false
        leftMouseDownLocation = nil
    }

    private func cancelSelectAll() {
        longPressWorkItem?.cancel()
        longPressWorkItem = nil
        longPressGeneration += 1
    }
}
