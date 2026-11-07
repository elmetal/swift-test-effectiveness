public final class Calculator {
    public private(set) var history: [String] = []

    public init() {}

    // tested: both 0 and 1 mutants are detected.
    public func add(_ a: Int, _ b: Int) -> Int {
        a + b
    }

    // partially tested: only the `true` case is asserted.
    public func isPositive(_ x: Int) -> Bool {
        x > 0
    }

    // pseudo-tested: called by a test, but its result is never checked.
    public func greeting(for name: String) -> String {
        "Hello, \(name)!"
    }

    // pseudo-tested: side effect is never asserted.
    public func record(_ entry: String) {
        history.append(entry)
    }

    // tested via optional.
    public func firstNegative(in values: [Int]) -> Int? {
        for value in values where value < 0 {
            return value
        }
        return nil
    }

    // not covered: no test executes this.
    public func unused() -> Int {
        42
    }

    // computed property, tested.
    public var isEmpty: Bool {
        history.isEmpty
    }

    // collection result: the `[]` mutant is detected by the count check.
    public func doubled(_ values: [Int]) -> [Int] {
        values.map { $0 * 2 }
    }

    // unsupported return type → reported as not analyzed.
    public func pair() -> (Int, Int) {
        (1, 2)
    }
}
