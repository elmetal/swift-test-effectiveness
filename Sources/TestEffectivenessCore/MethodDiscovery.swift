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

    public var mutations: [ExtremeMutation] {
        if case .mutate(let mutations) = decision { return mutations }
        return []
    }
}

public struct DiscoveryOptions: Sendable {
    /// Also generate a `throw` mutant for methods declared with untyped `throws`.
    public var includeThrowMutants: Bool

    public init(includeThrowMutants: Bool = false) {
        self.includeThrowMutants = includeThrowMutants
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
    private static let neverReturningCalls: Set<String> = ["fatalError", "preconditionFailure"]

    private final class Visitor: SyntaxVisitor {
        let path: String
        let converter: SourceLocationConverter
        let options: DiscoveryOptions
        var typeStack: [String] = []
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
                    returnType: returnType, isResultBuilder: isBuilder, canThrow: false,
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
                    leftBrace: body.leftBrace, rightBrace: body.rightBrace, statements: body.statements
                )
            }
            return .skipChildren
        }

        // MARK: Recording

        private func record(
            decl: Syntax, name: String, kind: MethodInfo.Kind, attributes: [String],
            returnType: TypeSyntax?, isResultBuilder: Bool, canThrow: Bool,
            leftBrace: TokenSyntax, rightBrace: TokenSyntax, statements: CodeBlockItemListSyntax
        ) {
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
            if let attribute = attributes.first(where: inliningAttributes.contains) {
                decision = .skip(reason: "`@\(attribute)` body cannot reference the mutant switch")
            } else if leftBrace.presence == .missing || rightBrace.presence == .missing {
                decision = .skip(reason: "could not parse the body")
            } else {
                decision = MutationOperators.mutations(for: returnType, isResultBuilder: isResultBuilder)
                if case .mutate(var mutations) = decision, options.includeThrowMutants, canThrow, !isResultBuilder {
                    mutations.append(.throwError)
                    decision = .mutate(mutations)
                }
            }

            var implicitReturn: Int?
            if case .mutate(let mutations) = decision, !isResultBuilder,
               !mutations.contains(.emptyBody) {
                implicitReturn = implicitReturnOffset(statements)
            }

            methods.append(DiscoveredMethod(
                info: info,
                decision: decision,
                bodyContentStart: leftBrace.endPositionBeforeTrailingTrivia.utf8Offset,
                bodyContentEnd: rightBrace.positionAfterSkippingLeadingTrivia.utf8Offset,
                implicitReturnInsertion: implicitReturn,
                isResultBuilder: isResultBuilder
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

    /// Finds `return` statements, ignoring nested closures and functions.
    private final class ReturnFinder: SyntaxVisitor {
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
    }
}
