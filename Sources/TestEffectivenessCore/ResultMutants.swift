import SwiftSyntax

/// The mutants that replace only what a body returns (`--return-mutants`).
///
/// An extreme mutant leaves the body at its start, so what the body does goes with what it
/// returns: a test that asserts the one detects the mutant, whatever becomes of the other. Where a
/// body changes state and then returns a value, the value may be one no test looks at.
///
/// These mutants keep the statements and replace the value: every `return` of the body gives the
/// simplest value of the return type instead of its own.
///
///     state.unread += 1
///     if __steActiveMutant == 7 { return .none }; return .reload
///
/// The expression of the `return` is not evaluated. A body gets such a mutant only where it would
/// differ from the mutant that leaves at the start:
///
/// - it does something besides returning: a statement that is an expression (an assignment, a
///   call) and does not only log, and
/// - one of its `return`s gives something else than the value.
struct ResultMutants: Equatable, Sendable {
    /// One mutation for each value that is returned instead.
    var mutations: [ExtremeMutation] = []
    /// For the expression of each mutation: the UTF-8 offsets of the `return`s it replaces.
    var sites: [String: [Int]] = [:]

    /// - Parameters:
    ///   - statements: the body, or the statements of a case.
    ///   - mutations: the mutants that leave at the start; those that return a value give theirs.
    static func discover(
        _ statements: CodeBlockItemListSyntax, mutations: [ExtremeMutation], arid: AridDetector?
    ) -> ResultMutants {
        let values = mutations.compactMap(\.returnedExpression)
        guard !values.isEmpty else { return ResultMutants() }
        let finder = Finder(arid: arid)
        finder.walk(statements)
        guard finder.doesSomething else { return ResultMutants() }

        var result = ResultMutants()
        for (mutation, value) in zip(mutations.filter { $0.returnedExpression != nil }, values) {
            // A `return` that gives the value already stays as it is.
            let replaced = finder.returns.filter { !SwitchCases.isEquivalent(mutation, to: $0.value) }
            guard !replaced.isEmpty else { continue }
            result.mutations.append(.resultOnly(value))
            result.sites[value] = replaced.map(\.offset)
        }
        return result
    }

    /// Finds the `return`s of a body and whether it does anything else. What a closure, a local
    /// function or a local type does is its own.
    private final class Finder: SyntaxVisitor {
        let arid: AridDetector?
        var returns: [(offset: Int, value: ExprSyntax)] = []
        var doesSomething = false

        init(arid: AridDetector?) {
            self.arid = arid
            super.init(viewMode: .sourceAccurate)
        }

        override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
            if let value = node.expression {
                returns.append((node.returnKeyword.positionAfterSkippingLeadingTrivia.utf8Offset, value))
            }
            return .skipChildren
        }

        override func visit(_ node: CodeBlockItemSyntax) -> SyntaxVisitorContinueKind {
            let expression: ExprSyntax? = switch node.item {
            case .expr(let expr): expr
            case .stmt(let stmt): stmt.as(ExpressionStmtSyntax.self)?.expression
            case .decl: nil
            }
            // An `if` or a `switch` does what its statements do.
            if let expression, !expression.is(IfExprSyntax.self), !expression.is(SwitchExprSyntax.self),
               arid?.isArid(node) != true {
                doesSomething = true
            }
            return .visitChildren
        }

        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    }
}
