import Foundation

/// A drag of a whole stack by its tab bar, as the window manager sees it.
///
/// The stack's selected window follows the mouse, and the other windows wait out of sight.
/// Every way a drag can end puts them back: a drop places them, and anything else returns
/// them to their tiles.
public struct StackDragSession {
    /// Where the stack was when the drag began.
    public let workspace: WorkspaceKey
    /// The selected window's frame when the drag began.
    public let start: Rect
    /// Where the selected window is now.
    public private(set) var current: Rect
    /// True if the left mouse button was up at the last check.
    private var buttonWasUp = false

    public init(workspace: WorkspaceKey, frame: Rect) {
        self.workspace = workspace
        start = frame
        current = frame
    }

    /// Moves the selected window by the mouse's offset from where the drag began.
    ///
    /// - Parameters:
    ///   - dx: The offset to the right, in points.
    ///   - dy: The offset upward, in screen points with y up. Window frames have y down.
    /// - Returns: The frame that the window moves from, and the frame that it moves to.
    public mutating func move(dx: Double, dy: Double) -> (from: Rect, to: Rect) {
        var to = start
        to.x += dx.rounded()
        to.y -= dy.rounded()
        let from = current
        current = to
        return (from, to)
    }

    /// Checks the left mouse button while the drag lasts. Returns true if the drag's mouse-up was lost.
    ///
    /// The mouse-up event can trail the button's state, so the button must be up on two checks in a row.
    public mutating func mouseUpWasLost(buttonDown: Bool) -> Bool {
        defer { buttonWasUp = !buttonDown }
        return buttonWasUp && !buttonDown
    }

    public enum Outcome: Equatable {
        /// The stack lands at the drop, on the Space with this key.
        case drop(WorkspaceKey)
        /// The stack goes back to its tiles.
        case restore
    }

    /// What a drop does.
    ///
    /// - Parameters:
    ///   - key: The workspace under the cursor, or nil if the cursor is on no display.
    ///   - visible: The workspaces in view now.
    ///   - stackIntact: False if the stack changed or dissolved while it was dragged.
    public func outcome(at key: WorkspaceKey?, visible: Set<WorkspaceKey>, stackIntact: Bool) -> Outcome {
        // The windows stay on their Space while the bar is dragged. A stack from a Space out of view
        // must not join the tree of the Space in view.
        guard stackIntact, visible.contains(workspace), let key, visible.contains(key) else { return .restore }
        return .drop(key)
    }
}

/// A tab bar's side of a stack drag.
///
/// The bar follows the mouse from its origin when the drag began. A cancelled drag ignores
/// the rest of its gesture, so it cannot start again from where it stopped.
public struct BarDrag: Equatable {
    public enum State: Equatable {
        case idle
        /// The bar follows the mouse. `origin` is the bar's origin when the drag began.
        case dragging(origin: Point)
        /// The drag was cancelled while the button was still down.
        case cancelled
    }

    public private(set) var state = State.idle

    public init() {}

    /// True while the bar follows the mouse, so it does not glide to its stack.
    public var isDragging: Bool {
        if case .dragging = state {
            true
        } else {
            false
        }
    }

    /// The bar's origin when the drag began, for a move of the mouse. Nil if the drag was cancelled.
    ///
    /// - Parameter origin: The bar's origin now, which begins a new drag.
    public mutating func moved(from origin: Point) -> Point? {
        switch state {
        case .idle:
            state = .dragging(origin: origin)
            return origin
        case let .dragging(start):
            return start
        case .cancelled:
            return nil
        }
    }

    /// Begins a new gesture. A drag left over from an earlier one, whose mouse-up was lost, is over.
    public mutating func pressed() {
        state = .idle
    }

    /// Ends the gesture. Returns true if the drop must be reported.
    public mutating func ended() -> Bool {
        defer { state = .idle }
        return isDragging
    }

    /// Stops following the mouse. While the button is down, the rest of the gesture is ignored.
    /// With the button up, as after a lost mouse-up, the next gesture drags again.
    public mutating func cancel(buttonDown: Bool) {
        state = buttonDown ? .cancelled : .idle
    }
}
