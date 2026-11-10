import Testing
@testable import Counter

@Test func countsUpToTheLimit() {
    #expect(Counter(limit: 3).count() == 3)
}

@Test func labelNamesTheLimit() {
    #expect(Counter(limit: 3).label() == "limit 3")
}
