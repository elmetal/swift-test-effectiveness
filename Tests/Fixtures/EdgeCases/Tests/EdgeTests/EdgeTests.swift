import Testing
@testable import Edge
@testable import MainActorDefault

@Test func smoke() async throws {
    var edge = Edge(value: 1)
    edge.bump()
    #expect(edge.ifExpression(true) == 1)
    #expect(edge.switchStatement(.b) == 2)
    #expect(try edge.tryExpression() == 1)
    #expect(await Counter().next() == 1)
}

@MainActor @Test func mainActorDefault() {
    let model = Model()
    model.increment()
    #expect(model.label == "count: 1")
}
