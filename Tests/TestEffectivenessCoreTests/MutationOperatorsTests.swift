import SwiftParser
import SwiftSyntax
import Testing
@testable import TestEffectivenessCore

struct MutationOperatorsTests {
    private func decision(
        _ type: String?, builder: Bool = false, defaults: [String] = []
    ) -> MutationOperators.Decision {
        let syntax = type.map { text -> TypeSyntax in
            var parser = Parser(text)
            return TypeSyntax.parse(from: &parser)
        }
        return MutationOperators.mutations(
            for: syntax, isResultBuilder: builder, defaults: try! DefaultValues(parsing: defaults)
        )
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

    // MARK: Values from the user

    /// A return type is found as it is written: the whole type, its name without generic
    /// arguments, or the last component of that name.
    @Test(arguments: [
        ("Money", "Money=.zero", ".zero"),
        ("Tagged<User, Int>", "Tagged=.init(0)", ".init(0)"),
        ("Shop.Money", "Money=.zero", ".zero"),
        ("Shop.Money", "Shop.Money=.zero", ".zero"),
        ("Shop.Tagged<User, Int>", "Tagged=.init(0)", ".init(0)"),
        ("Result<Int, Error>", "Result<Int,Error>=.success(0)", ".success(0)"),
        ("(Int, Int)", "( Int, Int ) = (0, 0)", "(0, 0)"),
        ("any Shape", "any Shape=Circle()", "Circle()"),
        ("Flag", "Flag=a == b", "a == b"),
    ])
    func typeTheUserNamedReturnsItsValue(_ type: String, _ argument: String, _ expression: String) {
        #expect(decision(type, defaults: [argument]) == .mutate([.returnValue(expression)]))
    }

    @Test func eachValueOfATypeIsAMutant() {
        let defaults = ["Tint=.gray", "Money=.zero", "Tint=.red", "Tint=.gray"]
        #expect(decision("Tint", defaults: defaults) == .mutate([.returnValue(".gray"), .returnValue(".red")]))
    }

    @Test func valuesFromTheUserReplaceTheBuiltInOnes() {
        #expect(decision("Int", defaults: ["Int=42"]) == .mutate([.returnValue("42")]))
        #expect(decision("Int?", defaults: ["Int?=0"]) == .mutate([.returnValue("0")]))
    }

    @Test func theMostSpecificNameWins() {
        let defaults = ["Money=.zero", "Shop.Money=.one", "Box=.empty", "Box<Int>=.init(0)"]
        #expect(decision("Shop.Money", defaults: defaults) == .mutate([.returnValue(".one")]))
        #expect(decision("Bank.Money", defaults: defaults) == .mutate([.returnValue(".zero")]))
        #expect(decision("Box<Int>", defaults: defaults) == .mutate([.returnValue(".init(0)")]))
        #expect(decision("Box<String>", defaults: defaults) == .mutate([.returnValue(".empty")]))
    }

    /// A type that only contains the named one is another type.
    @Test func typesAroundTheNamedOneKeepTheirRules() {
        let defaults = ["Money=.zero"]
        #expect(decision("Money?", defaults: defaults) == .mutate([.returnNil]))
        #expect(decision("[Money]", defaults: defaults) == .mutate([.returnEmptyArray]))
        #expect(decision("(Money, Money)", defaults: defaults) == .skip(reason: "unsupported return type `(Money, Money)`"))
        #expect(decision("MoneyBox", defaults: defaults) == .skip(reason: "unsupported return type `MoneyBox`"))
        #expect(decision(nil, defaults: defaults) == .mutate([.emptyBody]))
    }

    /// Every `return` of a `some` type has one concrete type, and a result builder has no `return`.
    @Test func opaqueTypesAndResultBuildersTakeNoValue() {
        #expect(decision("some Shape", defaults: ["some Shape=Circle()"]) == .skip(reason: "unsupported return type `some Shape`"))
        #expect(decision("some View", defaults: ["some View=Text(\"\")"]) == .mutate([.emptyView]))
        #expect(decision("Money", builder: true, defaults: ["Money=.zero"]) == .skip(reason: "result builder body returning `Money`"))
        #expect(decision("any Shape", builder: true, defaults: ["any Shape=Circle()"]) == .skip(reason: "unsupported return type `any Shape`"))
    }

    @Test(arguments: [
        ("Money", "'Money' is not TYPE=EXPRESSION"),
        ("=.zero", "'=.zero' names no type before `=`"),
        ("Void=()", "`Void` has no value to return"),
        ("Never=fatalError()", "`Never` has no value to return"),
        ("Money=", "'' is not one expression on one line, for `Money`"),
        ("Money=return .zero", "'return .zero' is not one expression on one line, for `Money`"),
        ("Money=.zero; log()", "'.zero; log()' is not one expression on one line, for `Money`"),
        ("Money=.zero;", "'.zero;' is not one expression on one line, for `Money`"),
        ("Money=Money(", "'Money(' is not one expression on one line, for `Money`"),
        ("Money=Money\n.zero", "'Money\n.zero' is not one expression on one line, for `Money`"),
    ])
    func argumentThatIsNotATypeAndAnExpressionIsRejected(_ argument: String, _ message: String) {
        #expect(throws: DefaultValues.ParseError(description: message)) {
            try DefaultValues(parsing: [argument])
        }
    }

    @Test func noArgumentsAreNoValues() throws {
        #expect(try DefaultValues(parsing: []).isEmpty)
        #expect(try !DefaultValues(parsing: ["Money=.zero"]).isEmpty)
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
            (.returnValue(".zero"), "return .zero", "`return .zero`"),
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
