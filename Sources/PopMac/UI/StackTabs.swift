import AppKit
import PopCore

/// The tab bar drawn above a stack of windows.
///
/// A click on a tab focuses its window. A drag of the grip at a tab's right
/// end moves the tab to another position. A drag of the rest moves the whole stack.
/// A secondary click opens a menu that renames the tab or gives it a color.
/// The bar glides along when its stack moves.
final class StackTabBar: NSPanel, GlidingWindow {
    private let tabsView = NSStackView()
    /// The copy of a tab dragged by its grip, which follows the mouse,
    /// with how far right of the tab's center the mouse grabbed it.
    private var grabbed: (ghost: TabGhost, offset: CGFloat)?
    var targetFrame: NSRect?
    var fadeGeneration = 0
    var isFadingOut = false
    var onSelect: ((WindowID) -> Void)?
    /// Called when a tab dragged by its grip was dropped, with its new index.
    var onReorder: ((WindowID, Int) -> Void)?
    var onDrag: ((DragPhase) -> Void)?
    /// Called when the user renamed a tab. An empty name shows the window's title again.
    var onRename: ((WindowID, String) -> Void)?
    /// Called when the user picked a color for a tab, or nil for none.
    var onColor: ((WindowID, TabColor?) -> Void)?
    /// True while a tab's name is edited. Only then can the bar take key presses.
    private var isRenaming = false

    enum DragPhase {
        case moved
        /// The drag ended, with the modifiers held at mouse-up.
        case ended(CGEventFlags)
    }

    struct Tab: Equatable {
        let id: WindowID
        /// The name the user gave the tab, or else the window's title.
        let title: String
        let icon: NSImage?
        var color: TabColor?
        /// True if the user gave the tab a name.
        var isRenamed = false
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
        tabsView.wantsLayer = true
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

    /// The bar is a non-activating panel, so it takes key presses without activating Pop Mac.
    override var canBecomeKey: Bool { isRenaming }
    override var canBecomeMain: Bool { false }

    /// A click in another window ends the rename, and keeps the new name.
    override func resignKey() {
        super.resignKey()
        if isRenaming { makeFirstResponder(nil) }
    }

