import SwiftSyntax

/// One `case` of the switch a method ends with, and the extreme mutants it gets.
///
/// A method whose logic is a switch is verified case by case: one test of one case detects every
/// mutant of the whole body, and the method then looks tested whatever the other cases do. Each
/// case is therefore mutated as a body of its own: at its start the method returns the simplest
/// value for its return type (or returns at once, for `Void`), so the case does nothing.
///
/// Where the return type has no simplest value (an enum, a type of the project), the method has
/// no mutant of its own, and each case does what another case does instead: the next one where
/// it can fall through to it, or else the first one whose statements fit on its line.
public struct DiscoveredCase: Sendable {
    /// The label as written, without the colon: `case .loading`, `default`.
    public var label: String
    /// Line of the label.
    public var line: Int
    /// The method's mutations that change what this case does; empty when none does.
    public var mutations: [ExtremeMutation]

    /// UTF-8 offset just after the label's `:`.
    var contentStart: Int
    /// UTF-8 offsets of the case's expression, when the switch is the expression the method
    /// returns implicitly. A statement in front of it would turn the switch into a statement, so
    /// the mutants are the branches of an `if` expression around it instead.
    var expression: Range<Int>?
    /// What the case executes as the `otherCase` mutant: `fallthrough`, or the statements (in a
    /// switch expression, the expression) of the other case.
    var otherCaseStatement: String?
}

enum SwitchCases {
    /// The cases of the switch that `statements` ends with, or `[]` when there is no such switch
    /// or none of its cases can be mutated.
    ///
    /// Only a switch that is the last statement of the body is taken: leaving the method at the
    /// start of a case is then the same as the case doing nothing. After a switch in the middle
    /// of a body, the statements that follow would be skipped as well.
    ///
    /// - Parameters:
    ///   - mutations: the mutations of the method (see `MutationOperators`); empty when its return
    ///     type has no simplest value, and each case then does what another case does.
    ///   - line: the line of a position in the file.
    static func discover(
        _ statements: CodeBlockItemListSyntax, mutations: [ExtremeMutation], arid: AridDetector?,
        line: (AbsolutePosition) -> Int
    ) -> [DiscoveredCase] {
        guard let last = statements.last, let switchExpr = expression(of: last)?.as(SwitchExprSyntax.self) else {
            return []
        }
        // An `#if` around cases: which cases exist depends on the build configuration.
        let cases = switchExpr.cases.compactMap { $0.as(SwitchCaseSyntax.self) }
        guard cases.count == switchExpr.cases.count, cases.count >= 2 else { return [] }

        let returnsNothing = mutations.contains(.emptyBody)
        // The whole body is one switch without a `return`: its value is returned implicitly.
        let isExpression = !returnsNothing && statements.count == 1
            && !MethodDiscovery.ReturnFinder.containsReturn(Syntax(switchExpr))

        var result: [DiscoveredCase] = []
        var bodies: [Body] = []
        for switchCase in cases {
            let items = switchCase.statements
            var discovered = DiscoveredCase(
                label: label(of: switchCase),
                line: line(switchCase.positionAfterSkippingLeadingTrivia),
                mutations: mutations,
                contentStart: colon(of: switchCase).endPositionBeforeTrailingTrivia.utf8Offset
            )

            // What the case evaluates to, when it is a single `return` or a single expression.
            var value: ExprSyntax?
            var isThrow = false
            if items.count == 1, let item = items.first {
                if case .stmt(let stmt) = item.item {
                    if let returned = stmt.as(ReturnStmtSyntax.self) { value = returned.expression }
                    isThrow = stmt.is(ThrowStmtSyntax.self)
                }
                if isExpression {
                    if let expr = expression(of: item) { value = expr } else if !isThrow { return [] }
                    // Without a `;` after it.
                    discovered.expression = item.item.positionAfterSkippingLeadingTrivia.utf8Offset
                        ..< item.item.endPositionBeforeTrailingTrivia.utf8Offset
                }
            } else if isExpression {
                // Not a case of a switch expression after all.
                return []
            }

            if items.count == 1, let only = items.first, let expr = expression(of: only), neverReturns(expr) {
                // `fatalError()`: nothing a test can assert.
                discovered.mutations = []
            } else if returnsNothing, doesNothing(items, arid: arid) {
                discovered.mutations.removeAll { $0 == .emptyBody }
            }
            if let value {
                discovered.mutations.removeAll { isEquivalent($0, to: value) }
            }
            if isThrow {
                discovered.mutations.removeAll { $0 == .throwError }
            }
            result.append(discovered)
            bodies.append(Body(switchCase))
        }
        if mutations.isEmpty {
            for index in result.indices {
                guard let (other, statement) = otherCase(for: index, among: bodies, canFallThrough: !isExpression) else {
                    continue
                }
                result[index].mutations = [.otherCase(result[other].label)]
                result[index].otherCaseStatement = statement
            }
        }
        return result.contains { !$0.mutations.isEmpty } ? result : []
    }

    /// What decides whether one case can do what another does.
    private struct Body {
        /// The statements as written.
        var text: String
        /// The statements on one line, to execute in another case; `nil` when they cannot move.
        var copy: String?
        /// The names the label binds.
        var bound: Set<String> = []
        var bindsVariables = false
        /// Every identifier in the statements.
        var identifiers: Set<String> = []
        var neverReturns = false

