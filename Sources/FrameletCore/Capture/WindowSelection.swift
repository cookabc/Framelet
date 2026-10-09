import CoreGraphics

public struct WindowCandidate: Equatable {
    public let id: UInt32
    public let ownerPID: Int32
    public let frame: CGRect
    public let title: String
    public init(id: UInt32, ownerPID: Int32, frame: CGRect, title: String) {
        self.id = id
        self.ownerPID = ownerPID
        self.frame = frame
        self.title = title
    }
}

public enum WindowSelection {
    public static func appKitRect(fromQuartz rect: CGRect, primaryTop: CGFloat) -> CGRect {
        CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height)
    }
    /// Candidates must be in WindowServer front-to-back order; smallest-window heuristics pick obscured windows.
    public static func hit(at point: CGPoint, candidates: [WindowCandidate]) -> WindowCandidate? {
        candidates.first { $0.frame.contains(point) }
    }
}