    func update(tabs: [Tab], active: WindowID, color: NSColor, frame: Rect, above window: WindowID) {
        // A rebuild would remove the name field. The next update after the rename rebuilds the bar.
        if !isRenaming, shown?.tabs != tabs || shown?.active != active || shown?.color != color {
            shown = (tabs, active, color)
            dropGhost()
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
                    if button.isDraggedByGrip { dragEnded(button, id: tab.id) } else { onDrag?(.ended(flags)) }
                }
                button.onMenu = { [weak self, weak button] event in
                    guard let self, let button else { return }
                    showMenu(for: tab, of: button, event: event)
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

    // MARK: - Names and colors

    private func showMenu(for tab: Tab, of button: TabButton, event: NSEvent) {
        guard !isRenaming else { return }
        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.addItem(ActionMenuItem(title: "Rename Tab…") { [weak self, weak button] in
            guard let self, let button else { return }
            rename(button, id: tab.id)
        })
        if tab.isRenamed {
            menu.addItem(ActionMenuItem(title: "Show Window Title") { [weak self] in
                self?.onRename?(tab.id, "")
            })
        }
        menu.addItem(.separator())
        let colors = NSMenuItem()
        colors.view = TabColorPicker(selected: tab.color) { [weak self] color in
            self?.onColor?(tab.id, color)
        }
        menu.addItem(colors)
        NSMenu.popUpContextMenu(menu, with: event, for: button)
    }

    /// Turns the tab's name into a text field and takes the keyboard.
    private func rename(_ button: TabButton, id: WindowID) {
        dropGhost()
        isRenaming = true
        makeKey()
        button.beginRename { [weak self] name, refocus in
            guard let self else { return }
            isRenaming = false
            if let name { onRename?(id, name) }
            // Return or Escape hands the keyboard back to the stack's window.
            if refocus, let window { onSelect?(window) }
        }
    }

    // MARK: - Reordering

    /// Floats a copy of the dragged tab under the mouse, and slides the other tabs out of its way.
    ///
    /// The dragged tab stays behind as an empty slot. It moves to the slot nearest to the copy.
    private func dragMoved(_ button: TabButton, to point: NSPoint) {
        // A rebuild of the bar during the drag removed the tab.
        guard tabsView.arrangedSubviews.contains(button) else { return }
        if grabbed == nil {
            let down = tabsView.convert(button.downPoint ?? point, from: nil)
            let ghost = TabGhost(showing: button.copy())
            addChildWindow(ghost, ordered: .above)
            grabbed = (ghost, down.x - button.frame.midX)
            button.isPlaceholder = true
        }
        guard let grabbed else { return }

        // The copy stays inside the bar.
        let half = button.frame.width / 2
        let x = tabsView.convert(point, from: nil).x - grabbed.offset
        let center = min(max(x, half), max(tabsView.bounds.width - half, half))

        // The tabs have equal widths, so the slots are one tab and one gap apart.
        let pitch = button.frame.width + tabsView.spacing
        let last = tabsView.arrangedSubviews.count - 1
        let index = min(max(Int(((center - half) / pitch).rounded()), 0), last)
        if tabsView.arrangedSubviews.firstIndex(of: button) != index {
            // The tab stays in the view tree, so it keeps getting the drag's events.
            tabsView.removeArrangedSubview(button)
            tabsView.insertArrangedSubview(button, at: index)
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.2
                context.allowsImplicitAnimation = true
                tabsView.layoutSubtreeIfNeeded()
            }
        }

        var slot = button.frame
        slot.origin.x = center - half
        grabbed.ghost.lift(over: screenFrame(of: slot))
    }

    /// Settles the copy into the dragged tab's slot, then reports the tab's new index.
    private func dragEnded(_ button: TabButton, id: WindowID) {
        guard let ghost = grabbed?.ghost, let index = tabsView.arrangedSubviews.firstIndex(of: button) else {
            dropGhost()
            return
        }
        grabbed = nil
        // The model changes after the animation, because the change rebuilds the tabs.
        ghost.settle(onto: screenFrame(of: button.frame)) { [weak self, weak button] in
            button?.isPlaceholder = false
            self?.removeChildWindow(ghost)
            ghost.orderOut(nil)
            self?.onReorder?(id, index)
        }
    }

    /// Removes the copy of a dragged tab right away.
    private func dropGhost() {
        guard let ghost = grabbed?.ghost else { return }
        removeChildWindow(ghost)
        ghost.orderOut(nil)
        grabbed = nil
    }

    private func screenFrame(of rect: NSRect) -> NSRect {
        convertToScreen(tabsView.convert(rect, to: nil))
    }
}

/// A rounded item of the tab bar, which reports clicks and drags.
private class BarItem: NSView {
    var onClick: (() -> Void)?
    /// Called while the item is dragged, with the mouse in window coordinates.
    var onDragMoved: ((NSPoint) -> Void)?
    /// Called when the drag ended, with the modifiers held at mouse-up.
    var onDragEnded: ((CGEventFlags) -> Void)?
    /// Called on a secondary click, such as a two-finger click.
    var onMenu: ((NSEvent) -> Void)?
    /// The view that holds the item's content.
    private(set) var body: NSView!
    /// Where the mouse went down, in window coordinates.
    private(set) var downPoint: NSPoint?
    /// While true, clicks reach the item's content, such as a text field.
    var passesClicksToContent = false
    private var isDragging = false
    private var glass: NSView?

    /// Liquid Glass on macOS 26 and later, tinted with `tint`. A solid rounded rectangle before.
    ///
    /// A `gradient` fills the item from left to right, over the glass.
    init(tint: NSColor?, gradient colors: [NSColor]? = nil) {
        super.init(frame: .zero)
        defer { addGradient(colors) }
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
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

    private func addGradient(_ colors: [NSColor]?) {
        guard let colors else { return }
        let view = GradientView(colors: colors, pill: glass != nil)
        body.addSubview(view, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: body.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: body.trailingAnchor),
            view.topAnchor.constraint(equalTo: body.topAnchor),
            view.bottomAnchor.constraint(equalTo: body.bottomAnchor),
        ])
    }

