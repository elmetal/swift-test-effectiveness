import Foundation

public enum AnalysisError: Error, CustomStringConvertible {
    case packageDescription(String)
    case buildFailed(log: URL, tail: String)
    case baselineFailed(log: URL, tail: String)
    case git(String)
    case noSources

    public var description: String {
        switch self {
        case .packageDescription(let output):
            "could not describe the package:\n\(output)"
        case .buildFailed(let log, let tail):
            "building the mutant schema failed (full log: \(log.path)):\n\(tail)"
        case .baselineFailed(let log, let tail):
            "the test suite does not pass without mutations; fix it first (full log: \(log.path)):\n\(tail)"
        case .git(let output):
            "git failed:\n\(output)"
        case .noSources:
            "no Swift source files found to analyze"
        }
    }
}

public struct AnalysisConfiguration: Sendable {
    public enum BuildSystem: Sendable {
        /// A Swift package, built and tested with `swift build` / `swift test`.
        case swiftPM(swiftExecutable: String, targets: [String], testFilter: String?)
        /// Any other project (e.g. Xcode). Commands run with `/bin/sh -c` inside the copied project.
        /// The active mutant is exported as `STE_MUTANT` and `TEST_RUNNER_STE_MUTANT` (the latter is
        /// forwarded by `xcodebuild test` to the test process).
        case custom(sourceDirectories: [String], buildCommand: String, testCommand: String)
    }

    public var projectPath: URL
    public var workDirectory: URL
    public var buildSystem: BuildSystem
    public var useCoverage: Bool
    /// Fill the referenced column from the compiler's index.
    public var useIndex: Bool
    /// Index store to read. A relative path is resolved inside the copied project, where the build
    /// runs. SwiftPM: defaults to the one `swift build --enable-index-store` writes. Custom mode:
    /// required for the referenced column (e.g. `<derivedDataPath>/Index.noindex/DataStore`).
    public var indexStorePath: String?
    public var discovery: DiscoveryOptions
    public var changedSince: String?
    public var excludePathSubstrings: [String]
    public var timeoutFactor: Double
    public var minimumTimeout: Double

    public init(
        projectPath: URL,
        workDirectory: URL? = nil,
        buildSystem: BuildSystem,
        useCoverage: Bool = true,
        useIndex: Bool = true,
        indexStorePath: String? = nil,
        discovery: DiscoveryOptions = .init(),
        changedSince: String? = nil,
        excludePathSubstrings: [String] = [],
        timeoutFactor: Double = 3,
        minimumTimeout: Double = 30
    ) {
        self.projectPath = projectPath.standardizedFileURL
        self.workDirectory = (workDirectory
            ?? projectPath.appendingPathComponent(".build/test-effectiveness")).standardizedFileURL
        self.buildSystem = buildSystem
        self.useCoverage = useCoverage
        self.useIndex = useIndex
        self.indexStorePath = indexStorePath
        self.discovery = discovery
        self.changedSince = changedSince
        self.excludePathSubstrings = excludePathSubstrings
        self.timeoutFactor = timeoutFactor
        self.minimumTimeout = minimumTimeout
    }
}

/// Runs the whole pipeline: discover → build schema once → baseline → one test run per mutant →
/// classify each method.
public final class Analyzer: @unchecked Sendable {
    public let configuration: AnalysisConfiguration
    private let log: @Sendable (String) -> Void
    /// Relative paths of the production sources found by the last `plan()`.
    private var productionFiles: [String] = []

    public init(configuration: AnalysisConfiguration, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.configuration = configuration
        self.log = log
    }

    private var copyRoot: URL { configuration.workDirectory.appendingPathComponent("project") }
    private var logDirectory: URL { configuration.workDirectory.appendingPathComponent("logs") }

    /// Discovers methods and their mutants without building or running anything.
    public func plan() throws -> (methods: [DiscoveredMethod], skipped: [SkippedMethod]) {
        let files = try sourceFiles()
        guard !files.isEmpty else { throw AnalysisError.noSources }
        productionFiles = files
        let changed = try configuration.changedSince.map {
            try ChangedLines.load(since: $0, in: configuration.projectPath)
        }

        var methods: [DiscoveredMethod] = []
        var skipped: [SkippedMethod] = []
        for relativePath in files {
            let url = configuration.projectPath.appendingPathComponent(relativePath)
            let source = try String(contentsOf: url, encoding: .utf8)
            for method in MethodDiscovery.discover(source: source, relativePath: relativePath, options: configuration.discovery) {
                if let changed, !changed.intersects(
                    file: url.path,
                    lines: method.info.declarationStart.line...method.info.declarationEnd.line
                ) { continue }
                switch method.decision {
                case .mutate: methods.append(method)
                case .skip(let reason): skipped.append(SkippedMethod(method: method.info, reason: reason))
                }
            }
        }
        return (methods, skipped)
    }

