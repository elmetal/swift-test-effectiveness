import Testing
@testable import TestEffectivenessCore

struct ProgressTests {
    @Test func showsPositionTotalAndRemainingTime() {
        var progress = Progress(total: 3, initialEstimate: 10)
        // Before any run finishes, the baseline duration is the estimate: 3 runs × 10s.
        #expect(progress.next("A.f(): empty body") == "[1/3] A.f(): empty body (about 30s left)")
        progress.finished(duration: 40)
        // Then the average of finished runs: 2 runs × 40s.
        #expect(progress.next("A.g(): `return nil`") == "[2/3] A.g(): `return nil` (about 1m 20s left)")
        progress.finished(duration: 20)
        #expect(progress.next("A.h(): `return 0`") == "[3/3] A.h(): `return 0` (about 30s left)")
    }

    @Test func remainingTimeDividesByParallelRuns() {
        var progress = Progress(total: 8, initialEstimate: 10, parallelism: 4)
        // 8 runs × 10s on 4 workers.
        #expect(progress.next("A.f(): empty body") == "[1/8] A.f(): empty body (about 20s left)")
    }

    @Test func formatsDurations() {
        #expect(Progress.format(0) == "0s")
        #expect(Progress.format(44.6) == "45s")
        #expect(Progress.format(185) == "3m 05s")
        #expect(Progress.format(3720) == "1h 02m")
    }
}
