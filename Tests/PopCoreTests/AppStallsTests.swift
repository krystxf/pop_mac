@testable import PopCore
import Testing

struct AppStallsTests {
    @Test func callsAreSkippedForAPauseAfterATimeout() {
        var stalls = AppStalls()
        #expect(stalls.health(of: 7, at: 100) == .healthy)

        let pause = stalls.timedOut(7, at: 100)
        #expect(pause == AppStalls.firstPause)
        #expect(stalls.health(of: 7, at: 100) == .stalled)
        #expect(stalls.health(of: 7, at: 101.9) == .stalled)
        // Other apps are not affected.
        #expect(stalls.health(of: 8, at: 101) == .healthy)

        // After the pause, one call tries again.
        #expect(stalls.health(of: 7, at: 102) == .retrying)
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
        #expect(stalls.health(of: 7, at: 102.1) == .healthy)
        let stillStalled = stalls.answered(7)
        #expect(!stillStalled)

        // The next stall starts with the first pause again.
        let pause = stalls.timedOut(7, at: 200)
        #expect(pause == AppStalls.firstPause)
    }
}
