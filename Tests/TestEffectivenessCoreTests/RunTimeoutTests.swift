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

    /// A run in a resident host that takes longer than its timeout gets a process of its own,
    /// with the usual timeout: the floor there is short, so that an endless loop waits little
    /// before it does.
    @Test func runsInAResidentHostGetAShortFloorAndTheSameFactor() {
        let timeout = RunTimeout(factor: 3, minimum: 5, baseline: 0.2)
        #expect(timeout.inResidentHost(expected: 0.01) == 1)
        #expect(timeout.inResidentHost(expected: 0.3) == 1)
        #expect(RunTimeout(factor: 10, minimum: 5, baseline: 0.2).inResidentHost(expected: 0.2) == 2)
        // A floor below it stays.
        #expect(RunTimeout(factor: 3, minimum: 0.5, baseline: 0.1).inResidentHost(expected: 0.01) == 0.5)
    }

    /// The host saves the start of a process; a run it cannot decide takes place twice.
    @Test func longRunsAndRunsOfUnknownDurationAreNotForAResidentHost() {
        let timeout = RunTimeout(factor: 3, minimum: 5, baseline: 0.2)
        #expect(timeout.inResidentHost(expected: 0.31) == nil)
        #expect(timeout.inResidentHost(expected: 60) == nil)
        #expect(timeout.inResidentHost(expected: nil) == nil)
    }

    /// Each scope ran alone in a process of its own, which is not what it takes in a host.
    @Test func expectedDurationLeavesOutWhatEachRunCostBesidesItsTests() {
        #expect(RunTimeout.expected(aloneDurations: [0.5, 0.25], overhead: 0.125) == 0.5)
        #expect(RunTimeout.expected(aloneDurations: [0.1, 0.11], overhead: 0.2) == 0)
        #expect(RunTimeout.expected(aloneDurations: [], overhead: 0.1) == 0)
        #expect(RunTimeout.expected(aloneDurations: [0.5, nil], overhead: 0.1) == nil)
    }

    @Test func unknownDurationGetsTheTimeoutOfTheWholeSuite() {
        let timeout = RunTimeout(factor: 3, minimum: 5, baseline: 60)
        #expect(timeout.selected(aloneDurations: [2, nil]) == 180)
    }
}
