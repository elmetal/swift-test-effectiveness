import SwiftParser
import SwiftSyntax
import Testing
@testable import TestEffectivenessCore

struct MutationOperatorsTests {
    private func decision(_ type: String?, builder: Bool = false) -> MutationOperators.Decision {
        let syntax = type.map { text -> TypeSyntax in
            var parser = Parser(text)
            return TypeSyntax.parse(from: &parser)
        }
        return MutationOperators.mutations(for: syntax, isResultBuilder: builder)
    }

    @Test(arguments: [nil, "Void", "()", "Swift.Void"])
    func voidRemovesBody(_ type: String?) {
        #expect(decision(type) == .mutate([.emptyBody]))
    }

    @Test(arguments: ["Int?", "String!", "Optional<Int>", "[Int]?"])
    func optionalsReturnNil(_ type: String) {
        #expect(decision(type) == .mutate([.returnNil]))
    }

    @Test func boolGetsBothValues() {
        #expect(decision("Bool") == .mutate([.returnBool(true), .returnBool(false)]))
    }

    @Test(arguments: ["Int", "UInt8", "Double", "CGFloat", "Swift.Int"])
    func numbersReturnZeroAndOne(_ type: String) {
        #expect(decision(type) == .mutate([.returnNumber("0"), .returnNumber("1")]))
    }

    @Test func stringsReturnEmptyAndA() {
        #expect(decision("String") == .mutate([.returnString(""), .returnString("A")]))
    }

    @Test(arguments: ["[Int]", "Array<String>", "Set<Int>"])
    func collectionsReturnEmpty(_ type: String) {
        #expect(decision(type) == .mutate([.returnEmptyArray]))
    }

    @Test(arguments: ["[String: Int]", "Dictionary<String, Int>"])
    func dictionariesReturnEmpty(_ type: String) {
        #expect(decision(type) == .mutate([.returnEmptyDictionary]))
    }

    @Test func dataReturnsEmptyData() {
        #expect(decision("Data") == .mutate([.returnEmptyData]))
    }

    @Test func someViewOnlyInsideResultBuilder() {
        #expect(decision("some View", builder: true) == .mutate([.emptyView]))
        guard case .skip = decision("some View") else {
            Issue.record("`some View` outside a builder must be skipped")
            return
        }
    }

    @Test(arguments: ["Never", "(Int, Int)", "Result<Int, Error>", "T", "some Collection"])
    func unsupportedTypesAreSkipped(_ type: String) {
        guard case .skip = decision(type) else {
            Issue.record("expected \(type) to be skipped")
            return
        }
    }
}
