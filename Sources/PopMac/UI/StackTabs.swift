import AppKit
import PopCore

/// The tab bar drawn above a stack of windows.
///
/// A click on a tab focuses its window. A drag of the grip at a tab's right
/// end moves the tab to another position. A drag of the rest moves the whole stack.
/// The bar glides along when its stack moves.
final class StackTabBar: NSPanel, GlidingWindow {
    private let tabsView = NSStackView()
    var targetFrame: NSRect?
    var fadeGeneration = 0
    var isFadingOut = false
    var onSelect: ((WindowID) -> Void)?
    /// Called when a tab dragged by its grip was dropped, with its new index.
    var onReorder: ((WindowID, Int) -> Void)?
    var onDrag: ((DragPhase) -> Void)?

    enum DragPhase {
        case moved
        /// The drag ended, with the modifiers held at mouse-up.
        case ended(CGEventFlags)
    }

    struct Tab: Equatable {
        let id: WindowID
        let title: String
        let icon: NSImage?
    }

    /// The stack's selected window, which the bar stays above.
    private(set) var window: WindowID?

    /// What the bar shows now, so an unchanged bar is not rebuilt.
    private var shown: (tabs: [Tab], active: WindowID, color: NSColor)?

    init() {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isReleasedWhenClosed = false
        hidesOnDeactivate = false
        animationBehavior = .none
        level = .normal
        collectionBehavior = [.transient, .ignoresCycle]

        tabsView.orientation = .horizontal
        tabsView.distribution = .fillEqually
        tabsView.spacing = 4
        tabsView.edgeInsets = NSEdgeInsets(top: 1, left: 0, bottom: 1, right: 0)
        if #available(macOS 26, *) {
            // The tabs' glass blends where they meet, like one bar.
            let container = NSGlassEffectContainerView()
            container.spacing = 6
            container.contentView = tabsView
            contentView = container
        } else {
            contentView = tabsView
        }
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    func update(tabs: [Tab], active: WindowID, color: NSColor, frame: Rect, above window: WindowID) {
        if shown?.tabs != tabs || shown?.active != active || shown?.color != color {
            shown = (tabs, active, color)
            for view in tabsView.arrangedSubviews {
                tabsView.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for tab in tabs {
                let button = TabButton(tab: tab, isActive: tab.id == active, color: color)
                button.onClick = { [weak self] in self?.onSelect?(tab.id) }
                button.onDragMoved = { [weak self, weak button] point in
                    guard let self, let button else { return }
                    if button.isDraggedByGrip { dragMoved(button, to: point) } else { onDrag?(.moved) }
                }
                button.onDragEnded = { [weak self, weak button] flags in
                    guard let self, let button else { return }
                    if !button.isDraggedByGrip {
                        onDrag?(.ended(flags))
                    } else if let index = tabsView.arrangedSubviews.firstIndex(of: button) {
                        onReorder?(tab.id, index)
                    }
                }
                tabsView.addArrangedSubview(button)
                // A horizontal stack view does not stretch its views to its height.
                let insets = tabsView.edgeInsets.top + tabsView.edgeInsets.bottom
                button.heightAnchor.constraint(equalTo: tabsView.heightAnchor, constant: -insets).isActive = true
            }
        }

        self.window = window
        appear(at: Displays.toCocoa(frame))
        order(.above, relativeTo: Int(window))
    }

    /// Moves the dragged tab to the place under the mouse.
    ///
    /// The tab takes the place after every other tab whose center is left of the mouse.
    private func dragMoved(_ button: NSView, to point: NSPoint) {
        let x = tabsView.convert(point, from: nil).x
        let index = tabsView.arrangedSubviews.filter { $0 !== button && $0.frame.midX < x }.count
        guard tabsView.arrangedSubviews.firstIndex(of: button) != index else { return }
        // The tab stays in the view tree, so it keeps getting the drag's events.
        tabsView.removeArrangedSubview(button)
        tabsView.insertArrangedSubview(button, at: index)
        tabsView.layoutSubtreeIfNeeded()
    }
}

/// A rounded item of the tab bar, which reports clicks and drags.
private class BarItem: NSView {
    var onClick: (() -> Void)?
    /// Called while the item is dragged, with the mouse in window coordinates.
    var onDragMoved: ((NSPoint) -> Void)?
    /// Called when the drag ended, with the modifiers held at mouse-up.
    var onDragEnded: ((CGEventFlags) -> Void)?
    /// The view that holds the item's content.
    private(set) var body: NSView!
    private var downPoint: NSPoint?
    private var isDragging = false
    private var glass: NSView?

    /// Liquid Glass on macOS 26 and later, tinted with `tint`. A solid rounded rectangle before.
    init(tint: NSColor?) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            self.glass = glass
            glass.tintColor = tint?.withAlphaComponent(0.8)
            glass.translatesAutoresizingMaskIntoConstraints = false
            body = NSView()
            glass.contentView = body
            addSubview(glass)
            NSLayoutConstraint.activate([
                glass.leadingAnchor.constraint(equalTo: leadingAnchor),
                glass.trailingAnchor.constraint(equalTo: trailingAnchor),
                glass.topAnchor.constraint(equalTo: topAnchor),
                glass.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
        } else {
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.backgroundColor = (tint ?? NSColor(srgbRed: 0.61, green: 0.56, blue: 0.54, alpha: 0.95)).cgColor
            body = self
        }
    }

