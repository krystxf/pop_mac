import Foundation
import os

/// A rule that makes matching windows float instead of tile.
///
/// `app` matches the application name or the bundle identifier.
/// `title` matches the window title. Both are case-insensitive regular expressions.
public struct FloatRule: Sendable, Codable, Equatable {
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

    private static let cache = OSAllocatedUnfairLock(initialState: [String: NSRegularExpression]())

    private static func test(_ pattern: String, _ value: String) -> Bool {
        let regex: NSRegularExpression
        if let cached = cache.withLock({ $0[pattern] }) {
            regex = cached
        } else if let compiled = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) {
            cache.withLock { $0[pattern] = compiled }
            regex = compiled
        } else {
            return value.caseInsensitiveCompare(pattern) == .orderedSame
        }
        return regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
    }
}

public enum FloatRules {
    /// Built-in float rules, checked after the user's rules.
    ///
    /// Apps whose main window cannot tile, and windows that are better floating.
    public static let defaults: [FloatRule] = [
        // Keka's window has a fixed size.
        FloatRule(app: "^com\\.aone\\.keka$"),
        // The Google Meet web app floats beside your work. A browser window on a Meet
        // tab tiles. Meet's picture-in-picture window is not a standard window, so it
        // floats without a rule.
        FloatRule(app: "^Google Meet$"),
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
