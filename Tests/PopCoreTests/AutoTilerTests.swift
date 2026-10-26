import Testing
@testable import PopCore

/// A fake world where windows move instantly to their requested rectangles.
final class FakeEnv: TilingEnvironment {
    var gapOuter: Double = 0
    var smartGaps = false
    var stackingWithMouse = true
    var screens: [MonitorID: Rect] = [1: Rect(0, 0, 1600, 1000)]
    var rects: [WindowID: Rect] = [:]
    var keys: [WindowID: WorkspaceKey] = [:]
    var focusHistory: [WindowID] = []
    var stacks: [StackNode] = []

    func workArea(_ monitor: MonitorID) -> Rect? { screens[monitor] }
    func windowRect(_ window: WindowID) -> Rect? { rects[window] }
    func workspaceKey(of window: WindowID) -> WorkspaceKey? { keys[window] }
    func previouslyFocused(excluding window: WindowID) -> WindowID? {
        focusHistory.last { $0 != window }
    }
    func isTilable(_ window: WindowID) -> Bool { rects[window] != nil }
    func isMinimized(_ window: WindowID) -> Bool { false }
    func windows(at point: Point, key: WorkspaceKey) -> [WindowID] {
        rects.filter { $0.value.contains(point) && keys[$0.key] == key }.map(\.key)
    }
    func applyLayout(_ moves: [(WindowID, Rect)]) {
        for (w, r) in moves { rects[w] = r }
    }
    func updateStacks(_ stacks: [StackNode]) { self.stacks = stacks }

    let key = WorkspaceKey(monitor: 1, space: 1)

    /// Adds a window and tiles it onto the previously focused window.
    func open(_ tiler: AutoTiler, _ id: WindowID) {
        rects[id] = Rect(100, 100, 400, 300)
        keys[id] = key
        tiler.autoTile(id)
        focusHistory.append(id)
    }
}

@Suite struct AutoTilerTests {
    let env = FakeEnv()
    let tiler: AutoTiler

    init() {
        tiler = AutoTiler(env: env, gapInner: 0)
    }

    @Test func singleWindowFillsScreen() {
        env.open(tiler, 1)
        #expect(env.rects[1] == Rect(0, 0, 1600, 1000))
    }

    @Test func secondWindowSplitsHorizontally() {
        env.open(tiler, 1)
        env.open(tiler, 2)
        #expect(env.rects[1] == Rect(0, 0, 800, 1000))
        #expect(env.rects[2] == Rect(800, 0, 800, 1000))
    }

    @Test func thirdWindowSplitsFocusedVertically() {
        env.open(tiler, 1)
        env.open(tiler, 2)
        env.open(tiler, 3)
        #expect(env.rects[1] == Rect(0, 0, 800, 1000))
        #expect(env.rects[2] == Rect(800, 0, 800, 500))
        #expect(env.rects[3] == Rect(800, 500, 800, 500))
    }

    @Test func gapsAreApplied() {
        env.gapOuter = 10
        tiler.forest.gapInner = 10
        env.open(tiler, 1)
        env.open(tiler, 2)
        #expect(env.rects[1] == Rect(10, 10, 785, 980))
        #expect(env.rects[2] == Rect(805, 10, 785, 980))
    }

    @Test func smartGapsHideOuterGapForSingleWindow() {
        env.gapOuter = 10
        env.smartGaps = true
        env.open(tiler, 1)
        #expect(env.rects[1] == Rect(0, 0, 1600, 1000))
        env.open(tiler, 2)
        #expect(env.rects[1]?.x == 10)
        tiler.detachWindow(2)
        #expect(env.rects[1] == Rect(0, 0, 1600, 1000))
    }

    @Test func detachRestoresSiblingToFullArea() {
        env.open(tiler, 1)
        env.open(tiler, 2)
        env.open(tiler, 3)
        tiler.detachWindow(3)
        #expect(env.rects[2] == Rect(800, 0, 800, 1000))
        tiler.detachWindow(1)
        #expect(env.rects[2] == Rect(0, 0, 1600, 1000))
        tiler.detachWindow(2)
        #expect(tiler.forest.toplevels.isEmpty)
        #expect(tiler.attached.isEmpty)
    }

    @Test func toggleOrientationStacksVertically() {
        env.open(tiler, 1)
        env.open(tiler, 2)
        tiler.toggleOrientation(2)
        #expect(env.rects[1] == Rect(0, 0, 1600, 500))
        #expect(env.rects[2] == Rect(0, 500, 1600, 500))
        // The second toggle also swaps the branches.
        tiler.toggleOrientation(2)
        #expect(env.rects[2] == Rect(0, 0, 800, 1000))
    }

