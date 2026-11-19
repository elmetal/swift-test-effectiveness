import SwiftParser
import SwiftSyntax

/// The closures that are analyzed like methods, for the calls the user names
/// (`--closure 'Handler=Command'`).
///
/// Where the logic of a project is written as closures (a handler passed to a type that calls it
/// for every event), no method holds it: the method that makes the closure only returns it. The
/// trailing closure of a call the user names is therefore a method of its own, with the mutants
/// of the return type given for it; a closure does not say what it returns.
///
/// A call is matched as it is written, since nothing here resolves names: by the last components
/// of what is called. `subscribe` matches `subscribe { }`, `store.subscribe { }` and
/// `.subscribe { }`; `Store.subscribe` only the calls that end with both.
public struct ClosureUnits: Equatable, Sendable {
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// The return type of the closure, for each name.
    private var types: [String: String] = [:]

    public init() {}

    /// - Parameter arguments: `NAME=TYPE`, split at the first `=`.
    public init(parsing arguments: [String]) throws {
        for argument in arguments {
            guard let separator = argument.firstIndex(of: "=") else {
                throw ParseError(description: "'\(argument)' is not NAME=TYPE")
            }
            // `.init` is called as `init`: an implicit member has nothing in front of its dot.
            let name = String(argument[..<separator]).trimmingCharacters(in: .whitespaces)
                .split(separator: ".", omittingEmptySubsequences: true).joined(separator: ".")
            let type = argument[argument.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, !name.contains(where: \.isWhitespace) else {
                throw ParseError(description: "'\(argument)' names no function before `=`")
            }
            guard let syntax = Self.type(type) else {
                throw ParseError(description: "'\(type)' is not a type, for `\(name)`")
            }
            // Every `return` of a `some` type has one concrete type, which a mutant cannot have.
            guard !syntax.tokens(viewMode: .sourceAccurate).contains(where: { $0.tokenKind == .keyword(.some) }) else {
                throw ParseError(description: "'\(type)' is an opaque type, which a closure cannot return, for `\(name)`")
            }
            if let known = types[name], known != type {
                throw ParseError(description: "`\(name)` returns `\(known)` and `\(type)`")
            }
            types[name] = type
        }
    }

    public var isEmpty: Bool { types.isEmpty }

    /// The name given for a call to `callee`, and the type its trailing closure returns. The
    /// name with the most components wins.
    func match(_ callee: ExprSyntax) -> (name: String, type: TypeSyntax)? {
        // `Handler<State, Event> { }` calls `Handler`.
        let called = callee.as(GenericSpecializationExprSyntax.self)?.expression ?? callee
        let components = called.trimmedDescription.filter { !$0.isWhitespace }.split(separator: ".")
        for start in components.indices {
            let name = components[start...].joined(separator: ".")
            if let type = types[name], let syntax = Self.type(type) { return (name, syntax) }
        }
        return nil
    }

    /// `text` as a type, or `nil` when it is not one.
    private static func type(_ text: String) -> TypeSyntax? {
        guard !text.isEmpty else { return nil }
        var parser = Parser(text)
        let type = TypeSyntax.parse(from: &parser)
        return type.hasError ? nil : type
    }
}

/// A closure of a body that is analyzed like a method.
struct FoundClosure {
    var closure: ClosureExprSyntax
    /// The name the user gave for the call.
    var name: String
    var returnType: TypeSyntax
    /// Inside an `#if` clause of the body.
    var isConditionallyCompiled: Bool
}

/// Finds the trailing closures of the calls `ClosureUnits` names, in the body of a method. A
/// closure inside another is found as well, and is a method of its own.
final class ClosureFinder: SyntaxVisitor {
    private let units: ClosureUnits
    private var ifConfigDepth = 0
    private(set) var found: [FoundClosure] = []

    static func closures(in statements: CodeBlockItemListSyntax, units: ClosureUnits) -> [FoundClosure] {
        guard !units.isEmpty else { return [] }
        let finder = ClosureFinder(units: units)
        finder.walk(statements)
        return finder.found
    }

    private init(units: ClosureUnits) {
        self.units = units
        super.init(viewMode: .sourceAccurate)
    }

    override func visit(_ node: FunctionCallExprSyntax) -> SyntaxVisitorContinueKind {
        if let closure = node.trailingClosure, let (name, type) = units.match(node.calledExpression),
           closure.leftBrace.presence == .present, closure.rightBrace.presence == .present,
           closure.signature?.inKeyword.presence != .missing {
            // A closure that writes its return type says more than the name of the call.
            let written = closure.signature?.returnClause?.type
            found.append(FoundClosure(
                closure: closure, name: name, returnType: written ?? type, isConditionallyCompiled: ifConfigDepth > 0
            ))
        }
        return .visitChildren
    }

    override func visit(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind {
        ifConfigDepth += 1
        return .visitChildren
    }
    override func visitPost(_ node: IfConfigClauseSyntax) { ifConfigDepth -= 1 }

    // The methods of a type declared in a body are not analyzed, and neither are their closures.
    override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
}
