import Carbon

/// The shortcuts are registered as exclusive global hot keys, so they have to carry enough
/// modifiers to stay out of the way of the frontmost app's own menu commands.
///
/// Control-Command is the floor: a bare Command-R style shortcut would be taken away from every
/// app on the system, and Control is the modifier ordinary app menus rarely bind. Option is
/// deliberately left out — Control-Option-R belongs to Rectangle's centre-two-thirds shortcut.
enum RecorderShortcuts {
    static let signature: OSType = 0x4652_4D4C
    static let modifiers = UInt32(controlKey | cmdKey)
    static let captureKey = UInt32(kVK_ANSI_R)
    static let pauseKey = UInt32(kVK_ANSI_P)
    static let captureLabel = "⌃⌘R"
    static let pauseLabel = "⌃⌘P"
}
