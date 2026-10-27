import AppKit
import ApplicationServices
import Foundation
import PopCore
import Testing

/// Support for the end-to-end tests, which run the real PopMac binary.
///
/// The tests open windows on the main display and send real key presses.
/// They run only with `POP_MAC_E2E=1`, and only while no other Pop Mac runs.
/// The terminal that runs them needs Accessibility access.
enum E2E {
    static let enabled = ProcessInfo.processInfo.environment["POP_MAC_E2E"] != nil

    /// The folder with the built products. The test bundle is built into it too.
    static let binDir = Bundle(for: Marker.self).bundleURL.deletingLastPathComponent()

    private final class Marker {}

    /// The work area of the main display, in top-left-origin coordinates, as Pop Mac sees it.
    static var workArea: Rect {
        let screen = NSScreen.screens[0]
        let area = screen.visibleFrame
        return Rect(area.minX, screen.frame.height - area.maxY, area.width, area.height)
    }

    /// A window's frame as the window server sees it.
    static func frame(of window: TestWindow) -> Rect? {
        guard let entry = (CGWindowListCopyWindowInfo([.optionIncludingWindow], window.id) as? [[String: Any]])?.first,
              let bounds = entry[kCGWindowBounds as String] as? NSDictionary,
              let rect = CGRect(dictionaryRepresentation: bounds)
        else { return nil }
        return Rect(rect.minX, rect.minY, rect.width, rect.height)
    }

    /// Settings that make the frames easy to predict, and leave the cursor alone.
    static var settings: Settings {
        var settings = Settings()
        settings.gapInner = 0
        settings.gapOuter = 0
        settings.activeHint = false
        settings.mouseCursorFollowsActiveWindow = false
        return settings
    }
}

struct TestWindow: Hashable, CustomStringConvertible {
    let id: CGWindowID
    let title: String

    var description: String { title }
}

/// Key presses, sent as if from the keyboard.
enum Keys {
    static let left: CGKeyCode = 123
    static let right: CGKeyCode = 124
    static let g: CGKeyCode = 5
    static let o: CGKeyCode = 31

    /// Presses a key with Super, which is ⌃⌥ by default.
    static func superPress(_ code: CGKeyCode) {
        let flags: CGEventFlags = [.maskControl, .maskAlternate]
        for down in [true, false] {
            let event = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: down)
            event?.flags = flags
            event?.post(tap: .cghidEventTap)
        }
    }
}

/// The app that owns the test windows. See Tests/PopTestApp.
final class TestApp {
    private let process = Process()
    private let input = Pipe()
    private let output = Pipe()
    private var buffer = Data()

    var pid: pid_t { process.processIdentifier }

    init() throws {
        process.executableURL = E2E.binDir.appendingPathComponent("PopTestApp")
        process.standardInput = input
        process.standardOutput = output
        try process.run()
    }

    func open(_ title: String) throws -> TestWindow {
        let answer = try send("open \(title)")
        return try TestWindow(id: #require(CGWindowID(answer)), title: title)
    }

    func close(_ window: TestWindow) throws { try send("close \(window.title)") }
    func focus(_ window: TestWindow) throws { try send("focus \(window.title)") }
    func move(_ window: TestWindow, to r: Rect) throws { try send("move \(window.title) \(r.x) \(r.y) \(r.width) \(r.height)") }

    /// The title of the key window, or "-".
    func keyWindow() throws -> String { try send("key") }

    @discardableResult
    private func send(_ command: String) throws -> String {
        input.fileHandleForWriting.write(Data((command + "\n").utf8))
        let answer = readLine()
        if answer.hasPrefix("error") {
            throw TestAppError(message: "\(command): \(answer)")
        }
        return answer
    }

    private func readLine() -> String {
        while true {
            if let newline = buffer.firstIndex(of: UInt8(ascii: "\n")) {
                let line = String(decoding: buffer[..<newline], as: UTF8.self)
                buffer.removeSubrange(...newline)
                return line
            }
            let data = output.fileHandleForReading.availableData
            if data.isEmpty { return "error: the test app quit" }
            buffer.append(data)
        }
    }

    /// Closes stdin, which makes the app quit.
    func quit() {
        try? input.fileHandleForWriting.close()
        process.waitUntilExit()
    }
}

struct TestAppError: Error, CustomStringConvertible {
    let message: String
    var description: String { message }
}

/// A test app, and a Pop Mac that manages only its windows, with its own config folder.
///
/// Call `close()` at the end, so that both processes quit.
final class Session {
    let app: TestApp
    let configDir: URL
    private var popMac: Process?