    public func run() throws -> AnalysisReport {
        var (methods, skipped) = try plan()
        log("Found \(methods.count) methods to mutate (\(skipped.count) not analyzable).")

        var nextID = 1
        var assignments: [(DiscoveredMethod, [Mutant])] = []
        for method in methods {
            let mutants = method.mutations.map { mutation in
                defer { nextID += 1 }
                return Mutant(id: nextID, mutation: mutation)
            }
            assignments.append((method, mutants))
        }
        let mutantCount = nextID - 1
        guard mutantCount > 0 else {
            return AnalysisReport(
                projectPath: configuration.projectPath.path, coverageAvailable: false, methods: [], skipped: skipped
            )
        }

        try prepareWorkspace(assignments)
        try build()
        let references = loadReferences(methods.map(\.info))
        let (baselineDuration, coverage) = try runBaseline()
        let timeout = max(baselineDuration * configuration.timeoutFactor, configuration.minimumTimeout)
        log(String(format: "Baseline passed in %.1fs; per-mutant timeout %.0fs.", baselineDuration, timeout))

        var results: [MethodResult] = []
        var executed = 0
        for (method, mutants) in assignments {
            let reached = coverage?.wasExecuted(
                file: copyRoot.appendingPathComponent(method.info.file).path,
                bodyStart: method.info.bodyStart
            )
            // llvm-cov lists every compiled function, executed or not. A method inside `#if` that is
            // missing from the data was most likely compiled out; running its mutants would only
            // report it as pseudo-tested.
            if coverage != nil, reached == nil, method.isConditionallyCompiled {
                skipped.append(SkippedMethod(method: method.info, reason: Self.notCompiledReason))
                continue
            }
            var mutantResults: [MutantResult] = []
            for mutant in mutants {
                if reached == false {
                    mutantResults.append(MutantResult(mutant: mutant, outcome: .notRun))
                    continue
                }
                executed += 1
                log("[\(executed)] \(method.info.name): \(mutant.mutation.summary)")
                mutantResults.append(try runMutant(mutant, timeout: timeout))
            }
            results.append(MethodResult(
                method: method.info,
                referenced: references?[method.info] ?? .unknown,
                executed: ExecutionStatus.resolve(coverage: reached, mutants: mutantResults),
                classification: Classifier.classify(mutantResults),
                mutants: mutantResults
            ))
        }

        return AnalysisReport(
            projectPath: configuration.projectPath.path,
            coverageAvailable: coverage != nil,
            referencesAvailable: references != nil,
            methods: results,
            skipped: skipped
        )
    }

    static let notCompiledReason =
        "inside `#if` and missing from the coverage data (not compiled in this build configuration)"

    // MARK: - Sources

    private func sourceFiles() throws -> [String] {
        let files: [String]
        switch configuration.buildSystem {
        case .swiftPM(let swift, let targets, _):
            files = try swiftPMSourceFiles(swift: swift, onlyTargets: targets)
        case .custom(let directories, _, _):
            files = directories.flatMap { swiftFiles(under: $0) }
        }
        return files
            .filter { path in !configuration.excludePathSubstrings.contains { path.contains($0) } }
            .sorted()
    }

    private func swiftPMSourceFiles(swift: String, onlyTargets: [String]) throws -> [String] {
        let result = try ProcessRunner.run(
            [swift, "package", "describe", "--type", "json"], in: configuration.projectPath
        )
        guard result.exitCode == 0 else { throw AnalysisError.packageDescription(result.output) }
        // Warnings may precede the JSON document.
        guard let start = result.output.firstIndex(of: "{"),
              let data = String(result.output[start...]).data(using: .utf8)
        else { throw AnalysisError.packageDescription(result.output) }

        struct Description: Decodable {
            struct Target: Decodable {
                var name: String
                var path: String
                var type: String
                var sources: [String]?
                var module_type: String?
            }
            var targets: [Target]
        }
        let description: Description
        do {
            description = try JSONDecoder().decode(Description.self, from: data)
        } catch {
            throw AnalysisError.packageDescription("\(error)\n\(result.output)")
        }
        return description.targets
            .filter { ["library", "executable"].contains($0.type) && $0.module_type == "SwiftTarget" }
            .filter { onlyTargets.isEmpty || onlyTargets.contains($0.name) }
            .flatMap { target in
                (target.sources ?? []).filter { $0.hasSuffix(".swift") }.map { "\(target.path)/\($0)" }
            }
    }

