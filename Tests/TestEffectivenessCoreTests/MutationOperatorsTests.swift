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

    @Test(arguments: ["some View", "some SwiftUI.View"])
    func someViewReturnsEmptyViewInsideAResultBuilderOrNot(_ type: String) {
        #expect(decision(type, builder: true) == .mutate([.emptyView]))
        #expect(decision(type) == .mutate([.emptyView]))
    }

    @Test(arguments: ["Never", "(Int, Int)", "Result<Int, Error>", "T", "some Collection", "any View", "some Shape"])
    func unsupportedTypesAreSkipped(_ type: String) {
        guard case .skip = decision(type) else {
            Issue.record("expected \(type) to be skipped")
            return
        }
    }
}

struct ExtremeMutationTests {
    /// What each mutation puts in place of the body, and how the report names it.
    @Test func statementAndSummaryOfEachMutation() {
        let expected: [(ExtremeMutation, statement: String, summary: String)] = [
            (.emptyBody, "return", "empty body"),
            (.returnNil, "return nil", "`return nil`"),
            (.returnBool(true), "return true", "`return true`"),
            (.returnBool(false), "return false", "`return false`"),
            (.returnNumber("0"), "return 0", "`return 0`"),
            (.returnNumber("1"), "return 1", "`return 1`"),
            (.returnString(""), "return \"\"", "`return \"\"`"),
            (.returnString("A"), "return \"A\"", "`return \"A\"`"),
            (.returnEmptyArray, "return []", "`return []`"),
            (.returnEmptyData, "return Data()", "`return Data()`"),
            (.returnEmptyDictionary, "return [:]", "`return [:]`"),
            (.emptyView, "EmptyView()", "`EmptyView()`"),
            (.throwError, "throw __STEExtremeMutationError()", "`throw __STEExtremeMutationError()`"),
        ]
        for (mutation, statement, summary) in expected {
            #expect(mutation.replacementStatement == statement)
            #expect(mutation.summary == summary)
        }
    }

    /// The literal of a string mutant is written as Swift source.
    @Test func stringLiteralIsEscaped() {
        #expect(ExtremeMutation.returnString(#"say "hi" \ bye"#).replacementStatement == #"return "say \"hi\" \\ bye""#)
    }
}
