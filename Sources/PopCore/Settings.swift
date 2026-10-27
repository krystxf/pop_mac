import Foundation

/// A modifier key on a Mac keyboard.
public enum MacModifier: String, Codable, CaseIterable, Hashable {
    case control, option, shift, command

    public var symbol: String {
        switch self {
        case .control: "⌃"
        case .option: "⌥"
        case .shift: "⇧"
        case .command: "⌘"
        }
    }

    init?(alias: String) {
        switch alias.lowercased() {
        case "control", "ctrl": self = .control
        case "option", "alt", "opt": self = .option
        case "shift": self = .shift
        case "command", "cmd", "meta": self = .command
        default: return nil
        }
    }
}

/// A parsed key binding such as `<Super><Shift>Left`.
///
/// `<Super>` and `<Primary>` resolve to configurable modifier sets, because a
/// Mac keyboard has no Super key.
public struct KeyCombo: Hashable, CustomStringConvertible {
    public var key: String
    public var modifiers: Set<MacModifier>

    public init(key: String, modifiers: Set<MacModifier>) {
        self.key = key
        self.modifiers = modifiers
    }

    public static func parse(_ text: String, superModifiers: Set<MacModifier>, primaryModifiers: Set<MacModifier>) -> KeyCombo? {
        var rest = Substring(text.trimmingCharacters(in: .whitespaces))
        var modifiers = Set<MacModifier>()

        while rest.hasPrefix("<") {
            guard let end = rest.firstIndex(of: ">") else { return nil }
            let name = rest[rest.index(after: rest.startIndex) ..< end]
            rest = rest[rest.index(after: end)...]

            switch name.lowercased() {
            case "super": modifiers.formUnion(superModifiers)
            case "primary": modifiers.formUnion(primaryModifiers)
            default:
                guard let m = MacModifier(alias: String(name)) else { return nil }
                modifiers.insert(m)
            }
        }

        guard !rest.isEmpty else { return nil }
        return KeyCombo(key: String(rest), modifiers: modifiers)
    }

    public var description: String {
        let order: [MacModifier] = [.control, .option, .shift, .command]
        return order.filter { modifiers.contains($0) }.map(\.symbol).joined() + Self.displayName(key)
    }

    static func displayName(_ key: String) -> String {
        switch key {
        case "Left", "KP_Left": "←"
        case "Right", "KP_Right": "→"
        case "Up", "KP_Up": "↑"
        case "Down", "KP_Down": "↓"
        case "Return": "↩"
        case "KP_Enter": "⌤"
        case "Escape": "⎋"
        case "slash": "/"
        case "comma": ","
        case "period": "."
        case "space": "Space"
        case "Tab": "⇥"
        default: key.count == 1 ? key.uppercased() : key
        }
    }
}

/// The actions that can be bound to keys. The names match Pop Shell's settings.
public enum Action: String, CaseIterable, Codable {
    // Global
    case activateLauncher = "activate-launcher"
    case tileEnter = "tile-enter"
    case focusLeft = "focus-left"
    case focusDown = "focus-down"
    case focusUp = "focus-up"
    case focusRight = "focus-right"
    case focusNextTab = "focus-next-tab"
    case focusPreviousTab = "focus-previous-tab"
    case tileOrientation = "tile-orientation"
    case toggleFloating = "toggle-floating"
    case toggleTiling = "toggle-tiling"
    case toggleStackingGlobal = "toggle-stacking-global"
    case tileMoveLeftGlobal = "tile-move-left-global"
    case tileMoveDownGlobal = "tile-move-down-global"
    case tileMoveUpGlobal = "tile-move-up-global"
    case tileMoveRightGlobal = "tile-move-right-global"
    case monitorLeft = "pop-monitor-left"
    case monitorRight = "pop-monitor-right"
    case monitorUp = "pop-monitor-up"
    case monitorDown = "pop-monitor-down"
    case workspaceUp = "pop-workspace-up"
    case workspaceDown = "pop-workspace-down"
    case toggleMaximize = "toggle-maximize"
    case closeWindow = "close-window"
    case minimizeWindow = "minimize-window"

