import SwiftParser
import SwiftSyntax

/// Decides which extreme mutants a method gets, based on its declared return type.
///
/// Rules (see README "Default values"):
/// - `Void` / `()` / no return clause → empty body
/// - `T?`, `T!`, `Optional<T>` → `nil`
/// - `Bool` → `true` and `false` (both, as in Descartes)
/// - numeric types → `0` and `1`
/// - `String` / `Substring` → `""` and `"A"`
/// - `[T]`, `Array`, `Set`, `ContiguousArray`, `ArraySlice` → `[]`; `Data` → `Data()`
/// - `[K: V]`, `Dictionary` → `[:]`
/// - `some View` → `EmptyView()`, inside a result builder or not
/// - `Never` and anything else → not analyzed (reported with a reason)
///
/// A type that `DefaultValues` names returns the values given for it instead.
///
/// When the throw operator is enabled, untyped `throws` methods also get a `throw` mutant.
public enum MutationOperators {
    public enum Decision: Equatable, Sendable {
        case mutate([ExtremeMutation])
        case skip(reason: String)
    }

    static let numericTypes: Set<String> = [
        "Int", "Int8", "Int16", "Int32", "Int64", "Int128",
        "UInt", "UInt8", "UInt16", "UInt32", "UInt64", "UInt128",
        "Double", "Float", "Float16", "Float80", "CGFloat", "Decimal", "TimeInterval",
    ]
    static let stringTypes: Set<String> = ["String", "Substring"]
    static let arrayLikeTypes: Set<String> = ["Array", "Set", "ContiguousArray", "ArraySlice"]
    /// How the reason starts when the return type has no simplest value.
    static let unsupportedReturnType = "unsupported return type"

    /// - Parameters:
    ///   - returnType: the declared return type, or `nil` when there is no return clause.
    ///   - isResultBuilder: whether the body is transformed by a result builder.
    ///   - defaults: the values to return for the types the user named.
    public static func mutations(
        for returnType: TypeSyntax?, isResultBuilder: Bool, defaults: DefaultValues = DefaultValues()
    ) -> Decision {
        guard let returnType else {
            return isResultBuilder ? .skip(reason: "result builder body without return type") : .mutate([.emptyBody])
        }
        let type = unwrapAttributes(returnType)

        if let opaque = type.as(SomeOrAnyTypeSyntax.self) {
            let constraint = opaque.constraint.trimmedDescription
            if opaque.someOrAnySpecifier.tokenKind == .keyword(.some),
               constraint == "View" || constraint == "SwiftUI.View" {
                return .mutate([.emptyView])
            }
            // Every `return` of a `some` type has the same concrete type: a value of another type
            // cannot be returned in front of the body.
            guard opaque.someOrAnySpecifier.tokenKind == .keyword(.any) else {
                return .skip(reason: "\(unsupportedReturnType) `\(type.trimmedDescription)`")
            }
        }

        if isResultBuilder {
            return .skip(reason: "result builder body returning `\(type.trimmedDescription)`")
        }
        if let mutations = defaults.mutations(for: type) {
            return .mutate(mutations)
        }

        if type.is(OptionalTypeSyntax.self) || type.is(ImplicitlyUnwrappedOptionalTypeSyntax.self) {
            return .mutate([.returnNil])
        }
        if type.is(ArrayTypeSyntax.self) {
            return .mutate([.returnEmptyArray])
        }
        if type.is(DictionaryTypeSyntax.self) {
            return .mutate([.returnEmptyDictionary])
        }
        if let tuple = type.as(TupleTypeSyntax.self), tuple.elements.isEmpty {
            return .mutate([.emptyBody])
        }

        let name = baseName(of: type)
        switch name {
        case "Void", "Swift.Void":
            return .mutate([.emptyBody])
        case "Never", "Swift.Never":
            return .skip(reason: "returns `Never`")
        case "Optional", "Swift.Optional":
            return .mutate([.returnNil])
        case "Bool", "Swift.Bool":
            return .mutate([.returnBool(true), .returnBool(false)])
        case "Dictionary", "Swift.Dictionary":
            return .mutate([.returnEmptyDictionary])
        default:
            break
        }
        let unqualified = name.split(separator: ".").last.map(String.init) ?? name
        if numericTypes.contains(unqualified) {
            return .mutate([.returnNumber("0"), .returnNumber("1")])
        }
        if stringTypes.contains(unqualified) {
            return .mutate([.returnString(""), .returnString("A")])
        }
        if arrayLikeTypes.contains(unqualified) {
            return .mutate([.returnEmptyArray])
        }
        if unqualified == "Data" {
            return .mutate([.returnEmptyData])
        }
        return .skip(reason: "\(unsupportedReturnType) `\(type.trimmedDescription)`")
    }

