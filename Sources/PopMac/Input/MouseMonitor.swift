import AppKit
import PopCore

/// Detects when the user drags or resizes a window with the mouse.
///
/// macOS has no "grab started" event. At a mouse-down, the monitor records
/// every managed window near the cursor. A resize can start a few points
/// outside a window, in the gap between tiles. At the mouse-up, each of those
/// windows whose frame changed was grabbed.
@MainActor
final class MouseMonitor {
    private weak var manager: WindowManager?
    private var monitors: [Any] = []
    /// Windows near the cursor at mouse-down, with their frames at that time.
    private var candidates: [WindowID: Rect] = [:]
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
        dragged = nil
        downTime = Date()
        candidates = SpaceMover.isMoving ? [:] : windowsNearCursor()
    }

    /// Starts the drop preview once one of the candidates moves without a size change.
    private func mouseDragged() {
        guard dragged == nil, !candidates.isEmpty, Date().timeIntervalSince(lastCheck) > 0.1, manager != nil else { return }
        lastCheck = Date()

        // The window server's frames: the app of a dragged window is busy and slow to answer.
        let frames = Dictionary(Displays.onScreenFrames().map { ($0.id, $0.frame) }, uniquingKeysWith: { first, _ in first })
        for (id, rect) in candidates {
            guard let frame = frames[id] else { continue }
            let moved = abs(frame.x - rect.x) > 1 || abs(frame.y - rect.y) > 1
            let resized = abs(frame.width - rect.width) > 1 || abs(frame.height - rect.height) > 1
            guard moved, !resized else { continue }

            dragged = id
            // Show where the window will land 30 times a second, after 200 ms like Pop Shell.
            let timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let dragged = self.dragged else { return }
                    self.manager?.dragPreview(dragged)
                }
            }
            timer.fireDate = Date().addingTimeInterval(0.2)
            previewTimer = timer
            return
        }
    }

    private func mouseUp(flags: CGEventFlags) {
        previewTimer?.invalidate()
        previewTimer = nil
        manager?.overlay.hide()
        // The active hint hides while the mouse moves the focused window.
        manager?.scheduleHint()

        let grabbed = candidates
        let since = downTime
        let stack = manager?.holdsSuper(flags) ?? false
        candidates = [:]
        dragged = nil
        guard !grabbed.isEmpty else { return }

        for (id, rect) in grabbed {
            settle(id, previous: nil, attempts: 10) { [weak self] in
                guard let manager = self?.manager, !manager.wasMovedByPopMac(id, since: since) else { return }
                manager.onGrabEnd(id, original: rect, stack: stack)
            }
        }
    }

    /// Waits until a window's frame stops changing, then runs `done`.
    ///
    /// Apps apply a mouse resize with some lag, so the frame right after the
    /// mouse-up can miss the last few points.
    private func settle(_ id: WindowID, previous: Rect?, attempts: Int, done: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let frame = Displays.onScreenFrame(of: id) ?? self.manager?.windows[id]?.frame else { return }
                if frame == previous || attempts <= 0 {
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