        init(_ switchCase: SwitchCaseSyntax) {
            let items = switchCase.statements
            // Without the `;` that may follow a statement.
            text = items.map(\.item.trimmedDescription).joined(separator: "; ")
            for token in switchCase.label.tokens(viewMode: .sourceAccurate) {
                if token.tokenKind == .keyword(.let) || token.tokenKind == .keyword(.var) { bindsVariables = true }
                if token.parent?.is(IdentifierPatternSyntax.self) == true { bound.insert(token.text) }
            }
            var movable = !items.isEmpty
            for token in items.tokens(viewMode: .sourceAccurate) {
                if case .identifier(let name) = token.tokenKind { identifiers.insert(name) }
                // Both mean something else in another place.
                if token.tokenKind == .keyword(.fallthrough) || token.tokenKind == .keyword(.defer) { movable = false }
            }
            // A comment would hide what follows it on the line; another line would move the rest.
            if text.contains("\n") || text.contains("//") || text.contains("/*") { movable = false }
            if movable { copy = text }
            if items.count == 1, let only = items.first, let expr = SwitchCases.expression(of: only) {
                neverReturns = SwitchCases.neverReturns(expr)
            }
        }
    }

    /// The case that the case at `index` does the same as, as its mutant, and the statement that
    /// makes it: the nearest following case (then from the first) that binds no variables and
    /// does something else.
    ///
    /// - Parameter canFallThrough: `false` in a switch expression, whose cases are expressions.
    private static func otherCase(for index: Int, among bodies: [Body], canFallThrough: Bool) -> (Int, String)? {
        let body = bodies[index]
        // `fatalError()`: nothing a test can assert, and as the other case it would only crash.
        guard !body.neverReturns else { return nil }
        for offset in 1..<bodies.count {
            let other = (index + offset) % bodies.count
            let candidate = bodies[other]
            // The statements of a case that binds variables need them.
            guard !candidate.bindsVariables, !candidate.neverReturns, candidate.text != body.text else { continue }
            if other == index + 1, canFallThrough { return (other, "fallthrough") }
            // Elsewhere the statements run in this case, where its own variables must not hide
            // the names they use.
            if let copy = candidate.copy, candidate.identifiers.isDisjoint(with: body.bound) { return (other, copy) }
        }
        return nil
    }

    private static func expression(of item: CodeBlockItemSyntax) -> ExprSyntax? {
        switch item.item {
        case .expr(let expr): expr
        case .stmt(let stmt): stmt.as(ExpressionStmtSyntax.self)?.expression
        case .decl: nil
        }
    }

    private static func colon(of switchCase: SwitchCaseSyntax) -> TokenSyntax {
        switch switchCase.label {
        case .case(let label): label.colon
        case .default(let label): label.colon
        }
    }

    /// `case .a, .b` or `@unknown default`, on one line.
    private static func label(of switchCase: SwitchCaseSyntax) -> String {
        var text = (switchCase.attribute.map { $0.trimmedDescription + " " } ?? "") + switchCase.label.trimmedDescription
        if text.hasSuffix(":") { text.removeLast() }
        return text.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func neverReturns(_ expr: ExprSyntax) -> Bool {
        guard let call = expr.as(FunctionCallExprSyntax.self),
              let callee = call.calledExpression.as(DeclReferenceExprSyntax.self)
        else { return false }
        return MethodDiscovery.neverReturningCalls.contains(callee.baseName.text)
    }

    /// The case already does what the empty-body mutant makes it do, or only logs.
    private static func doesNothing(_ items: CodeBlockItemListSyntax, arid: AridDetector?) -> Bool {
        if arid?.isArid(items) == true { return true }
        return items.allSatisfy { item in
            guard case .stmt(let stmt) = item.item else { return false }
            if let returned = stmt.as(ReturnStmtSyntax.self) { return returned.expression == nil }
            return stmt.is(BreakStmtSyntax.self)
        }
    }

    /// Whether the mutant returns what the case returns already: it could not be detected.
    static func isEquivalent(_ mutation: ExtremeMutation, to value: ExprSyntax) -> Bool {
        switch mutation {
        case .returnNil:
            return value.is(NilLiteralExprSyntax.self)
        case .returnBool(let bool):
            return value.as(BooleanLiteralExprSyntax.self)?.literal.text == "\(bool)"
        case .returnNumber(let literal):
            let text = value.as(IntegerLiteralExprSyntax.self)?.literal.text
                ?? value.as(FloatLiteralExprSyntax.self)?.literal.text
            guard let text, let number = Double(text.replacingOccurrences(of: "_", with: "")) else { return false }
            return number == Double(literal)
        case .returnString(let literal):
            guard let string = value.as(StringLiteralExprSyntax.self) else { return false }
            if string.segments.isEmpty { return literal.isEmpty }
            guard string.segments.count == 1, let segment = string.segments.first?.as(StringSegmentSyntax.self) else {
                return false
            }
            return segment.content.text == literal
        case .returnEmptyArray:
            return value.as(ArrayExprSyntax.self)?.elements.isEmpty == true
        case .returnEmptyDictionary:
            guard let dictionary = value.as(DictionaryExprSyntax.self) else { return false }
            if case .colon = dictionary.content { return true }
            return false
        case .returnEmptyData:
            return value.trimmedDescription == "Data()"
        case .emptyBody, .emptyView, .throwError, .otherCase:
            return false
        }
    }
}
