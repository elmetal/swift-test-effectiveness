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
    /// How the reason starts when the return type has no simplest value.
    static let unsupportedReturnType = "unsupported return type"
    static let arrayLikeTypes: Set<String> = ["Array", "Set", "ContiguousArray", "ArraySlice"]

    /// - Parameters:
    ///   - returnType: the declared return type, or `nil` when there is no return clause.
    ///   - isResultBuilder: whether the body is transformed by a result builder.
    public static func mutations(for returnType: TypeSyntax?, isResultBuilder: Bool) -> Decision {
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
            return .skip(reason: "\(unsupportedReturnType) `\(type.trimmedDescription)`")
        }

        if isResultBuilder {
            return .skip(reason: "result builder body returning `\(type.trimmedDescription)`")
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
    private static func baseName(of type: TypeSyntax) -> String {
        if let identifier = type.as(IdentifierTypeSyntax.self) {
            return identifier.name.text
        }
        if let member = type.as(MemberTypeSyntax.self) {
            return baseName(of: member.baseType) + "." + member.name.text
        }
        return type.trimmedDescription
    }
}
