@testable import PopCore
import Testing

struct AppStallsTests {
    @Test func callsAreSkippedForAPauseAfterATimeout() {
        var stalls = AppStalls()
        let first = stalls.beginCall(to: 7, at: 100)
        #expect(first == .healthy)

        let pause = stalls.timedOut(7, at: 100)
        #expect(pause == AppStalls.firstPause)
        let during = stalls.beginCall(to: 7, at: 101.9)
        #expect(during == .stalled)
        #expect(stalls.isStalled(7, at: 101.9))
        // Other apps are not affected.
        let other = stalls.beginCall(to: 8, at: 101)
        #expect(other == .healthy)
    }

    @Test func onlyOneCallTriesAgainAfterThePause() {
        var stalls = AppStalls()
        stalls.timedOut(7, at: 100)

        let retry = stalls.beginCall(to: 7, at: 102)
        #expect(retry == .retrying)
        // A call from another thread does not wait for the app too.
        let second = stalls.beginCall(to: 7, at: 102.5)
        #expect(second == .stalled)

        let whileStillRunning = stalls.beginCall(to: 7, at: 1000)
        #expect(whileStillRunning == .stalled)

        // The retry got no answer. The pause doubles.
        let pause = stalls.timedOut(7, at: 103)
        #expect(pause == 2 * AppStalls.firstPause)
        let after = stalls.beginCall(to: 7, at: 106.9)
        #expect(after == .stalled)
    }

    @Test func eachFurtherTimeoutDoublesThePause() {
        var stalls = AppStalls()
        var now = 100.0
        var pauses: [Double] = []
        for _ in 0 ..< 5 {
            let pause = stalls.timedOut(7, at: now)
            pauses.append(pause)
            now += pause
        }
        #expect(pauses == [2, 4, 8, 10, 10])
    }

    @Test func anAnswerEndsThePause() {
        var stalls = AppStalls()
        stalls.timedOut(7, at: 100)
        stalls.timedOut(7, at: 102)

        // An event from the app arrives while its pause runs.
        let wasStalled = stalls.answered(7)
        #expect(wasStalled)
        let health = stalls.beginCall(to: 7, at: 102.1)
        #expect(health == .healthy)
        let stillStalled = stalls.answered(7)
        #expect(!stillStalled)

        // The next stall starts with the first pause again.
        let pause = stalls.timedOut(7, at: 200)
        #expect(pause == AppStalls.firstPause)
    }
}
