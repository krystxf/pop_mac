import AppKit
@preconcurrency import ApplicationServices
import os
import PopCore

/// Moves windows to new frames in small steps, so that they glide instead of jump.
///
/// Accessibility calls wait for the window's app, so each app gets its own queue:
/// a slow app slows only its own windows, and never the main thread. Each step
/// takes its frame from the clock, so a late step skips ahead, and every
/// animation ends on time.
final class WindowAnimator: @unchecked Sendable {
    private struct Animation {
        let serial: Int
        let element: AXUIElement
        let pid: pid_t
        let from: Rect
        let to: Rect
        let start: CFTimeInterval
        let duration: Double
        /// The frame of the last step.
        var current: Rect
        let done: @MainActor () -> Void
    }

    private struct State {
        var animations: [WindowID: Animation] = [:]
        /// Apps whose queue is stepping their windows.
        var running = Set<pid_t>()
        var serial = 0
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    /// One serial queue per app. Only the main thread uses this dictionary.
    private var queues: [pid_t: DispatchQueue] = [:]
    /// The time between two steps: one frame of a 120 Hz display.
    private static let stepInterval = 1.0 / 120

    /// Moves `window` from `from` to `to`.
    ///
    /// A window that is still moving starts from where it is now. `done` runs on the
    /// main thread when the window arrives, unless a newer animation replaced this one.
    @MainActor
    func animate(_ window: ManagedWindow, from: Rect, to: Rect, done: @escaping @MainActor () -> Void) {
        let pid = window.pid
        let duration = Motion.duration
        let start = state.withLockUnchecked { state -> Bool in
            state.serial += 1
            let from = state.animations[window.id]?.current ?? from
            state.animations[window.id] = Animation(
                serial: state.serial, element: window.element, pid: pid, from: from, to: to,
                start: CACurrentMediaTime(), duration: duration, current: from, done: done
            )
            return state.running.insert(pid).inserted
        }
        guard start else { return }

        let queue = queues[pid] ?? DispatchQueue(label: "dev.krystof.popmac.animate.\(pid)", qos: .userInteractive)
        queues[pid] = queue
        let app = window.appElement
        queue.async { self.run(pid, app: app) }
    }

    /// Stops a window where it is. Its `done` does not run.
    @MainActor
    func cancel(_ id: WindowID) {
        state.withLockUnchecked { _ = $0.animations.removeValue(forKey: id) }
    }

    /// The frame that a moving window goes to, or nil if it is not moving.
    @MainActor
    func target(of id: WindowID) -> Rect? {
        state.withLockUnchecked { $0.animations[id]?.to }
    }

    /// Steps every animation of one app until none is left.
    private func run(_ pid: pid_t, app: AXUIElement) {
        // While this is on, some apps animate each frame change themselves and fall behind.
        let enhanced: Bool = AX.get(app, "AXEnhancedUserInterface") ?? false
        if enhanced { AX.set(app, "AXEnhancedUserInterface", kCFBooleanFalse) }
        defer { if enhanced { AX.set(app, "AXEnhancedUserInterface", kCFBooleanTrue) } }

        while true {
            let now = CACurrentMediaTime()
            let batch = state.withLockUnchecked { state -> [(WindowID, Animation)] in
                let batch = state.animations.filter { $0.value.pid == pid }
                if batch.isEmpty { state.running.remove(pid) }
                return Array(batch)
            }
            guard !batch.isEmpty else { return }

            var finished: [@MainActor () -> Void] = []
            for (id, animation) in batch {
                // Skip a window that was stopped or got a new target meanwhile.
                guard state.withLockUnchecked({ $0.animations[id]?.serial == animation.serial }) else { continue }
                let progress = min(1, (now - animation.start) / animation.duration)
                let rect = progress >= 1 ? animation.to : mix(animation.from, animation.to, Motion.ease(progress))
                if progress >= 1 {
                    AX.setFrame(animation.element, rect)
                } else {
                    step(animation.element, from: animation.current, to: rect)
                }

                let done = state.withLockUnchecked { state -> (@MainActor () -> Void)? in
                    guard state.animations[id]?.serial == animation.serial else { return nil }
                    if progress >= 1 { return state.animations.removeValue(forKey: id)?.done }
                    state.animations[id]?.current = rect
                    return nil
                }
                if let done { finished.append(done) }
            }

            if !finished.isEmpty {
                DispatchQueue.main.async { MainActor.assumeIsolated { finished.forEach { $0() } } }
            }
            let wait = Self.stepInterval - (CACurrentMediaTime() - now)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        }
    }

    /// Sets only what changed since the last step: a move is much cheaper than a resize.
    private func step(_ element: AXUIElement, from: Rect, to: Rect) {
        if to.x != from.x || to.y != from.y {
            AX.setPosition(element, CGPoint(x: to.x, y: to.y))
        }
        if to.width != from.width || to.height != from.height {
            AX.setSize(element, CGSize(width: to.width, height: to.height))
        }
    }

    /// The frame `progress` of the way from `a` to `b`, on whole points.
    private func mix(_ a: Rect, _ b: Rect, _ progress: Double) -> Rect {
        func value(_ a: Double, _ b: Double) -> Double { a + (b - a) * progress }
        return Rect(value(a.x, b.x), value(a.y, b.y), value(a.width, b.width), value(a.height, b.height)).rounded()
    }
}
