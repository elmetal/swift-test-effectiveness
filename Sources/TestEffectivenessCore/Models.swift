import Foundation


/// A position in a source file. Lines and columns are 1-based; columns count UTF-8 bytes,
/// matching both SwiftSyntax's `SourceLocationConverter` and llvm-cov.
public struct SourcePosition: Codable, Hashable, Sendable, Comparable {
    public var line: Int
    public var column: Int

    public init(line: Int, column: Int) {
        self.line = line
        self.column = column
    }

    public static func < (lhs: SourcePosition, rhs: SourcePosition) -> Bool {
        (lhs.line, lhs.column) < (rhs.line, rhs.column)
    }
}

/// The kind of extreme mutation applied to a method body.
///
/// Following Niedermayr et al. (2016) and Descartes (Vera-Pérez et al. 2018), the whole body is
/// replaced by the simplest possible behaviour for its return type.
public enum ExtremeMutation: Codable, Hashable, Sendable {
    /// `Void` methods: the body is removed.
    case emptyBody
    /// `Optional` results: `return nil`.
    case returnNil
    /// `Bool` results: `return true` / `return false`.
    case returnBool(Bool)
    /// Numeric results: `return 0` / `return 1`.
    case returnNumber(String)
    /// String results: `return ""` / `return "A"`.
    case returnString(String)
    /// Array / Set results: `return []`.
    case returnEmptyArray
    /// `Data` results: `return Data()`.
    case returnEmptyData
    /// Dictionary results: `return [:]`.
    case returnEmptyDictionary
    /// `some View` result builder bodies: `EmptyView()`.
    case emptyView
    /// Throwing methods (opt-in): `throw <error>`.
    case throwError

    /// Swift statement executed in place of the original body (except `emptyView`,
    /// which is spliced as an `if`/`else` inside the result builder).
    var replacementStatement: String {
        switch self {
        case .emptyBody: "return"
        case .returnNil: "return nil"
        case .returnBool(let value): "return \(value)"
        case .returnNumber(let literal): "return \(literal)"
        case .returnString(let literal): "return \(Self.quoted(literal))"
        case .returnEmptyArray: "return []"
        case .returnEmptyData: "return Data()"
        case .returnEmptyDictionary: "return [:]"
        case .emptyView: "EmptyView()"
        case .throwError: "throw \(SchemataRewriter.errorTypeName)()"
        }
    }

    /// Human-readable description of the mutated behaviour, e.g. "`return 0`".
    public var summary: String {
        switch self {
        case .emptyBody: "empty body"
        case .emptyView: "`EmptyView()`"
        default: "`\(replacementStatement)`"
        }
    }

    private static func quoted(_ literal: String) -> String {
        "\"" + literal.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}

/// A method (function or computed-property getter) discovered in production code.
public struct MethodInfo: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable {
        case function
        case getter
    }

    /// Path relative to the analyzed project root.
    public var file: String
    /// Display name, e.g. `Calculator.add(_:_:)`.
    public var name: String
    public var kind: Kind
    /// Start of the declaration (after leading trivia).
    public var declarationStart: SourcePosition
    /// End of the declaration.
    public var declarationEnd: SourcePosition
    /// Position of the body's opening `{`. llvm-cov function regions start here.
    public var bodyStart: SourcePosition
    /// The declared return type as written, if any.
    public var returnType: String?

    public init(
        file: String, name: String, kind: Kind,
        declarationStart: SourcePosition, declarationEnd: SourcePosition,
        bodyStart: SourcePosition, returnType: String?
    ) {
        self.file = file
        self.name = name
        self.kind = kind
        self.declarationStart = declarationStart
        self.declarationEnd = declarationEnd
        self.bodyStart = bodyStart
        self.returnType = returnType
    }
}

/// One mutant inserted into the schemata build.
public struct Mutant: Codable, Hashable, Sendable {
    /// Identifier used at runtime (`STE_MUTANT=<id>`) to activate this mutant.
    public var id: Int
    public var mutation: ExtremeMutation

    public init(id: Int, mutation: ExtremeMutation) {
        self.id = id
        self.mutation = mutation
    }
}

/// Outcome of running the test suite against one mutant.
public enum MutantOutcome: String, Codable, Sendable {
    /// At least one test failed: the mutant was detected.
    case killed
    /// The test run exceeded the timeout. Counted as detected, as in PIT/Descartes.
    case timedOut
    /// Every test passed: no test noticed the method's behaviour changed.
    case survived
    /// Not executed because coverage showed no test reaches the method.
    case notRun
}

public struct MutantResult: Codable, Hashable, Sendable {
    public var mutant: Mutant
    public var outcome: MutantOutcome
    public var duration: Double?

    public init(mutant: Mutant, outcome: MutantOutcome, duration: Double? = nil) {
        self.mutant = mutant
        self.outcome = outcome
        self.duration = duration
    }

    public var isDetected: Bool { outcome == .killed || outcome == .timedOut }
}

