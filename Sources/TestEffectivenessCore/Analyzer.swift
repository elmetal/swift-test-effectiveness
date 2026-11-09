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
        /// forwarded by `xcodebuild test` to the test process). `{only-testing}` in the test command
        /// enables test selection (see `TestSelection`).
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
    /// Run each mutant against the tests that reach its method first (see `TestSelection`). Needs
    /// the index; SwiftPM: not with a test filter; custom mode: only with `{only-testing}` in the
    /// test command.
    public var testSelection: Bool

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
        minimumTimeout: Double = 30,
        testSelection: Bool = true
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
        self.testSelection = testSelection
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
        let selectable = try selectableTests(references, timeout: timeout)

        // Decide up front which mutants run, so that progress can show the total.
        var planned: [(method: DiscoveredMethod, mutants: [Mutant], reached: Bool?)] = []
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
            planned.append((method, mutants, reached))
        }
        var progress = Progress(
            total: planned.filter { $0.reached != false }.reduce(0) { $0 + $1.mutants.count },
            initialEstimate: baselineDuration
        )
        log("Running \(progress.total) mutants.")

        var results: [MethodResult] = []
        var statistics = SelectionStatistics()
        for (method, mutants, reached) in planned {
            let tests = selectable.flatMap { all in
                TestSelection.tests(
                    reaching: references?.reachingTests[method.info].map { $0.intersection(all) }, all: all
                )
            }
            var mutantResults: [MutantResult] = []
            for mutant in mutants {
                if reached == false {
                    mutantResults.append(MutantResult(mutant: mutant, outcome: .notRun))
                    continue
                }
                let selected = tests.map { " [\($0.count) selected test \($0.count == 1 ? "scope" : "scopes")]" } ?? ""
                log(progress.next("\(method.info.name): \(mutant.mutation.summary)\(selected)"))
                let result = try runMutant(mutant, tests: tests, timeout: timeout, statistics: &statistics)
                progress.finished(duration: result.duration ?? 0)
                mutantResults.append(result)
            }
            results.append(MethodResult(
                method: method.info,
                referenced: references?.status[method.info] ?? .unknown,
                executed: ExecutionStatus.resolve(coverage: reached, mutants: mutantResults),
                classification: Classifier.classify(mutantResults),
                mutants: mutantResults
            ))
        }

        if selectable != nil {
            log("Test selection: \(statistics.decidedBySelection) mutants detected by the selected tests; "
                + "\(statistics.reran) survived them and re-ran the whole suite; "
                + "\(statistics.wholeSuite) ran the whole suite directly.")
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

    /// The referenced column (and the tests reaching each method, for test selection), or `nil`
    /// when no index is available. Never fails the analysis.
    private func loadReferences(_ methods: [MethodInfo]) -> ReferenceAnalysis? {
        guard configuration.useIndex else {
            if selectionRequested { log("Test selection needs the index; running the whole suite for every mutant.") }
            return nil
        }
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
            guard let path = configuration.indexStorePath else {
                if selectionRequested {
                    log("Test selection needs --index-store-path; running the whole suite for every mutant.")
                }
                return nil
            }
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
                projectRoot: copyRoot, productionFiles: Set(productionFiles), methods: methods,
                selectTests: selectionRequested
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
            let result = try ProcessRunner.runShell(
                TestSelection.expand(testCommand, tests: nil), in: copyRoot, logFile: logFile
            )
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

    // MARK: - Test selection

    /// Whether the configuration asks for test selection and the build system supports it.
    private var selectionRequested: Bool {
        guard configuration.testSelection else { return false }
        switch configuration.buildSystem {
        case .swiftPM(_, _, let filter): return filter == nil
        case .custom(_, _, let testCommand): return testCommand.contains(TestSelection.placeholder)
        }
    }

    struct SelectionStatistics {
        var decidedBySelection = 0
        var reran = 0
        var wholeSuite = 0
    }

    /// The tests that may be selected, or `nil` to run the whole suite for every mutant.
    ///
    /// Selecting every test must pass on the unmodified code. Otherwise a selector names a target
    /// the scheme cannot run (`xcodebuild` then fails), or a test depends on tests outside the
    /// selection; either would make a mutant look detected. A module whose selection fails on its
    /// own is never selected.
    private func selectableTests(_ references: ReferenceAnalysis?, timeout: Double) throws -> Set<TestSelector>? {
        guard selectionRequested, let references else { return nil }
        let all = references.allTests
        guard !all.isEmpty else {
            log("Test selection: no test scopes found in the index; running the whole suite for every mutant.")
            return nil
        }
        log("Checking that the \(all.count) test scopes can be selected…")
        let check = try executeTests(
            all.sorted(), mutant: nil, timeout: timeout,
            logFile: logDirectory.appendingPathComponent("selection-check.log")
        )
        if check.exitCode == 0 && !check.timedOut { return all }

        var selectable = Set<TestSelector>()
        var dropped: [String] = []
        for (module, tests) in Dictionary(grouping: all, by: \.module).sorted(by: { $0.key < $1.key }) {
            let result = try executeTests(
                tests.sorted(), mutant: nil, timeout: timeout,
                logFile: logDirectory.appendingPathComponent("selection-check-\(module).log")
            )
            if result.exitCode == 0 && !result.timedOut {
                selectable.formUnion(tests)
            } else {
                dropped.append(module)
            }
        }
        log("Test selection: selecting tests of \(dropped.joined(separator: ", ")) fails without mutations "
            + "(see selection-check-*.log); mutants reached only by them run the whole suite.")
        return selectable.isEmpty ? nil : selectable
    }

    // MARK: - Mutants

    /// Runs the selected tests first, if any, and the whole suite when the mutant survives them.
    private func runMutant(
        _ mutant: Mutant, tests: [TestSelector]?, timeout: Double, statistics: inout SelectionStatistics
    ) throws -> MutantResult {
        var duration = 0.0
        if let tests {
            let selected = try executeTests(
                tests, mutant: mutant, timeout: timeout,
                logFile: logDirectory.appendingPathComponent("mutant-\(mutant.id)-selected.log")
            )
            duration += selected.duration
            if selected.timedOut || selected.exitCode != 0 {
                statistics.decidedBySelection += 1
                return MutantResult(mutant: mutant, outcome: Self.outcome(selected), duration: duration)
            }
            statistics.reran += 1
        } else {
            statistics.wholeSuite += 1
        }
        let result = try executeTests(
            nil, mutant: mutant, timeout: timeout,
            logFile: logDirectory.appendingPathComponent("mutant-\(mutant.id).log")
        )
        duration += result.duration
        return MutantResult(mutant: mutant, outcome: Self.outcome(result), duration: duration)
    }

    private static func outcome(_ result: ProcessResult) -> MutantOutcome {
        result.timedOut ? .timedOut : (result.exitCode == 0 ? .survived : .killed)
    }

    /// Runs `tests` (`nil`: the whole suite) with `mutant` active (`nil`: none).
    private func executeTests(
        _ tests: [TestSelector]?, mutant: Mutant?, timeout: Double, logFile: URL
    ) throws -> ProcessResult {
        var environment: [String: String] = [:]
        if let mutant {
            environment[SchemataRewriter.environmentVariable] = String(mutant.id)
            environment["TEST_RUNNER_\(SchemataRewriter.environmentVariable)"] = String(mutant.id)
        }
        switch configuration.buildSystem {
        case .swiftPM(let swift, _, let filter):
            // Keep the baseline's coverage data.
            environment["LLVM_PROFILE_FILE"] = logDirectory.appendingPathComponent("mutant.profraw").path
            var arguments = testArguments(swift: swift, filter: filter)
            if let tests { arguments += TestSelection.filterArguments(tests) }
            return try ProcessRunner.run(
                arguments, in: copyRoot, environment: environment, timeout: timeout, logFile: logFile
            )
        case .custom(_, _, let testCommand):
            return try ProcessRunner.runShell(
                TestSelection.expand(testCommand, tests: tests), in: copyRoot,
                environment: environment, timeout: timeout, logFile: logFile
            )
        }
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
