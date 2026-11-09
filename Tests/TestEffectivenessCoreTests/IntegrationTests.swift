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
        _ fixture: String, throwMutants: Bool = false, testSelection: Bool = true,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) throws -> AnalysisReport {
        let project = Self.fixturesRoot.appendingPathComponent(fixture)
        let configuration = AnalysisConfiguration(
            projectPath: project,
            workDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ste-it-\(fixture)"),
            buildSystem: .swiftPM(swiftExecutable: Self.swift, targets: [], testFilter: nil),
            discovery: DiscoveryOptions(includeThrowMutants: throwMutants),
            minimumTimeout: 120,
            testSelection: testSelection
        )
        return try Analyzer(configuration: configuration, log: log).run()
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
    }

    /// Custom mode with xcodebuild: coverage from the profile the baseline writes, the index the
    /// build writes, and test selection through `{only-testing}`.
    @Test func customModeWithXcodebuild() throws {
        let project = Self.fixturesRoot.appendingPathComponent("ReferencedProject")
        let xcodebuild = "-scheme ReferencedProject-Package -destination platform=macOS "
            + "-derivedDataPath build -enableCodeCoverage YES -quiet"
        let configuration = AnalysisConfiguration(
            projectPath: project,
            workDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ste-it-custom"),
            buildSystem: .custom(
                sourceDirectories: ["Sources"],
                buildCommand: "xcodebuild build-for-testing \(xcodebuild)",
                testCommand: "xcodebuild test-without-building \(xcodebuild) {only-testing}"
            ),
            indexStorePath: "build/Index.noindex/DataStore",
            coverageProfilePath: "build/Build/ProfileData",
            coverageBinaryPaths: ["build/Build/Products"],
            minimumTimeout: 120
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
        #expect(messages.all.contains { $0.hasPrefix("Test selection:") && !$0.hasPrefix("Test selection: 0 mutants detected") })
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