    override func layout() {
        super.layout()
        // A pill: fully round ends at any height.
        if #available(macOS 26, *), let glass = glass as? NSGlassEffectView {
            glass.cornerRadius = bounds.height / 2
        }
    }

    /// True while a copy of the item floats elsewhere, so only an empty slot shows.
    var isPlaceholder = false {
        didSet {
            if let glass { glass.isHidden = isPlaceholder } else { alphaValue = isPlaceholder ? 0 : 1 }
        }
    }

    /// The item takes every click inside it, so its content and glass never swallow one.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard frame.contains(point) else { return nil }
        return passesClicksToContent ? super.hitTest(point) ?? self : self
    }

    /// Pop Mac is never the active app, so the first click must count.
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

    override func rightMouseDown(with event: NSEvent) {
        guard !passesClicksToContent, let onMenu else { return super.rightMouseDown(with: event) }
        onMenu(event)
    }

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

/// A left-to-right gradient with rounded ends, which sizes itself with its view.
private final class GradientView: NSView {
    private let pill: Bool

    /// With `pill`, the ends are fully round, like Liquid Glass. Otherwise the corners are slightly round.
    init(colors: [NSColor], pill: Bool) {
        self.pill = pill
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        guard let layer = layer as? CAGradientLayer else { return }
        layer.colors = colors.map(\.cgColor)
        layer.startPoint = CGPoint(x: 0, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
    }

    required init?(coder _: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { CAGradientLayer() }

    /// Clicks go to the tab.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = pill ? bounds.height / 2 : 6
    }
}

private final class TabButton: BarItem, NSTextFieldDelegate {
    /// The dots at the tab's right end, which drag the tab along the bar.
    private let grip = NSImageView()
    /// True while a drag that began on the grip lasts.
    private(set) var isDraggedByGrip = false
    private let tab: StackTabBar.Tab
    private let isActive: Bool
    private let color: NSColor
    private let label: NSTextField
    private let icon: NSImageView
    /// The field that edits the tab's name, while a rename lasts.
    private var nameField: NSTextField?
    /// Called once when the rename ends, with the new name or nil if it was canceled,
    /// and true if the user pressed a key that hands the keyboard back.
    private var onRenameEnd: ((String?, Bool) -> Void)?

    init(tab: StackTabBar.Tab, isActive: Bool, color: NSColor) {
        self.tab = tab
        self.isActive = isActive
        self.color = color
        label = NSTextField(labelWithString: tab.title.isEmpty ? "Untitled" : tab.title)
        icon = NSImageView(image: tab.icon ?? NSImage())

        // A colored tab shows its color instead of the accent color. The selected tab
        // shows the color fully, the others faintly.
        let gradient = tab.color.map { $0.gradient(alpha: isActive ? 0.95 : 0.4) }
        super.init(tint: isActive && tab.color == nil ? color : nil, gradient: gradient)

        let textColor: NSColor = if isActive, tab.color != nil {
            NSColor.black.withAlphaComponent(0.82)
        } else if isActive {
            color.contrastingText
        } else if #available(macOS 26, *) {
            .labelColor
        } else if tab.color != nil {
            NSColor.black.withAlphaComponent(0.82)
        } else {
            .white
        }

        label.font = .systemFont(ofSize: 11, weight: isActive ? .semibold : .regular)
        label.textColor = textColor
        label.lineBreakMode = .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

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

    /// A new tab that looks the same.
    func copy() -> TabButton {
        TabButton(tab: tab, isActive: isActive, color: color)
    }

    override func mouseDown(with event: NSEvent) {
        // The grip takes the tab's end, from a little left of its dots, so it is easy to hit.
        let point = convert(event.locationInWindow, from: nil)
        isDraggedByGrip = point.x >= grip.convert(grip.bounds, to: self).minX - 4
        super.mouseDown(with: event)
    }

