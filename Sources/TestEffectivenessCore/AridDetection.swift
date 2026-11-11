import SwiftSyntax

/// Finds bodies whose only effect is logging or debug output ("arid" bodies).
///
/// The empty-body mutant of such a method survives every reasonable test suite, and reporting
/// it as pseudo-tested asks for an assertion nobody should write (an assertion on a log
/// message). Google's mutation testing suppresses mutants in such code as *arid nodes*
/// (Petrović & Ivanković 2018); this is the same idea applied to whole bodies.
///
/// The definition is recursive, and syntactic:
/// - a call to a known logging function, or to a logging method on a logger-like receiver,
///   or to a function named with `--arid-call`, is arid;
/// - a bare `return` is arid;
/// - `if`, `guard`, `defer` and `#if` are arid if every statement they contain is arid and
///   their conditions call nothing (a call in a condition may have a side effect);
/// - a body is arid if it has at least one statement and every statement is arid.
public struct AridDetector: Sendable {
    /// Free functions that only produce debug output.
    static let loggingFunctions: Set<String> = [
        "print", "debugPrint", "dump", "NSLog", "os_log", "os_signpost",
        "assert", "assertionFailure",
    ]
    /// Methods of `os.Logger` (and of most logging libraries) that emit a message.
    static let loggingMethods: Set<String> = [
        "log", "trace", "debug", "info", "notice", "warning", "error", "critical", "fault",
    ]

    /// Additional callees, matched against the called expression with any leading `self.`
    /// removed (`track` matches `track(…)`, `Analytics.shared.track` matches that exact chain).
    public var additionalCalls: Set<String>

    public init(additionalCalls: [String] = []) {
        self.additionalCalls = Set(additionalCalls)
    }

    public static let skipReason = "body only logs (arid): no test should assert on it"

    public func isArid(_ statements: CodeBlockItemListSyntax) -> Bool {
        !statements.isEmpty && statements.allSatisfy(isArid)
    }

    private func isArid(_ item: CodeBlockItemSyntax) -> Bool {
        switch item.item {
        case .expr(let expr):
            return isArid(expr)
        case .stmt(let stmt):
            return isArid(stmt)
        case .decl(let decl):
            return isArid(decl)
        }
    }

    private func isArid(_ stmt: StmtSyntax) -> Bool {
        if let exprStmt = stmt.as(ExpressionStmtSyntax.self) {
            return isArid(exprStmt.expression)
        }
        if let returnStmt = stmt.as(ReturnStmtSyntax.self) {
            return returnStmt.expression == nil
        }
        if let guardStmt = stmt.as(GuardStmtSyntax.self) {
            return !CallFinder.containsCall(Syntax(guardStmt.conditions)) && isArid(guardStmt.body.statements)
        }
        if let deferStmt = stmt.as(DeferStmtSyntax.self) {
            return isArid(deferStmt.body.statements)
        }
        return false
    }

    private func isArid(_ decl: DeclSyntax) -> Bool {
        guard let ifConfig = decl.as(IfConfigDeclSyntax.self) else { return false }
        return ifConfig.clauses.allSatisfy { clause in
            switch clause.elements {
            case .none:
                return true
            case .statements(let statements):
                return statements.allSatisfy(isArid)
            default:
                return false
            }
        }
    }

    private func isArid(_ expr: ExprSyntax) -> Bool {
        if let tryExpr = expr.as(TryExprSyntax.self) {
            return isArid(tryExpr.expression)
        }
        if let awaitExpr = expr.as(AwaitExprSyntax.self) {
            return isArid(awaitExpr.expression)
        }
        if let ifExpr = expr.as(IfExprSyntax.self) {
            return isArid(ifExpr)
        }
        if let call = expr.as(FunctionCallExprSyntax.self) {
            return isAridCall(call.calledExpression)
        }
        if let macro = expr.as(MacroExpansionExprSyntax.self) {
            return additionalCalls.contains("#" + macro.macroName.text)
        }
        return false
    }

    private func isArid(_ ifExpr: IfExprSyntax) -> Bool {
        guard !CallFinder.containsCall(Syntax(ifExpr.conditions)),
              ifExpr.body.statements.allSatisfy(isArid)
        else { return false }
        switch ifExpr.elseBody {
        case .none:
            return true
        case .ifExpr(let nested):
            return isArid(nested)
        case .codeBlock(let block):
            return block.statements.allSatisfy(isArid)
        }
    }

    private func isAridCall(_ callee: ExprSyntax) -> Bool {
        let text = Self.strippingSelf(callee.trimmedDescription)
        if additionalCalls.contains(text) { return true }
        if let reference = callee.as(DeclReferenceExprSyntax.self) {
            return Self.loggingFunctions.contains(reference.baseName.text)
        }
        if let member = callee.as(MemberAccessExprSyntax.self), let base = member.base {
            return Self.loggingMethods.contains(member.declName.baseName.text) && Self.isLoggerLike(base)
        }
        return false
    }

    /// `logger`, `self.logger`, `Self.log`, `Log.network`, `Logger(subsystem:category:)`, …
    private static func isLoggerLike(_ base: ExprSyntax) -> Bool {
        let receiver = base.as(FunctionCallExprSyntax.self)?.calledExpression ?? base
        // Any component counts, so a logger stored on a namespace (`Log.network`) matches too.
        return receiver.trimmedDescription.split(separator: ".").contains { component in
            let lowered = component.lowercased()
            return lowered == "log" || lowered.hasSuffix("logger")
        }
    }

    private static func strippingSelf(_ text: String) -> String {
        text.hasPrefix("self.") ? String(text.dropFirst(5)) : text
    }

    /// Finds function calls and macro expansions, also inside closures.
    private final class CallFinder: SyntaxVisitor {
        var found = false

        static func containsCall(_ node: Syntax) -> Bool {
            let finder = CallFinder(viewMode: .sourceAccurate)
            finder.walk(node)
            return finder.found
        }

        override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
            found = true
            return .skipChildren
        }
        override func visit(_ node: MacroExpansionExprSyntax) -> SyntaxVisitorContinueKind {
            found = true
            return .skipChildren
        }
    }
}
