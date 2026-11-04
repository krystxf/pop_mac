import AppKit
import PopCore

/// Detects when the user drags or resizes a window with the mouse.
///
/// macOS has no "grab started" event. At a mouse-down, the monitor records
/// every managed window near the cursor. A resize can start a few points
/// outside a window, in the gap between tiles. At the mouse-up, each of those
/// windows whose frame changed during a mouse drag was grabbed.
@MainActor
final class MouseMonitor {
    private weak var manager: WindowManager?
    private var monitors: [Any] = []
    /// The windows near the cursor at mouse-down, and the drops that wait.
    private var grab = GrabTracker()
    private var downTime = Date.distantPast
    private var dragged: WindowID?
    private var lastCheck = Date.distantPast
    private var previewTimer: Timer?

    /// How far outside a window a resize grab can start.
    private static let grabMargin = 12.0

    init(manager: WindowManager) {
        self.manager = manager
    }

    func start() {
        let down = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDown() }
        }
        let drag = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDragged) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseDragged() }
        }
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] event in
            let flags = CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue))
            MainActor.assumeIsolated { self?.mouseUp(flags: flags) }
        }
        monitors = [down, drag, up].compactMap(\.self)
    }

    private func mouseDown() {
        stopPreview()
        downTime = Date()
        grab.mouseDown(candidates: SpaceMover.isMoving ? [:] : windowsNearCursor())
    }

    /// True while the user drags a window, or its drop waits to be handled.
    func isBusy(generation: Int) -> Bool {
        grab.isBusy(generation: generation, buttonDown: NSEvent.pressedMouseButtons & 1 != 0)
    }

    /// A Space switch makes the window server's frames unreliable for a moment.
    ///
    /// The grab goes on, because a dragged window travels to the new Space with the mouse.
    /// The drop preview stops, and starts again once the switch settles.
    func spaceChanged() {
        stopPreview()
    }

    private func stopPreview() {
        dragged = nil
        previewTimer?.invalidate()
        previewTimer = nil
        manager?.overlay.hide()
    }

    /// Starts the drop preview once one of the candidates moves without a size change.
    private func mouseDragged() {
        if SpaceMover.isMoving {
            // Pop Mac's own drag, which moves a window to another Space.
            grab.cancel()
            stopPreview()
            return
        }
        grab.mouseDragged()
        guard let manager, !manager.isSwitchingSpaces, dragged == nil, !grab.candidates.isEmpty,
              Date().timeIntervalSince(lastCheck) > 0.1 else { return }
        lastCheck = Date()

        // The window server's frames: the app of a dragged window is busy and slow to answer.
        let frames = Dictionary(Displays.onScreenFrames().map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        for (id, rect) in grab.candidates {
            guard let frame = frames[id] else { continue }
            let moved = abs(frame.x - rect.x) > 1 || abs(frame.y - rect.y) > 1
            let resized = abs(frame.width - rect.width) > 1 || abs(frame.height - rect.height) > 1
            guard moved, !resized else { continue }

            dragged = id
            // Show where the window will land 30 times a second, after 200 ms like Pop Shell.
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let dragged = self.dragged, self.manager?.isSwitchingSpaces == false else { return }
                    self.manager?.dragPreview(dragged)
                }
            }
            timer.fireDate = Date().addingTimeInterval(0.2)
            previewTimer = timer
            return
        }
    }

    private func mouseUp(flags: CGEventFlags) {
        stopPreview()
        // The active hint hides while the mouse moves the focused window.
        manager?.scheduleHint()
        guard let manager else { return }

        let generation = manager.spaceSwitches.generation
        let grabbed = grab.mouseUp(generation: generation)
        let drop = Drop(since: downTime, cursor: Displays.cursor, stack: manager.holdsSuper(flags), generation: generation)
        for (id, rect) in grabbed {
            settle(id, previous: nil, attempts: 10) { [weak self] in
                self?.finish(id, original: rect, drop)
            }
        }
    }

    /// What a mouse-up knew about a drop.
    private struct Drop {
        let since: Date
        /// The cursor at mouse-up: the drop may be handled after the mouse moved on.
        let cursor: Point
        let stack: Bool
        /// The Space generation at mouse-up.
        let generation: Int
    }

    /// Hands a drop to the manager once the Space switch around it settled.
    ///
    /// A drop made before a later Space switch is stale: its window and its target
    /// may be on a Space out of view.
    private func finish(_ id: WindowID, original: Rect, _ drop: Drop) {
        guard let manager else { return }
        switch manager.spaceSwitches.decide(drop.generation, at: ProcessInfo.processInfo.systemUptime) {
        case .drop:
            grab.dropEnded(id)
        case let .wait(delay):
            DispatchQueue.main.asyncAfter(deadline: .now() + delay + 0.01) { [weak self] in
                MainActor.assumeIsolated { self?.finish(id, original: original, drop) }
            }
        case .run:
            grab.dropEnded(id)
            guard !manager.wasMovedByPopMac(id, since: drop.since) else { return }
            manager.onGrabEnd(id, original: original, cursor: drop.cursor, stack: drop.stack)
        }
    }

    /// Waits until a window's frame stops changing, then runs `done`.
    ///
    /// Apps apply a mouse resize with some lag, so the frame right after the
    /// mouse-up can miss the last few points.
    private func settle(_ id: WindowID, previous: Rect?, attempts: Int, done: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A window that is gone settles at once. The drop's handler skips it.
                let frame = Displays.onScreenFrame(of: id) ?? self.manager?.windows[id]?.frame
                if frame == nil || frame == previous || attempts <= 0 {
                    done()
                } else {
                    self.settle(id, previous: frame, attempts: attempts - 1, done: done)
                }
            }
        }
    }

    /// Managed windows whose frame, widened by the grab margin, holds the cursor.
    private func windowsNearCursor() -> [WindowID: Rect] {
        guard let manager,
              let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [:] }

        let cursor = Displays.cursor
        let ownPID = ProcessInfo.processInfo.processIdentifier
        var result: [WindowID: Rect] = [:]

        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  (entry[kCGWindowOwnerPID as String] as? Int32) != ownPID,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  manager.windows[id] != nil,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            let rect = Rect(Double(bounds.origin.x), Double(bounds.origin.y), Double(bounds.width), Double(bounds.height))
            guard rect.inset(by: -Self.grabMargin).contains(cursor) else { continue }
            // In Mission Control the window list shows thumbnails, not the real frames.
            // Dragging a thumbnail is not a window drag.
            guard let frame = manager.windows[id]?.frame, frame.approximatelyEquals(rect, tolerance: 4) else { continue }
            result[id] = rect
        }
        return result
    }
}
