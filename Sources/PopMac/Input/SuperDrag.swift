import AppKit
import os
import PopCore

/// Moves a window when the user drags anywhere in it while holding the Super modifiers.
///
/// A mouse event tap consumes the click, so the application under the cursor
/// never sees it. The release goes through the same drop logic as a title bar drag.
///
/// The tap sees every click and drag in every app, so it runs on its own thread.
/// On the main thread, each slow Accessibility call would delay them all.
@MainActor
final class SuperDrag {
    /// The state that the tap thread reads.
    private struct Shared {
        /// The Super modifiers, or none while Super + drag is off.
        var modifiers: CGEventFlags = []
        var grabbing = false
        /// The cursor at the latest drag event.
        var cursor: CGPoint?
        /// The modifiers held at mouse-up.
        var releaseFlags: CGEventFlags = []
        var moveScheduled = false
    }

    private let shared = OSAllocatedUnfairLock(initialState: Shared())
    private nonisolated(unsafe) var tap: CFMachPort?
    private weak var manager: WindowManager?
    /// The window being moved, with its frame and the cursor at mouse-down.
    private var grab: (id: WindowID, frame: Rect, cursor: CGPoint)?
    private var previewTimer: Timer?

    init(manager: WindowManager) {
        self.manager = manager
    }

    func start() {
        let thread = Thread { [self] in runTap() }
        thread.name = "Super + drag"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    /// Turns Super + drag on or off, and sets its modifiers.
    func configure(_ settings: Settings) {
        let modifiers = settings.superDragMovesWindows ? CGEventFlags(modifiers: settings.superModifiers) : []
        shared.withLock { $0.modifiers = modifiers }
    }

    /// The window being moved, if any.
    var window: WindowID? { grab?.id }

    private nonisolated func runTap() {
        let mask = CGEventMask(1 << CGEventType.leftMouseDown.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseDragged.rawValue)
            | CGEventMask(1 << CGEventType.leftMouseUp.rawValue)
        let callback: CGEventTapCallBack = { _, type, event, userInfo in
            guard let userInfo else { return Unmanaged.passUnretained(event) }
            return Unmanaged<SuperDrag>.fromOpaque(userInfo).takeUnretainedValue().handle(type, event)
        }
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: callback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.warn("could not create the mouse event tap")
            return
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(nil, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        CFRunLoopRun()
    }

    /// Runs on the tap thread. Only a Super click waits for the main thread.
    private nonisolated func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        let location = event.location
        let flags = event.flags
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // macOS turns a slow tap off. Turn it back on.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .leftMouseDown:
            let modifiers = shared.withLock { $0.grabbing ? [] : $0.modifiers }
            guard !modifiers.isEmpty, event.flags.intersection(.modifiers) == modifiers else { break }
            let began = DispatchQueue.main.sync { MainActor.assumeIsolated { begin(at: location) } }
            if began { return nil }
        case .leftMouseDragged:
            let (grabbing, schedule) = shared.withLock { state -> (Bool, Bool) in
                guard state.grabbing else { return (false, false) }
                state.cursor = location
                defer { state.moveScheduled = true }
                return (true, !state.moveScheduled)
            }
            if schedule {
                // Moves the window once per main run loop pass, however many drag events arrive.
                DispatchQueue.main.async { MainActor.assumeIsolated { self.move() } }
            }
            if grabbing { return nil }
        case .leftMouseUp:
            let grabbing = shared.withLock { state -> Bool in
                guard state.grabbing else { return false }
                state.grabbing = false
                state.cursor = location
                state.releaseFlags = flags
                return true
            }
            if grabbing {
                DispatchQueue.main.async { MainActor.assumeIsolated { self.end() } }
                return nil
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Grabs the frontmost managed window under the cursor. Returns false if there is none.
    private func begin(at point: CGPoint) -> Bool {
        guard let manager, !SpaceMover.isMoving, let id = windowID(at: point),
              let window = manager.windows[id], !window.isFullscreen
        else { return false }
        // The mouse takes over from a running animation.
        manager.animator.cancel(id)
        guard let frame = window.frame else { return false }

        grab = (id, frame, point)
        shared.withLock {
            $0.grabbing = true
            $0.cursor = point
        }
        // Focus after the tap returns, so the click is not held up.
        DispatchQueue.main.async { window.focus() }
        // Show where the window will land, like a title bar drag does.
        previewTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let id = self.grab?.id else { return }
                self.manager?.dragPreview(id)
            }
        }
        return true
    }

    private func move() {
        let cursor = shared.withLock { state -> CGPoint? in
            state.moveScheduled = false
            return state.cursor
        }
        guard let grab, let cursor, let window = manager?.windows[grab.id] else { return }
        window.setPosition(Point(grab.frame.x + cursor.x - grab.cursor.x, grab.frame.y + cursor.y - grab.cursor.y))
    }

    private func end() {
        previewTimer?.invalidate()
        previewTimer = nil
        move()
        guard let grab, let manager else { return }
        self.grab = nil
        let stack = manager.holdsSuper(shared.withLock(\.releaseFlags))
        // Let the app apply the last move before the drop reads the frame.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak manager] in
            MainActor.assumeIsolated { manager?.onGrabEnd(grab.id, original: grab.frame, stack: stack) }
        }
    }

    /// The frontmost window of another app that holds the point and that Pop Mac manages.
    private func windowID(at point: CGPoint) -> WindowID? {
        guard let manager,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return nil }

        let ownPID = ProcessInfo.processInfo.processIdentifier
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict), bounds.contains(point)
            else { continue }
            // The frontmost window under the cursor decides, even if Pop Mac does not manage it.
            guard let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value, manager.windows[id] != nil else {
                return nil
            }
            return id
        }
        return nil
    }
}
