import AppKit
import PopCore

/// Catches system-wide key bindings with a keyboard event tap.
///
/// The tap consumes a matching key press, so the focused application never
/// sees it. It needs Accessibility access, which Pop Mac needs anyway.
/// Unlike Carbon hot keys, a tap also sees synthetic key events and key repeats.
final class HotkeyManager {
    private struct Binding: Hashable {
        let code: Int64
        let modifiers: UInt64
    }

    private var handlers: [Binding: (handler: () -> Void, repeats: Bool)] = [:]
    /// Key codes whose key-down was consumed, so their key-up is consumed too.
    private var swallowed = Set<Int64>()
    private var tap: CFMachPort?

    private static let modifierMask = CGEventFlags.modifiers.rawValue

    init() {
        installTap()
    }

    deinit {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
    }

    private func installTap() {
        let mask = CGEventMask(1 << CGEventType.keyDown.rawValue) | CGEventMask(1 << CGEventType.keyUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            let manager = Unmanaged<HotkeyManager>.fromOpaque(userInfo).takeUnretainedValue()
            return manager.handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.warn("could not create the keyboard event tap")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetMain(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow tap off. Turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let binding = Binding(code: code, modifiers: event.flags.rawValue & Self.modifierMask)
            guard let entry = handlers[binding] else { return Unmanaged.passUnretained(event) }
            swallowed.insert(code)
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat || entry.repeats {
                // Run the action after the tap returns, so the tap stays fast.
                DispatchQueue.main.async(execute: entry.handler)
            }
            return nil
        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            return swallowed.remove(code) != nil ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Registers a key combination. Returns false if the key name is unknown.
    @discardableResult
    func register(_ combo: KeyCombo, repeats: Bool = false, handler: @escaping () -> Void) -> Bool {
        guard let code = KeyCodes.code(for: combo.key) else {
            Log.warn("unknown key name: \(combo.key)")
            return false
        }

        let binding = Binding(code: Int64(code), modifiers: CGEventFlags(modifiers: combo.modifiers).rawValue)
        if handlers[binding] != nil {
            Log.warn("\(combo) is bound twice; the last binding wins")
        }
        handlers[binding] = (handler, repeats)
        return true
    }

    func unregisterAll() {
        handlers.removeAll()
    }
}

extension CGEventFlags {
    /// The modifier keys that key bindings look at.
    static let modifiers: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]

    init(modifiers: some Sequence<MacModifier>) {
        self = []
        for modifier in modifiers {
            switch modifier {
            case .command: insert(.maskCommand)
            case .option: insert(.maskAlternate)
            case .control: insert(.maskControl)
            case .shift: insert(.maskShift)
            }
        }
    }
}
