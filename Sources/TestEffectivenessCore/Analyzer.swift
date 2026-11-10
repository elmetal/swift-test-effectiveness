import Foundation
import Synchronization

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
    /// Custom mode: the `.profdata` the baseline writes, or a directory to search for the newest
    /// one (e.g. `<derivedDataPath>/Build/ProfileData`). Relative paths are resolved inside the
    /// copied project. Without it, custom mode collects no coverage.
    public var coverageProfilePath: String?
    /// Custom mode: binaries with coverage instrumentation, or directories to search for Mach-O
    /// files (e.g. `<derivedDataPath>/Build/Products`).
    public var coverageBinaryPaths: [String]
    public var discovery: DiscoveryOptions
    public var changedSince: String?
    public var excludePathSubstrings: [String]
    public var timeoutFactor: Double
    /// The least a run's timeout can be, in seconds. `nil`: `RunTimeout.defaultMinimum`, or
    /// `RunTimeout.defaultMinimumForDirectLaunch` when the test bundles are started directly.
    public var minimumTimeout: Double?
    /// Run each mutant against the tests that reach its method first (see `TestSelection`). Needs
    /// the index; SwiftPM: not with a test filter; custom mode: only with `{only-testing}` in the
    /// test command.
    public var testSelection: Bool
    /// How many test runs execute at once. Custom mode: each worker's command gets its number for
    /// `{job}` (see `CommandTemplate`). SwiftPM: only when the tests are started directly.
    public var jobs: Int
    /// SwiftPM: start the test bundles directly instead of through `swift test` for every run
    /// after the baseline (see `DirectTestLauncher`). Not with a test filter.
    public var directLaunch: Bool
    /// Run a mutant that survives the tests that execute its method against the whole suite as
    /// well, even when those tests are known to be every test that executes it (see
    /// `RecordedReach`).
    public var rerunSurvivors: Bool

    public init(
        projectPath: URL,
        workDirectory: URL? = nil,
        buildSystem: BuildSystem,
        useCoverage: Bool = true,
        useIndex: Bool = true,
        indexStorePath: String? = nil,
        coverageProfilePath: String? = nil,
        coverageBinaryPaths: [String] = [],
        discovery: DiscoveryOptions = .init(),
        changedSince: String? = nil,
        excludePathSubstrings: [String] = [],
        timeoutFactor: Double = 3,
        minimumTimeout: Double? = nil,
        testSelection: Bool = true,
        jobs: Int = 1,
        directLaunch: Bool = true,
        rerunSurvivors: Bool = false
    ) {
        self.projectPath = projectPath.standardizedFileURL
        self.workDirectory = (workDirectory
            ?? projectPath.appendingPathComponent(".build/test-effectiveness")).standardizedFileURL
        self.buildSystem = buildSystem
        self.useCoverage = useCoverage
        self.useIndex = useIndex
        self.indexStorePath = indexStorePath
        self.coverageProfilePath = coverageProfilePath
        self.coverageBinaryPaths = coverageBinaryPaths
        self.discovery = discovery
        self.changedSince = changedSince
        self.excludePathSubstrings = excludePathSubstrings
        self.timeoutFactor = timeoutFactor
        self.minimumTimeout = minimumTimeout
        self.testSelection = testSelection
        self.jobs = max(1, jobs)
        self.directLaunch = directLaunch
        self.rerunSurvivors = rerunSurvivors
    }
}

/// Runs the whole pipeline: discover → build schema once → baseline → one test run per mutant →
/// classify each method.
public final class Analyzer: @unchecked Sendable {
    public let configuration: AnalysisConfiguration
    private let log: @Sendable (String) -> Void
    /// Relative paths of the production sources found by the last `plan()`.
    private var productionFiles: [String] = []
    /// SwiftPM: the package's name and its test targets, found by the last `plan()`.
    private var package: (name: String, testTargets: [String])?
    /// SwiftPM: set once starting the test bundles directly gave the baseline's results.
    private var directLauncher: DirectTestLauncher?
    /// SwiftPM: the answer of `swift build --show-bin-path`, which takes about a second to ask.
    private var knownBinPath: URL?

