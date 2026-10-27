import AppKit
import PopCore

extension NSColor {
    /// Black or white, whichever reads better on this color.
    var contrastingText: NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.55 ? .black : .white
    }
}

/// A borderless, click-through window that draws a rounded rectangle.
///
/// It glides from place to place, and fades in and out.
class ShapeWindow: NSPanel, GlidingWindow {
    let shape = CALayer()
    var targetFrame: NSRect?
    var fadeGeneration = 0
    var isFadingOut = false

    init(level: NSWindow.Level) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        self.level = level
        collectionBehavior = [.canJoinAllSpaces, .transient, .ignoresCycle, .fullScreenAuxiliary]

        let view = NSView()
        view.wantsLayer = true
        // The shape follows the window's size while it glides.
        shape.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        view.layer?.addSublayer(shape)
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the shape around a top-left-origin rectangle.
    func show(_ rect: Rect) {
        appear(at: Displays.toCocoa(rect), growing: true)
    }

    func hide() {
        disappear()
    }
}

/// The highlight that shows where a window will go in tile mode or on drop.
///
/// Clear Liquid Glass on macOS 26 and later, a tinted fill with a border before.
final class OverlayWindow: ShapeWindow {
    private var glass: NSView?
    /// The corner radius for windows whose radius the window server does not tell.
    private var radius: Double = 10
    /// Text in the middle, such as "Switch windows" when a drop swaps. It lies above the glass.
    private let label = NSTextField(labelWithString: "")

    init() {
        super.init(level: .floating)
        guard let contentView else { return }
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView(frame: contentView.bounds)
            glass.autoresizingMask = [.width, .height]
            glass.style = .clear
            // A private glass variant, more see-through than the clear style.
            glass.setPrivateVariant(23)
            contentView.addSubview(glass)
            self.glass = glass
        }

        label.font = .systemFont(ofSize: 15, weight: .semibold)
        label.textColor = .white
        label.alignment = .center
        // A shadow keeps the text readable over any window below.
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.6)
        shadow.shadowBlurRadius = 6
        label.shadow = shadow
        label.isHidden = true
        label.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(label)
        NSLayoutConstraint.activate([
            label.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
            label.centerYAnchor.constraint(equalTo: contentView.centerYAnchor),
        ])
    }

    func style(color: NSColor, radius: Double) {
        self.radius = radius
        if #available(macOS 26, *), glass != nil {
            shape.backgroundColor = NSColor.clear.cgColor
            shape.borderWidth = 0
        } else {
            shape.backgroundColor = color.withAlphaComponent(0.25).cgColor
            shape.borderColor = color.cgColor
            shape.borderWidth = 3
        }
    }

    /// Shows the highlight with the rounded corners of `window`, and `text` in the middle if given.
    func show(_ rect: Rect, like window: WindowID?, text: String? = nil) {
        let cornerRadius = window.flatMap(WindowShapes.cornerRadius(of:)) ?? radius
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if #available(macOS 26, *), let glass = glass as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else {
            shape.cornerRadius = cornerRadius
        }
        CATransaction.commit()
        show(rect)
        if let text {
            label.stringValue = text
            label.isHidden = false
        }
    }

    override func show(_ rect: Rect) {
        label.isHidden = true
        super.show(rect)
    }
}

/// The outline around the focused window.
///
/// On macOS 26 and later, the outline is clear Liquid Glass just below the
/// window, so the window covers all of it but a rim. Before, it is a border
/// just above the window.
final class HintWindow: ShapeWindow {
    private var width: Double = 3
    /// The corner radius for windows whose radius the window server does not tell.
    private var radius: Double = 10
    /// The window that the outline surrounds.
    private var target: WindowID?
    private var glass: NSView?

    init() {
        super.init(level: .normal)
        collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary, .moveToActiveSpace]
        if #available(macOS 26, *), let contentView {
            let glass = NSGlassEffectView(frame: contentView.bounds)
            glass.autoresizingMask = [.width, .height]
            // Clear glass is less frosted than regular glass.
            glass.style = .clear
            contentView.addSubview(glass)
            self.glass = glass
        }
    }

    /// Orders the outline next to its window again, after the window's app raised it.
    ///
    /// Without this, windows between them would cover the glass, or the window's shadow the border.
    func reorder(after window: WindowID) {
        guard isVisible, window == target else { return }
        order(placement, relativeTo: Int(window))
    }

    /// Glass goes below the window, a border above it.
    private var placement: NSWindow.OrderingMode { glass == nil ? .above : .below }

    func style(color: NSColor, width: Double, radius: Double) {
        self.width = width
        self.radius = radius
        shape.backgroundColor = NSColor.clear.cgColor
        if #available(macOS 26, *), glass != nil {
            // Plain glass: the accent color is for the border before macOS 26.
            shape.borderWidth = 0
        } else {
            shape.borderColor = color.cgColor
            shape.borderWidth = width
        }
    }

    /// Draws the outline around a window, and orders it next to that window.
    ///
    /// The outline's inner edge follows the window's own rounded corners.
    func show(around rect: Rect, of window: WindowID) {
        let cornerRadius = (WindowShapes.cornerRadius(of: window) ?? radius) + width
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        if #available(macOS 26, *), let glass = glass as? NSGlassEffectView {
            glass.cornerRadius = cornerRadius
        } else {
            shape.cornerRadius = cornerRadius
        }
        CATransaction.commit()
        // The outline glides along while its window moves. Anywhere else, it appears at once.
        let follows = target == window && isVisible && !isFadingOut
        appear(at: Displays.toCocoa(rect.inset(by: -width)), animated: follows)
        order(placement, relativeTo: Int(window))
        if target != window {
            target = window
            WindowReorders.watch([window])
        }
    }
}

@available(macOS 26, *)
extension NSGlassEffectView {
    /// Picks one of the glass variants that AppKit uses internally. The public styles are two of them.
    ///
    /// The setting is private. Without it, the glass keeps its public style.
    func setPrivateVariant(_ variant: Int) {
        guard responds(to: NSSelectorFromString("set_variant:")) else { return }
        setValue(variant, forKey: "_variant")
    }
}
