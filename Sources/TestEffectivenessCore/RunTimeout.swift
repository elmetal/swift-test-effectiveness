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

    /// The floor in a resident host, where a run has no process to start and so less noise. What
    /// takes longer there is stopped and gets a process of its own, with the usual timeout, so a
    /// short floor only costs time when it is too short; a long one makes an endless loop wait
    /// for the timeout twice.
    static let minimumInResidentHost = 1.0
    /// A run that is expected to take longer than this, in seconds, is not for a resident host.
    /// The host saves the start of a process, a tenth of a second or so; when it cannot decide a
    /// run (the mutant survives, the run times out), the run takes place twice, and for long
    /// tests that costs more than starting processes does.
    static let longestRunInResidentHost = 0.3

    var factor: Double
    var minimum: Double
    /// The duration of the baseline, a run of the whole suite.
    var baseline: Double

    /// For a run of the whole suite.
    var wholeSuite: Double { max(baseline * factor, minimum) }

    /// For a run in a resident host that is expected to take `expected` seconds there, or `nil`
    /// when the run is too long for one or its duration is unknown.
    func inResidentHost(expected: Double?) -> Double? {
        guard let expected, expected <= Self.longestRunInResidentHost else { return nil }
        return max(expected * factor, min(minimum, Self.minimumInResidentHost))
    }

    /// What a run of scopes that took `aloneDurations` when each ran alone is expected to take
    /// without what each of those runs cost besides its tests (`overhead`: starting a process).
    /// `nil` when a duration is unknown.
    static func expected(aloneDurations: [Double?], overhead: Double) -> Double? {
        var expected = 0.0
        for duration in aloneDurations {
            guard let duration else { return nil }
            expected += max(0, duration - overhead)
        }
        return expected
    }

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
