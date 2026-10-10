import AppKit
import FrameletCore
import ScreenCaptureKit

@MainActor
final class RegionSelector {
    private var windows: [NSWindow] = []
    private var completion: ((CaptureRegion?) -> Void)?
    private var confirmationTask: Task<Void, Never>?

    func begin(completion: @escaping (CaptureRegion?) -> Void) async throws {
        try Task.checkCancellation()
        self.completion = completion
        let content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        try Task.checkCancellation()
        guard self.completion != nil else { return }
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        let shareable = Dictionary(uniqueKeysWithValues: content.windows.map { ($0.windowID, $0) })
        let descriptions =
            CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        let candidates: [WindowCandidate] = descriptions.compactMap { item in
            guard let id = (item[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                let layer = (item[kCGWindowLayer as String] as? NSNumber)?.intValue,
                let owner = item[kCGWindowOwnerName as String] as? String,
                let bounds = item[kCGWindowBounds as String] as? [String: Any],
                let quartz = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                quartz.width >= 24, quartz.height >= 24,
                (item[kCGWindowAlpha as String] as? Double ?? 1) > 0
            else { return nil }
            // Menu-level windows (dropdowns) are not in ScreenCaptureKit's list, so they are accepted
            // from the WindowServer list alone and recorded as an area.
            let isMenu = WindowSelection.acceptsMenu(layer: layer, owner: owner)
            if !isMenu {
                guard let window = shareable[id], window.windowLayer == 0,
                    let app = window.owningApplication,
                    app.processID != ProcessInfo.processInfo.processIdentifier
                else { return nil }
                let title = window.title.flatMap { $0.isEmpty ? nil : $0 }
                return WindowCandidate(
                    id: id, ownerPID: app.processID,
                    frame: WindowSelection.appKitRect(fromQuartz: quartz, primaryTop: primaryTop),
                    title: app.applicationName + (title.map { " · " + $0 } ?? ""))
            }
            guard let pid = (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                pid != ProcessInfo.processInfo.processIdentifier
            else { return nil }
            return WindowCandidate(
                id: id, ownerPID: pid,
                frame: WindowSelection.appKitRect(fromQuartz: quartz, primaryTop: primaryTop),
                title: owner + " · Menu", isMenu: true)
        }
        for screen in NSScreen.screens {
            let window = SelectionPanel(frame: screen.frame)
            window.setFrame(screen.frame, display: true)
            window.level = .screenSaver
            window.isOpaque = false
            window.backgroundColor = NSColor.black.withAlphaComponent(0.02)
            window.hasShadow = false
            window.acceptsMouseMovedEvents = true
            window.isReleasedWhenClosed = false
            window.collectionBehavior = [
                .canJoinAllSpaces, .canJoinAllApplications, .fullScreenAuxiliary, .fullScreenDisallowsTiling,
                .stationary, .ignoresCycle,
            ]
            let view = SelectionView(frame: CGRect(origin: .zero, size: screen.frame.size))
            view.screenOrigin = screen.frame.origin
            view.candidates = candidates
            view.onCancel = { [weak self] in self?.cancel() }
            view.onSelect = { [weak self] rect in
                self?.finish(
                    CaptureRegion(
                        screen: screen, rect: rect.offsetBy(dx: screen.frame.minX, dy: screen.frame.minY)))
            }
            view.onWindowSelect = { [weak self] candidate in
                self?.finish(
                    CaptureRegion(
                        screen: screen, rect: candidate.frame, windowID: candidate.id,
                        ownerPID: candidate.ownerPID, title: candidate.title))
            }
            window.contentView = view
            window.makeFirstResponder(view)
            window.orderFrontRegardless()
            view.updateHover(globalPoint: NSEvent.mouseLocation)
            windows.append(window)
        }
        (windows.first { $0.frame.contains(NSEvent.mouseLocation) } ?? windows.first)?.makeKey()
    }

    func cancel() { finish(nil) }

    private func finish(_ region: CaptureRegion?) {
        guard completion != nil else { return }
        if let region {
            guard confirmationTask == nil else { return }
            // Consume the second click before removing the overlay; otherwise a double-click
            // can reach the target title bar and unzoom the window after confirmation.
            confirmationTask = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(NSEvent.doubleClickInterval)) } catch { return }
                self?.closeAndComplete(region)
            }
        } else {
            confirmationTask?.cancel()
            closeAndComplete(nil)
        }
    }

    private func closeAndComplete(_ region: CaptureRegion?) {
        let callback = completion
        completion = nil
        confirmationTask = nil
        for window in windows {
            window.orderOut(nil)
            window.close()
        }
        windows.removeAll()
        NSCursor.arrow.set()
        callback?(region)
    }
}