    // Tile (management) mode
    case managementOrientation = "management-orientation"
    case toggleStacking = "toggle-stacking"
    case tileMoveLeft = "tile-move-left"
    case tileMoveDown = "tile-move-down"
    case tileMoveUp = "tile-move-up"
    case tileMoveRight = "tile-move-right"
    case tileResizeLeft = "tile-resize-left"
    case tileResizeDown = "tile-resize-down"
    case tileResizeUp = "tile-resize-up"
    case tileResizeRight = "tile-resize-right"
    case tileSwapLeft = "tile-swap-left"
    case tileSwapDown = "tile-swap-down"
    case tileSwapUp = "tile-swap-up"
    case tileSwapRight = "tile-swap-right"
    case tileAccept = "tile-accept"
    case tileReject = "tile-reject"

    /// True for bindings that only work inside tile mode.
    public var isTileMode: Bool {
        switch self {
        case .managementOrientation, .toggleStacking,
             .tileMoveLeft, .tileMoveDown, .tileMoveUp, .tileMoveRight,
             .tileResizeLeft, .tileResizeDown, .tileResizeUp, .tileResizeRight,
             .tileSwapLeft, .tileSwapDown, .tileSwapUp, .tileSwapRight,
             .tileAccept, .tileReject:
            true
        default:
            false
        }
    }

    public var summary: String {
        switch self {
        case .activateLauncher: "Launch and switch applications"
        case .tileEnter: "Enter tile mode"
        case .focusLeft: "Focus window to the left"
        case .focusDown: "Focus window below"
        case .focusUp: "Focus window above"
        case .focusRight: "Focus window to the right"
        case .focusNextTab: "Focus the next tab of the stack"
        case .focusPreviousTab: "Focus the previous tab of the stack"
        case .tileOrientation: "Toggle tiling orientation"
        case .toggleFloating: "Toggle floating mode for the window"
        case .toggleTiling: "Toggle auto-tiling"
        case .toggleStackingGlobal: "Toggle stacking for the window"
        case .tileMoveLeftGlobal: "Move window left"
        case .tileMoveDownGlobal: "Move window down"
        case .tileMoveUpGlobal: "Move window up"
        case .tileMoveRightGlobal: "Move window right"
        case .monitorLeft: "Move window to the display on the left"
        case .monitorRight: "Move window to the display on the right"
        case .monitorUp: "Move window to the display above"
        case .monitorDown: "Move window to the display below"
        case .workspaceUp: "Move window to the previous Space"
        case .workspaceDown: "Move window to the next Space"
        case .toggleMaximize: "Toggle maximize"
        case .closeWindow: "Close window"
        case .minimizeWindow: "Minimize window"
        case .managementOrientation: "Toggle orientation"
        case .toggleStacking: "Toggle stacking"
        case .tileMoveLeft: "Move window left"
        case .tileMoveDown: "Move window down"
        case .tileMoveUp: "Move window up"
        case .tileMoveRight: "Move window right"
        case .tileResizeLeft: "Shrink width"
        case .tileResizeDown: "Grow height"
        case .tileResizeUp: "Shrink height"
        case .tileResizeRight: "Grow width"
        case .tileSwapLeft: "Swap with window to the left"
        case .tileSwapDown: "Swap with window below"
        case .tileSwapUp: "Swap with window above"
        case .tileSwapRight: "Swap with window to the right"
        case .tileAccept: "Apply changes and exit tile mode"
        case .tileReject: "Cancel changes and exit tile mode"
        }
    }

