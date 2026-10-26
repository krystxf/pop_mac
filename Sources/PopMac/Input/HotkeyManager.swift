import Carbon
import PopCore

/// Registers system-wide hot keys through Carbon.
///
/// Carbon hot keys need no extra permission, and they consume the key press,
/// so the focused application never sees it.
final class HotkeyManager {
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var nextID: UInt32 = 1
    private var eventHandler: EventHandlerRef?
    private static let signature: OSType = 0x504F_504D // "POPM"

    init() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let callback: EventHandlerUPP = { _, event, userData in
            guard let event, let userData else { return OSStatus(eventNotHandledErr) }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(
                event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID
            )
            guard status == noErr else { return status }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userData).takeUnretainedValue()
            manager.handlers[hotKeyID.id]?()
            return noErr
        }
        InstallEventHandler(GetApplicationEventTarget(), callback, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), &eventHandler)
    }

    deinit {
        unregisterAll()
        if let eventHandler { RemoveEventHandler(eventHandler) }
    }

    /// Registers a key combination. Returns false if the key is unknown or taken.
    @discardableResult
    func register(_ combo: KeyCombo, handler: @escaping () -> Void) -> Bool {
        guard let code = KeyCodes.code(for: combo.key) else {
            Log.warn("unknown key name: \(combo.key)")
            return false
        }

        var modifiers: UInt32 = 0
        if combo.modifiers.contains(.command) { modifiers |= UInt32(cmdKey) }
        if combo.modifiers.contains(.option) { modifiers |= UInt32(optionKey) }
        if combo.modifiers.contains(.control) { modifiers |= UInt32(controlKey) }
        if combo.modifiers.contains(.shift) { modifiers |= UInt32(shiftKey) }

        let id = nextID
        nextID += 1
        var ref: EventHotKeyRef?
        let status = RegisterEventHotKey(code, modifiers, EventHotKeyID(signature: Self.signature, id: id), GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else {
            Log.warn("could not register \(combo) (status \(status))")
            return false
        }
        refs[id] = ref
        handlers[id] = handler
        return true
    }

    func unregisterAll() {
        for ref in refs.values {
            UnregisterEventHotKey(ref)
        }
        refs.removeAll()
        handlers.removeAll()
    }
}