    public init(configuration: AnalysisConfiguration, log: @escaping @Sendable (String) -> Void = { _ in }) {
        self.configuration = configuration
        self.log = log
    }

    private var copyRoot: URL { configuration.workDirectory.appendingPathComponent("project") }
    private var logDirectory: URL { configuration.workDirectory.appendingPathComponent("logs") }
    /// The files the test runs without mutations record the methods they execute in.
    private var reachedDirectory: URL { configuration.workDirectory.appendingPathComponent("reached") }

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
        let (baselineDuration, coverage, baselineOutput) = try runBaseline()
        log(String(format: "Baseline passed in %.1fs.", baselineDuration))
        var runTimeout = RunTimeout(
            factor: configuration.timeoutFactor,
            minimum: configuration.minimumTimeout ?? RunTimeout.defaultMinimum, baseline: baselineDuration
        )
        try setUpDirectLaunch(baselineOutput: baselineOutput, timeout: runTimeout.wholeSuite)
        if directLauncher != nil, configuration.minimumTimeout == nil {
            runTimeout.minimum = RunTimeout.defaultMinimumForDirectLaunch
        }
        let timeout = runTimeout.wholeSuite
        log(String(
            format: "Timeout for a run of the whole suite: %.0fs; for selected tests: %.0f times what they "
                + "took alone, at least %.0fs.",
            timeout, runTimeout.factor, runTimeout.minimum
        ))
        let (selectable, testsFailingAlone, recorded, aloneDurations) = try selectableTests(
            references, baselineTests: TestOutput.executedTests(in: baselineOutput), timeout: timeout
        )

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
        let total = planned.filter { $0.reached != false }.reduce(0) { $0 + $1.mutants.count }
        log("Running \(total) mutants\(jobs > 1 ? " with \(jobs) jobs" : "").")
        if jobs > 1, case .custom(_, _, let testCommand) = configuration.buildSystem {
            if !testCommand.contains(CommandTemplate.job) {
                log("Warning: --test-command has no {job}, so every job uses the same destination.")
            }
            if testCommand.contains("xcodebuild") && !testCommand.contains(CommandTemplate.resultBundle) {
                log("Warning: xcodebuild runs that start in the same second share a result bundle; "
                    + "pass -resultBundlePath {result-bundle}.")
            }
        }

        // Every mutant that runs, in order; the results go back into the same positions.
        var outcomes: [[MutantResult?]] = planned.map { method, mutants, reached in
            mutants.map { reached == false ? MutantResult(mutant: $0, outcome: .notRun) : nil }
        }
        var work: [MutantRun] = []
        // A mutant that survives every test that executes its method survives the whole suite.
        let selectionIsExact = recorded?.coversSuite == true && !configuration.rerunSurvivors
        // Asked of the index only when nothing was recorded, and never for a single scope, which
        // is the whole suite either way.
        let indexReach = recorded == nil && (selectable?.count ?? 0) > 1 ? references?.reachingTests() : nil
        for (methodIndex, (method, mutants, reached)) in planned.enumerated() where reached != false {
            // What the scopes executed when the build recorded it; what the index says otherwise.
            let reaching = recorded.map { $0.scopes[mutants[0].id] ?? [] } ?? indexReach?[method.info]
            let tests = selectable.flatMap { all in
                TestSelection.tests(reaching: reaching.map { $0.intersection(all) }, all: all)
            }
            let selectedTimeout = tests.map { tests in
                runTimeout.selected(aloneDurations: tests.map { aloneDurations[$0] })
            } ?? timeout
            for (mutantIndex, mutant) in mutants.enumerated() {
                work.append(MutantRun(
                    method: methodIndex, index: mutantIndex, mutant: mutant, tests: tests,
                    selectedTimeout: selectedTimeout, rerunsSurvivor: !selectionIsExact, name: method.info.name
                ))
            }
        }
        let (finished, statistics) = try runMutants(work, timeout: timeout, initialEstimate: baselineDuration)
        for (run, result) in zip(work, finished) {
            outcomes[run.method][run.index] = result
        }

