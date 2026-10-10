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
        for key in keys { UnregisterEventHotKey(key) }
        if let handler { RemoveEventHandler(handler) }
    }
}