    private func swiftFiles(under relativeDirectory: String) -> [String] {
        let root = configuration.projectPath.appendingPathComponent(relativeDirectory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else { return [] }
        let base = configuration.projectPath.path.hasSuffix("/") ? configuration.projectPath.path : configuration.projectPath.path + "/"
        var result: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            let path = url.standardizedFileURL.path
            if path.hasPrefix(base) { result.append(String(path.dropFirst(base.count))) }
        }
        return result
    }

    // MARK: - Workspace

    static let excludedFromCopy: Set<String> = [".build", ".git", ".swiftpm", "DerivedData", "xcuserdata"]

    private func prepareWorkspace(_ assignments: [(DiscoveredMethod, [Mutant])]) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: copyRoot, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: logDirectory)
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)

        // Keep the copy's `.build` so later runs build incrementally and reuse dependency checkouts.
        for item in try fileManager.contentsOfDirectory(atPath: copyRoot.path) where item != ".build" {
            try fileManager.removeItem(at: copyRoot.appendingPathComponent(item))
        }
        for item in try fileManager.contentsOfDirectory(atPath: configuration.projectPath.path)
        where !Self.excludedFromCopy.contains(item) {
            let source = configuration.projectPath.appendingPathComponent(item)
            if source.standardizedFileURL.path == configuration.workDirectory.path { continue }
            try fileManager.copyItem(at: source, to: copyRoot.appendingPathComponent(item))
        }

        let byFile = Dictionary(grouping: assignments, by: { $0.0.info.file })
        for (file, fileAssignments) in byFile {
            let url = copyRoot.appendingPathComponent(file)
            let original = try String(contentsOf: url, encoding: .utf8)
            let rewritten = SchemataRewriter.rewrite(source: original, methods: fileAssignments)
            try rewritten.write(to: url, atomically: true, encoding: .utf8)
        }
        log("Wrote mutant schema to \(copyRoot.path)")
    }

    // MARK: - Build & test

    private func build() throws {
        let logFile = logDirectory.appendingPathComponent("build.log")
        log("Building mutant schema…")
        let result: ProcessResult
        switch configuration.buildSystem {
        case .swiftPM(let swift, _, _):
            var arguments = [swift, "build", "--build-tests"]
            if configuration.useCoverage { arguments.append("--enable-code-coverage") }
            if configuration.useIndex { arguments.append("--enable-index-store") }
            result = try ProcessRunner.run(arguments, in: copyRoot, logFile: logFile)
        case .custom(_, let buildCommand, _):
            result = try ProcessRunner.runShell(buildCommand, in: copyRoot, logFile: logFile)
        }
        guard result.exitCode == 0 else {
            throw AnalysisError.buildFailed(log: logFile, tail: Self.tail(result.output))
        }
    }

    // MARK: - References

    /// The referenced column, or `nil` when no index is available. Never fails the analysis.
    private func loadReferences(_ methods: [MethodInfo]) -> [MethodInfo: ReferenceStatus]? {
        guard configuration.useIndex else { return nil }
        let swift: String
        let store: URL
        switch configuration.buildSystem {
        case .swiftPM(let executable, _, _):
            swift = executable
            if let path = configuration.indexStorePath {
                store = URL(fileURLWithPath: path, relativeTo: copyRoot).standardizedFileURL
            } else {
                guard let result = try? ProcessRunner.run([swift, "build", "--show-bin-path"], in: copyRoot),
                      result.exitCode == 0,
                      let binPath = result.output.split(separator: "\n").last
                else {
                    log("Could not locate the index store; the referenced column is unavailable.")
                    return nil
                }
                store = URL(fileURLWithPath: binPath.trimmingCharacters(in: .whitespaces))
                    .appendingPathComponent("index/store")
            }
        case .custom:
            guard let path = configuration.indexStorePath else { return nil }
            swift = "swift"
            store = URL(fileURLWithPath: path, relativeTo: copyRoot).standardizedFileURL
        }
        guard let library = ReferenceColumn.libraryPath(swift: swift) else {
            log("libIndexStore not found next to `\(swift)`; the referenced column is unavailable.")
            return nil
        }
        do {
            let result = try ReferenceColumn.compute(
                storePath: store, libraryPath: library,
                databasePath: configuration.workDirectory.appendingPathComponent("index-db"),
                projectRoot: copyRoot, productionFiles: Set(productionFiles), methods: methods
            )
            log("Read test references from \(store.path).")
            return result
        } catch {
            log("\(error); the referenced column is unavailable.")
            return nil
        }
    }

    // MARK: - Baseline

    private func runBaseline() throws -> (Double, CoverageMap?) {
        let logFile = logDirectory.appendingPathComponent("baseline.log")
        log("Running baseline tests…")
        switch configuration.buildSystem {
        case .swiftPM(let swift, _, let filter):
            var arguments = testArguments(swift: swift, filter: filter)
            if configuration.useCoverage { arguments.append("--enable-code-coverage") }
            let result = try ProcessRunner.run(arguments, in: copyRoot, logFile: logFile)
            guard result.exitCode == 0 else {
                throw AnalysisError.baselineFailed(log: logFile, tail: Self.tail(result.output))
            }
            guard configuration.useCoverage else { return (result.duration, nil) }
            return (result.duration, loadCoverage(swift: swift))
        case .custom(_, _, let testCommand):
            let result = try ProcessRunner.runShell(testCommand, in: copyRoot, logFile: logFile)
            guard result.exitCode == 0 else {
                throw AnalysisError.baselineFailed(log: logFile, tail: Self.tail(result.output))
            }
            return (result.duration, nil)
        }
    }

    private func loadCoverage(swift: String) -> CoverageMap? {
        guard let pathResult = try? ProcessRunner.run(
            [swift, "test", "--show-codecov-path"], in: copyRoot
        ), pathResult.exitCode == 0,
            let path = pathResult.output.split(separator: "\n").last.map(String.init),
            let data = FileManager.default.contents(atPath: path.trimmingCharacters(in: .whitespaces))
        else {
            log("Coverage data unavailable; running every mutant.")
            return nil
        }
        do {
            return try CoverageMap(jsonData: data)
        } catch {
            log("Could not parse coverage data (\(error)); running every mutant.")
            return nil
        }
    }

    private func runMutant(_ mutant: Mutant, timeout: Double) throws -> MutantResult {
        let logFile = logDirectory.appendingPathComponent("mutant-\(mutant.id).log")
        let id = String(mutant.id)
        var environment = [
            SchemataRewriter.environmentVariable: id,
            "TEST_RUNNER_\(SchemataRewriter.environmentVariable)": id,
        ]
        let result: ProcessResult
        switch configuration.buildSystem {
        case .swiftPM(let swift, _, let filter):
            environment["LLVM_PROFILE_FILE"] = logDirectory.appendingPathComponent("mutant.profraw").path
            result = try ProcessRunner.run(
                testArguments(swift: swift, filter: filter), in: copyRoot,
                environment: environment, timeout: timeout, logFile: logFile
            )
        case .custom(_, _, let testCommand):
            result = try ProcessRunner.runShell(
                testCommand, in: copyRoot, environment: environment, timeout: timeout, logFile: logFile
            )
        }
        let outcome: MutantOutcome = result.timedOut ? .timedOut : (result.exitCode == 0 ? .survived : .killed)
        return MutantResult(mutant: mutant, outcome: outcome, duration: result.duration)
    }

    private func testArguments(swift: String, filter: String?) -> [String] {
        var arguments = [swift, "test", "--skip-build"]
        if let filter { arguments += ["--filter", filter] }
        return arguments
    }

    /// Compiler/test diagnostics worth showing: `error:` lines (with ANSI colours stripped) if any,
    /// otherwise the last lines of output.
    static func tail(_ output: String, lines: Int = 30) -> String {
        let plain = output.replacingOccurrences(of: "\u{1B}\\[[0-9;]*m", with: "", options: .regularExpression)
        let all = plain.split(separator: "\n", omittingEmptySubsequences: false)
        let errors = all.filter { $0.contains("error:") && $0.count < 500 }
        var seen = Set<Substring>()
        let unique = errors.filter { seen.insert($0).inserted }
        return (unique.isEmpty ? Array(all.suffix(lines)) : Array(unique.prefix(lines))).joined(separator: "\n")
    }
}
