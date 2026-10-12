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
        window.title = "Framelet"
        window.titlebarAppearsTransparent = true
        window.backgroundColor = NSColor(red: 0.97, green: 0.97, blue: 0.94, alpha: 1)
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 880, height: 678)
        window.contentView = NSHostingView(rootView: MainView(model: model))
        // Reopen where the user left it; only a first run starts centred.
        if !window.setFrameUsingName("FrameletMainWindow") { window.center() }
        window.setFrameAutosaveName("FrameletMainWindow")
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
        Task { await model.recoverUnfinishedSessions() }
    }

    private func buildMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Framelet", action: #selector(about), keyEquivalent: "").target =
            self
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide Framelet", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(
            withTitle: "Quit Framelet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(withTitle: "New Recording", action: #selector(toggleRecording), keyEquivalent: "n")
            .target =
            self
        fileMenu.addItem(withTitle: "Show Main Window", action: #selector(showWindow), keyEquivalent: "0")
            .target = self
        fileItem.submenu = fileMenu
        main.addItem(fileItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
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
        // Both keys share one modifier set, so try whole sets in order and keep the first whose
        // keys are both free. Registering a combination another app already owns fails, which is
        // how a conflict is detected rather than guessed at.
        for candidate in RecorderShortcuts.modifierSets {
            let capture = RegisterEventHotKey(
                RecorderShortcuts.captureKey, candidate.modifiers,
                EventHotKeyID(signature: RecorderShortcuts.signature, id: 1), GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive), &hotKey)
            guard capture == noErr else { continue }
            let pause = RegisterEventHotKey(
                RecorderShortcuts.pauseKey, candidate.modifiers,
                EventHotKeyID(signature: RecorderShortcuts.signature, id: 2), GetApplicationEventTarget(),
                OptionBits(kEventHotKeyExclusive), &pauseHotKey)
            guard pause == noErr else {
                // Hand the record key back before trying the next set.
                if let registered = hotKey { UnregisterEventHotKey(registered) }
                hotKey = nil
                continue
            }
            RecorderShortcuts.select(candidate)
            if candidate.modifiers != RecorderShortcuts.preferred.modifiers {
                model.notice =
                    "Another app owns \(RecorderShortcuts.preferred.captureLabel), so recording uses "
                    + "\(candidate.captureLabel) and \(candidate.pauseLabel)."
            }
            return
        }
        model.notice =
            "Every recording shortcut is taken by another app. Use the buttons instead, or quit the app holding it."
    }

    private func refreshStatus() {
        let recording = model.hasActiveRecording
        statusItem?.button?.image = NSImage(
            systemSymbolName: model.phase == .paused
                ? "pause.circle.fill" : recording ? "record.circle.fill" : "viewfinder",
            accessibilityDescription: "Framelet")
        statusItem?.button?.contentTintColor =
            model.phase == .paused ? .systemOrange : recording ? .systemRed : nil
        statusItem?.button?.toolTip = "Framelet · \(RecorderShortcuts.captureLabel) start / stop"
    }

    func menuWillOpen(_ menu: NSMenu) {
        menu.removeAllItems()
        let title: String
        switch model.phase {
        case .recording: title = "Stop Recording  \(model.formattedElapsed)"
        case .paused: title = "Stop and Save  \(model.formattedElapsed)"
        case .restarting: title = "Saving, then restarting…"
        case .selecting: title = "Cancel Selection"
        case .countdown: title = "Cancel Recording"
        case .starting: title = "Starting…"
        case .stopping: title = "Saving…"
        case .idle: title = "New Recording  \(RecorderShortcuts.captureLabel)"
        }
        let item = menu.addItem(
            withTitle: title,
            action: model.phase == .selecting ? #selector(cancelSelection) : #selector(toggleRecording),
            keyEquivalent: "")
        item.target = self
        if model.canControlRecording {
            menu.addItem(
                withTitle: (model.phase == .paused ? "Resume Recording  " : "Pause Recording  ")
                    + RecorderShortcuts.pauseLabel,
                action: #selector(togglePause), keyEquivalent: ""
            ).target = self
            menu.addItem(
                withTitle: "Save and Record Again", action: #selector(restartRecording), keyEquivalent: ""
            )
            .target = self
        }
        menu.addItem(withTitle: "Show Main Window", action: #selector(showWindow), keyEquivalent: "").target =
            self
        menu.addItem(.separator())
        menu.addItem(
            withTitle: "Quit Framelet", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    @objc private func toggleRecording() { model.toggleCapture() }
    @objc private func cancelSelection() { model.cancelSelection() }
    @objc private func togglePause() { model.togglePause() }
    @objc private func restartRecording() { model.restartRecording() }
    @objc private func showWindow() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    @objc private func about() {
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "Framelet",
            .applicationVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "Development build",
            .credits: NSAttributedString(string: "Window and area screen recording"),
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
            model.errorMessage =
                "A recording or an export is still running. Stop the recording or cancel the export, then quit."
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
