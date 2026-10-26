import Foundation

/// A rule that makes matching windows float instead of tile.
///
/// `app` matches the application name or the bundle identifier.
/// `title` matches the window title. Both are case-insensitive regular expressions.
public struct FloatRule: Codable, Equatable {
    public var app: String?
    public var title: String?
    /// A disabled rule forces matching windows to tile.
    public var disabled: Bool?

    public init(app: String? = nil, title: String? = nil, disabled: Bool? = nil) {
        self.app = app
        self.title = title
        self.disabled = disabled
    }

    func matches(appName: String, bundleID: String, title windowTitle: String) -> Bool {
        if let app, !app.isEmpty {
            guard Self.test(app, appName) || Self.test(app, bundleID) else { return false }
        }
        if let title, !title.isEmpty {
            guard Self.test(title, windowTitle) else { return false }
        }
        return app != nil || title != nil
    }

    private static var cache: [String: NSRegularExpression] = [:]

    private static func test(_ pattern: String, _ value: String) -> Bool {
        let regex: NSRegularExpression
        if let cached = cache[pattern] {
            regex = cached
        } else if let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            cache[pattern] = compiled
            regex = compiled
        } else {
            return value.caseInsensitiveCompare(pattern) == .orderedSame
        }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}

public enum FloatRules {
    /// Windows that should float by default on macOS.
    public static let defaults: [FloatRule] = [
        FloatRule(app: "^com\\.apple\\.systempreferences$"),
        FloatRule(app: "^com\\.apple\\.calculator$"),
        FloatRule(app: "^com\\.apple\\.archiveutility$"),
        FloatRule(app: "^com\\.apple\\.ScreenSharing$"),
        FloatRule(app: "^com\\.apple\\.DigitalColorMeter$"),
        FloatRule(app: "^com\\.apple\\.Stickies$"),
        FloatRule(app: "^com\\.apple\\.PhotoBooth$"),
        FloatRule(app: "^com\\.apple\\.ColorSyncUtility$"),
        FloatRule(app: "^com\\.apple\\.SystemProfiler$"),
        FloatRule(app: "^com\\.apple\\.FaceTime$"),
        FloatRule(app: "^com\\.apple\\.finder$", title: "^(Copy|Move|Info|.* Info)$"),
        FloatRule(app: "^com\\.apple\\.Safari$", title: "^(Downloads|Settings|Preferences)$"),
        FloatRule(app: "^com\\.1password"),
        FloatRule(app: "^com\\.raycast\\.macos$"),
        FloatRule(app: "^com\\.runningwithcrayons\\.Alfred"),
        FloatRule(app: "^us\\.zoom\\.xos$"),
        FloatRule(app: "^org\\.mozilla\\.firefox$", title: "^(Library|Picture-in-Picture)$"),
        FloatRule(app: "^com\\.google\\.Chrome$", title: "^Picture in Picture$"),
        FloatRule(app: "^com\\.jetbrains\\.toolbox$"),
        FloatRule(title: "^(Preferences|Settings)$"),
        FloatRule(title: "^Picture[- ]in[- ]Picture$"),
    ]

    /// Returns true if the window should float.
    ///
    /// User rules are checked first, so they can override the defaults.
    public static func windowShallFloat(appName: String, bundleID: String, title: String, userRules: [FloatRule]) -> Bool {
        for rule in userRules + defaults where rule.matches(appName: appName, bundleID: bundleID, title: title) {
            return rule.disabled != true
        }
        return false
    }
}
