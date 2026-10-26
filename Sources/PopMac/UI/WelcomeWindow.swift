import AppKit
import PopCore
import SwiftUI

/// The first-run window: asks for Accessibility access, then shows the main shortcuts.
@MainActor
final class WelcomeWindowController: ObservableObject {
    @Published var isTrusted = false
    private var window: NSWindow?

    func show() {
        if window == nil {
            let host = NSHostingController(rootView: WelcomeView(controller: self))
            let window = NSWindow(contentViewController: host)
            window.title = "Welcome to Pop Mac"
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func openAccessibilitySettings() {
        // The prompt adds Pop Mac to the list, so the user only flips the switch.
        _ = AX.isTrusted(prompt: true)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
}

private struct WelcomeView: View {
    @ObservedObject var controller: WelcomeWindowController

    var body: some View {
        VStack(spacing: 18) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 88, height: 88)

            if controller.isTrusted {
                ready
            } else {
                waiting
            }
        }
        .padding(28)
        .frame(width: 460)
    }

    private var waiting: some View {
        VStack(spacing: 14) {
            Text("Pop Mac needs Accessibility access").font(.title2.bold())
            Text("Pop Mac moves and resizes the windows of other apps. macOS allows that only for apps with Accessibility access.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("Open Accessibility Settings") { controller.openAccessibilitySettings() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Turn on Pop Mac in the list. Pop Mac starts on its own.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var ready: some View {
        VStack(spacing: 14) {
            Text("Pop Mac is running").font(.title2.bold())
            Text("Your windows now tile automatically. Pop Mac lives in the menu bar.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)

            Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 6) {
                shortcut("⌃⌥ ← ↓ ↑ →", "Focus a window")
                shortcut("⌃⌥ ↩", "Tile mode: move, resize, and swap")
                shortcut("⌃⌥ /", "Launcher")
                shortcut("⌃⌥ G", "Float or tile a window")
                shortcut("⌃⌥ Y", "Turn tiling on or off")
            }
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))

            Text("Drag a window onto another to swap them, or onto an edge to split.")
                .font(.callout)
                .foregroundStyle(.secondary)

            Button("Done") { controller.close() }
                .keyboardShortcut(.defaultAction)
                .controlSize(.large)
        }
    }

    private func shortcut(_ keys: String, _ text: String) -> some View {
        GridRow {
            Text(keys).font(.system(.body, design: .monospaced))
            Text(text)
        }
    }
}
