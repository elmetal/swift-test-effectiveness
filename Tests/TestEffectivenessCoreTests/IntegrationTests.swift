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
        _ fixture: String, throwMutants: Bool = false, caseMutants: Bool = false, defaultValues: [String] = [], closures: [String] = [],
        returnMutants: Bool = false,
        testSelection: Bool = true,
        jobs: Int = 1, directLaunch: Bool = true, rerunSurvivors: Bool = false, residentHost: Bool = true,
        minimumTimeout: Double? = 120, workDirectory: URL? = nil,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> AnalysisReport {
        let project = Self.fixturesRoot.appendingPathComponent(fixture)
        let configuration = AnalysisConfiguration(
            projectPath: project,
            workDirectory: workDirectory
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("ste-it-\(fixture)"),
            buildSystem: .swiftPM(swiftExecutable: Self.swift, targets: [], testFilter: nil),
            discovery: DiscoveryOptions(
                includeThrowMutants: throwMutants, caseMutants: caseMutants,
                defaultValues: try DefaultValues(parsing: defaultValues), closures: try ClosureUnits(parsing: closures),
                returnMutants: returnMutants
            ),
            minimumTimeout: minimumTimeout,
            testSelection: testSelection,
            jobs: jobs,
            directLaunch: directLaunch,
            rerunSurvivors: rerunSurvivors,
            residentHost: residentHost
        )
        return try Analyzer(configuration: configuration, log: log).run()
    }

    /// A second run in a work directory does not ask again what the first one found out: it does
    /// not build a copy that did not change, and its baseline is a run of the test bundles started
    /// directly instead of `swift test`. Its report is the first run's. A file of the copy that
    /// differs from the project's is copied again, and then the copy is built.
    @Test func secondRunInAWorkDirectoryNeitherBuildsNorRunsSwiftTest() throws {
        let workDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("ste-it-rerun")
        try? FileManager.default.removeItem(at: workDirectory)
        defer { try? FileManager.default.removeItem(at: workDirectory) }
        func summary(_ report: AnalysisReport) -> [String] {
            report.methods.map {
                "\($0.method.name) \($0.classification) \($0.executed) \($0.referenced) \($0.mutants.map(\.outcome))"
            } + report.skipped.map { "\($0.method.name): \($0.reason)" }
        }
        let notBuilding = "Not building: nothing in the copy changed since it was built."
        let directBaseline = "Starting the test bundles directly, as for the baseline"

        let firstMessages = Messages()
        let first = try analyze("SampleProject", workDirectory: workDirectory) { firstMessages.append($0) }
        #expect(firstMessages.all.contains("Building mutant schema…"))
        #expect(firstMessages.all.contains { $0.hasPrefix("Starting the test bundles directly from here on") })

        let secondMessages = Messages()
        let second = try analyze("SampleProject", workDirectory: workDirectory) { secondMessages.append($0) }
        #expect(secondMessages.all.contains(notBuilding))
        #expect(!secondMessages.all.contains("Building mutant schema…"))
        #expect(secondMessages.all.contains { $0.hasPrefix(directBaseline) })
        #expect(summary(second) == summary(first))
        #expect(second.coverageAvailable)

        let manifest = workDirectory.appendingPathComponent("project/Package.swift")
        try FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: manifest.path)
        let thirdMessages = Messages()
        let third = try analyze("SampleProject", workDirectory: workDirectory) { thirdMessages.append($0) }
        #expect(thirdMessages.all.contains("Building mutant schema…"))
        #expect(!thirdMessages.all.contains(notBuilding))
        #expect(thirdMessages.all.contains { $0.hasPrefix(directBaseline) })
        #expect(summary(third) == summary(first))
    }

    /// The numbers of the log line about the kept test processes: runs that found their mutant
    /// detected there, and those left to processes of their own, by what the kept process said.
    private func keptProcesses(_ messages: Messages) throws -> (detected: Int, passed: Int, timedOut: Int, ended: Int, failedAgain: Int) {
        let line = try #require(messages.all.first { $0.hasPrefix("Kept test processes:") })
        let match = try #require(line.firstMatch(
            of: #/: (\d+) runs found .* \((\d+) passed there, (\d+) timed out, (\d+) ended the process, (\d+) failed again/#
        ))
        return (Int(match.1)!, Int(match.2)!, Int(match.3)!, Int(match.4)!, Int(match.5)!)
    }

    /// A process that runs the tests of one mutant after the other gives the outcomes of a
    /// process for every run: with Swift Testing tests (SampleProject), XCTest tests
    /// (ReferencedProject, OrderDependentProject) and mutants of cases (SwitchProject).
    @Test(arguments: ["SampleProject", "ReferencedProject", "OrderDependentProject", "SwitchProject"])
    func keptTestProcessesKeepOutcomes(fixture: String) throws {
        func summary(_ report: AnalysisReport) -> [String] {
            report.methods.map { method in
                "\(method.method.name) \(method.classification) \(method.executed) \(method.mutants.map(\.outcome)) "
                    + "\((method.cases ?? []).map { "\($0.label) \($0.mutants.map(\.outcome))" })"
            }
        }
        let messages = Messages()
        let kept = try analyze(fixture, caseMutants: true, jobs: 2) { messages.append($0) }
        #expect(messages.all.contains { $0.hasPrefix("Keeping a test process per worker and test bundle") })
        #expect(try keptProcesses(messages).detected > 0)

        let perRunMessages = Messages()
        let perRun = try analyze(fixture, caseMutants: true, jobs: 2, residentHost: false) { perRunMessages.append($0) }
        #expect(!perRunMessages.all.contains { $0.contains("test process") })
        #expect(summary(kept) == summary(perRun))
        #expect(kept.testsFailingAlone?.map(\.test) == perRun.testsFailingAlone?.map(\.test))
    }

    /// `Tests/Fixtures/SharedStateProject`: state that outlives a test. A kept process says that
    /// a mutant is detected only when a test fails with it and passes again without it; the rest
    /// is left to a process of its own, so the outcomes are those of a process for every run.
    ///
    /// - `Phrase.makeSeparator()` is only called when `Phrase.separator` is first read, which the
    ///   mutants of `Phrase.join(_:)` made the kept process do: its mutants pass there.
    /// - `invitedGuestIsOnTheList()` passes once in a process, so once the kept process has run
    ///   it, it fails there again without the mutant.
    @Test func keptTestProcessesLeaveWhatSharedStateDecidesToAProcessOfItsOwn() throws {
        let messages = Messages()
        let kept = try analyze("SharedStateProject") { messages.append($0) }
        let outcomes = Dictionary(uniqueKeysWithValues: kept.methods.map { ($0.method.name, $0.mutants.map(\.outcome)) })
        #expect(outcomes == [
            "Phrase.join(_:)": [.killed, .killed],
            "Phrase.makeSeparator()": [.killed, .killed],
            "Guests.invite(_:)": [.killed],
            "Guests.isInvited(_:)": [.survived, .killed],
            "Guests.count": [.killed, .survived],
        ])
        let numbers = try keptProcesses(messages)
        // Both mutants of `join` and the one of `invite`.
        #expect(numbers.detected == 3)
        // Both mutants of `makeSeparator`, and the one of `count` that survives.
        #expect(numbers.passed == 3)
        // Both mutants of `isInvited`, and the other one of `count`.
        #expect(numbers.failedAgain == 3)
        #expect(numbers.timedOut == 0 && numbers.ended == 0)

        let perRun = try analyze("SharedStateProject", residentHost: false)
        #expect(Dictionary(uniqueKeysWithValues: perRun.methods.map { ($0.method.name, $0.mutants.map(\.outcome)) }) == outcomes)
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

    /// `Tests/Fixtures/SwitchProject`: with a value for their return types, the methods that had no
    /// mutant of their own are mutated like the others, and so are their cases.
    @Test func defaultValuesGiveMethodsAndTheirCasesMutantsThatReturnThem() throws {
        let defaultValues = ["Tint=.gray", "Severity=Severity(level: 0)"]
        let whole = try analyze("SwitchProject", defaultValues: defaultValues)
        #expect(whole.skipped.isEmpty)
        #expect(whole.methods.allSatisfy { $0.classification == .tested && $0.cases == nil })

        let report = try analyze("SwitchProject", caseMutants: true, defaultValues: defaultValues)
        let methods = Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0) })
        func cases(_ name: String) -> [String] {
            (methods[name]?.cases ?? []).map { result in
                let outcomes = result.mutants.map { "\($0.mutant.mutation.summary) \($0.outcome.rawValue)" }
                return "\(result.label): \(result.executed.rawValue) \(outcomes.joined(separator: ","))"
            }
        }
        // A test asserts the tint of `.failed`, so the mutant of the whole body is detected.
        // `case .idle` returns the value already, and has no mutant.
        #expect(methods["LoadState.tint"]?.mutants.map(\.outcome) == [.killed])
        #expect(methods["LoadState.tint"]?.classification == .partiallyTested)
        #expect(cases("LoadState.tint") == [
            "case .loading: true `return .gray` survived", "case .loaded: false `return .gray` notRun",
            "case .failed: true `return .gray` killed",
        ])
        // `case .idle` and `default` return the value already.
        #expect(methods["LoadState.severity(threshold:)"]?.mutants.map(\.outcome) == [.killed])
        #expect(methods["LoadState.severity(threshold:)"]?.classification == .tested)
        #expect(cases("LoadState.severity(threshold:)") == [
            "case .loaded(let count) where count > threshold: true `return Severity(level: 0)` killed",
            "case .failed(let message): true `return Severity(level: 0)` killed",
        ])
    }

    /// `Tests/Fixtures/ClosureProject`: where a body changes state and then returns a value, a test
    /// of the state detects the mutant that leaves at the start, whatever becomes of the value.
    @Test func returnMutantsFindTheResultsNoTestChecks() throws {
        let report = try analyze(
            "ClosureProject", caseMutants: true, defaultValues: ["Command=.none"], closures: ["Handler=Command"],
            returnMutants: true
        )
        func outcomes(_ mutants: [MutantResult]) -> String {
            mutants.map { "\($0.mutant.mutation.summary) \($0.outcome.rawValue)" }.joined(separator: ", ")
        }
        func cases(_ name: String) -> [String] {
            (report.methods.first { $0.method.name == name }?.cases ?? []).map { "\($0.label): \(outcomes($0.mutants))" }
        }
        #expect(cases("Outbox.handler, Handler { }") == [
            // The state and the command are asserted.
            "case .received: `return .none` killed, `return .none` after its statements killed",
            // Only the state is: the case can return anything.
            "case .opened: `return .none` killed, `return .none` after its statements survived",
            // Nothing is.
            "case .refreshed: `return .none` survived, `return .none` after its statements survived",
        ])
        #expect(cases("Inbox.handler, Handler { }") == [
            // Returns the value already: nothing to replace.
            "case .received: `return .none` killed",
            "case .opened: `return .none` survived, `return .none` after its statements survived",
            "case .muted: `return .none` notRun, `return .none` after its statements notRun",
            // Does nothing before it returns.
            "case .refreshed: `return .none` killed",
        ])

        // A method: the state is asserted, the result never.
        let send = try #require(report.methods.first { $0.method.name == "Outbox.send(_:in:)" })
        #expect(outcomes(send.mutants) == "`return true` killed, `return false` killed, "
            + "`return true` after its statements survived, `return false` after its statements survived")
        #expect(send.classification == .partiallyTested)

        let text = try Reporter.render(report, format: .text)
        #expect(text.contains("→ In `case .opened` (line 188), `Outbox.handler, Handler { }` can `return .none` after the "
            + "statements of the case without any test failing: tests check what the case changes, not what it returns. "
            + "Assert the result."))
        // Where leaving at the start survived as well, that is what is said.
        #expect(text.contains("→ In `case .refreshed` (line 191), `Outbox.handler, Handler { }` can `return .none` "
            + "without any test failing."))
        #expect(text.contains("→ `Outbox.send(_:in:)` can do what it does and then return `false` without any test failing: "
            + "tests check what it changes, not what it returns. Assert the value it returns."))

        // Without the option, the same run finds nothing in these two.
        let without = try analyze(
            "ClosureProject", caseMutants: true, defaultValues: ["Command=.none"], closures: ["Handler=Command"]
        )
        #expect(without.methods.first { $0.method.name == "Outbox.send(_:in:)" }?.classification == .tested)
        #expect(without.methods.first { $0.method.name == "Outbox.handler, Handler { }" }?.cases?
            .first { $0.label == "case .opened" }?.isVerified == true)
    }

    /// `Tests/Fixtures/ClosureProject`: logic written as closures. The methods that make them have
    /// no mutant, so nothing is found until the closures are methods of their own.
    @Test func closuresOfNamedCallsAreAnalyzedLikeMethods() throws {
        let unnamed = try analyze("ClosureProject", caseMutants: true)
        #expect(unnamed.methods.map(\.method.name) == [
            "Feed.subscribe(_:)", "Feed.post(_:)", "Recorder.record(_:)", "Recorder.mute(_:)", "Outbox.send(_:in:)",
        ])
        #expect(unnamed.methods.allSatisfy { $0.classification == .tested })
        #expect(unnamed.skipped.map(\.method.name) == [
            "Inbox.handler", "Archive.handler()", "Archive.refreshing", "Rules.positive", "Rules.all(_:)",
            "Archive.count(of:)", "Archive.idle", "Recorder.reset()", "Outbox.handler",
        ])
        // An empty body has no mutant a test could detect.
        #expect(unnamed.skipped.first { $0.method.name == "Recorder.reset()" }?.reason == "body does nothing, like its mutant")

        let report = try analyze(
            "ClosureProject", caseMutants: true, defaultValues: ["Command=.none"],
            closures: ["Handler=Command", ".init=Command", "subscribe=Void", "Rule=Bool", "allSatisfy=Bool", "Job=Int"]
        )
        // The methods are still not analyzed themselves.
        #expect(report.skipped.filter { $0.method.kind != .closure }.map(\.method.name) == unnamed.skipped.map(\.method.name))
        // Neither a closure that only returns the value nor one that does nothing has a mutant a
        // test could detect.
        #expect(report.skipped.filter { $0.method.kind == .closure }.map { "\($0.method.name) (\($0.method.declarationStart.line)): \($0.reason)" } == [
            "Archive.idle, Handler { } (154): body only returns the value of its mutant (`return .none`)",
            "Recorder.mute(_:), subscribe { } (163): body does nothing, like its mutant",
        ])
        // They only make the closures, so no value for their types is asked for.
        #expect(Reporter.defaultValueHint(unnamed.skipped, analyzed: unnamed.methods.map(\.method))?.hasSuffix(
            ": `Handler` (5 methods), `Rule` (2 methods) and `Job` (1 method)."
        ) == true)
        #expect(Reporter.defaultValueHint(report.skipped, analyzed: report.methods.map(\.method)) == nil)
        let closures = report.methods.filter { $0.method.kind == .closure }
        let summary = closures.map { result in
            "\(result.method.name) (\(result.method.declarationStart.line)): \(result.classification.rawValue) "
                + result.mutants.map { "\($0.mutant.mutation.summary) \($0.outcome.rawValue)" }.joined(separator: ",")
        }
        #expect(summary == [
            "Inbox.handler, Handler { } (42): partially-tested `return .none` killed",
            "Archive.handler(), Handler { } (68): partially-tested `return .none` killed",
            // One expression, returned implicitly.
            "Archive.refreshing, init { } (79): tested `return .none` killed",
            "Recorder.record(_:), subscribe { } #1 (105): tested empty body killed",
            // No test reads what it counts.
            "Recorder.record(_:), subscribe { } #2 (108): pseudo-tested empty body survived",
            // Without a signature.
            "Rules.positive, Rule { } (122): tested `return true` killed,`return false` killed",
            // A closure and the closure in it.
            "Rules.all(_:), Rule { } (126): tested `return true` killed,`return false` killed",
            "Rules.all(_:), allSatisfy { } (127): tested `return true` killed,`return false` killed",
            // `async throws`.
            "Archive.count(of:), Job { } (143): tested `return 0` killed,`return 1` killed",
            // `.refreshed` runs without an assertion.
            "Outbox.handler, Handler { } (183): partially-tested `return .none` killed",
        ])
        // Whether tests execute a closure is known for the closure itself. No test can refer to it.
        #expect(closures.allSatisfy { $0.referenced == .unknown && $0.executed == .executed })

        func cases(_ line: Int) -> [String] {
            (closures.first { $0.method.declarationStart.line == line }?.cases ?? []).map { result in
                "\(result.label): \(result.executed.rawValue) \(result.mutants.map(\.outcome.rawValue).joined(separator: ","))"
            }
        }
        // A switch statement. `case .ignored` returns the value already.
        #expect(cases(42) == [
            "case .received: true killed", "case .opened: true survived", "case .muted: false notRun",
            "case .refreshed: true killed",
        ])
        // A switch expression. `default` returns the value already.
        #expect(cases(68) == ["case .received: true killed", "case .opened: true survived"])
        // The other methods are what they were.
        #expect(report.methods.filter { $0.method.kind != .closure }.map(\.method.name) == unnamed.methods.map(\.method.name))
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
        // A body that is one `#if` block: each clause returns implicitly. One mutant of each is
        // what the active clause returns already, and survives.
        let ifConfig = Dictionary(uniqueKeysWithValues: report.methods.map { ($0.method.name, $0.classification) })
        #expect(ifConfig["Edge.isDebug"] == .partiallyTested)
        #expect(ifConfig["Edge.level()"] == .partiallyTested)
        let afterBlock = report.skipped.first { $0.method.name == "Edge.afterInactiveBlock()" }
        #expect(afterBlock?.reason == "`#if` in the body decides whether its value is returned implicitly")
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
