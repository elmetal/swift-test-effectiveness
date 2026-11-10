/// How long a test run may take before it is stopped and its mutant counts as detected.
///
/// A mutant can turn a loop into an endless one, and the run then costs the whole timeout. So
/// the timeout follows what the run is expected to take: the baseline's duration for the whole
/// suite, and for selected test scopes the time they took when each ran alone, which is usually
/// far less. Both are multiplied by `factor` and have `minimum` as a floor against the noise of a
/// short run.
struct RunTimeout: Equatable, Sendable {
    /// The floor when the user gives none.
    static let defaultMinimum = 30.0
    /// The floor when the user gives none and the test bundles are started directly: such a run
    /// has almost no fixed cost, and a failing run takes no longer than a passing one. (A failing
    /// `xcodebuild` run can take much longer, e.g. to collect diagnostics.)
    static let defaultMinimumForDirectLaunch = 5.0

    var factor: Double
    var minimum: Double
    /// The duration of the baseline, a run of the whole suite.
    var baseline: Double

    /// For a run of the whole suite.
    var wholeSuite: Double { max(baseline * factor, minimum) }

    /// For a run of test scopes that took `aloneDurations` when each ran alone. Never more than
    /// for the whole suite, and that of the whole suite when a duration is unknown.
    func selected(aloneDurations: [Double?]) -> Double {
        var expected = 0.0
        for duration in aloneDurations {
            guard let duration else { return wholeSuite }
            expected += duration
        }
        return min(wholeSuite, max(expected * factor, minimum))
    }
}
