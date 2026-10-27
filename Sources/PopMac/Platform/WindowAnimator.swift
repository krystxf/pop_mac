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
///
/// A move is cheap, but a resize makes the app lay out the window again, and some
/// apps take tens of milliseconds for it. The animator measures each app's resizes.
/// A window of a slow app keeps one size while it slides, and takes its final size
/// at the end, so its motion stays smooth.
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
        /// The size that the window keeps while it slides, once its app turned out to be slow to resize.
        var heldSize: Size?
        let done: @MainActor () -> Void
    }

    private struct State {
        var animations: [WindowID: Animation] = [:]
        /// Apps whose queue is stepping their windows.
        var running = Set<pid_t>()
        var serial = 0
        /// How long each app takes for a resize, in seconds, averaged over its recent resizes.
        var resizeTime: [pid_t: Double] = [:]
    }

    private let state = OSAllocatedUnfairLock(uncheckedState: State())
    /// One serial queue per app. Only the main thread uses this dictionary.
    private var queues: [pid_t: DispatchQueue] = [:]
    /// The time between two steps: one frame of a 120 Hz display.
    private static let stepInterval = 1.0 / 120
    /// A resize that takes longer than this leaves too few steps for a smooth glide.
    private static let slowResize = 0.02

    /// Moves `window` from `from` to `to`.
    ///
    /// A window that is still moving starts from where it is now. `done` runs on the
    /// main thread when the window arrives, unless a newer animation replaced this one.
    /// A duration of zero moves the window at once, but still off the main thread.
    @MainActor
    func animate(
        _ window: ManagedWindow, from: Rect, to: Rect, duration: Double = Motion.duration,
        done: @escaping @MainActor () -> Void
    ) {
        let pid = window.pid
        let start = state.withLockUnchecked { state -> Bool in
            state.serial += 1
            let from = state.animations[window.id]?.current ?? from
            state.animations[window.id] = Animation(
                serial: state.serial, element: window.element, pid: pid, from: from, to: to,
                start: CACurrentMediaTime(), duration: duration, current: from, heldSize: nil, done: done
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

            let slowApp = state.withLockUnchecked { ($0.resizeTime[pid] ?? 0) > Self.slowResize }
            var finished: [@MainActor () -> Void] = []
            for (id, var animation) in batch {
                // Skip a window that was stopped or got a new target meanwhile.
                guard state.withLockUnchecked({ $0.animations[id]?.serial == animation.serial }) else { continue }
                let progress = animation.duration > 0 ? min(1, (now - animation.start) / animation.duration) : 1
                var rect = progress >= 1 ? animation.to : mix(animation.from, animation.to, Motion.ease(progress))
                if progress >= 1 {
                    AX.setFrame(animation.element, rect)
                } else {
                    if slowApp, animation.heldSize == nil, rect.size != animation.from.size {
                        animation.heldSize = heldSize(animation)
                    }
                    if let size = animation.heldSize {
                        rect.width = size.width
                        rect.height = size.height
                    }
                    if let time = step(animation.element, from: animation.current, to: rect) {
                        learn(time, of: pid)
                    }
                }

                let done = state.withLockUnchecked { state -> (@MainActor () -> Void)? in
                    guard state.animations[id]?.serial == animation.serial else { return nil }
                    if progress >= 1 { return state.animations.removeValue(forKey: id)?.done }
                    state.animations[id]?.current = rect
                    state.animations[id]?.heldSize = animation.heldSize
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

    /// Sets only what changed since the last step. Returns how long the resize took, if there was one.
    private func step(_ element: AXUIElement, from: Rect, to: Rect) -> Double? {
        if to.x != from.x || to.y != from.y {
            AX.setPosition(element, CGPoint(x: to.x, y: to.y))
        }
        guard to.size != from.size else { return nil }
        let start = CACurrentMediaTime()
        AX.setSize(element, CGSize(width: to.width, height: to.height))
        return CACurrentMediaTime() - start
    }

    /// The size that a window of a slow app keeps while it slides.
    ///
    /// At the start, it is the smaller of the two sizes on each side, so the window
    /// never covers more than at either end. Later, it is the size the window has now.
    private func heldSize(_ animation: Animation) -> Size {
        guard animation.current == animation.from else { return animation.current.size }
        return Size(width: min(animation.from.width, animation.to.width), height: min(animation.from.height, animation.to.height))
    }

    /// Updates an app's average resize time.
    private func learn(_ time: Double, of pid: pid_t) {
        state.withLockUnchecked { state in
            let average = state.resizeTime[pid] ?? time
            state.resizeTime[pid] = average * 0.7 + time * 0.3
        }
    }

    /// The frame `progress` of the way from `a` to `b`, on whole points.
    private func mix(_ a: Rect, _ b: Rect, _ progress: Double) -> Rect {
        func value(_ a: Double, _ b: Double) -> Double { a + (b - a) * progress }
        return Rect(value(a.x, b.x), value(a.y, b.y), value(a.width, b.width), value(a.height, b.height)).rounded()
    }
}

private extension Rect {
    var size: Size { Size(width: width, height: height) }
}
