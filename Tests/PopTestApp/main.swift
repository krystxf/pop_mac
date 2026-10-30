import AppKit

// A plain app with windows for the end-to-end tests to tile.
//
// It reads one command per line on stdin and answers with one line on stdout:
//
//     open <title>             opens a window and answers its window number
//     close <title>            closes a window
//     focus <title>            makes the app active and the window key
//     key                      answers the title of the key window, or "-"
//     move <title> x y w h     sets a frame, in top-left-origin coordinates
//     size <title>             answers the size of the window's content: w h
//     area                     answers the work area of the main display: x y w h,
//                              in top-left-origin coordinates
//
// The app quits when stdin closes, so it never outlives the test.

@MainActor
final class TestApp {
    private var windows: [String: NSWindow] = [:]

    private var screen: NSScreen { NSScreen.screens[0] }

    func handle(_ line: String) -> String {
        let words = line.split(separator: " ").map(String.init)
        guard let command = words.first else { return "error: empty command" }
        let title = words.count > 1 ? words[1] : ""

        switch command {
        case "open":
            let area = screen.visibleFrame
            let window = NSWindow(
                contentRect: NSRect(x: area.midX - 200, y: area.midY - 150, width: 400, height: 300),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            window.isReleasedWhenClosed = false
            window.title = title
            windows[title] = window
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return String(window.windowNumber)
        case "close":
            guard let window = windows.removeValue(forKey: title) else { return "error: no window \(title)" }
            window.close()
            return "ok"
        case "focus":
            guard let window = windows[title] else { return "error: no window \(title)" }
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            return "ok"
        case "key":
            return NSApp.keyWindow?.title ?? "-"
        case "size":
            guard let window = windows[title] else { return "error: no window \(title)" }
            let content = window.contentRect(forFrameRect: window.frame)
            return "\(content.width) \(content.height)"
        case "area":
            // This app runs an event loop, so its screens are current, unlike the test process's.
            let area = screen.visibleFrame
            return "\(area.minX) \(screen.frame.height - area.maxY) \(area.width) \(area.height)"
        case "move":
            guard let window = windows[title] else { return "error: no window \(title)" }
            let numbers = words.dropFirst(2).compactMap(Double.init)
            guard numbers.count == 4 else { return "error: move needs x y w h" }
            let primaryHeight = screen.frame.height
            let frame = NSRect(x: numbers[0], y: primaryHeight - numbers[1] - numbers[3], width: numbers[2], height: numbers[3])
            window.setFrame(frame, display: true)
            return "ok"
        default:
            return "error: unknown command \(command)"
        }
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
let testApp = MainActor.assumeIsolated { TestApp() }

Thread.detachNewThread {
    while let line = readLine() {
        DispatchQueue.main.async {
            let answer = MainActor.assumeIsolated { testApp.handle(line) }
            print(answer)
            fflush(stdout)
        }
    }
    DispatchQueue.main.async { exit(0) }
}

app.run()
