@testable import PopCore
import Testing

struct StackDragTests {
    private let here = WorkspaceKey(monitor: 1, space: 10)
    private let otherDisplay = WorkspaceKey(monitor: 2, space: 20)
    private let otherSpace = WorkspaceKey(monitor: 1, space: 11)

    // MARK: - The window manager's session

    @Test func selectedWindowFollowsTheMouse() {
        var session = StackDragSession(workspace: here, frame: Rect(100, 100, 800, 600))
        // Screen points have y up, so a mouse that moves up lowers the window's y.
        let first = session.move(dx: 30.4, dy: 20.6)
        #expect(first.from == Rect(100, 100, 800, 600))
        #expect(first.to == Rect(130, 79, 800, 600))

        // Each move starts where the last one ended, and the offset counts from the drag's start.
        let second = session.move(dx: -10, dy: 0)
        #expect(second.from == first.to)
        #expect(second.to == Rect(90, 100, 800, 600))
    }

    @Test func dropLandsOnAWorkspaceInView() {
        let session = StackDragSession(workspace: here, frame: Rect(0, 0, 800, 600))
        let visible: Set = [here, otherDisplay]
        #expect(session.outcome(at: here, visible: visible, stackIntact: true) == .drop(here))
        #expect(session.outcome(at: otherDisplay, visible: visible, stackIntact: true) == .drop(otherDisplay))
    }

    @Test func stackFromASpaceOutOfViewGoesBack() {
        let session = StackDragSession(workspace: here, frame: Rect(0, 0, 800, 600))
        // The Space switched during the drag. The windows are still on the old Space.
        #expect(session.outcome(at: otherSpace, visible: [otherSpace, otherDisplay], stackIntact: true) == .restore)
    }

    @Test func dropOffEveryDisplayOrOfAChangedStackGoesBack() {
        let session = StackDragSession(workspace: here, frame: Rect(0, 0, 800, 600))
        #expect(session.outcome(at: nil, visible: [here], stackIntact: true) == .restore)
        #expect(session.outcome(at: here, visible: [here], stackIntact: false) == .restore)
        #expect(session.outcome(at: otherSpace, visible: [here], stackIntact: true) == .restore)
    }

    @Test func lostMouseUpIsFoundOnTheSecondCheck() {
        var session = StackDragSession(workspace: here, frame: Rect(0, 0, 800, 600))
        let checks = [true, false, false].map { session.mouseUpWasLost(buttonDown: $0) }
        // The mouse-up event can trail the button by a moment, so one check with the button up is not enough.
        #expect(checks == [false, false, true])

        // The button went down again in between: the drag goes on.
        var held = StackDragSession(workspace: here, frame: Rect(0, 0, 800, 600))
        let heldChecks = [false, true, false].map { held.mouseUpWasLost(buttonDown: $0) }
        #expect(heldChecks == [false, false, false])
    }

    // MARK: - The tab bar

    @Test func barFollowsFromItsOriginAtTheDragStart() {
        var drag = BarDrag()
        let start = drag.moved(from: Point(10, 20))
        // The bar moved under the mouse, but the drag still counts from its start.
        let later = drag.moved(from: Point(50, 60))
        #expect(start == Point(10, 20))
        #expect(later == Point(10, 20))
        #expect(drag.isDragging)

        let reported = drag.ended()
        #expect(reported)
        #expect(drag.state == .idle)
    }

    @Test func cancelledDragIgnoresTheRestOfItsGesture() {
        var drag = BarDrag()
        _ = drag.moved(from: Point(10, 20))
        drag.cancel(buttonDown: true)
        #expect(!drag.isDragging)

        // The mouse keeps moving: the drag does not start again from the bar's new place.
        let moved = drag.moved(from: Point(50, 60))
        #expect(moved == nil)
        // Its mouse-up reports no drop.
        let reported = drag.ended()
        #expect(!reported)

        // The next gesture drags again, from where the bar is then.
        let next = drag.moved(from: Point(0, 0))
        #expect(next == Point(0, 0))
    }

    @Test func newPressEndsADragWhoseMouseUpWasLost() {
        var drag = BarDrag()
        _ = drag.moved(from: Point(10, 20))
        drag.cancel(buttonDown: true)
        // The cancelled gesture's mouse-up never came. The next press starts over.
        drag.pressed()
        let next = drag.moved(from: Point(50, 60))
        #expect(next == Point(50, 60))

        // The same for a drag that was never cancelled.
        drag.pressed()
        #expect(!drag.isDragging)
    }

    @Test func dragWithALostMouseUpStartsFresh() {
        var drag = BarDrag()
        _ = drag.moved(from: Point(10, 20))
        // Cancelled after its button went up: no mouse-up comes to clear it.
        drag.cancel(buttonDown: false)
        #expect(drag.state == .idle)

        let next = drag.moved(from: Point(50, 60))
        #expect(next == Point(50, 60))
    }
}
