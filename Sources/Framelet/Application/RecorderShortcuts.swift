import Carbon

enum RecorderShortcuts {
    static let signature: OSType = 0x4652_4D4C
    // Control-Option-R is Rectangle's center-two-thirds shortcut. Do not register it.
    static let modifiers = UInt32(controlKey | shiftKey | cmdKey)
    static let captureKey = UInt32(kVK_ANSI_R)
    static let pauseKey = UInt32(kVK_ANSI_P)
    static let captureLabel = "⌃⇧⌘R"
    static let pauseLabel = "⌃⇧⌘P"
}