    var logURL: URL { configDir.appendingPathComponent("popmac.log") }
    var layoutURL: URL { configDir.appendingPathComponent("layout.json") }

    init(settings: Settings = E2E.settings) throws {
        try #require(AXIsProcessTrusted(), "Give the terminal Accessibility access, so that it can run Pop Mac and press keys.")
        let others = ["dev.krystof.popmac", "dev.krystof.popmac.prod"].flatMap(NSRunningApplication.runningApplications(withBundleIdentifier:))
        try #require(others.isEmpty, "Quit Pop Mac first. It would tile the test windows too.")

        configDir = FileManager.default.temporaryDirectory.appendingPathComponent("pop-mac-e2e-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true)
        try settings.save(to: configDir.appendingPathComponent("config.json"))
        app = try TestApp()
    }

    func startPopMac() throws {
        let process = Process()
        process.executableURL = E2E.binDir.appendingPathComponent("PopMac")
        var environment = ProcessInfo.processInfo.environment
        environment["POP_MAC_CONFIG_DIR"] = configDir.path
        environment["POP_MAC_ONLY_PID"] = String(app.pid)
        environment["POP_MAC_DEBUG"] = "1"
        process.environment = environment
        FileManager.default.createFile(atPath: logURL.path, contents: nil)
        let log = try FileHandle(forWritingTo: logURL)
        log.seekToEndOfFile()
        process.standardOutput = log
        process.standardError = log
        try process.run()
        popMac = process
    }

    func stopPopMac() {
        guard let popMac else { return }
        popMac.terminate()
        popMac.waitUntilExit()
        self.popMac = nil
    }

    func close() {
        stopPopMac()
        app.quit()
        try? FileManager.default.removeItem(at: configDir)
    }

    /// Waits until every window has its expected frame, give or take a point.
    func expectFrames(
        _ expected: [TestWindow: Rect],
        timeout: Duration = .seconds(5),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        func matches() -> Bool {
            expected.allSatisfy { window, rect in
                guard let frame = E2E.frame(of: window) else { return false }
                return abs(frame.x - rect.x) <= 1 && abs(frame.y - rect.y) <= 1
                    && abs(frame.width - rect.width) <= 1 && abs(frame.height - rect.height) <= 1
            }
        }
        if try await waitUntil(timeout: timeout, matches) { return }

        let report = expected.keys.sorted { $0.title < $1.title }.map { window in
            "\(window): expected \(expected[window]!), got \(E2E.frame(of: window).map { "\($0)" } ?? "nothing")"
        }
        Issue.record("Frames did not settle:\n\(report.joined(separator: "\n"))\n\(logTail())", sourceLocation: sourceLocation)
    }

    /// Waits until the window is the key window of the test app.
    func expectKeyWindow(_ window: TestWindow, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        if try await waitUntil(timeout: .seconds(5), { try app.keyWindow() == window.title }) { return }
        let actual = try app.keyWindow()
        Issue.record("Expected \(window) to be the key window, got \(actual)\n\(logTail())", sourceLocation: sourceLocation)
    }

    /// The end of Pop Mac's log, to explain a failure.
    func logTail(lines: Int = 30) -> String {
        let text = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        return "Pop Mac log:\n" + text.split(separator: "\n").suffix(lines).joined(separator: "\n")
    }
}

/// Checks a condition every 50 ms. Returns false if it is still false after the timeout.
func waitUntil(timeout: Duration, _ condition: () throws -> Bool) async throws -> Bool {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if try condition() { return true }
        try await Task.sleep(for: .milliseconds(50))
    }
    return try condition()
}

extension Rect {
    /// The left or right half, for a horizontal split.
    func half(_ side: Direction) -> Rect {
        switch side {
        case .left: Rect(x, y, (width / 2).rounded(), height)
        case .right: Rect(x + (width / 2).rounded(), y, width - (width / 2).rounded(), height)
        case .up: Rect(x, y, width, (height / 2).rounded())
        case .down: Rect(x, y + (height / 2).rounded(), width, height - (height / 2).rounded())
        }
    }
}
