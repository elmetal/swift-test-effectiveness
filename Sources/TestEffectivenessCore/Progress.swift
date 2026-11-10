import Foundation

/// Progress lines for the mutant runs: `[3/40] Calculator.add(_:_:): `return 0` (about 1m 10s left)`.
///
/// The remaining time is the average duration of the finished runs times the runs left. Before the
/// first run finishes, the baseline duration stands in for the average.
struct Progress {
    let total: Int
    private let initialEstimate: Double
    /// Runs that execute at once; the remaining time divides by it.
    private let parallelism: Int
    private var started = 0
    private var finishedCount = 0
    private var finishedDuration = 0.0

    init(total: Int, initialEstimate: Double, parallelism: Int = 1) {
        self.total = total
        self.initialEstimate = initialEstimate
        self.parallelism = max(1, parallelism)
    }

    /// The line to show when the next run starts.
    mutating func next(_ description: String) -> String {
        started += 1
        let average = finishedCount > 0 ? finishedDuration / Double(finishedCount) : initialEstimate
        let remaining = average * Double(total - started + 1) / Double(parallelism)
        return "[\(started)/\(total)] \(description) (about \(Self.format(remaining)) left)"
    }

    mutating func finished(duration: Double) {
        finishedCount += 1
        finishedDuration += duration
    }

    /// `45s`, `3m 05s`, `1h 02m`.
    static func format(_ seconds: Double) -> String {
        let total = max(0, Int(seconds.rounded()))
        let (hours, minutes, secs) = (total / 3600, total % 3600 / 60, total % 60)
        if hours > 0 { return "\(hours)h \(String(format: "%02d", minutes))m" }
        if minutes > 0 { return "\(minutes)m \(String(format: "%02d", secs))s" }
        return "\(secs)s"
    }
}
