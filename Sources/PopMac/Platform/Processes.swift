import AppKit
import Darwin

/// Finds the process of a running application.
///
/// macOS reports process ID -1 for some apps, for example Xcode's Device Hub.
/// Their windows are still reachable through Accessibility with the real ID,
/// which this finds through the app's executable path.
@MainActor
enum Processes {
    private static var cache: [String: pid_t] = [:]

    static func pid(of app: NSRunningApplication) -> pid_t? {
        if app.processIdentifier > 0 { return app.processIdentifier }
        guard let path = app.executableURL?.resolvingSymlinksInPath().path else { return nil }
        if let cached = cache[path], executablePath(of: cached) == path { return cached }
        // A terminated app's process is gone; its last known ID still identifies its windows.
        if app.isTerminated { return cache[path] }

        guard let pid = allPIDs().first(where: { executablePath(of: $0) == path }) else { return nil }
        cache[path] = pid
        return pid
    }

    private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) + 32)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return pids.prefix(Int(max(filled, 0))).filter { $0 > 0 }
    }

    private static func executablePath(of pid: pid_t) -> String? {
        var buffer = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return nil }
        return URL(fileURLWithPath: String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)).resolvingSymlinksInPath().path
    }
}
