import AppKit
import os
import PopCore

/// Catches system-wide key bindings with a keyboard event tap.
///
/// The tap consumes a matching key press, so the focused application never
/// sees it. It needs Accessibility access, which Pop Mac needs anyway.
/// Unlike Carbon hot keys, a tap also sees synthetic key events and key repeats.
///
/// macOS holds every key press of every app until the tap answers. So the tap has
/// its own thread, and only looks the key up: typing never waits for the main
/// thread, which can be busy with a slow app. The actions run on the main thread.
final class HotkeyManager: @unchecked Sendable {
    /// A key combination and what it does.
    struct Entry {
        let combo: KeyCombo
        /// True if the action runs again while the key is held down.
        let repeats: Bool
        let handler: @MainActor () -> Void
    }

    private struct Binding: Hashable {
        let code: Int64
        let modifiers: UInt64
    }

    private struct State {
        var handlers: [Binding: Entry] = [:]
        /// Key codes whose key-down was consumed, so their key-up is consumed too.
        var swallowed = Set<Int64>()
    }

    /// The main thread writes the bindings, and the tap's thread reads them.
    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    private var tap: CFMachPort?

    private static let modifierMask = CGEventFlags.modifiers.rawValue

    init() {
        installTap()
    }

    deinit {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        // Its thread's run loop has no other source, so the thread ends.
        CFMachPortInvalidate(tap)
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

        let thread = Thread {
            CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
            CFRunLoopRun()
        }
        thread.name = "dev.krystof.popmac.hotkeys"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Runs on the tap's thread.
    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turned the tap off. Turn it back on. The key-ups that passed meanwhile
            // went to their apps, so nothing waits to be consumed.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            state.withLockUnchecked { $0.swallowed.removeAll() }
            return Unmanaged.passUnretained(event)
        case .keyDown:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let binding = Binding(code: code, modifiers: event.flags.rawValue & Self.modifierMask)
            let entry = state.withLockUnchecked { state -> Entry? in
                guard let entry = state.handlers[binding] else {
                    // The app gets this key-down, so it gets the key-up too.
                    state.swallowed.remove(code)
                    return nil
                }
                state.swallowed.insert(code)
                return entry
            }
            guard let entry else { return Unmanaged.passUnretained(event) }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            if !isRepeat || entry.repeats {
                DispatchQueue.main.async { MainActor.assumeIsolated(entry.handler) }
            }
            return nil
        case .keyUp:
            let code = event.getIntegerValueField(.keyboardEventKeycode)
            let swallowed = state.withLockUnchecked { $0.swallowed.remove(code) != nil }
            return swallowed ? nil : Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }
    }

    /// Replaces every binding at once, so no key press sees half of the new bindings.
    ///
    /// A key name that the keyboard layout lacks is skipped.
    func setBindings(_ entries: [Entry]) {
        var handlers: [Binding: Entry] = [:]
        for entry in entries {
            guard let code = KeyCodes.code(for: entry.combo.key) else {
                Log.warn("unknown key name: \(entry.combo.key)")
                continue
            }
            let binding = Binding(code: Int64(code), modifiers: CGEventFlags(modifiers: entry.combo.modifiers).rawValue)
            if handlers[binding] != nil {
                Log.warn("\(entry.combo) is bound twice; the last binding wins")
            }
            handlers[binding] = entry
        }
        state.withLockUnchecked { $0.handlers = handlers }
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
