import Testing
@testable import Sample

@Test func addition() {
    let calc = Calculator()
    #expect(calc.add(2, 3) == 5)
}

@Test func positive() {
    #expect(Calculator().isPositive(3))
}

@Test func greetingDoesNotCrash() {
    _ = Calculator().greeting(for: "Swift")
}

@Test func recordDoesNotCrash() {
    let calc = Calculator()
    calc.record("a")
}

@Test func firstNegative() {
    #expect(Calculator().firstNegative(in: [1, -2, 3]) == -2)
}

@Test func emptiness() {
    #expect(Calculator().isEmpty)
}

@Test func doubled() {
    #expect(Calculator().doubled([1, 2, 3]).count == 3)
}

@Test func pair() {
    _ = Calculator().pair()
}