        let results = zip(planned, outcomes).map { plan, outcomes in
            let mutantResults = outcomes.map { $0! }
            return MethodResult(
                method: plan.method.info,
                referenced: references?.status[plan.method.info] ?? .unknown,
                executed: ExecutionStatus.resolve(coverage: plan.reached, mutants: mutantResults),
                classification: Classifier.classify(mutantResults),
                mutants: mutantResults
            )
        }

        if selectable != nil {
            log("Test selection: \(statistics.decidedBySelection) mutants detected by the selected tests; "
                + "\(statistics.survivedSelection) survived them, which are every test that executes their method; "
                + "\(statistics.reran) survived them and re-ran the whole suite; "
                + "\(statistics.wholeSuite) ran the whole suite directly.")
        }

        return AnalysisReport(
            projectPath: configuration.projectPath.path,
            coverageAvailable: coverage != nil,
            referencesAvailable: references != nil,
            methods: results,
            skipped: skipped,
            testsFailingAlone: testsFailingAlone
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
            var name: String
            var targets: [Target]
        }
        let description: Description
        do {
            description = try JSONDecoder().decode(Description.self, from: data)
        } catch {
            throw AnalysisError.packageDescription("\(error)\n\(result.output)")
        }
        package = (description.name, description.targets.filter { $0.type == "test" }.map(\.name))
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

    private func prepareWorkspace(_ assignments: [(DiscoveredMethod, [Mutant])]) throws {
        let fileManager = FileManager.default
        try? fileManager.removeItem(at: logDirectory)
        try fileManager.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: resultBundleDirectory)
        try fileManager.createDirectory(at: resultBundleDirectory, withIntermediateDirectories: true)
        try? fileManager.removeItem(at: reachedDirectory)
        try fileManager.createDirectory(at: reachedDirectory, withIntermediateDirectories: true)

        var schemata: [String: Data] = [:]
        for (file, fileAssignments) in Dictionary(grouping: assignments, by: { $0.0.info.file }) {
            let original = try String(contentsOf: configuration.projectPath.appendingPathComponent(file), encoding: .utf8)
            schemata[file] = Data(SchemataRewriter.rewrite(source: original, methods: fileAssignments).utf8)
        }
        // In place: files that did not change keep their modification time, and what the last
        // build wrote into the copy stays, so the build only redoes what changed.
        let summary = try WorkspaceCopy.sync(
            from: configuration.projectPath, to: copyRoot,
            manifest: configuration.workDirectory.appendingPathComponent("copied-files.json"),
            skipping: [configuration.workDirectory], contents: schemata
        )
        log("Wrote mutant schema to \(copyRoot.path) (\(summary.written) files written, "
            + "\(summary.unchanged) unchanged, \(summary.removed) removed).")
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
                guard let binPath = binPath(swift: swift) else {
                    log("Could not locate the index store; the referenced column is unavailable.")
                    return nil
                }
                store = binPath.appendingPathComponent("index/store")
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

    /// SwiftPM: where the build of the copy writes its products.
    private func binPath(swift: String) -> URL? {
        if let knownBinPath { return knownBinPath }
        guard let result = try? ProcessRunner.run([swift, "build", "--show-bin-path"], in: copyRoot),
              result.exitCode == 0,
              let path = result.output.split(separator: "\n").last
        else { return nil }
        knownBinPath = URL(fileURLWithPath: path.trimmingCharacters(in: .whitespaces))
        return knownBinPath
    }

    // MARK: - Baseline