    public static let defaultBindings: [Action: [String]] = [
        .activateLauncher: ["<Super>slash"],
        .tileEnter: ["<Super>Return", "<Super>KP_Enter"],
        .focusLeft: ["<Super>Left", "<Super>h"],
        .focusDown: ["<Super>Down", "<Super>j"],
        .focusUp: ["<Super>Up", "<Super>k"],
        .focusRight: ["<Super>Right", "<Super>l"],
        .focusNextTab: ["<Super>Tab"],
        .focusPreviousTab: ["<Super><Shift>Tab"],
        .tileOrientation: ["<Super>o"],
        .toggleFloating: ["<Super>g"],
        .toggleTiling: ["<Super>y"],
        .toggleStackingGlobal: ["<Super>s"],
        .tileMoveLeftGlobal: [],
        .tileMoveDownGlobal: [],
        .tileMoveUpGlobal: [],
        .tileMoveRightGlobal: [],
        .monitorLeft: ["<Super><Shift><Primary>Left", "<Super><Shift><Primary>h"],
        .monitorRight: ["<Super><Shift><Primary>Right", "<Super><Shift><Primary>l"],
        .monitorUp: ["<Super><Shift><Primary>Up", "<Super><Shift><Primary>k"],
        .monitorDown: ["<Super><Shift><Primary>Down", "<Super><Shift><Primary>j"],
        .workspaceUp: ["<Super><Shift>Up", "<Super><Shift>k"],
        .workspaceDown: ["<Super><Shift>Down", "<Super><Shift>j"],
        .toggleMaximize: ["<Super>m"],
        .closeWindow: ["<Super>q"],
        .minimizeWindow: ["<Super>comma"],

        .managementOrientation: ["o"],
        .toggleStacking: ["s"],
        .tileMoveLeft: ["Left", "h"],
        .tileMoveDown: ["Down", "j"],
        .tileMoveUp: ["Up", "k"],
        .tileMoveRight: ["Right", "l"],
        .tileResizeLeft: ["<Shift>Left", "<Shift>h"],
        .tileResizeDown: ["<Shift>Down", "<Shift>j"],
        .tileResizeUp: ["<Shift>Up", "<Shift>k"],
        .tileResizeRight: ["<Shift>Right", "<Shift>l"],
        .tileSwapLeft: ["<Primary>Left", "<Primary>h"],
        .tileSwapDown: ["<Primary>Down", "<Primary>j"],
        .tileSwapUp: ["<Primary>Up", "<Primary>k"],
        .tileSwapRight: ["<Primary>Right", "<Primary>l"],
        .tileAccept: ["Return", "KP_Enter"],
        .tileReject: ["Escape"],
    ]
}

/// Where the cursor goes when it follows the active window.
public enum FocusLocation: String, Codable, CaseIterable {
    case topLeft = "top-left"
    case topRight = "top-right"
    case bottomLeft = "bottom-left"
    case bottomRight = "bottom-right"
    case center

    public func point(in rect: Rect) -> Point {
        let inset = 8.0
        switch self {
        case .topLeft: return Point(rect.x + inset, rect.y + inset)
        case .topRight: return Point(rect.maxX - inset, rect.y + inset)
        case .bottomLeft: return Point(rect.x + inset, rect.maxY - inset)
        case .bottomRight: return Point(rect.maxX - inset, rect.maxY - inset)
        case .center: return rect.center
        }
    }
}

