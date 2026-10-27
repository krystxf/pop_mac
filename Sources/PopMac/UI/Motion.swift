import AppKit

/// How Pop Mac animates windows and its highlights.
///
/// Windows and highlights share one duration and curve, so an outline keeps up with its window.
@MainActor
enum Motion {
    /// Mirrors the `animations` setting.
    static var enabled = true

    /// False while the setting is off, or while macOS is set to reduce motion.
    static var isOn: Bool {
        enabled && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    /// How long a window or a highlight takes to reach a new frame.
    static let duration = 0.22
    /// How long a highlight takes to appear or disappear.
    static let fadeDuration = 0.15

    /// Ease-out cubic: fast at the start, gentle at the end.
    nonisolated static func ease(_ progress: Double) -> Double {
        1 - pow(1 - progress, 3)
    }

    /// The same curve as `ease`, for AppKit animations.
    static var timing: CAMediaTimingFunction {
        CAMediaTimingFunction(controlPoints: 0.33, 1, 0.68, 1)
    }
}

/// A window of Pop Mac's own that glides to new frames and fades in and out.
@MainActor
protocol GlidingWindow: NSWindow {
    /// The frame that the window is at or gliding to.
    var targetFrame: NSRect? { get set }
    /// Counts the calls to `appear` and `disappear`, so a fade-out that ends late does not hide a window shown again.
    var fadeGeneration: Int { get set }
    var isFadingOut: Bool { get set }
}

extension GlidingWindow {
    /// Orders the window in at `frame`, or glides it there if it is visible already.
    ///
    /// A hidden window fades in. With `growing`, it also grows out from a bit smaller.
    /// With `animated` false, the window is at `frame` at once, fully visible.
    func appear(at frame: NSRect, growing: Bool = false, animated: Bool = true) {
        fadeGeneration += 1
        isFadingOut = false
        let animated = animated && Motion.isOn
        if !isVisible {
            let start = growing && frame.width > 40 && frame.height > 40 ? frame.insetBy(dx: 10, dy: 10) : frame
            alphaValue = animated ? 0 : 1
            setFrame(animated ? start : frame, display: false)
            targetFrame = animated ? start : frame
            orderFrontRegardless()
        }
        let moves = frame != targetFrame
        targetFrame = frame
        NSAnimationContext.runAnimationGroup { context in
            context.duration = animated ? Motion.duration : 0
            context.timingFunction = Motion.timing
            // A new animation of a property replaces the running one, which also stops a fade-out.
            if moves { animator().setFrame(frame, display: true) }
            animator().alphaValue = 1
        }
    }

    /// Fades the window out, then orders it out.
    func disappear() {
        guard isVisible, !isFadingOut else { return }
        fadeGeneration += 1
        let generation = fadeGeneration
        guard Motion.isOn else {
            orderOut(nil)
            return
        }
        isFadingOut = true
        NSAnimationContext.runAnimationGroup { context in
            context.duration = Motion.fadeDuration
            animator().alphaValue = 0
        } completionHandler: {
            MainActor.assumeIsolated {
                guard self.fadeGeneration == generation else { return }
                self.isFadingOut = false
                self.orderOut(nil)
            }
        }
    }
}
