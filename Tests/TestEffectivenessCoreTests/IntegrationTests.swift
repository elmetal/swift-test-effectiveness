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

    private func analyze(_ fixture: String, throwMutants: Bool = false) throws -> AnalysisReport {
        let project = Self.fixturesRoot.appendingPathComponent(fixture)
        let configuration = AnalysisConfiguration(
            projectPath: project,
            workDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("ste-it-\(fixture)"),
            buildSystem: .swiftPM(swiftExecutable: Self.swift, targets: [], testFilter: nil),
            discovery: DiscoveryOptions(includeThrowMutants: throwMutants),
            minimumTimeout: 120
        )
        return try Analyzer(configuration: configuration).run()
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
        #expect(report.skipped.map(\.method.name) == ["Calculator.pair()"])
        #expect(report.coverageAvailable)
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
