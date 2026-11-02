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
    /// The rounded track behind the tabs: Liquid Glass on macOS 26 and later.
    private var track = NSView()
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
    private var shown: (tabs: [Tab], active: WindowID)?

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
        tabsView.spacing = 2
        tabsView.edgeInsets = NSEdgeInsets(top: 2, left: 2, bottom: 2, right: 2)
        tabsView.wantsLayer = true
        // One track holds the tabs, like the tab bar of Safari.
        if #available(macOS 26, *) {
            let glass = NSGlassEffectView()
            glass.contentView = tabsView
            track = glass
        } else {
            track.wantsLayer = true
            track.layer?.backgroundColor = NSColor(white: 0.14, alpha: 0.92).cgColor
            tabsView.translatesAutoresizingMaskIntoConstraints = false
            track.addSubview(tabsView)
            NSLayoutConstraint.activate([
                tabsView.leadingAnchor.constraint(equalTo: track.leadingAnchor),
                tabsView.trailingAnchor.constraint(equalTo: track.trailingAnchor),
                tabsView.topAnchor.constraint(equalTo: track.topAnchor),
                tabsView.bottomAnchor.constraint(equalTo: track.bottomAnchor),
            ])
        }
        contentView = track
    }

    private static let trackShade = NSColor(name: nil) {
        $0.isDark ? NSColor(white: 0, alpha: 0.4) : NSColor(white: 1, alpha: 0.4)
    }

    /// The bar is a non-activating panel, so it takes key presses without activating Pop Mac.
    override var canBecomeKey: Bool { isRenaming }
    override var canBecomeMain: Bool { false }

    /// A click in another window ends the rename, and keeps the new name.
    override func resignKey() {
        super.resignKey()
        if isRenaming { makeFirstResponder(nil) }
    }

    func update(tabs: [Tab], active: WindowID, frame: Rect, above window: WindowID) {
        // A rebuild would remove the name field. The next update after the rename rebuilds the bar.
        if !isRenaming, shown?.tabs != tabs || shown?.active != active {
            shown = (tabs, active)
            dropGhost()
            for view in tabsView.arrangedSubviews {
                tabsView.removeArrangedSubview(view)
                view.removeFromSuperview()
            }
            for tab in tabs {
                let button = TabButton(tab: tab, isActive: tab.id == active)
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
        // The track is a pill, with fully round ends.
        let radius = CGFloat(frame.height) / 2
        if #available(macOS 26, *), let glass = track as? NSGlassEffectView {
            glass.cornerRadius = radius
            // A shade over the glass, so the wallpaper shows less, as in Safari.
            tabsView.layer?.cornerRadius = radius
            effectiveAppearance.performAsCurrentDrawingAppearance {
                tabsView.layer?.backgroundColor = Self.trackShade.cgColor
            }
        } else {
            track.layer?.cornerRadius = radius
        }
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
        // The same choices as titled items, for the keyboard and VoiceOver.
        let submenu = NSMenu()
        for color in [nil] + TabColor.allCases.map(Optional.some) {
            let item = ActionMenuItem(title: color?.name ?? "None") { [weak self] in
                self?.onColor?(tab.id, color)
            }
            item.state = color == tab.color ? .on : .off
            item.image = color.map(TabColorPicker.swatch)
            submenu.addItem(item)
        }
        let colorItem = NSMenuItem(title: "Tab Color", action: nil, keyEquivalent: "")
        colorItem.submenu = submenu
        menu.addItem(colorItem)
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

/// An item of the tab bar, which reports clicks, drags, and the mouse over it.
private class BarItem: NSView {
    var onClick: (() -> Void)?
    /// Called while the item is dragged, with the mouse in window coordinates.
    var onDragMoved: ((NSPoint) -> Void)?
    /// Called when the drag ended, with the modifiers held at mouse-up.
    var onDragEnded: ((CGEventFlags) -> Void)?
    /// Called on a secondary click, such as a two-finger click.
    var onMenu: ((NSEvent) -> Void)?
    /// Where the mouse went down, in window coordinates.
    private(set) var downPoint: NSPoint?
    /// While true, clicks reach the item's content, such as a text field.
    var passesClicksToContent = false
    private var isDragging = false
    /// True while the mouse is over the item.
    private(set) var isHovered = false

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
    }

    required init?(coder _: NSCoder) { nil }

    /// Called when the mouse enters or leaves the item.
    func hoverChanged() {}

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self))
    }

    override func mouseEntered(with _: NSEvent) {
        isHovered = true
        hoverChanged()
    }

    override func mouseExited(with _: NSEvent) {
        isHovered = false
        hoverChanged()
    }

    /// True while a copy of the item floats elsewhere, so only an empty slot shows.
    var isPlaceholder = false {
        didSet { alphaValue = isPlaceholder ? 0 : 1 }
    }

    /// The item takes every click inside it, so its content never swallows one.
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

