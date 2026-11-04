import Foundation

/// Tracks Space switches, so work that reads window frames waits until a switch settles.
///
/// While a Space switch animates, and for a moment after it, the window server can report
/// frames translated across displays, and windows leave and enter the screen.
/// Times are monotonic seconds, such as `ProcessInfo.systemUptime`, so a change of the
/// system clock cannot hold the quiet period open.
public struct SpaceSwitchClock: Sendable {
    /// How long after a switch the frames can still be wrong. Every switch restarts it.
    public static let quietPeriod: TimeInterval = 0.7

    /// Counts the switches. Work that began before a switch is stale after it.
    public private(set) var generation = 0
    private var lastSwitch: TimeInterval?

    public init() {}

    /// Records a switch at `now`.
    public mutating func switched(at now: TimeInterval) {
        generation += 1
        lastSwitch = now
    }

    /// The time until the last switch settles, or zero. Never more than the quiet period.
    public func remaining(at now: TimeInterval) -> TimeInterval {
        guard let lastSwitch else { return 0 }
        return min(Self.quietPeriod, max(0, Self.quietPeriod - (now - lastSwitch)))
    }

    public func isSwitching(at now: TimeInterval) -> Bool {
        remaining(at: now) > 0
    }

    public enum Decision: Equatable {
        /// The Space did not change since the work began, and the frames are settled.
        case run
        /// Try again after this many seconds, when the switch has settled.
        case wait(TimeInterval)
        /// The Space changed since the work began. Its frames and its Space are stale.
        case drop
    }

    /// What to do with work that began in `generation`.
    public func decide(_ generation: Int, at now: TimeInterval) -> Decision {
        guard generation == self.generation else { return .drop }
        let left = remaining(at: now)
        return left > 0 ? .wait(left) : .run
    }
}

/// The state of a mouse grab of windows, from mouse-down until its drop is handled.
///
/// At mouse-down, the windows near the cursor become candidates. Only a drag grabs
/// them: a window that moves after a plain click, as on a double-click of its title
/// bar, was not grabbed. A Space switch during the drag does not end the grab, because
/// a window dragged across Spaces travels with the mouse.
public struct GrabTracker {
    /// The windows near the cursor at mouse-down, with their frames then.
    public private(set) var candidates: [WindowID: Rect] = [:]
    public private(set) var receivedDrag = false
    /// Grabbed windows whose drop waits for their frame to settle, with the Space generation of the mouse-up.
    public private(set) var pendingDrops: [WindowID: Int] = [:]

    public init() {}

    /// True while the mouse drags windows that may be grabbed.
    public var isDragging: Bool {
        receivedDrag && !candidates.isEmpty
    }

    /// True while a drag lasts, or a drop of the current Space generation waits.
    ///
    /// Work that would move windows between trees waits meanwhile, so it does not undo the drop.
    /// A drag counts only while the button is down, so a lost mouse-up cannot hold that work back.
    public func isBusy(generation: Int, buttonDown: Bool) -> Bool {
        (isDragging && buttonDown) || pendingDrops.values.contains(generation)
    }

    /// Starts a new grab. A drop of an earlier grab that still waits stays valid.
    public mutating func mouseDown(candidates: [WindowID: Rect]) {
        self.candidates = candidates
        receivedDrag = false
    }

    public mutating func mouseDragged() {
        receivedDrag = true
    }

    /// Ends the grab. Returns the grabbed windows, whose drops wait until `dropEnded`.
    public mutating func mouseUp(generation: Int) -> [WindowID: Rect] {
        let grabbed = receivedDrag ? candidates : [:]
        cancel()
        for id in grabbed.keys {
            pendingDrops[id] = generation
        }
        return grabbed
    }

    /// Forgets the grab in progress, as when it was a synthetic drag.
    public mutating func cancel() {
        candidates = [:]
        receivedDrag = false
    }

    /// Records that the drop of a window was handled or dropped.
    public mutating func dropEnded(_ id: WindowID) {
        pendingDrops.removeValue(forKey: id)
    }
}
