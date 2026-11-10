import Testing
@testable import Edge
@testable import MainActorDefault

@Test func smoke() async throws {
    var edge = Edge(value: 1)
    edge.bump()
    #expect(edge.ifExpression(true) == 1)
    #expect(edge.switchStatement(.b) == 2)
    #expect(try edge.tryExpression() == 1)
    #expect(edge.isDebug)
    #expect(edge.level() == 1)
    #expect(edge.afterInactiveBlock() == 4)
    #expect(await Counter().next() == 1)
}

@MainActor @Test func mainActorDefault() {
    let model = Model()
    model.increment()
    #expect(model.label == "count: 1")
}

#if canImport(SwiftUI)
import SwiftUI

/// `some View` outside a result builder. A view's description shows what it is made of.
@MainActor @Test func viewsOutsideAResultBuilder() async throws {
    let greeting = Greeting()
    // Checked.
    #expect(String(describing: greeting.severalReturns(true)).contains("on!"))
    #expect(String(describing: Greeting.badge(3)).contains("badge 3"))
    #expect(String(describing: greeting.explicitGetter).contains("getter"))
    var tally = Tally()
    _ = tally.next()
    #expect(tally.count == 1)
    #expect(String(describing: Returning().body).contains("returning"))
    // Only executed.
    _ = greeting.header
    _ = greeting.plain()
    _ = try await greeting.asyncThrowing()
    _ = Text("x").modifier(Card(bordered: true))
}
#endif