/// Per-method classification. The tool deliberately reports this classification rather than an
/// aggregate score (see README: Papadakis et al. 2018 and Goodhart's law).
public enum MethodClassification: String, Codable, Sendable, CaseIterable {
    /// No test executes the method (fails the *Execution* step of the PIE model).
    case notCovered = "not-covered"
    /// Every extreme mutant survived: the method is executed but no test checks what it does.
    case pseudoTested = "pseudo-tested"
    /// Some extreme mutants survived.
    case partiallyTested = "partially-tested"
    /// Every extreme mutant was detected.
    case tested
}

/// The executed column: did any test run the method? Filled from coverage, independently of the
/// verified column (the mutant outcomes).
public enum ExecutionStatus: String, Codable, Sendable {
    /// Coverage shows the method ran, or one of its mutants was killed (a test observed it).
    case executed = "true"
    /// Coverage shows no test ran the method.
    case notExecuted = "false"
    /// No coverage data for the method. Surviving mutants may then mean either "not executed"
    /// or "executed but not verified".
    case unknown

    /// Combines coverage with the mutant outcomes. Dynamic evidence wins: a killed mutant means
    /// a test ran the method and noticed the change, whatever coverage says.
    public static func resolve(coverage: Bool?, mutants: [MutantResult]) -> ExecutionStatus {
        if mutants.contains(where: { $0.outcome == .killed }) { return .executed }
        switch coverage {
        case true?: return .executed
        case false?: return .notExecuted
        case nil: return .unknown
        }
    }
}

/// The referenced column: does any test refer to the method directly? Read from the compiler's
/// index, so it needs no test run. See `docs/methods/static-references.md`.
public enum ReferenceStatus: String, Codable, Sendable {
    /// A test, or a test-target helper it calls, refers to the method. A call through a protocol
    /// or an overridable method counts only for the concrete types the same test scope names.
    case referenced = "true"
    /// The index has the method, but no test refers to it directly.
    case notReferenced = "false"
    /// No index data (index unavailable, or the method is not in it).
    case unknown
}

public struct MethodResult: Codable, Hashable, Sendable {
    public var method: MethodInfo
    /// The referenced column.
    public var referenced: ReferenceStatus
    /// The executed column.
    public var executed: ExecutionStatus
    /// How the columns read together (Descartes' categories plus `not-covered`).
    public var classification: MethodClassification
    /// The verified column's evidence: each extreme mutant and its outcome.
    public var mutants: [MutantResult]

    public init(
        method: MethodInfo, referenced: ReferenceStatus = .unknown, executed: ExecutionStatus,
        classification: MethodClassification, mutants: [MutantResult]
    ) {
        self.method = method
        self.referenced = referenced
        self.executed = executed
        self.classification = classification
        self.mutants = mutants
    }

    public var survivingMutants: [MutantResult] { mutants.filter { $0.outcome == .survived } }
}

/// A method that was found but not mutated, with the reason.
public struct SkippedMethod: Codable, Hashable, Sendable {
    public var method: MethodInfo
    public var reason: String

    public init(method: MethodInfo, reason: String) {
        self.method = method
        self.reason = reason
    }
}

public struct AnalysisReport: Codable, Sendable {
    /// Version of the JSON report format. Incremented when a field is removed, renamed or changes
    /// meaning; adding a field does not change it.
    public static let currentSchemaVersion = 1

    /// The JSON format this report follows (see `currentSchemaVersion`).
    public var schemaVersion: Int
    /// Version of the tool that produced the report.
    public var toolVersion: String
    public var projectPath: String
    public var coverageAvailable: Bool
    /// Whether the referenced column was computed from an index.
    public var referencesAvailable: Bool
    public var methods: [MethodResult]
    public var skipped: [SkippedMethod]

    public init(
        projectPath: String, coverageAvailable: Bool, referencesAvailable: Bool = false,
        methods: [MethodResult], skipped: [SkippedMethod]
    ) {
        self.schemaVersion = Self.currentSchemaVersion
        self.toolVersion = ToolVersion.current
        self.projectPath = projectPath
        self.coverageAvailable = coverageAvailable
        self.referencesAvailable = referencesAvailable
        self.methods = methods
        self.skipped = skipped
    }

    public func methods(_ classification: MethodClassification) -> [MethodResult] {
        methods.filter { $0.classification == classification }
    }
}

public enum Classifier {
    /// Descartes' definition: all mutants survived → pseudo-tested; some → partially tested;
    /// none → tested. Methods whose mutants were not run (uncovered) are `notCovered`.
    public static func classify(_ results: [MutantResult]) -> MethodClassification {
        if results.isEmpty || results.allSatisfy({ $0.outcome == .notRun }) {
            return .notCovered
        }
        let executed = results.filter { $0.outcome != .notRun }
        let survived = executed.filter { $0.outcome == .survived }.count
        if survived == executed.count { return .pseudoTested }
        if survived == 0 { return .tested }
        return .partiallyTested
    }
}
