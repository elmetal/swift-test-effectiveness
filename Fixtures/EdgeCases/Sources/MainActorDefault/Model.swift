final class Model {
    var count = 0
    func increment() { count += 1 }
    nonisolated func pureValue() -> Int { 42 }
    var label: String { "count: \(count)" }
}
