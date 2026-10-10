import Carbon

/// The shortcuts are registered as exclusive global hot keys, so they need enough modifiers to stay
/// out of the way of the frontmost app's own menu commands — and a way to cope when another app
/// already owns the combination.
enum RecorderShortcuts {
    static let signature: OSType = 0x4652_4D4C
    static let captureKey = UInt32(kVK_ANSI_R)
    static let pauseKey = UInt32(kVK_ANSI_P)

    /// One modifier combination, shared by both keys so the pair always stays consistent.
    struct ModifierSet {
        let modifiers: UInt32
        let captureLabel: String
        let pauseLabel: String
    }

    /// Tried in order until a set registers both keys. Command has to be present, because a bare
    /// Command combination would be taken away from every app on the system. Control is the
    /// modifier ordinary app menus rarely bind. No set is exactly Control-Option, since
    /// Control-Option-R belongs to Rectangle's centre-two-thirds shortcut.
    static let modifierSets: [ModifierSet] = [
        ModifierSet(modifiers: UInt32(optionKey | cmdKey), captureLabel: "⌥⌘R", pauseLabel: "⌥⌘P"),
        ModifierSet(modifiers: UInt32(controlKey | cmdKey), captureLabel: "⌃⌘R", pauseLabel: "⌃⌘P"),
        ModifierSet(
            modifiers: UInt32(controlKey | shiftKey | cmdKey), captureLabel: "⌃⇧⌘R",
            pauseLabel: "⌃⇧⌘P"),
    ]

    /// Whichever set actually registered. Reported by the interface rather than assumed, so a
    /// fallback is never presented as the preferred combination.
    @MainActor private(set) static var captureLabel = modifierSets[0].captureLabel
    @MainActor private(set) static var pauseLabel = modifierSets[0].pauseLabel

    @MainActor static func select(_ set: ModifierSet) {
        captureLabel = set.captureLabel
        pauseLabel = set.pauseLabel
    }

    static var preferred: ModifierSet { modifierSets[0] }
}
