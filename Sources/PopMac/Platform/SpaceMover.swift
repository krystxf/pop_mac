import AppKit
import Carbon
import PopCore

/// Moves a window to the neighboring Space.
///
/// macOS has no public API for this. The mover grabs the window's title bar
/// with a synthetic mouse drag, and presses Control-Left or Control-Right
/// ("Move left/right a space" in Keyboard Shortcuts > Mission Control).
/// The window travels with the drag to the new Space.
@MainActor
enum SpaceMover {
    /// True while the synthetic drag runs, so it is not taken for a user drag.
    private(set) static var isMoving = false

    static func move(_ window: ManagedWindow, next: Bool, completion: @escaping @MainActor () -> Void) {
        guard let frame = window.frame, !isMoving else { return }
        isMoving = true
        waitForModifierRelease(deadline: Date().addingTimeInterval(1.5)) {
            perform(frame: frame, next: next) {
                isMoving = false
                completion()
            }
        }
    }

    /// The user still holds the shortcut's modifiers. They would mix with the synthetic events.
    private static func waitForModifierRelease(deadline: Date, then action: @escaping () -> Void) {
        let flags = CGEventSource.flagsState(.hidSystemState)
        let held: CGEventFlags = [.maskCommand, .maskControl, .maskAlternate, .maskShift]
        if flags.intersection(held).isEmpty || Date() > deadline {
            action()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                waitForModifierRelease(deadline: deadline, then: action)
            }
        }
    }

    private static func perform(frame: PopCore.Rect, next: Bool, completion: @escaping @MainActor () -> Void) {
        let source = CGEventSource(stateID: .hidSystemState)
        let original = CGEvent(source: nil)?.location ?? .zero
        // A point in the title bar, clear of the traffic-light buttons.
        let grab = CGPoint(x: frame.x + frame.width / 2, y: frame.y + 5)

        func post(_ type: CGEventType, _ point: CGPoint) {
            let event = CGEvent(mouseEventSource: source, mouseType: type, mouseCursorPosition: point, mouseButton: .left)
            event?.flags = []
            event?.post(tap: .cghidEventTap)
        }

        func key(_ code: Int, down: Bool) {
            let event = CGEvent(keyboardEventSource: source, virtualKey: CGKeyCode(code), keyDown: down)
            // Real arrow keys carry the fn and keypad flags, and the system shortcut requires them.
            event?.flags = [.maskControl, .maskSecondaryFn, .maskNumericPad]
            event?.post(tap: .cghidEventTap)
        }

        post(.mouseMoved, grab)
        post(.leftMouseDown, grab)

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            post(.leftMouseDragged, CGPoint(x: grab.x + 2, y: grab.y))
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
                let arrow = next ? kVK_RightArrow : kVK_LeftArrow
                key(arrow, down: true)
                key(arrow, down: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) {
                    post(.leftMouseUp, CGPoint(x: grab.x + 2, y: grab.y))
                    post(.mouseMoved, original)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: completion)
                }
            }
        }
    }
}
