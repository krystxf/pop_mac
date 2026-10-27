import AppKit
import PopCore

extension NSColor {
    /// Parses `#RRGGBB` or `#RRGGBBAA`.
    /// The color as `#RRGGBB` in sRGB.
    var hexString: String {
        let c = usingColorSpace(.sRGB) ?? self
        func byte(_ v: CGFloat) -> Int { Int((min(max(v, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", byte(c.redComponent), byte(c.greenComponent), byte(c.blueComponent))
    }

    /// Black or white, whichever reads better on this color.
    var contrastingText: NSColor {
        let c = usingColorSpace(.sRGB) ?? self
        let luminance = 0.2126 * c.redComponent + 0.7152 * c.greenComponent + 0.0722 * c.blueComponent
        return luminance > 0.55 ? .black : .white
    }

    convenience init?(hex: String) {
        var text = hex.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("#") { text.removeFirst() }
        guard text.count == 6 || text.count == 8, let value = UInt64(text, radix: 16) else { return nil }
        let hasAlpha = text.count == 8
        let r = Double((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let g = Double((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let b = Double((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let a = hasAlpha ? Double(value & 0xFF) / 255 : 1
        self.init(srgbRed: r, green: g, blue: b, alpha: a)
    }
}

/// A borderless, click-through window that draws a rounded rectangle.
class ShapeWindow: NSPanel {
    let shape = CALayer()

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
        view.layer?.addSublayer(shape)
        contentView = view
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the shape around a top-left-origin rectangle.
    func show(_ rect: Rect) {
        setFrame(Displays.toCocoa(rect), display: false)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shape.frame = contentView?.bounds ?? .zero
        CATransaction.commit()
        if !isVisible { orderFrontRegardless() }
    }

    func hide() {
        orderOut(nil)
    }
}

/// The highlight that shows where a window will go in tile mode or on drop.
///
/// Clear Liquid Glass on macOS 26 and later, a tinted fill with a border before.
final class OverlayWindow: ShapeWindow {
    private var glass: NSView?
    /// The corner radius for windows whose radius the window server does not tell.
    private var radius: Double = 10
    /// A tab along the top, shown when a drop stacks the window. It lies above the glass.
    private let tabLayer = CALayer()

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
        let tabView = NSView(frame: contentView.bounds)
        tabView.autoresizingMask = [.width, .height]
        tabView.wantsLayer = true
        tabView.layer?.addSublayer(tabLayer)
        contentView.addSubview(tabView)
        tabLayer.isHidden = true
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
        tabLayer.backgroundColor = color.withAlphaComponent(0.8).cgColor
    }

    /// Shows the highlight with the rounded corners of `window`, and a tab of `tabHeight`
    /// along the top if it is above zero.
    func show(_ rect: Rect, like window: WindowID?, tabHeight: Double = 0) {
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
        guard tabHeight > 0 else { return }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        // A pill inside the top band. Layer coordinates start at the bottom.
        let inset = 4.0
        let height = tabHeight - 2 * inset
        tabLayer.frame = CGRect(x: inset * 2, y: rect.height - tabHeight + inset, width: rect.width - inset * 4, height: height)
        tabLayer.cornerRadius = height / 2
        tabLayer.isHidden = false
        CATransaction.commit()
    }

    override func show(_ rect: Rect) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        tabLayer.isHidden = true
        CATransaction.commit()
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
            // Plain glass: the highlight color is for the border before macOS 26.
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
        show(rect.inset(by: -width))
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
