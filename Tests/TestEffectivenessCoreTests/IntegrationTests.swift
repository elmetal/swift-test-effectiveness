import Foundation
import Testing
@testable import TestEffectivenessCore

/// End-to-end runs against the packages in `Tests/Fixtures`. Slow (builds the fixture), so it only runs
/// when `STE_INTEGRATION=1`. Set `STE_SWIFT` to choose the `swift` executable.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["STE_INTEGRATION"] == "1"), .serialized)
struct IntegrationTests {
    /// `Tests/Fixtures`. It sits outside every target directory, so SwiftPM does not compile it.
    static let fixturesRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")
    static let swift = ProcessInfo.processInfo.environment["STE_SWIFT"] ?? "swift"

    private func analyze(
        _ fixture: String, throwMutants: Bool = false, caseMutants: Bool = false, testSelection: Bool = true,
        jobs: Int = 1, directLaunch: Bool = true, rerunSurvivors: Bool = false,
        minimumTimeout: Double? = 120,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> AnalysisReport {
        let project = Self.fixturesRoot.appendingPathComponent(fixture)
        let configuration = AnalysisConfiguration(
            projectPath: project,
            workDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ste-it-\(fixture)"),
            buildSystem: .swiftPM(swiftExecutable: Self.swift, targets: [], testFilter: nil),
            discovery: DiscoveryOptions(includeThrowMutants: throwMutants, caseMutants: caseMutants),
            minimumTimeout: minimumTimeout,
            testSelection: testSelection,
            jobs: jobs,
            directLaunch: directLaunch,
            rerunSurvivors: rerunSurvivors
        )
        return try Analyzer(configuration: configuration, log: log).run()
    }

    /// `Tests/Fixtures/HangingProject`: with `isDone` returning `false`, `count()` loops for ever.
    /// The run of the one test that calls it is stopped after the short timeout of selected
    /// tests started directly, not after the 30 seconds a run used to get at least.
    @Test func endlessLoopIsStoppedAfterTheTimeoutOfTheSelectedTests() throws {
        let messages = Messages()
        let report = try analyze("HangingProject", minimumTimeout: nil) { messages.append($0) }
        #expect(messages.all.contains { $0.hasPrefix("Starting the test bundles directly") })
        #expect(messages.all.contains { $0.hasSuffix("times what they took alone, at least 5s.") })
        let mutants = Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0.mutants) })
        let isDone = try #require(mutants["Counter.isDone(_:)"])
        #expect(isDone.map(\.outcome) == [.killed, .timedOut])
        let duration = try #require(isDone[1].duration)
        #expect(duration >= 5)
        #expect(duration < 15)
        #expect(mutants["Counter.count()"]?.map(\.outcome) == [.killed, .killed])
        #expect(mutants["Counter.label()"]?.map(\.outcome) == [.killed, .killed])
        let classification = Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0.classification) })
        #expect(classification["Counter.isDone(_:)"] == .tested)
    }

    /// The scopes of SampleProject and ReferencedProject are their whole suites, so a mutant that
    /// survives the scopes that execute its method is not run again. The outcomes are those of
    /// running the whole suite for it, and for every mutant.
    @Test(arguments: ["SampleProject", "ReferencedProject"])
    func survivorsOfTheTestsThatExecuteTheirMethodAreNotRerun(fixture: String) throws {
        func outcomes(_ report: AnalysisReport) -> [String: [MutantOutcome]] {
            Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0.mutants.map(\.outcome)) })
        }
        let messages = Messages()
        let exact = try analyze(fixture) { messages.append($0) }
        #expect(messages.all.contains { $0.hasPrefix("Recorded the methods each test scope executes. The scopes are the whole suite") })
        let summary = try #require(messages.all.first { $0.hasPrefix("Test selection:") })
        #expect(summary.contains("; 0 survived them and re-ran the whole suite;"))
        #expect(!summary.contains("; 0 survived them, which are every test"))

        let rerunMessages = Messages()
        let rerun = try analyze(fixture, rerunSurvivors: true) { rerunMessages.append($0) }
        let rerunSummary = try #require(rerunMessages.all.first { $0.hasPrefix("Test selection:") })
        #expect(rerunSummary.contains("; 0 survived them, which are every test"))
        #expect(!rerunSummary.contains("; 0 survived them and re-ran the whole suite;"))

        let whole = try analyze(fixture, testSelection: false)
        #expect(outcomes(exact) == outcomes(rerun))
        #expect(outcomes(exact) == outcomes(whole))
    }

    /// Starting the test bundles directly, also on several workers, gives the outcomes of
    /// `swift test`: with Swift Testing tests (SampleProject), XCTest tests (ReferencedProject)
    /// and a scope that fails alone (OrderDependentProject).
    @Test(arguments: ["SampleProject", "ReferencedProject", "OrderDependentProject"])
    func directLaunchKeepsOutcomes(fixture: String) throws {
        func outcomes(_ report: AnalysisReport) -> [String: [MutantOutcome]] {
            Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0.mutants.map(\.outcome)) })
        }
        let messages = Messages()
        let direct = try analyze(fixture, jobs: 4) { messages.append($0) }
        #expect(messages.all.contains { $0.hasPrefix("Starting the test bundles directly") })
        #expect(messages.all.contains { $0.hasSuffix("mutants with 4 jobs.") })

        let throughSwiftTest = Messages()
        let reference = try analyze(fixture, jobs: 4, directLaunch: false) { throughSwiftTest.append($0) }
        #expect(!throughSwiftTest.all.contains { $0.hasPrefix("Starting the test bundles directly") })
        #expect(throughSwiftTest.all.contains { $0.hasPrefix("--jobs needs the tests to be started directly") })

        #expect(outcomes(direct) == outcomes(reference))
        #expect(direct.testsFailingAlone?.map(\.test) == reference.testsFailingAlone?.map(\.test))
        #expect(direct.methods.map(\.executed) == reference.methods.map(\.executed))
    }

    @Test func sampleProjectClassification() throws {
        let report = try analyze("SampleProject")
        let classification = Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0.classification) })
        #expect(classification == [
            "Calculator.add(_:_:)": .tested,
            "Calculator.isPositive(_:)": .partiallyTested,
            "Calculator.greeting(for:)": .pseudoTested,
            "Calculator.record(_:)": .pseudoTested,
            "Calculator.firstNegative(in:)": .tested,
            "Calculator.unused()": .notCovered,
            "Calculator.isEmpty": .partiallyTested,
            "Calculator.doubled(_:)": .tested,
        ])
        #expect(report.skipped.map(\.method.name) == ["Calculator.dumpHistory()", "Calculator.pair()"])
        #expect(report.coverageAvailable)
        let executed = Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0.executed) })
        #expect(executed["Calculator.unused()"] == .notExecuted)
        #expect(report.methods.filter { $0.method.name != "Calculator.unused()" }.allSatisfy { $0.executed == .executed })
        #expect(report.referencesAvailable)
        let referenced = Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0.referenced) })
        #expect(referenced["Calculator.unused()"] == .notReferenced)
        #expect(report.methods.filter { $0.method.name != "Calculator.unused()" }.allSatisfy { $0.referenced == .referenced })
    }

    /// The referenced column on `Tests/Fixtures/ReferencedProject`: protocol and class dispatch,
    /// mock injection, a default implementation, setUp in the same XCTestCase.
    @Test func referencedColumn() throws {
        let report = try analyze("ReferencedProject")
        #expect(report.referencesAvailable)
        let referenced = Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0.referenced) })
        #expect(referenced == [
            "Repository.count()": .referenced,
            "SQLRepository.fetch(id:)": .referenced,
            "RemoteRepository.fetch(id:)": .notReferenced,
            "RemoteRepository.count()": .notReferenced,
            "UserService.name(of:)": .referenced,
            "UserService.normalized(_:)": .notReferenced,
            "UserService.isReady": .referenced,
            "Shape.area()": .referenced,
            "Square.area()": .referenced,
            "Circle.area()": .notReferenced,
            "Format.percent(_:)": .referenced,
            "Format.clamped(_:)": .notReferenced,
        ])
        let executed = Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0.executed) })
        // Referenced through the base type, but dispatch always reaches Square.area.
        #expect(executed["Shape.area()"] == .notExecuted)
        // Executed (and verified) only through Format.percent.
        #expect(executed["Format.clamped(_:)"] == .executed)
    }

    /// Test selection only changes which tests run first: the outcomes match running the whole
    /// suite for every mutant.
    @Test func testSelectionKeepsOutcomes() throws {
        let messages = Messages()
        let selected = try analyze("ReferencedProject") { messages.append($0) }
        let whole = try analyze("ReferencedProject", testSelection: false)
        func outcomes(_ report: AnalysisReport) -> [String: [MutantOutcome]] {
            Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0.mutants.map(\.outcome)) })
        }
        #expect(outcomes(selected) == outcomes(whole))
        let summary = messages.all.first { $0.hasPrefix("Test selection:") }
        #expect(summary != nil)
        #expect(summary?.hasPrefix("Test selection: 0 mutants detected") == false)
        #expect(selected.testsFailingAlone == [])
        #expect(whole.testsFailingAlone == nil)
    }

    /// `Tests/Fixtures/OrderDependentProject`: `LookupTests` passes only after another test has
    /// registered a name. It is reported, and not selected, so `Registry.summary()`, which only it
    /// reaches, keeps the outcomes of the whole suite instead of looking detected.
    @Test func testsFailingAloneAreReportedAndNotSelected() throws {
        let messages = Messages()
        let selected = try analyze("OrderDependentProject") { messages.append($0) }
        let whole = try analyze("OrderDependentProject", testSelection: false)
        func outcomes(_ report: AnalysisReport) -> [String: [MutantOutcome]] {
            Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0.mutants.map(\.outcome)) })
        }
        #expect(outcomes(selected) == outcomes(whole))
        let classification = Dictionary(uniqueKeysWithValues: selected.methods.map { ($0.method.name, $0.classification) })
        #expect(classification["Registry.summary()"] == .pseudoTested)
        #expect(selected.testsFailingAlone?.map(\.test) == ["RegistryTests/LookupTests"])
        #expect(selected.testsFailingAlone?.first?.timedOut == false)
        #expect(messages.all.contains { $0.hasPrefix("Test isolation: 1 test scope fails alone") })
        // The scopes that pass alone are not the whole suite, so no survivor is final without it.
        #expect(messages.all.contains { $0.hasSuffix("still runs the whole suite: some test scopes fail alone.") })
        #expect(messages.all.contains { $0.hasPrefix("Test selection:") && $0.contains("; 0 survived them, which are every test") })
        let text = try Reporter.render(selected, format: .text)
        #expect(text.contains("Tests that fail alone (1)"))
    }

    /// Custom mode with xcodebuild: coverage from the profile the baseline writes, the index the
    /// build writes, test selection through `{only-testing}`, and two jobs with a result bundle
    /// per run.
    @Test func customModeWithXcodebuild() throws {
        let project = Self.fixturesRoot.appendingPathComponent("ReferencedProject")
        let xcodebuild = "-scheme ReferencedProject-Package -destination platform=macOS "
            + "-derivedDataPath build -enableCodeCoverage YES -collect-test-diagnostics never -quiet"
        let configuration = AnalysisConfiguration(
            projectPath: project,
            workDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ste-it-custom"),
            buildSystem: .custom(
                sourceDirectories: ["Sources"],
                buildCommand: "xcodebuild build-for-testing \(xcodebuild)",
                testCommand: "xcodebuild test-without-building \(xcodebuild) -resultBundlePath {result-bundle} {only-testing}"
            ),
            indexStorePath: "build/Index.noindex/DataStore",
            coverageProfilePath: "build/Build/ProfileData",
            coverageBinaryPaths: ["build/Build/Products"],
            minimumTimeout: 120,
            jobs: 2
        )
        let messages = Messages()
        let report = try Analyzer(configuration: configuration) { messages.append($0) }.run()
        #expect(report.coverageAvailable)
        #expect(report.referencesAvailable)
        let executed = Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0.executed) })
        #expect(executed["Shape.area()"] == .notExecuted)
        #expect(executed["Circle.area()"] == .notExecuted)
        #expect(executed["Format.clamped(_:)"] == .executed)
        let classification = Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0.classification) })
        #expect(classification["RemoteRepository.count()"] == .notCovered)
        #expect(classification["Format.percent(_:)"] == .tested)
        // Each scope ran alone on the two workers.
        #expect(report.testsFailingAlone == [])
        #expect(messages.all.contains { $0.hasPrefix("Test selection:") && !$0.hasPrefix("Test selection: 0 mutants detected") })
    }

    /// `Tests/Fixtures/SwitchProject`: one test of one case detects every mutant of the whole body,
    /// so every method is `tested` until the cases are mutated one by one.
    @Test func caseMutantsFindTheCasesNoTestVerifies() throws {
        let whole = try analyze("SwitchProject")
        #expect(whole.methods.allSatisfy { $0.classification == .tested && $0.cases == nil })
        // A return type without a simplest value: nothing to replace the whole body with.
        #expect(whole.skipped.map(\.method.name) == ["LoadState.tint", "LoadState.severity(threshold:)"])

        let report = try analyze("SwitchProject", caseMutants: true)
        let methods = Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0) })
        #expect(report.methods.map(\.classification.rawValue).sorted() == [
            "partially-tested", "partially-tested", "partially-tested", "tested", "tested", "tested", "tested",
        ])
        #expect(report.skipped.isEmpty)
        func cases(_ name: String) -> [String] {
            (methods[name]?.cases ?? []).map { result in
                let outcomes = result.mutants.map(\.outcome.rawValue).joined(separator: ",")
                return "\(result.label): \(result.executed.rawValue) \(outcomes)"
            }
        }
        // A switch expression: the mutants are an `if` expression around each case.
        #expect(methods["Presenter.title(for:)"]?.classification == .partiallyTested)
        #expect(cases("Presenter.title(for:)") == [
            "case .idle: true killed,killed",
            "case .loading: false notRun,notRun",
            "case .loaded(let count): true survived,survived",
            "case .failed(let message): false notRun,notRun",
        ])
        // A mutant that returns what the case returns is left out.
        #expect(cases("Presenter.isBusy(_:)") == [
            "case .loading: true killed", "case .idle, .loaded, .failed: true killed",
        ])
        #expect(cases("Presenter.badge(for:)") == [
            "case .loaded(let count): true killed,killed", "case .failed: true killed", "default: true killed",
        ])
        #expect(cases("Presenter.retryDelay(for:)") == ["case .failed: true killed"])
        // `case .noop` does nothing to begin with.
        #expect(methods["Counter.handle(_:)"]?.classification == .partiallyTested)
        #expect(cases("Counter.handle(_:)") == [
            "case .increment: true killed", "case .decrement: true survived", "case .reset: false notRun",
        ])
        // Methods without mutants of their own: each case does what another case does. The last
        // case cannot fall through, and executes the statements of the first.
        #expect(methods["LoadState.tint"]?.classification == .partiallyTested)
        #expect(methods["LoadState.tint"]?.mutants == [])
        #expect(methods["LoadState.tint"]?.executed == .executed)
        #expect(cases("LoadState.tint") == [
            "case .idle: true killed", "case .loading: true survived", "case .loaded: false notRun",
            "case .failed: true killed",
        ])
        // `case .idle` and `default` do the same, and no other case can stand in for them.
        #expect(methods["LoadState.severity(threshold:)"]?.classification == .tested)
        #expect(cases("LoadState.severity(threshold:)") == [
            "case .loaded(let count) where count > threshold: true killed", "case .failed(let message): true killed",
        ])
    }

    /// The schema of every construct in `Tests/Fixtures/EdgeCases` must compile and the baseline must pass.
    @Test func edgeCasesCompile() throws {
        let report = try analyze("EdgeCases", throwMutants: true)
        #expect(report.methods.count > 20)
        // Compiled out: reported as not analyzed, not as pseudo-tested.
        let neverCompiled = report.skipped.first { $0.method.name.hasSuffix(".neverCompiled()") }
        #expect(neverCompiled?.reason == Analyzer.notCompiledReason)
        #expect(!report.methods.contains { $0.method.name.hasSuffix(".neverCompiled()") })
        // `#if DEBUG` is active in a debug build and must still be analysed.
        #expect(report.methods.contains { $0.method.name.hasSuffix(".debugOnly()") })
        #if canImport(SwiftUI)
        // `some View` outside a result builder: the mutant renders nothing, and a `throw` mutant may follow it.
        let classification = Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0.classification) })
        #expect(classification["Greeting.severalReturns(_:)"] == .tested)
        #expect(classification["Greeting.badge(_:)"] == .tested)
        #expect(classification["Greeting.explicitGetter"] == .tested)
        #expect(classification["Tally.next()"] == .tested)
        // A `var body` that returns explicitly is not a result builder body.
        #expect(classification["Returning.body"] == .tested)
        #expect(classification["Greeting.header"] == .pseudoTested)
        #expect(classification["Greeting.plain()"] == .pseudoTested)
        #expect(classification["Greeting.asyncThrowing()"] == .partiallyTested)
        #expect(classification["Card.body(content:)"] == .notCovered)
        let rethrowing = report.skipped.first { $0.method.name == "Greeting.rethrowing(_:)" }
        #expect(rethrowing?.reason == "`some View` returned from a `rethrows` function")
        #endif
    }
}

final class Messages: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func append(_ message: String) {
        lock.withLock { messages.append(message) }
    }

    var all: [String] { lock.withLock { messages } }
}