/// All user settings. Stored as JSON in `~/.config/pop-mac/config.json`.
public struct Settings: Codable, Equatable {
    public var tileByDefault = true
    /// The corner radius of the highlights, for windows whose own radius is unknown.
    public var overlayBorderRadius: Double = 10
    /// Draws an outline around the focused window.
    public var activeHint = true
    public var activeHintWidth: Double = 3
    /// Windows glide to their new frames, and the highlights glide and fade.
    public var animations = true
    public var gapInner: Double = 8
    public var gapOuter: Double = 8
    public var smartGaps = false
    public var snapToGrid = false
    /// Holding the Super modifiers and dragging anywhere in a window moves it.
    public var superDragMovesWindows = true
    public var mouseCursorFollowsActiveWindow = true
    public var mouseCursorFocusLocation: FocusLocation = .center
    public var columnSize: Double = 64
    public var rowSize: Double = 64
    /// Maximum width of tiled windows in points. Zero disables the limit.
    public var maxWindowWidth: Double = 0
    public var logOnFocus = false
    /// The modifiers that `<Super>` stands for.
    public var superModifiers: [MacModifier] = [.control, .option]
    /// The modifiers that `<Primary>` stands for.
    public var primaryModifiers: [MacModifier] = [.command]
    /// Overrides for the default key bindings, keyed by action name.
    public var keybindings: [String: [String]] = [:]
    /// Windows that float instead of tile.
    public var floatRules: [FloatRule] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        tileByDefault = try c.decodeIfPresent(Bool.self, forKey: .tileByDefault) ?? d.tileByDefault
        overlayBorderRadius = try c.decodeIfPresent(Double.self, forKey: .overlayBorderRadius) ?? d.overlayBorderRadius
        activeHint = try c.decodeIfPresent(Bool.self, forKey: .activeHint) ?? d.activeHint
        activeHintWidth = try c.decodeIfPresent(Double.self, forKey: .activeHintWidth) ?? d.activeHintWidth
        animations = try c.decodeIfPresent(Bool.self, forKey: .animations) ?? d.animations
        gapInner = try c.decodeIfPresent(Double.self, forKey: .gapInner) ?? d.gapInner
        gapOuter = try c.decodeIfPresent(Double.self, forKey: .gapOuter) ?? d.gapOuter
        smartGaps = try c.decodeIfPresent(Bool.self, forKey: .smartGaps) ?? d.smartGaps
        snapToGrid = try c.decodeIfPresent(Bool.self, forKey: .snapToGrid) ?? d.snapToGrid
        superDragMovesWindows = try c.decodeIfPresent(Bool.self, forKey: .superDragMovesWindows) ?? d.superDragMovesWindows
        mouseCursorFollowsActiveWindow = try c.decodeIfPresent(Bool.self, forKey: .mouseCursorFollowsActiveWindow) ?? d.mouseCursorFollowsActiveWindow
        mouseCursorFocusLocation = try c.decodeIfPresent(FocusLocation.self, forKey: .mouseCursorFocusLocation) ?? d.mouseCursorFocusLocation
        columnSize = try c.decodeIfPresent(Double.self, forKey: .columnSize) ?? d.columnSize
        rowSize = try c.decodeIfPresent(Double.self, forKey: .rowSize) ?? d.rowSize
        maxWindowWidth = try c.decodeIfPresent(Double.self, forKey: .maxWindowWidth) ?? d.maxWindowWidth
        logOnFocus = try c.decodeIfPresent(Bool.self, forKey: .logOnFocus) ?? d.logOnFocus
        superModifiers = try c.decodeIfPresent([MacModifier].self, forKey: .superModifiers) ?? d.superModifiers
        primaryModifiers = try c.decodeIfPresent([MacModifier].self, forKey: .primaryModifiers) ?? d.primaryModifiers
        keybindings = try c.decodeIfPresent([String: [String]].self, forKey: .keybindings) ?? d.keybindings
        floatRules = try c.decodeIfPresent([FloatRule].self, forKey: .floatRules) ?? d.floatRules
    }

    /// The key bindings for an action, with user overrides applied.
    public func bindings(for action: Action) -> [String] {
        keybindings[action.rawValue] ?? Action.defaultBindings[action] ?? []
    }

    /// Every resolved key combination for an action.
    public func combos(for action: Action) -> [KeyCombo] {
        let sup = Set(superModifiers), prim = Set(primaryModifiers)
        return bindings(for: action).compactMap { KeyCombo.parse($0, superModifiers: sup, primaryModifiers: prim) }
    }

    /// `POP_MAC_CONFIG_DIR` moves the folder, so the end-to-end tests do not touch the user's files.
    public static var defaultURL: URL {
        let folder = ProcessInfo.processInfo.environment["POP_MAC_CONFIG_DIR"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/pop-mac")
        return folder.appendingPathComponent("config.json")
    }

    public static func load(from url: URL = defaultURL) throws -> Settings {
        guard FileManager.default.fileExists(atPath: url.path) else { return Settings() }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Settings.self, from: data)
    }

    public func save(to url: URL = defaultURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(self).write(to: url, options: .atomic)
    }
}