    required init?(coder _: NSCoder) { nil }

    override func layout() {
        super.layout()
        // A pill: fully round ends at any height.
        if #available(macOS 26, *), let glass = glass as? NSGlassEffectView {
            glass.cornerRadius = bounds.height / 2
        }
    }

    /// The item takes every click inside it, so its content and glass never swallow one.
    override func hitTest(_ point: NSPoint) -> NSView? {
        frame.contains(point) ? self : nil
    }

    /// Pop Mac is never the active app, so the first click must count.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        downPoint = event.locationInWindow
        isDragging = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let downPoint else { return }
        let point = event.locationInWindow
        if !isDragging, hypot(point.x - downPoint.x, point.y - downPoint.y) > 4 {
            isDragging = true
        }
        if isDragging { onDragMoved?(point) }
    }

    override func mouseUp(with event: NSEvent) {
        if isDragging {
            onDragEnded?(CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
        } else if downPoint != nil {
            onClick?()
        }
        downPoint = nil
        isDragging = false
    }
}

private final class TabButton: BarItem {
    /// The dots at the tab's right end, which drag the tab along the bar.
    private let grip = NSImageView()
    /// True while a drag that began on the grip lasts.
    private(set) var isDraggedByGrip = false

    init(tab: StackTabBar.Tab, isActive: Bool, color: NSColor) {
        super.init(tint: isActive ? color : nil)

        let textColor: NSColor = if isActive {
            color.contrastingText
        } else if #available(macOS 26, *) {
            .labelColor
        } else {
            .white
        }

        let label = NSTextField(labelWithString: tab.title.isEmpty ? "Untitled" : tab.title)
        label.font = .systemFont(ofSize: 11, weight: isActive ? .semibold : .regular)
        label.textColor = textColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let icon = NSImageView(image: tab.icon ?? NSImage())
        icon.translatesAutoresizingMaskIntoConstraints = false
        icon.imageScaling = .scaleProportionallyUpOrDown

        grip.image = NSImage(systemSymbolName: "circle.grid.3x3.fill", accessibilityDescription: "Reorder tab")
        grip.symbolConfiguration = .init(pointSize: 8, weight: .regular)
        grip.contentTintColor = textColor.withAlphaComponent(0.6)
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.toolTip = "Drag to reorder the tab"

        body.addSubview(icon)
        body.addSubview(label)
        body.addSubview(grip)
        NSLayoutConstraint.activate([
            icon.leadingAnchor.constraint(equalTo: body.leadingAnchor, constant: 8),
            icon.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            label.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 4),
            label.trailingAnchor.constraint(lessThanOrEqualTo: grip.leadingAnchor, constant: -4),
            label.centerYAnchor.constraint(equalTo: body.centerYAnchor),
            grip.trailingAnchor.constraint(equalTo: body.trailingAnchor, constant: -8),
            grip.centerYAnchor.constraint(equalTo: body.centerYAnchor),
        ])
    }

    override func mouseDown(with event: NSEvent) {
        // The grip takes the tab's end, from a little left of its dots, so it is easy to hit.
        let point = convert(event.locationInWindow, from: nil)
        isDraggedByGrip = point.x >= grip.convert(grip.bounds, to: self).minX - 4
        super.mouseDown(with: event)
    }

    required init?(coder _: NSCoder) { nil }
}

/// Keeps one tab bar per stack on the visible Spaces.
@MainActor
final class StackTabsController {
    struct Entry {
        let stack: StackNode
        /// The bar's frame, above the stack.
        let frame: Rect
        let tabs: [StackTabBar.Tab]
    }

    private var bars: [Int: StackTabBar] = [:]

    func sync(
        _ entries: [Entry], color: NSColor,
        onSelect: @escaping (WindowID) -> Void,
        onReorder: @escaping (WindowID, Int) -> Void,
        onDrag: @escaping (StackNode, StackTabBar.DragPhase) -> Void
    ) {
        var seen = Set<Int>()
        for entry in entries {
            seen.insert(entry.stack.id)
            let bar = bars[entry.stack.id] ?? StackTabBar()
            bars[entry.stack.id] = bar
            bar.onSelect = onSelect
            bar.onReorder = onReorder
            let stack = entry.stack
            bar.onDrag = { onDrag(stack, $0) }
            bar.update(tabs: entry.tabs, active: entry.stack.active, color: color, frame: entry.frame, above: entry.stack.active)
        }
        for (id, bar) in bars where !seen.contains(id) {
            bar.disappear()
            bars.removeValue(forKey: id)
        }
    }

    /// Orders the tab bar of the stack whose selected window is `window` above that window again.
    func reorder(above window: WindowID) {
        for bar in bars.values where bar.window == window && bar.isVisible {
            bar.order(.above, relativeTo: Int(window))
        }
    }

    func removeAll() {
        for bar in bars.values { bar.disappear() }
        bars.removeAll()
    }
}
