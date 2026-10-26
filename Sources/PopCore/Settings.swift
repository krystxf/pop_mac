import Foundation

/// A modifier key on a Mac keyboard.
public enum MacModifier: String, Codable, CaseIterable, Hashable {
    case control, option, shift, command

    public var symbol: String {
        switch self {
        case .control: return "⌃"
        case .option: return "⌥"
        case .shift: return "⇧"
        case .command: return "⌘"
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
            let name = rest[rest.index(after: rest.startIndex)..<end]
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
        case "Left", "KP_Left": return "←"
        case "Right", "KP_Right": return "→"
        case "Up", "KP_Up": return "↑"
        case "Down", "KP_Down": return "↓"
        case "Return": return "↩"
        case "KP_Enter": return "⌤"
        case "Escape": return "⎋"
        case "slash": return "/"
        case "comma": return ","
        case "period": return "."
        case "space": return "Space"
        case "Tab": return "⇥"
        default: return key.count == 1 ? key.uppercased() : key
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
    case tileOrientation = "tile-orientation"
    case toggleFloating = "toggle-floating"
    case toggleTiling = "toggle-tiling"
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
        case .managementOrientation,
             .tileMoveLeft, .tileMoveDown, .tileMoveUp, .tileMoveRight,
             .tileResizeLeft, .tileResizeDown, .tileResizeUp, .tileResizeRight,
             .tileSwapLeft, .tileSwapDown, .tileSwapUp, .tileSwapRight,
             .tileAccept, .tileReject:
            return true
        default:
            return false
        }
    }

    public var summary: String {
        switch self {
        case .activateLauncher: return "Launch and switch applications"
        case .tileEnter: return "Enter tile mode"
        case .focusLeft: return "Focus window to the left"
        case .focusDown: return "Focus window below"
        case .focusUp: return "Focus window above"
        case .focusRight: return "Focus window to the right"
        case .tileOrientation: return "Toggle tiling orientation"
        case .toggleFloating: return "Toggle floating mode for the window"
        case .toggleTiling: return "Toggle auto-tiling"
        case .tileMoveLeftGlobal: return "Move window left"
        case .tileMoveDownGlobal: return "Move window down"
        case .tileMoveUpGlobal: return "Move window up"
        case .tileMoveRightGlobal: return "Move window right"
        case .monitorLeft: return "Move window to the display on the left"
        case .monitorRight: return "Move window to the display on the right"
        case .monitorUp: return "Move window to the display above"
        case .monitorDown: return "Move window to the display below"
        case .workspaceUp: return "Move window to the previous Space"
        case .workspaceDown: return "Move window to the next Space"
        case .toggleMaximize: return "Toggle maximize"
        case .closeWindow: return "Close window"
        case .minimizeWindow: return "Minimize window"
        case .managementOrientation: return "Toggle orientation"
        case .tileMoveLeft: return "Move window left"
        case .tileMoveDown: return "Move window down"
        case .tileMoveUp: return "Move window up"
        case .tileMoveRight: return "Move window right"
        case .tileResizeLeft: return "Shrink width"
        case .tileResizeDown: return "Grow height"
        case .tileResizeUp: return "Shrink height"
        case .tileResizeRight: return "Grow width"
        case .tileSwapLeft: return "Swap with window to the left"
        case .tileSwapDown: return "Swap with window below"
        case .tileSwapUp: return "Swap with window above"
        case .tileSwapRight: return "Swap with window to the right"
        case .tileAccept: return "Apply changes and exit tile mode"
        case .tileReject: return "Cancel changes and exit tile mode"
        }
    }

    public static let defaultBindings: [Action: [String]] = [
        .activateLauncher: ["<Super>slash"],
        .tileEnter: ["<Super>Return", "<Super>KP_Enter"],
        .focusLeft: ["<Super>Left", "<Super>h"],
        .focusDown: ["<Super>Down", "<Super>j"],
        .focusUp: ["<Super>Up", "<Super>k"],
        .focusRight: ["<Super>Right", "<Super>l"],
        .tileOrientation: ["<Super>o"],
        .toggleFloating: ["<Super>g"],
        .toggleTiling: ["<Super>y"],
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
    public var activeHint = true
    public var activeHintBorderRadius: Double = 10
    public var activeHintWidth: Double = 3
    public var hintColor = "#FBB86C"
    public var gapInner: Double = 8
    public var gapOuter: Double = 8
    public var smartGaps = false
    public var snapToGrid = false
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
    /// Windows that float instead of tile. Checked before the built-in rules.
    public var floatRules: [FloatRule] = []

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        tileByDefault = try c.decodeIfPresent(Bool.self, forKey: .tileByDefault) ?? d.tileByDefault
        activeHint = try c.decodeIfPresent(Bool.self, forKey: .activeHint) ?? d.activeHint
        activeHintBorderRadius = try c.decodeIfPresent(Double.self, forKey: .activeHintBorderRadius) ?? d.activeHintBorderRadius
        activeHintWidth = try c.decodeIfPresent(Double.self, forKey: .activeHintWidth) ?? d.activeHintWidth
        hintColor = try c.decodeIfPresent(String.self, forKey: .hintColor) ?? d.hintColor
        gapInner = try c.decodeIfPresent(Double.self, forKey: .gapInner) ?? d.gapInner
        gapOuter = try c.decodeIfPresent(Double.self, forKey: .gapOuter) ?? d.gapOuter
        smartGaps = try c.decodeIfPresent(Bool.self, forKey: .smartGaps) ?? d.smartGaps
        snapToGrid = try c.decodeIfPresent(Bool.self, forKey: .snapToGrid) ?? d.snapToGrid
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

    public static var defaultURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/pop-mac/config.json")
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
