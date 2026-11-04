@testable import PopCore
import Testing

struct SpaceSwitchTests {
    // MARK: - The quiet period

    @Test func quietPeriodFollowsEachSwitch() {
        var clock = SpaceSwitchClock()
        #expect(!clock.isSwitching(at: 100))

        clock.switched(at: 100)
        #expect(clock.isSwitching(at: 100))
        #expect(clock.isSwitching(at: 100.69))
        #expect(!clock.isSwitching(at: 100.7))

        // A rapid second switch restarts the period.
        clock.switched(at: 100.5)
        #expect(clock.isSwitching(at: 101.1))
        #expect(!clock.isSwitching(at: 101.2))
    }

    @Test func quietPeriodNeverOutlastsItsLength() {
        var clock = SpaceSwitchClock()
        clock.switched(at: 100)
        // A clock that runs backward cannot hold the period open.
        #expect(clock.remaining(at: 0) == SpaceSwitchClock.quietPeriod)
        #expect(clock.remaining(at: 100.25) == SpaceSwitchClock.quietPeriod - 0.25)
    }

    @Test func workWaitsForTheSwitchAndDropsAfterALaterOne() {
        var clock = SpaceSwitchClock()
        clock.switched(at: 100)
        let generation = clock.generation

        // Work that began during the switch waits until it settles, then runs.
        #expect(clock.decide(generation, at: 100.5) == .wait(SpaceSwitchClock.quietPeriod - 0.5))
        #expect(clock.decide(generation, at: 101) == .run)

        // After another switch, the work is stale, even once that switch has settled.
        clock.switched(at: 102)
        #expect(clock.decide(generation, at: 102.1) == .drop)
        #expect(clock.decide(generation, at: 110) == .drop)
    }

    // MARK: - Grabs

    private let frame = Rect(0, 0, 800, 600)

    @Test func clickWithoutDragGrabsNothing() {
        var grab = GrabTracker()
        grab.mouseDown(candidates: [1: frame])
        #expect(grab.mouseUp(generation: 0).isEmpty)
        #expect(grab.pendingDrops.isEmpty)
    }

    @Test func dragAcrossASpaceSwitchStaysAGrab() {
        var clock = SpaceSwitchClock()
        var grab = GrabTracker()
        grab.mouseDown(candidates: [1: frame])
        grab.mouseDragged()

        // The window travels to the next Space with the mouse.
        clock.switched(at: 100)
        grab.mouseDragged()
        #expect(grab.isBusy(generation: clock.generation, buttonDown: true))

        let grabbed = grab.mouseUp(generation: clock.generation)
        #expect(grabbed == [1: frame])
        // Its drop is handled on the new Space, once the switch settles.
        #expect(clock.decide(grab.pendingDrops[1]!, at: 100.25) == .wait(SpaceSwitchClock.quietPeriod - 0.25))
        #expect(clock.decide(grab.pendingDrops[1]!, at: 100.8) == .run)
    }

    @Test func newClickKeepsTheWaitingDrop() {
        var grab = GrabTracker()
        grab.mouseDown(candidates: [1: frame])
        grab.mouseDragged()
        _ = grab.mouseUp(generation: 3)

        grab.mouseDown(candidates: [2: frame])
        #expect(grab.pendingDrops == [1: 3])
        #expect(grab.isBusy(generation: 3, buttonDown: true))

        grab.dropEnded(1)
        #expect(!grab.isBusy(generation: 3, buttonDown: true))
    }

    @Test func staleOrLostGrabsDoNotHoldWorkBack() {
        var grab = GrabTracker()
        grab.mouseDown(candidates: [1: frame])
        grab.mouseDragged()
        // The mouse-up was missed: the button is up.
        #expect(grab.isBusy(generation: 0, buttonDown: true))
        #expect(!grab.isBusy(generation: 0, buttonDown: false))

        // A drop from before a Space switch does not count.
        _ = grab.mouseUp(generation: 0)
        #expect(grab.isBusy(generation: 0, buttonDown: false))
        #expect(!grab.isBusy(generation: 1, buttonDown: false))
    }

    @Test func cancelledGrabDropsNothing() {
        var grab = GrabTracker()
        grab.mouseDown(candidates: [1: frame])
        grab.mouseDragged()
        grab.cancel()
        #expect(!grab.isDragging)
        #expect(grab.mouseUp(generation: 0).isEmpty)
    }
}
