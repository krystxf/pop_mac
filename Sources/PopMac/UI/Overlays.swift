import AppKit
import PopCore

extension NSColor {
    /// Parses `#RRGGBB` or `#RRGGBBAA`.
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
final class OverlayWindow: ShapeWindow {
    init() {
        super.init(level: .floating)
    }

    func style(color: NSColor, radius: Double) {
        shape.backgroundColor = color.withAlphaComponent(0.25).cgColor
        shape.borderColor = color.cgColor
        shape.borderWidth = 3
        shape.cornerRadius = radius
    }
}