    private static func unwrapAttributes(_ type: TypeSyntax) -> TypeSyntax {
        if let attributed = type.as(AttributedTypeSyntax.self) {
            return unwrapAttributes(attributed.baseType)
        }
        return type
    }

    /// `Swift.Array<Int>` → `Swift.Array`, `Int` → `Int`.
    static func baseName(of type: TypeSyntax) -> String {
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return identifier.name.text
        }
        if let member = type.as(MemberTypeSyntax.self) {
            return baseName(of: member.baseType) + "." + member.name.text
        }
        return type.trimmedDescription
    }
}

/// The values a method returns as its mutants, for the return types the user names
/// (`--default-value 'Money=.zero'`).
///
/// The built-in rules know the simplest value of the standard library's types only. A type of the
/// project or of a library often has one as well (`.zero`, `.empty`, `.none`); with it, a method
/// that returns the type is mutated like any other, and so is each case of its switch.
///
/// A return type is looked up as it is written, since nothing here resolves types:
/// 1. the whole type (`Result<Int, Error>`, `(Int, Int)`, `any Shape`),
/// 2. its name without generic arguments (`Tagged` for `Tagged<User, Int>`),
/// 3. the last component of that name (`State` for `Feature.State`).
///
/// A type alias is another name, and needs values of its own. The values of a type replace the
/// built-in ones, and each value given for it is one mutant.
public struct DefaultValues: Equatable, Sendable {
    public struct ParseError: Error, Equatable, CustomStringConvertible {
        public var description: String
    }

    /// The expressions for each type, in the order given. The keys have no whitespace.
    private var values: [String: [String]] = [:]

    public init() {}

    /// - Parameter arguments: `TYPE=EXPRESSION`, split at the first `=`.
    public init(parsing arguments: [String]) throws {
        for argument in arguments {
            guard let separator = argument.firstIndex(of: "=") else {
                throw ParseError(description: "'\(argument)' is not TYPE=EXPRESSION")
            }
            let type = Self.withoutWhitespace(String(argument[..<separator]))
            let expression = argument[argument.index(after: separator)...].trimmingCharacters(in: .whitespaces)
            guard !type.isEmpty else {
                throw ParseError(description: "'\(argument)' names no type before `=`")
            }
            guard !["Void", "Swift.Void", "()", "Never", "Swift.Never"].contains(type) else {
                throw ParseError(description: "`\(type)` has no value to return")
            }
            // The mutants stand on the line of the code they replace, so that line numbers stay.
            guard Self.tokens(of: expression) != nil, !expression.contains(where: \.isNewline) else {
                throw ParseError(description: "'\(expression)' is not one expression on one line, for `\(type)`")
            }
            if values[type]?.contains(expression) != true {
                values[type, default: []].append(expression)
            }
        }
    }

    public var isEmpty: Bool { values.isEmpty }

    func mutations(for type: TypeSyntax) -> [ExtremeMutation]? {
        var keys = [Self.withoutWhitespace(type.trimmedDescription)]
        if type.is(IdentifierTypeSyntax.self) || type.is(MemberTypeSyntax.self) {
            let name = MutationOperators.baseName(of: type)
            keys.append(name)
            if let last = name.split(separator: ".").last { keys.append(String(last)) }
        }
        for key in keys {
            if let expressions = values[key] { return expressions.map { .returnValue($0) } }
        }
        return nil
    }

    /// The type to give a value for, when `reason` is why a method is not analyzed and a value
    /// would make it a target: the name of its return type without generic arguments, or the
    /// whole type when it is not a name. `nil` for any other reason, and for a type with `some`
    /// in it, which takes no value.
    static func typeToName(in reason: String) -> String? {
        let prefix = "\(MutationOperators.unsupportedReturnType) `"
        guard reason.hasPrefix(prefix), reason.hasSuffix("`") else { return nil }
        var parser = Parser(String(reason.dropFirst(prefix.count).dropLast()))
        let type = TypeSyntax.parse(from: &parser)
        guard !type.hasError,
              !type.tokens(viewMode: .sourceAccurate).contains(where: { $0.tokenKind == .keyword(.some) })
        else { return nil }
        if type.is(IdentifierTypeSyntax.self) || type.is(MemberTypeSyntax.self) {
            return MutationOperators.baseName(of: type)
        }
        return type.trimmedDescription.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    /// The tokens of `source` when it is one expression, to compare it with another as code:
    /// whitespace and comments make no difference.
    static func tokens(of source: String) -> [String]? {
        let file = Parser.parse(source: source)
        guard !file.hasError, file.statements.count == 1, let item = file.statements.first,
              case .expr(let expression) = item.item, item.semicolon == nil
        else { return nil }
        return expression.tokens(viewMode: .sourceAccurate).map(\.text)
    }

    private static func withoutWhitespace(_ text: String) -> String {
        String(text.filter { !$0.isWhitespace })
    }
}
