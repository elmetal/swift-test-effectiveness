import Testing
@testable import TestEffectivenessCore

struct RunTimeoutTests {
    @Test func wholeSuiteFollowsTheBaseline() {
        #expect(RunTimeout(factor: 3, minimum: 30, baseline: 60).wholeSuite == 180)
        #expect(RunTimeout(factor: 3, minimum: 30, baseline: 2).wholeSuite == 30)
    }

    @Test func selectedTestsFollowTheTimeTheyTookAlone() {
        let timeout = RunTimeout(factor: 3, minimum: 5, baseline: 60)
        #expect(timeout.selected(aloneDurations: [2, 4]) == 18)
        // A short run still gets the minimum.
        #expect(timeout.selected(aloneDurations: [0.1]) == 5)
        #expect(timeout.selected(aloneDurations: []) == 5)
    }

    /// Each scope alone pays for starting the tests, so many scopes can add up to more than the
    /// whole suite takes.
    @Test func selectedTestsNeverGetMoreThanTheWholeSuite() {
        let timeout = RunTimeout(factor: 3, minimum: 5, baseline: 10)
        #expect(timeout.selected(aloneDurations: [6, 6, 6]) == 30)
    }

    @Test func unknownDurationGetsTheTimeoutOfTheWholeSuite() {
        let timeout = RunTimeout(factor: 3, minimum: 5, baseline: 60)
        #expect(timeout.selected(aloneDurations: [2, nil]) == 180)
    }
}
