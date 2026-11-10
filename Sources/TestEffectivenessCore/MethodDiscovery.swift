import SwiftParser
import SwiftSyntax

/// A method found in a source file, together with what the schemata rewriter needs to mutate it.
public struct DiscoveredMethod: Sendable {
    public var info: MethodInfo
    public var decision: MutationOperators.Decision

    /// UTF-8 offset just after the body's `{`.
    var bodyContentStart: Int
    /// UTF-8 offset of the body's `}`.
    var bodyContentEnd: Int
    /// UTF-8 offset where `return ` must be inserted to keep a single-expression body valid
    /// once statements are placed in front of it.
    var implicitReturnInsertion: Int?
    var isResultBuilder: Bool
    /// Set when the method returns `some View` outside a result builder: the original body is then
    /// kept in a local function (see `SchemataRewriter`).
    var opaqueBody: OpaqueBody?
    /// Declared inside an `#if` clause. Whether that clause is active depends on the build
    /// configuration, so the method may not be compiled at all.
    var isConditionallyCompiled: Bool = false
    /// The cases of the switch the body ends with, when they are mutated one by one (see
    /// `DiscoveredCase`); empty otherwise.
    public var cases: [DiscoveredCase] = []

    public var mutations: [ExtremeMutation] {
        if case .mutate(let mutations) = decision { return mutations }
        return []
    }
}

/// The local function that keeps the original body of a method returning an opaque type.
///
/// Every `return` of such a method must have the same concrete type, so a mutant cannot return in
/// front of the original body. Inside a local function the original `return`s are on their own,
/// and the method returns once, with one type for the mutant and the original.
struct OpaqueBody: Equatable, Sendable {
    /// Whether the local function is a `@ViewBuilder`: when the body has no `return`.
    ///
    /// A requirement such as `ViewModifier.body(content:)` makes the body a view builder without
    /// the attribute being written, which a local function would lose. An explicit `return` turns
    /// the builder off, so a body with one is not a builder, and a body without one is valid as a
    /// builder: it is either builder syntax already, or a single expression.
    var isViewBuilder: Bool
    /// Effects and result type as declared, e.g. `async throws -> some View`.
    var signature: String
    /// `try await `, as far as the declaration throws and is async.
    var callEffects: String
}

public struct DiscoveryOptions: Sendable {
    /// Also generate a `throw` mutant for methods declared with untyped `throws`.
    public var includeThrowMutants: Bool
    /// Skip methods returning `Void` whose body only logs (see `AridDetector`); `nil` disables it.
    public var arid: AridDetector?
    /// Also mutate each case of a switch that a method ends with (see `DiscoveredCase`).
    public var caseMutants: Bool

    public init(
        includeThrowMutants: Bool = false, arid: AridDetector? = AridDetector(), caseMutants: Bool = false
    ) {
        self.includeThrowMutants = includeThrowMutants
        self.arid = arid
        self.caseMutants = caseMutants
    }
}

