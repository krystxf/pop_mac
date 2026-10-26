import AppKit
import PopCore

/// Detects when the user drags or resizes a window with the mouse.
///
/// macOS has no "grab started" event, so a grab starts at a mouse-down on a
/// managed window. It ends at the mouse-up, if the window's frame changed.
@MainActor
final class MouseMonitor {
    private weak var manager: WindowManager?
    private var monitors: [Any] = []
    private var grab: (id: WindowID, rect: Rect)?
    private var dragging = false
    private var lastCheck = Date.distantPast
    private var previewTimer: Timer?

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
        let up = NSEvent.addGlobalMonitorForEvents(matching: .leftMouseUp) { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseUp() }
        }
        monitors = [down, drag, up].compactMap { $0 }
    }

    private func mouseDown() {
        grab = nil
        dragging = false
        guard !SpaceMover.isMoving, let manager, let id = windowUnderCursor(), let window = manager.windows[id], let rect = window.frame else { return }
        grab = (id, rect)
    }

    private func mouseDragged() {
        guard let grab, !dragging, Date().timeIntervalSince(lastCheck) > 0.1 else { return }
        lastCheck = Date()

        guard let manager, let frame = manager.windows[grab.id]?.frame else { return }
        let moved = abs(frame.x - grab.rect.x) > 1 || abs(frame.y - grab.rect.y) > 1
        let resized = abs(frame.width - grab.rect.width) > 1 || abs(frame.height - grab.rect.height) > 1

        if moved && !resized {
            dragging = true
            // Show where the window will land, like Pop Shell does after 200 ms.
            previewTimer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let grab = self.grab else { return }
                    self.manager?.dragPreview(grab.id)
                }
            }
        }
    }

    private func mouseUp() {
        previewTimer?.invalidate()
        previewTimer = nil
        manager?.overlay.hide()

        guard let grab else { return }
        self.grab = nil
        dragging = false

        // Let the window settle into its final frame first.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            MainActor.assumeIsolated { self?.manager?.onGrabEnd(grab.id, original: grab.rect) }
        }
    }

    /// The managed window that is topmost under the cursor.
    private func windowUnderCursor() -> WindowID? {
        let cursor = Displays.cursor
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return nil
        }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for entry in info {
            guard (entry[kCGWindowLayer as String] as? Int) == 0,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict)
            else { continue }
            let rect = Rect(Double(bounds.origin.x), Double(bounds.origin.y), Double(bounds.width), Double(bounds.height))
            guard rect.contains(cursor) else { continue }
            // Skip Pop Mac's own windows. The active hint covers the focused window.
            if (entry[kCGWindowOwnerPID as String] as? Int32) == ownPID { continue }
            return (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        }
        return nil
    }
}
