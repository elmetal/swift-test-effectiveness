import Foundation

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
///     func add(_ a: Int, _ b: Int) -> Int { switch __steActiveMutant { case 3: return 0; case 4: return 1; case -2: __steReached(3); default: break };
///         return a + b
///     }
///
/// For a `some View` result builder body with mutant 7:
///
///     var body: some View { if __steMutantIs(7) { EmptyView() } else {
///         Text("Hello")
///     } }
///
/// For `some View` returned outside a result builder with mutant 8, the original body moves into a
/// local function, because every `return` of a method with an opaque result must have one type:
///
///     func badge() -> some View { func __steOriginal() -> some View {
///         return Circle().frame(width: 8)
///     }; return __steMutantIs(8) ? ViewBuilder.buildEither(first: EmptyView()) : ViewBuilder.buildEither(second: __steOriginal()) }
///
/// The local function is a `@ViewBuilder` when the body has no `return` (see `OpaqueBody`).
///
/// The same switch records which methods a test run executes: with `STE_REACHED=<file>` no mutant
/// is active, and each method appends the id of its first mutant to the file when it is first
/// called (see `ReachedMethods`).
public enum SchemataRewriter {
    public static let environmentVariable = "STE_MUTANT"
    /// Names a file to which the run appends the methods it executes.
    public static let reachedEnvironmentVariable = "STE_REACHED"
    static let switchName = "__steActiveMutant"
    static let errorTypeName = "__STEExtremeMutationError"
    /// The local function that keeps the original body of a method with an opaque result.
    static let originalBodyName = "__steOriginal"
    /// The value of the switch while recording; never a mutant id.
    static let recordingValue = -2

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
        let ids = methods.flatMap { $0.1.map(\.id) }
        return result + footer(mutantIDs: ids.min()!...ids.max()!)
    }

    static func insertions(for method: DiscoveredMethod, mutants: [Mutant]) -> [Insertion] {
        if method.isResultBuilder {
            // Result builders cannot contain `return`; splice an if/else instead.
            guard let mutant = mutants.first else { return [] }
            return [
                Insertion(
                    offset: method.bodyContentStart,
                    text: " if __steMutantIs(\(mutant.id)) { \(mutant.mutation.replacementStatement) } else {"
                ),
                Insertion(offset: method.bodyContentEnd, text: " } "),
            ]
        }
        if let opaque = method.opaqueBody {
            // The first mutant is the view; a `throw` mutant may follow. `buildEither` is what an
            // `if`/`else` in a view builder becomes, so both schemas give the method the same type.
            let view = mutants[0]
            let others = mutants.dropFirst()
                .map { "if \(switchName) == \($0.id) { \($0.mutation.replacementStatement) }; " }.joined()
            return [
                Insertion(
                    offset: method.bodyContentStart,
                    text: " \(opaque.isViewBuilder ? "@ViewBuilder " : "")func \(originalBodyName)() \(opaque.signature) {"
                ),
                Insertion(
                    offset: method.bodyContentEnd,
                    text: " }; \(others)return \(opaque.callEffects)__steMutantIs(\(view.id))"
                        + " ? ViewBuilder.buildEither(first: \(view.mutation.replacementStatement))"
                        + " : ViewBuilder.buildEither(second: \(originalBodyName)()) "
                ),
            ]
        }
        let cases = mutants.map { "case \($0.id): \($0.mutation.replacementStatement)" }.joined(separator: "; ")
        let record = "case \(recordingValue): __steReached(\(mutants[0].id))"
        var result = [
            Insertion(offset: method.bodyContentStart, text: " switch \(switchName) { \(cases); \(record); default: break };")
        ]
        if let offset = method.implicitReturnInsertion {
            result.append(Insertion(offset: offset, text: "return "))
        }
        return result
    }

    /// Appended at the end of every mutated file. Placed at the end (not the top) to keep line
    /// numbers stable; Swift allows imports anywhere at file scope.
    ///
    /// - Parameter mutantIDs: the smallest and the largest mutant id in the file; each method has
    ///   a flag at the offset of its first mutant, so that it is recorded once.
    static func footer(mutantIDs: ClosedRange<Int>) -> String {
        """

        // MARK: - swift-test-effectiveness mutant schema (generated, do not commit)
        #if canImport(Darwin)
        import Darwin
        #elseif canImport(Glibc)
        import Glibc
        #elseif canImport(Musl)
        import Musl
        #endif
        nonisolated fileprivate let __steReachedFile: Int32 = {
            guard let path = getenv("\(reachedEnvironmentVariable)") else { return -1 }
            return open(path, O_WRONLY | O_APPEND | O_CREAT, 0o644)
        }()
        nonisolated fileprivate let \(switchName): Int = {
            if __steReachedFile >= 0 { return \(recordingValue) }
            guard let raw = getenv("\(environmentVariable)") else { return -1 }
            return Int(String(cString: raw)) ?? -1
        }()
        nonisolated(unsafe) fileprivate let __steReachedFlags: UnsafeMutablePointer<UInt8> = {
            let flags = UnsafeMutablePointer<UInt8>.allocate(capacity: \(mutantIDs.count))
            flags.initialize(repeating: 0, count: \(mutantIDs.count))
            return flags
        }()
        nonisolated fileprivate func __steReached(_ id: Int) {
            let flag = __steReachedFlags + (id - \(mutantIDs.lowerBound))
            if flag.pointee != 0 { return }
            flag.pointee = 1
            let line = Array("\\(id)\\n".utf8)
            _ = line.withUnsafeBufferPointer { write(__steReachedFile, $0.baseAddress, $0.count) }
        }
        nonisolated fileprivate func __steMutantIs(_ id: Int) -> Bool {
            if \(switchName) == \(recordingValue) { __steReached(id) }
            return \(switchName) == id
        }
        nonisolated fileprivate struct \(errorTypeName): Error {}

        """
    }
}

/// The methods a test run executed, as the mutant schema records them when
/// `SchemataRewriter.reachedEnvironmentVariable` names a file: one line per method, with the id of
/// the method's first mutant. Several processes of one run may append to the same file.
enum ReachedMethods {
    /// The ids in the file's contents. Lines that are not a number are ignored: a process that is
    /// killed may leave a line unfinished.
    static func parse(_ contents: String) -> Set<Int> {
        Set(contents.split(separator: "\n").compactMap { Int($0) })
    }

    /// The ids recorded in `file`, or `nil` when the run recorded nothing.
    static func read(_ file: URL) -> Set<Int>? {
        guard let contents = try? String(contentsOf: file, encoding: .utf8) else { return nil }
        return parse(contents)
    }
}