    private func runBaseline() throws -> (duration: Double, coverage: CoverageMap?, output: String) {
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
            guard configuration.useCoverage else { return (result.duration, nil, result.output) }
            return (result.duration, loadCoverage(swift: swift), result.output)
        case .custom:
            // Coverage files are at least as new as the baseline; older ones are left over.
            let start = Date().addingTimeInterval(-1)
            let result = try executeTests(nil, mutant: nil, timeout: nil, logFile: logFile, keepResultBundle: true)
            guard result.exitCode == 0 else {
                throw AnalysisError.baselineFailed(log: logFile, tail: Self.tail(result.output))
            }
            guard configuration.useCoverage else { return (result.duration, nil, result.output) }
            return (result.duration, loadCustomCoverage(since: start), result.output)
        }
    }

    /// Custom mode: exports the coverage of each binary with `llvm-cov export` and merges it.
    /// Binaries without coverage data (resources, uninstrumented frameworks) are skipped.
    private func loadCustomCoverage(since start: Date) -> CoverageMap? {
        guard let profilePath = configuration.coverageProfilePath, !configuration.coverageBinaryPaths.isEmpty else {
            log("Custom mode collects no coverage without --coverage-profdata and --coverage-binary; running every mutant.")
            return nil
        }
        let resolve = { (path: String) in URL(fileURLWithPath: path, relativeTo: self.copyRoot).standardizedFileURL }
        guard let profile = CoverageArtifacts.profile(at: resolve(profilePath), modifiedAfter: start) else {
            log("No coverage profile written by the baseline at \(resolve(profilePath).path) "
                + "(does the test command pass -enableCodeCoverage YES?); running every mutant.")
            return nil
        }
        let binaries = configuration.coverageBinaryPaths.flatMap { CoverageArtifacts.binaries(at: resolve($0)) }
        let exportDirectory = configuration.workDirectory.appendingPathComponent("coverage")
        try? FileManager.default.removeItem(at: exportDirectory)
        try? FileManager.default.createDirectory(at: exportDirectory, withIntermediateDirectories: true)

        var maps: [CoverageMap] = []
        for (number, binary) in binaries.enumerated() {
            let output = exportDirectory.appendingPathComponent("\(number).json")
            let command = ["xcrun", "llvm-cov", "export", "-instr-profile", profile.path, binary.path]
                .map(TestSelection.shellQuoted).joined(separator: " ") + " > " + TestSelection.shellQuoted(output.path)
            guard let result = try? ProcessRunner.runShell(command, in: copyRoot), result.exitCode == 0,
                  let data = FileManager.default.contents(atPath: output.path),
                  let map = try? CoverageMap(jsonData: data)
            else { continue }
            maps.append(map)
        }
        guard !maps.isEmpty else {
            log("None of the \(binaries.count) binaries has coverage data for \(profile.path); running every mutant.")
            return nil
        }
        log("Read coverage of \(maps.count) of \(binaries.count) binaries from \(profile.path).")
        return CoverageMap(merging: maps)
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

    // MARK: - Direct launch

    /// SwiftPM: from here on, start the test bundles directly if that gives the baseline's
    /// results. Otherwise every run goes through `swift test`, one at a time.
    private func setUpDirectLaunch(baselineOutput: String, timeout: Double) throws {
        guard case .swiftPM(let swift, _, let filter) = configuration.buildSystem else { return }
        let fallback = "using `swift test` for every run" + (configuration.jobs > 1 ? ", one at a time" : "")
        guard configuration.directLaunch else {
            if configuration.jobs > 1 { log("--jobs needs the tests to be started directly; \(fallback).") }
            return
        }
        guard filter == nil else {
            if configuration.jobs > 1 { log("--jobs cannot be used with --test-filter; \(fallback).") }
            return
        }
        guard let package, let binPath = binPath(swift: swift) else {
            log("Could not locate the test bundles; \(fallback).")
            return
        }
        do {
            var launcher = try DirectTestLauncher.resolve(
                swift: swift, binPath: binPath, packageName: package.name, testTargets: package.testTargets,
                in: copyRoot
            )
            if let problem = try launcher.verify(
                baselineOutput: baselineOutput, timeout: timeout, in: copyRoot,
                logFile: logDirectory.appendingPathComponent("direct-launch-check.log")
            ) { throw problem }
            directLauncher = launcher
            log("Starting the test bundles directly from here on (same tests as the baseline).")
        } catch {
            // Also a tool that cannot be started: never a reason to stop the analysis.
            log("Cannot start the tests directly: \(error); \(fallback).")
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
        /// Survived the selected tests, which are every test that executes the method.
        var survivedSelection = 0
        var reran = 0
        var wholeSuite = 0

        mutating func add(_ other: SelectionStatistics) {
            decidedBySelection += other.decidedBySelection
            survivedSelection += other.survivedSelection
            reran += other.reran
            wholeSuite += other.wholeSuite
        }
    }

    /// What the test scopes executed when each ran alone, without mutations, as the mutant schema
    /// recorded it (see `ReachedMethods`). Unlike the index, which sees only the calls the compiler
    /// can resolve, this is what ran.
    struct RecordedReach {
        /// By the id of a method's first mutant: the selectable scopes that executed the method.
        var scopes: [Int: Set<TestSelector>] = [:]
        /// Every test of the suite belongs to a scope that passes alone and was recorded. A mutant
        /// that survives the scopes that execute its method then survives the whole suite: a test
        /// that never calls the method runs the same code with and without the mutant.
        var coversSuite = false
    }

    /// The tests that may be selected, or `nil` to run the whole suite for every mutant.
    ///
    /// Selecting every test must pass on the unmodified code. Otherwise a selector names a target
    /// the scheme cannot run (`xcodebuild` then fails), or a test depends on tests outside the
    /// selection; either would make a mutant look detected. A module whose selection fails on its
    /// own is never selected.
    ///
    /// Each remaining scope then runs alone (see `scopesFailingAlone`); a scope that fails is not
    /// selected either and is returned for the report. The same runs record the methods each
    /// scope executes.
    ///
    /// - Parameter baselineTests: the number of tests the baseline executed, `0` if unknown.
    private func selectableTests(
        _ references: ReferenceAnalysis?, baselineTests: Int, timeout: Double
    ) throws -> (Set<TestSelector>?, [TestFailingAlone]?, RecordedReach?, aloneDurations: [TestSelector: Double]) {
        guard selectionRequested, let references else { return (nil, nil, nil, [:]) }
        let all = references.allTests
        guard !all.isEmpty else {
            log("Test selection: no test scopes found in the index; running the whole suite for every mutant.")
            return (nil, nil, nil, [:])
        }
        guard let selectable = try selectableModules(all, timeout: timeout) else { return (nil, nil, nil, [:]) }
        let isolation = try scopesFailingAlone(selectable, timeout: timeout)
        let remaining = selectable.subtracting(isolation.failures.map(\.selector))
        guard !remaining.isEmpty else { return (nil, isolation.failures.map(\.report), nil, [:]) }

        var recorded: RecordedReach?
        if isolation.reached.values.contains(where: { !$0.isEmpty }) {
            var reach = RecordedReach()
            for (scope, methods) in isolation.reached where remaining.contains(scope) {
                for method in methods { reach.scopes[method, default: []].insert(scope) }
            }
            // The scopes come from the index and the test sources; a test they miss could detect
            // a mutant that survives them. Only when they ran as many tests as the baseline is
            // nothing left for the whole suite to add.
            let why: String? =
                !isolation.failures.isEmpty ? "some test scopes fail alone"
                : remaining.count != all.count ? "some test scopes cannot be selected"
                : baselineTests == 0 ? "the number of tests the baseline executed is unknown"
                : isolation.executedTests != baselineTests
                    ? "the scopes executed \(isolation.executedTests) tests alone, the baseline \(baselineTests)"
                : nil
            reach.coversSuite = why == nil
            if let why {
                log("Recorded the methods each test scope executes. A mutant that survives the scopes "
                    + "that execute its method still runs the whole suite: \(why).")
            } else if configuration.rerunSurvivors {
                log("Recorded the methods each test scope executes. A mutant that survives the scopes "
                    + "that execute its method still runs the whole suite (--rerun-survivors).")
            } else {
                log("Recorded the methods each test scope executes. The scopes are the whole suite "
                    + "(\(baselineTests) tests), so a mutant that survives the scopes that execute its "
                    + "method is not run against the whole suite.")
            }
            recorded = reach
        } else if selectable.count > 1 {
            log("The test runs recorded no executed method; selecting tests from the index.")
        }
        return (remaining, isolation.failures.map(\.report), recorded, isolation.durations)
    }

    private func selectableModules(_ all: Set<TestSelector>, timeout: Double) throws -> Set<TestSelector>? {
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

    /// Runs each scope on its own, without mutations, on the mutant workers. A scope that passes
    /// with the others but fails alone depends on tests that run before it or shares state with
    /// them; selected alone, it would make a mutant look detected. One run per scope; a single
    /// scope already ran alone in `selectableModules`.
    ///
    /// Each run also records the methods it executes (`SchemataRewriter.reachedEnvironmentVariable`).
    private func scopesFailingAlone(_ scopes: Set<TestSelector>, timeout: Double) throws -> IsolationOutcome {
        guard scopes.count > 1 else { return IsolationOutcome() }
        let ordered = scopes.sorted()
        log("Running each of the \(ordered.count) test scopes alone without mutations "
            + "(\(ordered.count) runs\(jobs > 1 ? " on \(jobs) jobs" : ""))…")
        let start = Date()
        struct State {
            var next = 0
            var failures: [Int: TestFailingAlone] = [:]
            var reached: [TestSelector: Set<Int>] = [:]
            var durations: [TestSelector: Double] = [:]
            var executedTests = 0
            var error: (any Error)?
        }
        let state = Mutex(State())
        DispatchQueue.concurrentPerform(iterations: min(jobs, ordered.count)) { worker in
            while true {
                let taken: Int? = state.withLock { state in
                    guard state.error == nil, state.next < ordered.count else { return nil }
                    defer { state.next += 1 }
                    return state.next
                }
                guard let taken else { return }
                let scope = ordered[taken]
                let logFile = logDirectory.appendingPathComponent("isolation-\(taken + 1).log")
                let reachedFile = reachedDirectory.appendingPathComponent("isolation-\(taken + 1).txt")
                do {
                    let result = try executeTests(
                        [scope], mutant: nil, timeout: timeout, job: worker + 1, logFile: logFile,
                        reachedFile: reachedFile
                    )
                    guard result.timedOut || result.exitCode != 0 else {
                        let reached = ReachedMethods.read(reachedFile) ?? []
                        let executed = TestOutput.executedTests(in: result.output)
                        state.withLock { state in
                            state.reached[scope] = reached
                            state.durations[scope] = result.duration
                            state.executedTests += executed
                        }
                        continue
                    }
                    let failure = TestFailingAlone(
                        test: scope.onlyTestingIdentifier, timedOut: result.timedOut, log: logFile.path
                    )
                    state.withLock { $0.failures[taken] = failure }
                } catch {
                    state.withLock { state in
                        if state.error == nil { state.error = error }
                    }
                    return
                }
            }
        }
        let (failures, reached, durations, executedTests) = try state.withLock { state in
            if let error = state.error { throw error }
            return (
                state.failures.sorted { $0.key < $1.key }.map { (selector: ordered[$0.key], report: $0.value) },
                state.reached, state.durations, state.executedTests
            )
        }
        let elapsed = String(format: "%.1fs", Date().timeIntervalSince(start))
        if failures.isEmpty {
            log("Test isolation: every test scope passes alone (checked in \(elapsed)).")
        } else {
            log("Test isolation: \(failures.count) test \(failures.count == 1 ? "scope fails" : "scopes fail") "
                + "alone without mutations and \(failures.count == 1 ? "is" : "are") not selected: "
                + failures.map(\.report.test).joined(separator: ", ") + " (checked in \(elapsed)).")
        }
        return IsolationOutcome(
            failures: failures, reached: reached, durations: durations, executedTests: executedTests
        )
    }

    struct IsolationOutcome {
        var failures: [(selector: TestSelector, report: TestFailingAlone)] = []
        /// The methods each scope that passes alone executed, by the id of their first mutant.
        var reached: [TestSelector: Set<Int>] = [:]
        /// How long each scope that passes alone took, with whatever its run costs besides the
        /// tests (starting the test process, `xcodebuild`).
        var durations: [TestSelector: Double] = [:]
        /// The number of tests the scopes that pass alone executed together.
        var executedTests = 0
    }

    // MARK: - Mutants

    /// `swift test` locks `.build`, so its runs cannot overlap; test bundles started directly can.
    private var jobs: Int {
        switch configuration.buildSystem {
        case .custom: configuration.jobs
        case .swiftPM: directLauncher == nil ? 1 : configuration.jobs
        }
    }

    struct MutantRun {
        var method: Int
        var index: Int
        var mutant: Mutant
        var tests: [TestSelector]?
        /// The timeout of the run of `tests`.
        var selectedTimeout: Double
        /// Run the whole suite when the mutant survives `tests`.
        var rerunsSurvivor = true
        var name: String
    }

    /// Runs `work` on `jobs` workers, each taking the next mutant when it is free. Returns the
    /// results in the order of `work`. The first error stops the workers from taking more mutants.
    private func runMutants(
        _ work: [MutantRun], timeout: Double, initialEstimate: Double
    ) throws -> ([MutantResult], SelectionStatistics) {
        struct State {
            var next = 0
            var results: [MutantResult?]
            var statistics = SelectionStatistics()
            var progress: Progress
            var error: (any Error)?
        }
        let state = Mutex(State(
            results: Array(repeating: nil, count: work.count),
            progress: Progress(total: work.count, initialEstimate: initialEstimate, parallelism: jobs)
        ))
        DispatchQueue.concurrentPerform(iterations: jobs) { worker in
            while true {
                let taken: Int? = state.withLock { state in
                    guard state.error == nil, state.next < work.count else { return nil }
                    defer { state.next += 1 }
                    let run = work[state.next]
                    let selected = run.tests.map { " [\($0.count) selected test \($0.count == 1 ? "scope" : "scopes")]" } ?? ""
                    log(state.progress.next("\(run.name): \(run.mutant.mutation.summary)\(selected)"))
                    return state.next
                }
                guard let taken else { return }
                let run = work[taken]
                do {
                    var statistics = SelectionStatistics()
                    let result = try runMutant(
                        run.mutant, tests: run.tests, selectedTimeout: run.selectedTimeout,
                        rerunsSurvivor: run.rerunsSurvivor, timeout: timeout, job: worker + 1,
                        statistics: &statistics
                    )
                    state.withLock { state in
                        state.results[taken] = result
                        state.statistics.add(statistics)
                        state.progress.finished(duration: result.duration ?? 0)
                    }
                } catch {
                    state.withLock { state in
                        if state.error == nil { state.error = error }
                    }
                    return
                }
            }
        }
        return try state.withLock { state in
            if let error = state.error { throw error }
            return (state.results.map { $0! }, state.statistics)
        }
    }

    /// Runs the selected tests first, if any, and the whole suite when the mutant survives them,
    /// unless they are known to be every test that executes the mutant's method.
    private func runMutant(
        _ mutant: Mutant, tests: [TestSelector]?, selectedTimeout: Double, rerunsSurvivor: Bool,
        timeout: Double, job: Int, statistics: inout SelectionStatistics
    ) throws -> MutantResult {
        var duration = 0.0
        if let tests {
            let selected = try executeTests(
                tests, mutant: mutant, timeout: selectedTimeout, job: job,
                logFile: logDirectory.appendingPathComponent("mutant-\(mutant.id)-selected.log")
            )
            duration += selected.duration
            if selected.timedOut || selected.exitCode != 0 {
                statistics.decidedBySelection += 1
                return MutantResult(mutant: mutant, outcome: Self.outcome(selected), duration: duration)
            }
            guard rerunsSurvivor else {
                statistics.survivedSelection += 1
                return MutantResult(mutant: mutant, outcome: .survived, duration: duration)
            }
            statistics.reran += 1
        } else {
            statistics.wholeSuite += 1
        }
        let result = try executeTests(
            nil, mutant: mutant, timeout: timeout, job: job,
            logFile: logDirectory.appendingPathComponent("mutant-\(mutant.id).log")
        )
        duration += result.duration
        return MutantResult(mutant: mutant, outcome: Self.outcome(result), duration: duration)
    }

    private static func outcome(_ result: ProcessResult) -> MutantOutcome {
        result.timedOut ? .timedOut : (result.exitCode == 0 ? .survived : .killed)
    }

    /// Runs `tests` (`nil`: the whole suite) with `mutant` active (`nil`: none) as worker `job`.
    /// With `reachedFile`, the run records the methods it executes there.
    private func executeTests(
        _ tests: [TestSelector]?, mutant: Mutant?, timeout: Double?, job: Int = 1, logFile: URL,
        keepResultBundle: Bool = false, reachedFile: URL? = nil
    ) throws -> ProcessResult {
        var environment: [String: String] = [:]
        if let reachedFile {
            try? FileManager.default.removeItem(at: reachedFile)
            environment[SchemataRewriter.reachedEnvironmentVariable] = reachedFile.path
            environment["TEST_RUNNER_\(SchemataRewriter.reachedEnvironmentVariable)"] = reachedFile.path
        }
        if let mutant {
            environment[SchemataRewriter.environmentVariable] = String(mutant.id)
            environment["TEST_RUNNER_\(SchemataRewriter.environmentVariable)"] = String(mutant.id)
        }
        switch configuration.buildSystem {
        case .swiftPM(let swift, _, let filter):
            if let directLauncher {
                return try directLauncher.run(
                    tests: tests, environment: environment, timeout: timeout, in: copyRoot, logFile: logFile
                )
            }
            // Keep the baseline's coverage data.
            environment["LLVM_PROFILE_FILE"] = logDirectory.appendingPathComponent("mutant.profraw").path
            var arguments = testArguments(swift: swift, filter: filter)
            if let tests { arguments += TestSelection.filterArguments(tests) }
            return try ProcessRunner.run(
                arguments, in: copyRoot, environment: environment, timeout: timeout, logFile: logFile
            )
        case .custom(_, _, let testCommand):
            // Named after the log, so each run gets a path of its own.
            let resultBundle = resultBundleDirectory
                .appendingPathComponent(logFile.deletingPathExtension().lastPathComponent + ".xcresult")
            try? FileManager.default.removeItem(at: resultBundle)
            defer { if !keepResultBundle { try? FileManager.default.removeItem(at: resultBundle) } }
            return try ProcessRunner.runShell(
                CommandTemplate.expand(testCommand, tests: tests, job: job, resultBundle: resultBundle),
                in: copyRoot, environment: environment, timeout: timeout, logFile: logFile
            )
        }
    }

    private var resultBundleDirectory: URL { configuration.workDirectory.appendingPathComponent("results") }

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
