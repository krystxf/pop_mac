import Foundation
import PopCore
import Testing

/// Runs the real PopMac binary against the windows of PopTestApp.
///
/// Run with `make e2e`. See `E2E` for what the tests need.
@Suite(.serialized, .enabled(if: E2E.enabled, "Set POP_MAC_E2E=1 to run the end-to-end tests"))
struct TilingE2ETests {
    let area = E2E.workArea

    @Test func newWindowsSplitTheFocusedWindow() async throws {
        let session = try Session()
        defer { session.close() }
        try session.startPopMac()

        let a = try session.app.open("A")
        try await session.expectFrames([a: area])

        let b = try session.app.open("B")
        try await session.expectFrames([a: area.half(.left), b: area.half(.right)])

        // B is taller than wide, so C splits it into a top and a bottom half.
        let c = try session.app.open("C")
        let right = area.half(.right)
        try await session.expectFrames([a: area.half(.left), b: right.half(.up), c: right.half(.down)])
    }

    @Test func windowsOpenBeforeTheStartGetTiled() async throws {
        let session = try Session()
        defer { session.close() }
        let a = try session.app.open("A")
        let b = try session.app.open("B")

        try session.startPopMac()
        try await session.expectFrames([a: area.half(.left), b: area.half(.right)])
    }

    @Test func closingAWindowGivesItsTileBack() async throws {
        let session = try Session()
        defer { session.close() }
        try session.startPopMac()
        let a = try session.app.open("A")
        let b = try session.app.open("B")
        try await session.expectFrames([a: area.half(.left), b: area.half(.right)])

        try session.app.close(b)
        try await session.expectFrames([a: area])
    }

    @Test func superArrowsMoveTheFocus() async throws {
        let session = try Session()
        defer { session.close() }
        try session.startPopMac()
        let a = try session.app.open("A")
        let b = try session.app.open("B")
        try await session.expectFrames([a: area.half(.left), b: area.half(.right)])
        try await session.expectKeyWindow(b)

        Keys.superPress(Keys.left)
        try await session.expectKeyWindow(a)
        Keys.superPress(Keys.right)
        try await session.expectKeyWindow(b)
    }

    @Test func toggleFloatingReturnsTheTile() async throws {
        let session = try Session()
        defer { session.close() }
        try session.startPopMac()
        let a = try session.app.open("A")
        let b = try session.app.open("B")
        try await session.expectFrames([a: area.half(.left), b: area.half(.right)])
        try await session.expectKeyWindow(b)

        // B floats at its size from before tiling, and A takes the whole area.
        Keys.superPress(Keys.g)
        try await session.expectFrames([a: area])
        let floating = try #require(E2E.frame(of: b))
        #expect(floating.width == 400 && floating.height == 300)

        Keys.superPress(Keys.g)
        try await session.expectFrames([a: area.half(.left), b: area.half(.right)])
    }

    @Test func toggleOrientationStacksTheWindows() async throws {
        let session = try Session()
        defer { session.close() }
        try session.startPopMac()
        let a = try session.app.open("A")
        let b = try session.app.open("B")
        try await session.expectFrames([a: area.half(.left), b: area.half(.right)])
        try await session.expectKeyWindow(b)

        Keys.superPress(Keys.o)
        try await session.expectFrames([a: area.half(.up), b: area.half(.down)])
    }

    @Test func restartKeepsTheLayout() async throws {
        let session = try Session()
        defer { session.close() }
        try session.startPopMac()
        let a = try session.app.open("A")
        let b = try session.app.open("B")
        try await session.expectFrames([a: area.half(.left), b: area.half(.right)])
        try await session.expectKeyWindow(b)

        // A fresh start splits a wide display left and right. Top and bottom must come from the saved layout.
        Keys.superPress(Keys.o)
        try await session.expectFrames([a: area.half(.up), b: area.half(.down)])
        let saved = try await waitUntil(timeout: .seconds(5)) {
            guard let layout = SavedLayout.load(from: session.layoutURL), let tree = layout.trees.first else { return false }
            return tree.root.orientation == .vertical && tree.root.windows == [a.id, b.id]
        }
        try #require(saved, "Pop Mac did not save the layout\n\(session.logTail())")

        session.stopPopMac()
        try session.app.move(a, to: Rect(area.x + 50, area.y + 50, 400, 300))
        try session.app.move(b, to: Rect(area.x + 100, area.y + 100, 400, 300))

        try session.startPopMac()
        try await session.expectFrames([a: area.half(.up), b: area.half(.down)])
    }
}

extension SavedFork {
    /// Every window in the fork, from left to right.
    var windows: [WindowID] {
        [left, right].compactMap(\.self).flatMap { node -> [WindowID] in
            switch node {
            case let .window(id): [id]
            case let .stack(windows, _): windows
            case let .fork(fork): fork.windows
            }
        }
    }
}
