import ArgumentParser
import Foundation
import TestEffectivenessCore

@main
struct SwiftTestEffectiveness: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "swift-test-effectiveness",
        abstract: "Find pseudo-tested methods in a Swift project with extreme mutation analysis.",
        discussion: """
        Each method body is replaced by the simplest possible behaviour for its return type \
        (empty body, nil, true/false, 0/1, "", [] …). A method whose replacements are not \
        detected by any test is pseudo-tested: tests execute it but do not check what it does.

        Swift packages are analyzed by default. For other projects (e.g. Xcode), pass \
        --source-dir, --build-command and --test-command.
        """
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

    @Flag(inversion: .prefixedNo, help: "Use code coverage to skip mutants of methods no test executes (SwiftPM only).")
    var coverage = true

    @Option(help: "Directory for the mutated copy and logs (default: <project>/.build/test-effectiveness).")
    var workDir: String?

    @Option(help: "Per-mutant timeout as a multiple of the baseline test duration.")
    var timeoutFactor: Double = 3

    @Option(help: "Minimum per-mutant timeout in seconds.")
    var minimumTimeout: Double = 30

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
        let customOptions = [buildCommand, testCommand].compactMap { $0 }
        if !customOptions.isEmpty || !sourceDirectories.isEmpty {
            guard buildCommand != nil, testCommand != nil, !sourceDirectories.isEmpty else {
                throw ValidationError("custom mode needs --source-dir, --build-command and --test-command together")
            }
        }
    }

    func run() throws {
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
            discovery: DiscoveryOptions(includeThrowMutants: throwMutants),
            changedSince: since,
            excludePathSubstrings: excludes,
            timeoutFactor: timeoutFactor,
            minimumTimeout: minimumTimeout
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
        } catch let error as AnalysisError {
            FileHandle.standardError.write(Data("error: \(error)\n".utf8))
            throw ExitCode(2)
        }
    }

    private func printPlan(_ analyzer: Analyzer) throws {
        let (methods, skipped) = try analyzer.plan()
        for method in methods {
            let mutations = method.mutations.map(\.summary).joined(separator: ", ")
            print("\(method.info.file):\(method.info.declarationStart.line)  \(method.info.name)  [\(mutations)]")
        }
        for skip in skipped {
            print("\(skip.method.file):\(skip.method.declarationStart.line)  \(skip.method.name)  (skipped: \(skip.reason))")
        }
        print("\(methods.count) methods, \(methods.reduce(0) { $0 + $1.mutations.count }) mutants, \(skipped.count) skipped")
    }
}
