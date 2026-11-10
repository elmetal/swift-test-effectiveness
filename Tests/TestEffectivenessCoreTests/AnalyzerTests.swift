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
}
