import ArgumentParser
import Foundation
import TestEffectivenessCore

@main
struct SwiftTestEffectiveness: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-test-effectiveness",
        abstract: "Report, per method, what a Swift project's tests are missing.",
        discussion: """
        For each method the report says whether any test refers to it (from the compiler's \
        index), whether any test executes it (from code coverage) and whether any test checks \
        what it does (from extreme mutation: the body is replaced by the simplest behaviour for \
        its return type, such as an empty body, nil, true/false, 0/1, "" or []). A method that \
        tests execute but whose replacements all pass the tests is pseudo-tested.

        Swift packages are analyzed by default. For other projects (e.g. Xcode), pass \
        --source-dir, --build-command and --test-command.
        """,
        version: ToolVersion.current
    )

    @Argument(help: "Path to the project to analyze.")
    var projectPath: String = "."

    @Option(name: .customLong("target"), help: "Only analyze this SwiftPM target (repeatable).")
    var targets: [String] = []

    @Option(help: "Pass `--filter <pattern>` to `swift test`.")
    var testFilter: String?

    @Option(help: "The `swift` executable to use.")
    var swift: String = "swift"

    @Option(name: .customLong("source-dir"), help: "Custom mode: directory with production sources, relative to the project (repeatable).")
    var sourceDirectories: [String] = []

    @Option(help: "Custom mode: command that builds the project and its tests once.")
    var buildCommand: String?

    @Option(help: "Custom mode: command that runs the tests without building.")
    var testCommand: String?

    @Option(help: "Only analyze methods whose declaration overlaps lines changed since this git revision.")
    var since: String?

    @Option(name: .customLong("exclude"), help: "Skip source files whose path contains this string (repeatable).")
    var excludes: [String] = []

    @Flag(help: "Also generate a `throw` mutant for methods declared with untyped `throws`.")
    var throwMutants = false

    @Flag(help: "Also mutate each case of a switch that a method ends with, to find the cases no test verifies.")
    var caseMutants = false

    @Flag(help: "Also replace only what a method returns, where it does something before it returns: its statements run, and each `return` gives the simplest value. Finds results no test checks behind side effects that tests do check. With --case-mutants, for each case.")
    var returnMutants = false

    @Option(name: .customLong("default-value"), help: ArgumentHelp("Return this expression as the mutant of methods whose return type is written as this type, e.g. 'Money=.zero' (repeatable; several values for a type are a mutant each). The type is the whole type, its name without generic arguments, or the last component of that name.", valueName: "type=expression"))
    var defaultValues: [String] = []

    @Option(name: .customLong("closure"), help: ArgumentHelp("Also analyze the trailing closure of calls to this function like a method that returns this type, e.g. 'Handler=Command' (repeatable). The name is the last components of what is called: 'subscribe' also matches 'store.subscribe { … }'.", valueName: "name=type"))
    var closures: [String] = []

    @Flag(inversion: .prefixedNo, help: "Skip methods returning Void whose body only logs (print, os_log, logger.info(…), …).")
    var arid = true

    @Option(name: .customLong("arid-call"), help: "Also treat calls to this function as logging, e.g. `track` or `Analytics.shared.track` (repeatable).")
    var aridCalls: [String] = []

    @Flag(inversion: .prefixedNo, help: "Find out which methods the tests execute, and skip the mutants of the others (custom mode: from code coverage, which needs --coverage-profdata and --coverage-binary).")
    var coverage = true

    @Flag(inversion: .prefixedNo, help: "Read the compiler's index to report whether any test refers to each method directly.")
    var index = true

    @Option(help: "Index store for the referenced column; a relative path is resolved inside the copied project. SwiftPM: defaults to the one the build writes. Custom mode: required (e.g. build/Index.noindex/DataStore with -derivedDataPath build).")
    var indexStorePath: String?

    @Flag(inversion: .prefixedNo, help: "Run each mutant against the tests that reach its method first, and against the whole suite only if it survives them. Needs the index. Custom mode: put {only-testing} in --test-command where xcodebuild's -only-testing: arguments go. SwiftPM: not with --test-filter.")
    var testSelection = true

    @Flag(help: "Run a mutant that survives the tests that execute its method against the whole suite as well. By default it is not, when the test scopes that ran alone are every test of the suite.")
    var rerunSurvivors = false

    @Option(name: .customLong("coverage-profdata"), help: "Custom mode: the .profdata the test command writes with -enableCodeCoverage YES, or a directory to search for the newest one (e.g. build/Build/ProfileData with -derivedDataPath build). Relative to the copied project.")
    var coverageProfdata: String?

    @Option(name: .customLong("coverage-binary"), help: "Custom mode: a binary built with coverage, or a directory to search for binaries (e.g. build/Build/Products). Relative to the copied project (repeatable).")
    var coverageBinaries: [String] = []

    @Option(help: "Run this many test runs at once. SwiftPM: needs the tests to be started directly (the default). Custom mode: {job} in --test-command becomes the worker's number (1…N), e.g. for a simulator per worker; {result-bundle} becomes a fresh path for -resultBundlePath.")
    var jobs: Int = 1

    @Flag(inversion: .prefixedNo, help: "SwiftPM: after the baseline, start the test bundles directly instead of through `swift test`, which is faster and lets runs overlap (--jobs). Not with --test-filter.")
    var directLaunch = true

    @Flag(inversion: .prefixedNo, help: "SwiftPM, with the test bundles started directly: keep a process per worker and test bundle that runs the tests of one mutant after the other. A mutant counts as detected there when a test fails with it and passes again without it; every other run gets a process of its own.")
    var residentHost = true

    @Option(help: "Directory for the mutated copy and logs (default: <project>/.build/test-effectiveness).")
    var workDir: String?

    @Option(help: "Timeout of a test run as a multiple of what it is expected to take: the baseline's duration for the whole suite, and for selected tests the time they took when each test scope ran alone.")
    var timeoutFactor: Double = 3

    @Option(help: "The least a test run's timeout can be, in seconds (default: 30, or 5 when the test bundles of a Swift package are started directly).")
    var minimumTimeout: Double?

    @Option(help: "Report format: \(ReportFormat.allCases.map(\.rawValue).joined(separator: ", ")).")
    var format: String = ReportFormat.text.rawValue

    @Option(name: .shortAndLong, help: "Write the report to this file instead of standard output.")
    var output: String?

    @Flag(help: "Only list methods and their mutants; do not build or run tests.")
    var dryRun = false

    @Flag(help: "Exit with status 1 if any method is pseudo-tested.")
    var failOnPseudoTested = false

    @Flag(name: .shortAndLong, help: "Do not print progress to standard error.")
    var quiet = false

    mutating func validate() throws {
        guard ReportFormat(rawValue: format) != nil else {
            throw ValidationError("unknown format '\(format)'")
        }
        guard jobs >= 1 else { throw ValidationError("--jobs must be at least 1") }
        do {
            _ = try DefaultValues(parsing: defaultValues)
        } catch {
            throw ValidationError("--default-value: \(error)")
        }
        do {
            _ = try ClosureUnits(parsing: closures)
        } catch {
            throw ValidationError("--closure: \(error)")
        }
        let customOptions = [buildCommand, testCommand].compactMap { $0 }
        if !customOptions.isEmpty || !sourceDirectories.isEmpty {
            guard buildCommand != nil, testCommand != nil, !sourceDirectories.isEmpty else {
                throw ValidationError("custom mode needs --source-dir, --build-command and --test-command together")
            }
        }
    }

    func run() throws {
        ProcessRunner.forwardTerminationSignals()
        let projectURL = URL(fileURLWithPath: projectPath).standardizedFileURL
        let buildSystem: AnalysisConfiguration.BuildSystem
        if let buildCommand, let testCommand {
            buildSystem = .custom(sourceDirectories: sourceDirectories, buildCommand: buildCommand, testCommand: testCommand)
        } else {
            buildSystem = .swiftPM(swiftExecutable: swift, targets: targets, testFilter: testFilter)
        }
        let configuration = AnalysisConfiguration(
            projectPath: projectURL,
            workDirectory: workDir.map { URL(fileURLWithPath: $0) },
            buildSystem: buildSystem,
            useCoverage: coverage,
            useIndex: index,
            indexStorePath: indexStorePath,
            coverageProfilePath: coverageProfdata,
            coverageBinaryPaths: coverageBinaries,
            discovery: DiscoveryOptions(
                includeThrowMutants: throwMutants,
                arid: arid ? AridDetector(additionalCalls: aridCalls) : nil,
                caseMutants: caseMutants,
                defaultValues: try DefaultValues(parsing: defaultValues),
                closures: try ClosureUnits(parsing: closures),
                returnMutants: returnMutants
            ),
            changedSince: since,
            excludePathSubstrings: excludes,
            timeoutFactor: timeoutFactor,
            minimumTimeout: minimumTimeout,
            testSelection: testSelection,
            jobs: jobs,
            directLaunch: directLaunch,
            rerunSurvivors: rerunSurvivors,
            residentHost: residentHost
        )
        let quiet = self.quiet
        let analyzer = Analyzer(configuration: configuration) { message in
            guard !quiet else { return }
            FileHandle.standardError.write(Data((message + "\n").utf8))
        }

        do {
            if dryRun {
                try printPlan(analyzer)
                return
            }
            let report = try analyzer.run()
            let rendered = try Reporter.render(report, format: ReportFormat(rawValue: format)!)
            if let output {
                try rendered.write(toFile: output, atomically: true, encoding: .utf8)
            } else {
                print(rendered, terminator: "")
            }
            if failOnPseudoTested && !report.methods(.pseudoTested).isEmpty {
                throw ExitCode(1)
            }
        } catch let exit as ExitCode {
            throw exit
        } catch {
            // Every failure is status 2: ArgumentParser would exit with 1 for an error it does
            // not know, which is the status of `--fail-on-pseudo-tested`.
            let message = error is AnalysisError || error is ProcessRunnerError
                ? "\(error)" : error.localizedDescription
            FileHandle.standardError.write(Data("error: \(message)\n".utf8))
            throw ExitCode(2)
        }
    }

    private func printPlan(_ analyzer: Analyzer) throws {
        let (methods, skipped) = try analyzer.plan()
        for method in methods {
            let mutations = method.mutations.map(\.summary).joined(separator: ", ")
            print("\(method.info.file):\(method.info.declarationStart.line)  \(method.info.name)  [\(mutations)]")
            for discovered in method.cases where !discovered.mutations.isEmpty {
                let mutations = discovered.mutations.map(\.summary).joined(separator: ", ")
                print("    line \(discovered.line)  \(discovered.label)  [\(mutations)]")
            }
        }
        for skip in skipped {
            print("\(skip.method.file):\(skip.method.declarationStart.line)  \(skip.method.name)  (skipped: \(skip.reason))")
        }
        let caseMutants = methods.reduce(0) { $0 + $1.cases.reduce(0) { $0 + $1.mutations.count } }
        let ofCases = caseMutants > 0 ? " and \(caseMutants) of their cases" : ""
        print("\(methods.count) methods, \(methods.reduce(0) { $0 + $1.mutations.count }) mutants\(ofCases), \(skipped.count) skipped")
        if let hint = Reporter.defaultValueHint(skipped, analyzed: methods.map(\.info)) { print(hint) }
        if methods.isEmpty, let tests = analyzer.changedTestFiles, !tests.isEmpty {
            print("\(tests.count) changed test \(tests.count == 1 ? "file" : "files") not analyzed. "
                + Reporter.testChangesNotAnalyzedExplanation)
            for test in tests { print("  \(test)") }
        }
    }
}
