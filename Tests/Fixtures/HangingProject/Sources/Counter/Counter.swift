public struct Counter {
    public var limit: Int

    public init(limit: Int) {
        self.limit = limit
    }

    /// With `return false`, `count()` never ends: the mutant is detected by a timeout.
    public func isDone(_ steps: Int) -> Bool {
        steps >= limit
    }

    public func count() -> Int {
        var steps = 0
        while !isDone(steps) {
            steps += 1
        }
        return steps
    }

    public func label() -> String {
        "limit \(limit)"
    }
}