/// The pill behind a tab: raised for the selected tab, faint under the mouse,
/// and a left-to-right pastel gradient for a colored tab.
private final class TabFill: NSView {
    enum Style: Equatable {
        case none
        /// A faint fill, as under the mouse.
        case hover
        /// The selected tab, lifted off the bar with a light edge and a shadow.
        case raised
        /// A colored tab, raised if selected.
        case colored(TabColor, raised: Bool)
    }

    var style = Style.none {
        didSet { if style != oldValue { apply() } }
    }

    private static let raisedFill = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.16) : NSColor(white: 1, alpha: 0.9) }
    private static let hoverFill = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.07) : NSColor(white: 0, alpha: 0.05) }
    private static let edge = NSColor(name: nil) { $0.isDark ? NSColor(white: 1, alpha: 0.12) : NSColor(white: 0, alpha: 0.08) }

    init() {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        guard let layer = layer as? CAGradientLayer else { return }
        layer.startPoint = CGPoint(x: 0, y: 0.5)
        layer.endPoint = CGPoint(x: 1, y: 0.5)
        layer.shadowOffset = CGSize(width: 0, height: -1)
        layer.shadowRadius = 2
        layer.shadowColor = NSColor.black.cgColor
    }

    required init?(coder _: NSCoder) { nil }

    override func makeBackingLayer() -> CALayer { CAGradientLayer() }

    /// Clicks go to the tab.
    override func hitTest(_: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        layer?.cornerRadius = bounds.height / 2
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        apply()
    }

    private func apply() {
        guard let layer = layer as? CAGradientLayer else { return }
        let (colors, raised): ([NSColor], Bool) = switch style {
        case .none: ([.clear, .clear], false)
        case .hover: ([Self.hoverFill, Self.hoverFill], false)
        case .raised: ([Self.raisedFill, Self.raisedFill], true)
        case let .colored(color, raised): (color.gradient(alpha: raised ? 0.8 : 0.6), raised)
        }
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer.colors = colors.map(\.cgColor)
            layer.borderColor = Self.edge.cgColor
        }
        layer.borderWidth = raised ? 0.5 : 0
        layer.shadowOpacity = raised ? 0.25 : 0
    }
}

private extension NSAppearance {
    var isDark: Bool { bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
}

private final class TabButton: BarItem, NSTextFieldDelegate {
    /// The dots at the tab's right end, which drag the tab along the bar. They show under the mouse.
    private let grip = NSImageView()
    /// True while a drag that began on the grip lasts.
    private(set) var isDraggedByGrip = false
    private let tab: StackTabBar.Tab
    private let isActive: Bool
    /// True for the copy that follows the mouse while the tab is dragged.
    private let isLifted: Bool
    private let fill = TabFill()
    /// The icon and the name, centered in the tab.
    private let content = NSStackView()
    private let label: NSTextField
    /// The field that edits the tab's name, while a rename lasts.
    private var nameField: NSTextField?
    /// Called once when the rename ends, with the new name or nil if it was canceled,
    /// and true if the user pressed a key that hands the keyboard back.
    private var onRenameEnd: ((String?, Bool) -> Void)?

