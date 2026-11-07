/// Rewrites a source file into a *mutant schema*: every mutant is compiled into the same binary
/// and selected at runtime through the `STE_MUTANT` environment variable, so the project is built
/// only once (Untch, Offutt & Harrold 1993, "Mutation Analysis Using Mutant Schemata").
///
/// All insertions are made on existing lines, so line numbers of the rewritten file match the
/// original. This lets coverage data and diagnostics from the mutated build map back to the
/// user's source.
///
/// For a method with mutants 3 and 4:
///
///     func add(_ a: Int, _ b: Int) -> Int { switch __steActiveMutant { case 3: return 0; case 4: return 1; default: break };
///         return a + b
///     }
///
/// For a `some View` result builder body with mutant 7:
///
///     var body: some View { if __steActiveMutant == 7 { EmptyView() } else {
///         Text("Hello")
///     } }
public enum SchemataRewriter {
    public static let environmentVariable = "STE_MUTANT"
    static let switchName = "__steActiveMutant"
    static let errorTypeName = "__STEExtremeMutationError"

    public struct Insertion: Equatable {
        var offset: Int
        var text: String
    }

    /// - Parameter methods: methods of this file and the mutants assigned to each.
    public static func rewrite(source: String, methods: [(DiscoveredMethod, [Mutant])]) -> String {
        var insertions: [Insertion] = []
        for (method, mutants) in methods where !mutants.isEmpty {
            insertions += self.insertions(for: method, mutants: mutants)
        }
        guard !insertions.isEmpty else { return source }

        var bytes = Array(source.utf8)
        // Apply from the end so earlier offsets stay valid. For equal offsets keep the original order.
        let ordered = insertions.enumerated().sorted { lhs, rhs in
            lhs.element.offset != rhs.element.offset ? lhs.element.offset > rhs.element.offset : lhs.offset > rhs.offset
        }
        for (_, insertion) in ordered {
            bytes.insert(contentsOf: Array(insertion.text.utf8), at: insertion.offset)
        }
        var result = String(decoding: bytes, as: UTF8.self)
        if !result.hasSuffix("\n") { result += "\n" }
        return result + footer
    }

    static func insertions(for method: DiscoveredMethod, mutants: [Mutant]) -> [Insertion] {
        if method.isResultBuilder {
            // Result builders cannot contain `return`; splice an if/else instead.
            guard let mutant = mutants.first else { return [] }
            return [
                Insertion(
                    offset: method.bodyContentStart,
                    text: " if \(switchName) == \(mutant.id) { \(mutant.mutation.replacementStatement) } else {"
                ),
                Insertion(offset: method.bodyContentEnd, text: " } "),
            ]
        }
        let cases = mutants.map { "case \($0.id): \($0.mutation.replacementStatement)" }.joined(separator: "; ")
        var result = [
            Insertion(offset: method.bodyContentStart, text: " switch \(switchName) { \(cases); default: break };")
        ]
        if let offset = method.implicitReturnInsertion {
            result.append(Insertion(offset: offset, text: "return "))
        }
        return result
    }

    /// Appended at the end of every mutated file. Placed at the end (not the top) to keep line
    /// numbers stable; Swift allows imports anywhere at file scope.
    static let footer = """

    // MARK: - swift-test-effectiveness mutant schema (generated, do not commit)
    #if canImport(Darwin)
    import Darwin
    #elseif canImport(Glibc)
    import Glibc
    #elseif canImport(Musl)
    import Musl
    #endif
    nonisolated fileprivate let \(switchName): Int = {
        guard let raw = getenv("\(environmentVariable)") else { return -1 }
        return Int(String(cString: raw)) ?? -1
    }()
    nonisolated fileprivate struct \(errorTypeName): Error {}

    """
}
