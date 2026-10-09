import AppKit
import Carbon
import SwiftUI

@main
enum FrameletMain {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = RecorderModel()
    private var window: NSWindow!
    private var statusItem: NSStatusItem!
    private var hotKey: EventHotKeyRef?
    private var pauseHotKey: EventHotKeyRef?
    private var eventHandler: EventHandlerRef?

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMenu()
        window = NSWindow(
            contentRect: CGRect(x: 0, y: 0, width: 940, height: 680),
            styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "录屏"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.97, green: 0.97, blue: 0.94, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 880, height: 678)
        window.contentView = NSHostingView(rootView: MainView(model: model))
        window.center()
        model.mainWindow = window
        model.showWindow = { [weak self] in self?.showWindow() }
        model.onPhaseChange = { [weak self] in self?.refreshStatus() }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshStatus()
        registerHotKey()
        showWindow()
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "关于录屏", action: #selector(about), keyEquivalent: "").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "隐藏录屏", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "退出录屏", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "文件")
        fileMenu.addItem(withTitle: "新建录制", action: #selector(toggleRecording), keyEquivalent: "n").target =
            self
        fileMenu.addItem(withTitle: "显示主窗口", action: #selector(showWindow), keyEquivalent: "0").target = self
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "编辑")
        editMenu.addItem(withTitle: "剪切", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "复制", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "粘贴", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "全选", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private func registerHotKey() {
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, userData in
                guard let userData, let event else { return noErr }
                let delegate = Unmanaged<AppDelegate>.fromOpaque(userData).takeUnretainedValue()
                var pressed = EventHotKeyID()
                guard
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                        nil,
                        MemoryLayout<EventHotKeyID>.size, nil, &pressed) == noErr
                else { return noErr }
                guard pressed.signature == RecorderShortcuts.signature else { return noErr }
                let isPause = pressed.id == 2
                Task { @MainActor in
                    if isPause { delegate.model.togglePause() } else { delegate.model.toggleCapture() }
                }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
        let id = EventHotKeyID(signature: RecorderShortcuts.signature, id: 1)
        let result = RegisterEventHotKey(
            RecorderShortcuts.captureKey, RecorderShortcuts.modifiers, id, GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &hotKey)
        if result != noErr { model.notice = "录制快捷键已被占用，请使用按钮。" }
        let pauseResult = RegisterEventHotKey(
            RecorderShortcuts.pauseKey, RecorderShortcuts.modifiers,
            EventHotKeyID(signature: RecorderShortcuts.signature, id: 2), GetApplicationEventTarget(),
            OptionBits(kEventHotKeyExclusive), &pauseHotKey)
        if pauseResult != noErr { model.notice = "暂停快捷键已被占用，请使用按钮。" }
    }

    private func refreshStatus() {
        let recording = model.hasActiveRecording
        statusItem?.button?.image = NSImage(
            systemSymbolName: model.phase == .paused
                ? "pause.circle.fill" : recording ? "record.circle.fill" : "viewfinder",
            accessibilityDescription: "Framelet")
        statusItem?.button?.contentTintColor =
            model.phase == .paused ? .systemOrange : recording ? .systemRed : nil
        statusItem?.button?.toolTip = "录屏 · \(RecorderShortcuts.captureLabel) 开始／停止"
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let title: String
        switch model.phase {
        case .recording: title = "停止录制  \(model.formattedElapsed)"
        case .paused: title = "停止并保存  \(model.formattedElapsed)"
        case .pausing: title = "正在暂停…"
        case .restarting: title = "保存后重新录制…"
        case .countdown, .selecting: title = "取消录制"
        case .starting: title = "正在启动…"
        case .stopping: title = "正在保存…"
        case .idle: title = "新建录制  \(RecorderShortcuts.captureLabel)"
        }
        let item = menu.addItem(withTitle: title, action: #selector(toggleRecording), keyEquivalent: "")
        item.target = self
        if model.canControlRecording {
            menu.addItem(
                withTitle: (model.phase == .paused ? "继续录制  " : "暂停录制  ") + RecorderShortcuts.pauseLabel,
                action: #selector(togglePause), keyEquivalent: ""
            ).target = self
            menu.addItem(withTitle: "保存当前并重新录制", action: #selector(restartRecording), keyEquivalent: "")
                .target = self
        }
        menu.addItem(withTitle: "显示主窗口", action: #selector(showWindow), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "退出录屏", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleRecording() { model.toggleCapture() }
    @objc private func togglePause() { model.togglePause() }
    @objc private func restartRecording() { model.restartRecording() }
    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "录屏",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "开发版",
            .credits: NSAttributedString(string: "窗口与区域录制"),
        ])
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Reopening the app while picking must not obscure the picker or switch out of the target Space.
        guard model.phase != .selecting, !model.isCountingDown else { return false }
        showWindow()
        return true
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if model.phase == .selecting || model.isCountingDown { model.cancelSelection() }
        guard !model.busy else {
            showWindow()
            model.errorMessage = "录制或导出尚未结束。请先停止录制，或等待 / 取消导出，然后退出。"
            return .terminateCancel
        }
        return .terminateNow
    }
    func applicationWillTerminate(_ notification: Notification) {
        if let hotKey { UnregisterEventHotKey(hotKey) }
        if let pauseHotKey { UnregisterEventHotKey(pauseHotKey) }
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }
}