    init(tab: StackTabBar.Tab, isActive: Bool, lifted: Bool = false) {
        self.tab = tab
        self.isActive = isActive
        isLifted = lifted
        label = NSTextField(labelWithString: tab.title.isEmpty ? "Untitled" : tab.title)
        super.init()

        // Dark text reads best on the pastel colors.
        let textColor: NSColor = if tab.color != nil {
            NSColor.black.withAlphaComponent(isActive || lifted ? 0.85 : 0.7)
        } else {
            isActive || lifted ? .labelColor : .secondaryLabelColor
        }

        label.font = .systemFont(ofSize: 11, weight: isActive ? .medium : .regular)
        label.textColor = textColor
        label.lineBreakMode = .byTruncatingTail
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        let icon = NSImageView(image: tab.icon ?? NSImage())
        icon.imageScaling = .scaleProportionallyUpOrDown
        content.orientation = .horizontal
        content.spacing = 5
        content.addArrangedSubview(icon)
        content.addArrangedSubview(label)
        content.translatesAutoresizingMaskIntoConstraints = false

        grip.image = NSImage(systemSymbolName: "circle.grid.3x3.fill", accessibilityDescription: "Reorder tab")
        grip.symbolConfiguration = .init(pointSize: 8, weight: .regular)
        grip.contentTintColor = textColor.withAlphaComponent(0.6)
        grip.translatesAutoresizingMaskIntoConstraints = false
        grip.toolTip = "Drag to reorder the tab"

        addSubview(fill)
        addSubview(content)
        addSubview(grip)
        // The name stays centered in the tab, unless it is too long to fit beside the grip.
        let centered = content.centerXAnchor.constraint(equalTo: centerXAnchor)
        centered.priority = .defaultLow
        NSLayoutConstraint.activate([
            fill.leadingAnchor.constraint(equalTo: leadingAnchor),
            fill.trailingAnchor.constraint(equalTo: trailingAnchor),
            fill.topAnchor.constraint(equalTo: topAnchor),
            fill.bottomAnchor.constraint(equalTo: bottomAnchor),
            icon.widthAnchor.constraint(equalToConstant: 14),
            icon.heightAnchor.constraint(equalToConstant: 14),
            centered,
            content.centerYAnchor.constraint(equalTo: centerYAnchor),
            content.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor, constant: 10),
            content.trailingAnchor.constraint(lessThanOrEqualTo: grip.leadingAnchor, constant: -4),
            grip.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            grip.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        hoverChanged()
    }

    required init?(coder _: NSCoder) { nil }

    /// A copy of the tab, lifted, to follow the mouse.
    func copy() -> TabButton {
        TabButton(tab: tab, isActive: isActive, lifted: true)
    }

    override func hoverChanged() {
        let raised = isActive || isLifted
        fill.style = if let color = tab.color {
            .colored(color, raised: raised)
        } else if raised {
            .raised
        } else {
            isHovered ? .hover : .none
        }
        grip.alphaValue = isHovered || isLifted ? 1 : 0
    }

    override func mouseDown(with event: NSEvent) {
        // The grip takes the tab's end, from a little left of its dots, so it is easy to hit.
        let point = convert(event.locationInWindow, from: nil)
        isDraggedByGrip = point.x >= grip.frame.minX - 4
        super.mouseDown(with: event)
    }

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
        field.alignment = .center
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)
        NSLayoutConstraint.activate([
            field.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            field.trailingAnchor.constraint(equalTo: grip.leadingAnchor, constant: -4),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        content.isHidden = true
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
        content.isHidden = false
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

    func sync(_ entries: [Entry], actions: Actions) {
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
            bar.update(tabs: entry.tabs, active: entry.stack.active, frame: entry.frame, above: entry.stack.active)
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
