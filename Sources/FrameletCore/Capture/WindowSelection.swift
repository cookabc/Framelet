import CoreGraphics
import Foundation

public struct WindowCandidate: Equatable {
    public let id: UInt32
    public let ownerPID: Int32
    public let frame: CGRect
    public let title: String
    /// Menu-level windows such as a menu bar dropdown. ScreenCaptureKit does not list them, so they
    /// can only be recorded as an area of the screen, not as a window.
    public let isMenu: Bool
    public init(id: UInt32, ownerPID: Int32, frame: CGRect, title: String, isMenu: Bool = false) {
        self.id = id
        self.ownerPID = ownerPID
        self.frame = frame
        self.title = title
        self.isMenu = isMenu
    }
}

public enum WindowSelection {
    public static func displayTitle(application: String, window: String?) -> String {
        let app = application.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let title = window?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            return app
        }
        if title.compare(app, options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame {
            return title
        }
        return app.isEmpty ? title : app + " · " + title
    }

    /// Owners whose menu-level windows are system chrome, not content a user would record.
    static let systemOwners: Set<String> = ["Window Server", "Dock", "WindowManager"]

    public static func appKitRect(fromQuartz rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }

    /// A layer between normal windows and the pop-up menu level. Everything above the menu level is
    /// our own overlay or the cursor, so it is excluded.
    public static func isMenuLevel(_ layer: Int) -> Bool {
        layer > 0 && layer <= Int(CGWindowLevelForKey(.popUpMenuWindow))
    }

    /// Whether a menu-level window owned by `owner` can be chosen. The menu bar, the Dock and the
    /// window manager sit at menu levels too, but they are chrome rather than something to record.
    public static func acceptsMenu(layer: Int, owner: String) -> Bool {
        isMenuLevel(layer) && !systemOwners.contains(owner)
    }

    /// Candidates must be in WindowServer front-to-back order; smallest-window heuristics pick obscured windows.
    public static func hit(at point: CGPoint, candidates: [WindowCandidate]) -> WindowCandidate? {
        candidates.first { $0.frame.contains(point) }
    }
}