    required init?(coder _: NSCoder) { nil }

    // MARK: - Renaming

    /// Puts a text field with the tab's name in place of the name, with the name selected.
    ///
    /// The tab's window must be key already.
    func beginRename(onEnd: @escaping (String?, Bool) -> Void) {
        guard nameField == nil else { return }
        let field = NSTextField(string: tab.title)
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = label.font
        field.textColor = label.textColor
        field.usesSingleLineMode = true
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.placeholderString = "Window title"
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        body.addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: icon.trailingAnchor, constant: 2),
            field.trailingAnchor.constraint(equalTo: grip.leadingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: body.centerYAnchor),
        ])
        label.isHidden = true
        nameField = field
        onRenameEnd = onEnd
        passesClicksToContent = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.cancelOperation(_:)):
            endRename(keep: false, refocus: true)
        case #selector(NSResponder.insertNewline(_:)), #selector(NSResponder.insertTab(_:)),
             #selector(NSResponder.insertBacktab(_:)):
            endRename(keep: true, refocus: true)
        default:
            return false
        }
        return true
    }

    /// The field lost the keyboard, as after a click in another window.
    func controlTextDidEndEditing(_: Notification) {
        endRename(keep: true, refocus: false)
    }

    private func endRename(keep: Bool, refocus: Bool) {
        guard let field = nameField, let onEnd = onRenameEnd else { return }
        // Cleared first: removing the field ends its editing, which calls back here.
        nameField = nil
        onRenameEnd = nil
        let name = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        window?.makeFirstResponder(nil)
        field.removeFromSuperview()
        passesClicksToContent = false
        if keep, !name.isEmpty { label.stringValue = name }
        label.isHidden = false
        onEnd(keep ? name : nil, refocus)
    }
}

/// A copy of a tab that floats above the tab bar while the tab is dragged.
private final class TabGhost: NSPanel {
    init(showing tab: NSView) {
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        ignoresMouseEvents = true
        isReleasedWhenClosed = false
        animationBehavior = .none
        collectionBehavior = [.transient, .ignoresCycle]

        let content = NSView()
        content.addSubview(tab)
        NSLayoutConstraint.activate([
            tab.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            tab.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            tab.topAnchor.constraint(equalTo: content.topAnchor),
            tab.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        contentView = content
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    /// Shows the tab a little larger than `slot`, as if it was lifted off the bar.
    func lift(over slot: NSRect) {
        setFrame(slot.insetBy(dx: -3, dy: -1.5), display: true)
        invalidateShadow()
    }

    /// Shrinks the tab into `slot`, then calls `completion`.
    func settle(onto slot: NSRect, completion: @escaping () -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.15
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            animator().setFrame(slot, display: true)
        } completionHandler: {
            MainActor.assumeIsolated { completion() }
        }
    }
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

    /// What the tab bars do when the user works with them.
    struct Actions {
        /// Focuses a tab's window.
        var select: (WindowID) -> Void
        /// Moves a tab to a new index in its stack.
        var reorder: (WindowID, Int) -> Void
        /// Moves the whole stack.
        var drag: (StackNode, StackTabBar.DragPhase) -> Void
        /// Names a tab. An empty name shows the window's title again.
        var rename: (WindowID, String) -> Void
        /// Colors a tab, or removes its color.
        var color: (WindowID, TabColor?) -> Void
    }

    private var bars: [Int: StackTabBar] = [:]

    func sync(_ entries: [Entry], color: NSColor, actions: Actions) {
        var seen = Set<Int>()
        for entry in entries {
            seen.insert(entry.stack.id)
            let bar = bars[entry.stack.id] ?? StackTabBar()
            bars[entry.stack.id] = bar
            bar.onSelect = actions.select
            bar.onReorder = actions.reorder
            bar.onRename = actions.rename
            bar.onColor = actions.color
            let stack = entry.stack
            bar.onDrag = { actions.drag(stack, $0) }
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