/// Finds mutable methods in one Swift source file.
///
/// Targets: functions with a body and computed-property getters declared at file scope or inside
/// types/extensions. Not targeted: initializers, deinitializers, subscripts, accessors other than
/// `get`, protocol requirements, local functions and closures.
public enum MethodDiscovery {
    public static func discover(
        source: String, relativePath: String, options: DiscoveryOptions = .init()
    ) -> [DiscoveredMethod] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: relativePath, tree: tree)
        let visitor = Visitor(path: relativePath, converter: converter, options: options)
        visitor.walk(tree)
        let isMainFile = relativePath.split(separator: "/").last == "main.swift"
        guard isMainFile else { return visitor.methods }
        return visitor.methods.map {
            var method = $0
            method.decision = .skip(reason: "declared in main.swift (top-level code)")
            return method
        }
    }

    private static let inliningAttributes: Set<String> = ["inlinable", "_transparent", "_alwaysEmitIntoClient"]
    static let neverReturningCalls: Set<String> = ["fatalError", "preconditionFailure"]

    private final class Visitor: SyntaxVisitor {
        let path: String
        let converter: SourceLocationConverter
        let options: DiscoveryOptions
        var typeStack: [String] = []
        var ifConfigDepth = 0
        var methods: [DiscoveredMethod] = []

        init(path: String, converter: SourceLocationConverter, options: DiscoveryOptions) {
            self.path = path
            self.converter = converter
            self.options = options
            super.init(viewMode: .sourceAccurate)
        }

        // MARK: Type context

        override func visit(_ node: StructDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text) }
        override func visitPost(_ node: StructDeclSyntax) { typeStack.removeLast() }
        override func visit(_ node: ClassDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text) }
        override func visitPost(_ node: ClassDeclSyntax) { typeStack.removeLast() }
        override func visit(_ node: EnumDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text) }
        override func visitPost(_ node: EnumDeclSyntax) { typeStack.removeLast() }
        override func visit(_ node: ActorDeclSyntax) -> SyntaxVisitorContinueKind { push(node.name.text) }
        override func visitPost(_ node: ActorDeclSyntax) { typeStack.removeLast() }
        override func visit(_ node: ExtensionDeclSyntax) -> SyntaxVisitorContinueKind {
            push(node.extendedType.trimmedDescription)
        }
        override func visitPost(_ node: ExtensionDeclSyntax) { typeStack.removeLast() }
        override func visit(_ node: ProtocolDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: DeinitializerDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: SubscriptDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }

        // Every clause is visited, active or not: which one is active is only known to the build.
        override func visit(_ node: IfConfigClauseSyntax) -> SyntaxVisitorContinueKind {
            ifConfigDepth += 1
            return .visitChildren
        }
        override func visitPost(_ node: IfConfigClauseSyntax) { ifConfigDepth -= 1 }

        private func push(_ name: String) -> SyntaxVisitorContinueKind {
            typeStack.append(name)
            return .visitChildren
        }

        private func qualified(_ name: String) -> String {
            (typeStack + [name]).joined(separator: ".")
        }

        // MARK: Functions

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            guard let body = node.body else { return .skipChildren }
            let labels = node.signature.parameterClause.parameters.map { "\($0.firstName.text):" }.joined()
            let returnType = node.signature.returnClause?.type
            let isBuilder = hasBuilderAttribute(node.attributes)
            let throwsClause = node.signature.effectSpecifiers?.throwsClause
            let throwsUntyped = throwsClause.map { clause in
                clause.type == nil || clause.type?.trimmedDescription == "any Error"
            } ?? false

            record(
                decl: Syntax(node),
                name: qualified("\(node.name.text)(\(labels))"),
                kind: .function,
                attributes: attributeNames(node.attributes),
                returnType: returnType,
                isResultBuilder: isBuilder,
                canThrow: throwsUntyped && throwsClause?.throwsSpecifier.tokenKind == .keyword(.throws),
                effects: Effects(async: node.signature.effectSpecifiers?.asyncSpecifier, throws: throwsClause),
                leftBrace: body.leftBrace,
                rightBrace: body.rightBrace,
                statements: body.statements
            )
            return .skipChildren
        }

        // MARK: Computed properties

        override func visit(_ node: VariableDeclSyntax) -> SyntaxVisitorContinueKind {
            guard node.bindings.count == 1, let binding = node.bindings.first,
                  let accessorBlock = binding.accessorBlock,
                  let identifier = binding.pattern.as(IdentifierPatternSyntax.self)
            else { return .skipChildren }

            let isBuilder = hasBuilderAttribute(node.attributes)
                || (identifier.identifier.text == "body"
                    && binding.typeAnnotation?.type.trimmedDescription == "some View")
            let name = qualified(identifier.identifier.text)
            let returnType = binding.typeAnnotation?.type

            switch accessorBlock.accessors {
            case .getter(let statements):
                record(
                    decl: Syntax(node), name: name, kind: .getter, attributes: attributeNames(node.attributes),
                    returnType: returnType, isResultBuilder: isBuilder, canThrow: false, effects: Effects(),
                    leftBrace: accessorBlock.leftBrace, rightBrace: accessorBlock.rightBrace,
                    statements: statements
                )
            case .accessors(let accessors):
                guard let getter = accessors.first(where: { $0.accessorSpecifier.tokenKind == .keyword(.get) }),
                      let body = getter.body
                else { break }
                record(
                    decl: Syntax(node), name: name, kind: .getter,
                    attributes: attributeNames(node.attributes) + attributeNames(getter.attributes),
                    returnType: returnType, isResultBuilder: isBuilder || hasBuilderAttribute(getter.attributes),
                    canThrow: false,
                    effects: Effects(
                        async: getter.effectSpecifiers?.asyncSpecifier, throws: getter.effectSpecifiers?.throwsClause
                    ),
                    leftBrace: body.leftBrace, rightBrace: body.rightBrace, statements: body.statements
                )
            }
            return .skipChildren
        }

        // MARK: Recording

        /// The `async` and `throws` of a function or a getter, as written.
        private struct Effects {
            var async: TokenSyntax?
            var `throws`: ThrowsClauseSyntax?

            var isRethrowing: Bool { `throws`?.throwsSpecifier.tokenKind == .keyword(.rethrows) }

            /// `async throws(E) -> some View`
            func signature(returning type: TypeSyntax) -> String {
                ([async?.trimmedDescription, `throws`?.trimmedDescription].compactMap { $0 }
                    + ["->", type.trimmedDescription]).joined(separator: " ")
            }

            var call: String { (`throws` == nil ? "" : "try ") + (async == nil ? "" : "await ") }
        }

        private func record(
            decl: Syntax, name: String, kind: MethodInfo.Kind, attributes: [String],
            returnType: TypeSyntax?, isResultBuilder: Bool, canThrow: Bool, effects: Effects,
            leftBrace: TokenSyntax, rightBrace: TokenSyntax, statements: CodeBlockItemListSyntax
        ) {
            // An explicit `return` turns a result builder off, written or implied: the body is
            // then an ordinary one.
            let returnsExplicitly = statements.contains { ReturnFinder.containsReturn(Syntax($0)) }
            let isResultBuilder = isResultBuilder && !returnsExplicitly
            let info = MethodInfo(
                file: path,
                name: name,
                kind: kind,
                declarationStart: position(decl.positionAfterSkippingLeadingTrivia),
                declarationEnd: position(decl.endPositionBeforeTrailingTrivia),
                bodyStart: position(leftBrace.positionAfterSkippingLeadingTrivia),
                returnType: returnType?.trimmedDescription
            )

            var decision: MutationOperators.Decision
            var opaqueBody: OpaqueBody?
            if let attribute = attributes.first(where: inliningAttributes.contains) {
                decision = .skip(reason: "`@\(attribute)` body cannot reference the mutant switch")
            } else if leftBrace.presence == .missing || rightBrace.presence == .missing {
                decision = .skip(reason: "could not parse the body")
            } else {
                decision = MutationOperators.mutations(for: returnType, isResultBuilder: isResultBuilder)
                // Only the empty-body mutant is affected: any other mutant replaces a result,
                // which tests should check whatever the body logs.
                if case .mutate(let mutations) = decision, mutations == [.emptyBody], let arid = options.arid, arid.isArid(statements) {
                    decision = .skip(reason: AridDetector.skipReason)
                }
                if case .mutate([.emptyView]) = decision, !isResultBuilder, let returnType {
                    if effects.isRethrowing {
                        // A local function cannot be `rethrows`: it has no parameter that throws.
                        decision = .skip(reason: "`\(returnType.trimmedDescription)` returned from a `rethrows` function")
                    } else {
                        opaqueBody = OpaqueBody(
                            isViewBuilder: !returnsExplicitly,
                            signature: effects.signature(returning: returnType), callEffects: effects.call
                        )
                    }
                }
                if case .mutate(var mutations) = decision, options.includeThrowMutants, canThrow, !isResultBuilder {
                    mutations.append(.throwError)
                    decision = .mutate(mutations)
                }
            }

            var implicitReturn: Int?
            // The body of a local function keeps its implicit return.
            if case .mutate(let mutations) = decision, !isResultBuilder, opaqueBody == nil,
               !mutations.contains(.emptyBody) {
                implicitReturn = implicitReturnOffset(statements)
            }

            var cases: [DiscoveredCase] = []
            if options.caseMutants, !isResultBuilder, opaqueBody == nil {
                let line = { [converter] (position: AbsolutePosition) in converter.location(for: position).line }
                if case .mutate(let mutations) = decision {
                    cases = SwitchCases.discover(statements, mutations: mutations, arid: options.arid, line: line)
                } else if case .skip(let reason) = decision, reason.hasPrefix(MutationOperators.unsupportedReturnType),
                          returnType?.tokens(viewMode: .sourceAccurate).contains(where: { $0.tokenKind == .keyword(.some) }) != true {
                    // No simplest value to return: the method has no mutant of its own, and each
                    // case does what another case does. Not for an opaque type: its body may be a
                    // result builder without saying so (`var body: some ToolbarContent`).
                    cases = SwitchCases.discover(statements, mutations: [], arid: options.arid, line: line)
                    if !cases.isEmpty { decision = .mutate([]) }
                }
            }

            methods.append(DiscoveredMethod(
                info: info,
                decision: decision,
                bodyContentStart: leftBrace.endPositionBeforeTrailingTrivia.utf8Offset,
                bodyContentEnd: rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset,
                implicitReturnInsertion: implicitReturn,
                isResultBuilder: isResultBuilder,
                opaqueBody: opaqueBody,
                isConditionallyCompiled: ifConfigDepth > 0,
                cases: cases
            ))
        }

        /// For a body consisting of a single expression that is implicitly returned, the offset
        /// where `return ` has to be inserted.
        private func implicitReturnOffset(_ statements: CodeBlockItemListSyntax) -> Int? {
            guard statements.count == 1, let item = statements.first else { return nil }
            let expression: ExprSyntax
            switch item.item {
            case .expr(let expr):
                expression = expr
            case .stmt(let stmt):
                guard let exprStmt = stmt.as(ExpressionStmtSyntax.self) else { return nil }
                expression = exprStmt.expression
            case .decl:
                return nil
            }
            if expression.is(IfExprSyntax.self) || expression.is(SwitchExprSyntax.self) {
                // An `if`/`switch` containing `return` is a statement, not an expression.
                guard !ReturnFinder.containsReturn(Syntax(expression)) else { return nil }
            }
            if let call = expression.as(FunctionCallExprSyntax.self),
               let callee = call.calledExpression.as(DeclReferenceExprSyntax.self),
               neverReturningCalls.contains(callee.baseName.text) {
                return nil
            }
            return item.positionAfterSkippingLeadingTrivia.utf8Offset
        }

        private func hasBuilderAttribute(_ attributes: AttributeListSyntax) -> Bool {
            attributeNames(attributes).contains { $0.hasSuffix("Builder") }
        }

        private func attributeNames(_ attributes: AttributeListSyntax) -> [String] {
            attributes.compactMap { element in
                element.as(AttributeSyntax.self)?.attributeName.trimmedDescription
            }
        }

        private func position(_ absolute: AbsolutePosition) -> SourcePosition {
            let location = converter.location(for: absolute)
            return SourcePosition(line: location.line, column: location.column)
        }
    }

    /// Finds `return` statements, ignoring nested closures, functions and accessors.
    final class ReturnFinder: SyntaxVisitor {
        var found = false

        static func containsReturn(_ node: Syntax) -> Bool {
            let finder = ReturnFinder(viewMode: .sourceAccurate)
            finder.walk(node)
            return finder.found
        }

        override func visit(_ node: ReturnStmtSyntax) -> SyntaxVisitorContinueKind {
            found = true
            return .skipChildren
        }
        override func visit(_ node: ClosureExprSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: InitializerDeclSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
        override func visit(_ node: AccessorBlockSyntax) -> SyntaxVisitorContinueKind { .skipChildren }
    }
}