    @Test func swapExchangesPositions() {
        env.open(tiler, 1)
        env.open(tiler, 2)
        env.open(tiler, 3)
        let r1 = env.rects[1], r3 = env.rects[3]
        tiler.attachSwap(1, 3)
        #expect(env.rects[1] == r3)
        #expect(env.rects[3] == r1)
    }

    @Test func moveOntoSiblingSwapsBranches() {
        env.open(tiler, 1)
        env.open(tiler, 2)
        tiler.moveAuto(2, to: .window(1))
        #expect(env.rects[2] == Rect(0, 0, 800, 1000))
        #expect(env.rects[1] == Rect(800, 0, 800, 1000))
    }

    @Test func stackingSharesOneTile() {
        env.open(tiler, 1)
        env.open(tiler, 2)
        tiler.toggleStacking(2)
        #expect(env.stacks.count == 1)
        env.open(tiler, 3)
        #expect(env.stacks.first?.entities == [2, 3])
        #expect(env.rects[2] == env.rects[3])
        #expect(env.rects[3]?.y == tiler.forest.tabHeight)

        tiler.moveFromStack(3, direction: .down)
        #expect(env.stacks.first?.entities == [2])
        #expect(env.rects[3]?.y == 500)
    }

    @Test func keyboardResizeGrowsWidth() {
        env.open(tiler, 1)
        env.open(tiler, 2)
        tiler.resizeAuto(1, direction: .right)
        #expect(env.rects[1]!.width > 800)
        #expect(env.rects[2]!.x > 800)
    }

    @Test func mouseResizeMovesSplit() {
        env.open(tiler, 1)
        env.open(tiler, 2)
        let original = env.rects[1]!
        tiler.resizeByMouse(1, from: original, to: Rect(0, 0, 1000, 1000))
        #expect(env.rects[1]!.width == 992)
        #expect(env.rects[2]!.x == 992)
    }

    @Test func dropOnLeftEdgePlacesWindowLeft() {
        env.open(tiler, 1)
        env.open(tiler, 2)
        env.open(tiler, 3)
        // Drag window 1 to the left edge of window 3.
        tiler.onDrop(1, cursor: Point(810, 750), key: env.key)
        #expect(env.rects[1]!.x == 800)
        #expect(env.rects[3]!.x > 800)
    }

    @Test func minimizeAndRestoreKeepsPlace() {
        env.open(tiler, 1)
        env.open(tiler, 2)
        let attachment = tiler.attachment(of: 1)!
        tiler.detachWindow(1)
        #expect(tiler.restore(1, to: attachment))
        #expect(env.rects[1] == Rect(0, 0, 800, 1000))
    }

    @Test func restoreIntoReplacedStackFails() {
        env.open(tiler, 1)
        env.open(tiler, 2)
        tiler.toggleStacking(2)
        env.open(tiler, 3)
        let attachment = tiler.attachment(of: 2)!
        tiler.detachWindow(2)
        // Unstack 3, then stack it again: the old stack is gone.
        tiler.toggleStacking(3)
        tiler.toggleStacking(3)
        #expect(!tiler.restore(2, to: attachment))
        #expect(!tiler.isAttached(2))
    }

    @Test func untilableTreeIsNotReplaced() {
        env.open(tiler, 1)
        // Window 1 stops answering, so it has no frame.
        env.rects[1] = nil
        env.rects[2] = Rect(0, 0, 100, 100)
        env.keys[2] = env.key
        tiler.autoTile(2, ignoreFocus: true)
        #expect(tiler.forest.toplevels.count == 1)
        #expect(tiler.forest.toplevel(of: tiler.attached[1]!) === tiler.forest.toplevel(of: tiler.attached[2]!))
    }

    @Test func replaceKeepsTheTile() {
        env.open(tiler, 1)
        env.open(tiler, 2)
        let tile = env.rects[2]
        env.rects[3] = Rect(0, 0, 10, 10)
        env.keys[3] = env.key
        #expect(tiler.replace(2, with: 3))
        #expect(env.rects[3] == tile)
        #expect(!tiler.isAttached(2))
        #expect(tiler.isAttached(3))
        #expect(!tiler.replace(2, with: 3))
    }

    @Test func moveToOtherMonitor() {
        env.screens[2] = Rect(1600, 0, 1000, 800)
        env.open(tiler, 1)
        env.open(tiler, 2)
        let other = WorkspaceKey(monitor: 2, space: 1)
        tiler.moveAuto(2, to: .workspace(other))
        env.keys[2] = other
        #expect(env.rects[2] == Rect(1600, 0, 1000, 800))
        #expect(env.rects[1] == Rect(0, 0, 1600, 1000))
    }
}
