import Foundation

/// Tracks apps that do not answer, so that Pop Mac stops waiting for them.
///
/// A call to an app that hangs returns only after its timeout. Pop Mac makes many
/// calls, so one such app would hold it up for seconds. After a call without an
/// answer, the calls to that app are skipped for a pause. Then one call tries again,
/// and the other calls stay skipped until that one call is over.
/// Each further call without an answer doubles the pause, up to `longestPause`.
/// Times are monotonic seconds, such as `ProcessInfo.systemUptime`.
public struct AppStalls: Sendable {
    public static let firstPause: TimeInterval = 2
    public static let longestPause: TimeInterval = 10

    /// The app's process ID.
    public typealias App = Int32

    private var stalled: [App: (until: TimeInterval, pause: TimeInterval)] = [:]

    public init() {}

    public enum Health: Equatable, Sendable {
        /// The app answered its last call.
        case healthy
        /// The app did not answer, and its pause runs. Calls are skipped.
        case stalled
        /// The pause is over, and this call shows whether the app answers again.
        case retrying
    }

    /// Tells whether a call to the app runs now. Report its result with `timedOut` or `answered`.
    ///
    /// After a pause, only the first caller gets `.retrying`. The others, also on other
    /// threads, see the app as stalled until that call is over, so they do not wait for it too.
    public mutating func beginCall(to app: App, at now: TimeInterval) -> Health {
        guard let entry = stalled[app] else { return .healthy }
        if now < entry.until { return .stalled }
        stalled[app]?.until = .infinity
        return .retrying
    }

    public func isStalled(_ app: App, at now: TimeInterval) -> Bool {
        stalled[app].map { now < $0.until } ?? false
    }

    /// Records a call that got no answer in time. Returns the pause that starts at `now`.
    @discardableResult
    public mutating func timedOut(_ app: App, at now: TimeInterval) -> TimeInterval {
        let pause = stalled[app].map { min($0.pause * 2, Self.longestPause) } ?? Self.firstPause
        stalled[app] = (now + pause, pause)
        return pause
    }

    /// Records that the app answered a call, or sent an event. Returns true if it was stalled.
    @discardableResult
    public mutating func answered(_ app: App) -> Bool {
        stalled.removeValue(forKey: app) != nil
    }
}
