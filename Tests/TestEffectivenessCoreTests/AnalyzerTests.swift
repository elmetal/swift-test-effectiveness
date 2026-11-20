import Foundation
import Testing
@testable import TestEffectivenessCore

struct AnalyzerTests {
    /// Custom mode: a source directory inside another lists its files twice, and a method found
    /// twice would get two sets of mutants at the same place.
    @Test func sourceDirectoriesThatContainEachOtherListAFileOnce() throws {
        func methods(in directories: [String]) throws -> [String] {
            let configuration = AnalysisConfiguration(
                projectPath: IntegrationTests.fixturesRoot.appendingPathComponent("SampleProject"),
                buildSystem: .custom(sourceDirectories: directories, buildCommand: "true", testCommand: "true")
            )
            return try Analyzer(configuration: configuration).plan().methods.map(\.info.name)
        }
        let once = try methods(in: ["Sources"])
        #expect(!once.isEmpty)
        #expect(try methods(in: ["Sources", "Sources/Sample"]) == once)
    }

    /// A target the scheme builds but its test plan leaves out cannot be selected, and the baseline
    /// does not run it either: the scopes that can be selected are still the whole suite.
    @Test func scopesTheBaselineDoesNotRunEitherLeaveTheOthersTheWholeSuite() {
        #expect(Analyzer.RecordedReach.whyNotTheWholeSuite(
            scopesFailAlone: false, scopesCannotBeSelected: true, executedAlone: 40, baselineTests: 40
        ) == nil)
        #expect(Analyzer.RecordedReach.whyNotTheWholeSuite(
            scopesFailAlone: false, scopesCannotBeSelected: false, executedAlone: 40, baselineTests: 40
        ) == nil)
    }

    /// A target named differently from its module cannot be selected, but the baseline runs it:
    /// its tests are missing from what the scopes executed alone.
    @Test func scopesOnlyTheBaselineRunsAreNotTheWholeSuite() {
        #expect(Analyzer.RecordedReach.whyNotTheWholeSuite(
            scopesFailAlone: false, scopesCannotBeSelected: true, executedAlone: 32, baselineTests: 40
        ) == "the scopes executed 32 tests alone, the baseline 40; some test scopes cannot be selected")
        // A test the index and the test sources miss.
        #expect(Analyzer.RecordedReach.whyNotTheWholeSuite(
            scopesFailAlone: false, scopesCannotBeSelected: false, executedAlone: 39, baselineTests: 40
        ) == "the scopes executed 39 tests alone, the baseline 40")
    }

    /// Equal counts say nothing when a scope that fails alone is left out, or when the baseline's
    /// count is unknown (`0`).
    @Test func scopesFailingAloneOrAnUnknownBaselineAreNotTheWholeSuite() {
        #expect(Analyzer.RecordedReach.whyNotTheWholeSuite(
            scopesFailAlone: true, scopesCannotBeSelected: false, executedAlone: 40, baselineTests: 40
        ) == "some test scopes fail alone")
        #expect(Analyzer.RecordedReach.whyNotTheWholeSuite(
            scopesFailAlone: false, scopesCannotBeSelected: true, executedAlone: 0, baselineTests: 0
        ) == "the number of tests the baseline executed is unknown")
    }
}
