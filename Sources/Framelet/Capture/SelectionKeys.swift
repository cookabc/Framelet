import Carbon

/// Receives only the selector's commands without making its panels key or requesting input monitoring.
/// Registrations exist only while choosing, so Return and Escape go back to other apps afterwards.
@MainActor
final class SelectionKeys {
    enum Command: UInt32 {
        case confirm = 1
        case cancel = 2
        case keypadConfirm = 3
    }

    private static let signature: OSType = 0x4653_454C
    private var handler: EventHandlerRef?
    private var keys: [EventHotKeyRef] = []
    private var action: ((Command) -> Void)?

    func start(action: @escaping (Command) -> Void) -> Set<Command> {
        stop()
        self.action = action
        var type = EventTypeSpec(
            eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let status = InstallEventHandler(
            GetApplicationEventTarget(),
            { _, event, context in
                guard let event, let context else { return OSStatus(eventNotHandledErr) }
                var id = EventHotKeyID()
                guard
                    GetEventParameter(
                        event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                        nil, MemoryLayout<EventHotKeyID>.size, nil, &id) == noErr,
                    id.signature == SelectionKeys.signature,
                    let command = Command(rawValue: id.id)
                else { return OSStatus(eventNotHandledErr) }
                let owner = Unmanaged<SelectionKeys>.fromOpaque(context).takeUnretainedValue()
                // Defer teardown until the Carbon callback has returned.
                Task { @MainActor [weak owner] in owner?.action?(command) }
                return noErr
            }, 1, &type, Unmanaged.passUnretained(self).toOpaque(), &handler)
        guard status == noErr else { return [] }
        var registered: Set<Command> = []
        for (command, code) in [
            (Command.confirm, kVK_Return), (.cancel, kVK_Escape), (.keypadConfirm, kVK_ANSI_KeypadEnter),
        ] {
            var key: EventHotKeyRef?
            if RegisterEventHotKey(
                UInt32(code), 0, EventHotKeyID(signature: Self.signature, id: command.rawValue),
                GetApplicationEventTarget(), OptionBits(kEventHotKeyExclusive), &key) == noErr,
                let key
            {
                keys.append(key)
                registered.insert(command)
            }
        }
        return registered
    }

    func stop() {
        action = nil
        for key in keys { UnregisterEventHotKey(key) }
        keys.removeAll()
        if let handler { RemoveEventHandler(handler) }
        handler = nil
    }

    deinit {
        // `stop` already tears everything down on the main thread on every real path; this only
        // guards the ones that skip it. Carbon registration belongs on the main thread and deinit
        // has no isolation guarantee, so hop over unless already there.
        let leftovers = Leftovers(keys: keys, handler: handler)
        if Thread.isMainThread {
            leftovers.tearDown()
        } else {
            DispatchQueue.main.async { leftovers.tearDown() }
        }
    }

    /// Carries the registrations across to the main queue. The Carbon references only have to be
    /// released on the main thread and are never dereferenced here, so the box exists to make the
    /// closure handed to `DispatchQueue.main.async` sendable.
    private struct Leftovers: @unchecked Sendable {
        let keys: [EventHotKeyRef]
        let handler: EventHandlerRef?

        func tearDown() {
            for key in keys { UnregisterEventHotKey(key) }
            if let handler { RemoveEventHandler(handler) }
        }
    }
}
