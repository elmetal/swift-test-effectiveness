import Foundation
import Testing
@testable import TestEffectivenessCore

struct TestSelectionTests {
    let suite = TestSelector(module: "AppTests", name: "StoreTests", isFunction: false)
    let function = TestSelector(module: "AppTests", name: "percent", isFunction: true)

    @Test func expandsPlaceholderToOnlyTestingArguments() {
        let command = "xcodebuild test-without-building -scheme App {only-testing}"
        #expect(TestSelection.expand(command, tests: [suite, function])
            == "xcodebuild test-without-building -scheme App '-only-testing:AppTests/StoreTests' '-only-testing:AppTests/percent()'")
        #expect(TestSelection.expand(command, tests: nil) == "xcodebuild test-without-building -scheme App ")
    }

    @Test func filterMatchesSwiftPMTestIdentifiers() throws {
        let arguments = TestSelection.filterArguments([suite, function])
        #expect(arguments.first == "--filter")
        let regex = try NSRegularExpression(pattern: arguments[1])
        func matches(_ id: String) -> Bool {
            regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) != nil
        }
        #expect(matches("AppTests.StoreTests/testFetch"))
        #expect(matches("AppTests.StoreTests"))
        #expect(matches("AppTests.percent()"))
        #expect(!matches("AppTests.StoreTestsExtra/testFetch"))
        #expect(!matches("AppTests.percentage()"))
        #expect(!matches("OtherTests.StoreTests/testFetch"))
    }

    @Test func wholeSuiteWhenNoTestOrEveryTestReachesTheMethod() {
        let all: Set = [suite, function]
        #expect(TestSelection.tests(reaching: nil, all: all) == nil)
        #expect(TestSelection.tests(reaching: [], all: all) == nil)
        #expect(TestSelection.tests(reaching: all, all: all) == nil)
        #expect(TestSelection.tests(reaching: [function], all: all) == [function])
    }

    @Test func quotesForTheShell() {
        #expect(TestSelection.shellQuoted("a'b") == "'a'\\''b'")
    }

    @Test func expandsJobAndResultBundle() {
        let command = "xcodebuild test-without-building -destination 'name=STE-{job}' -resultBundlePath {result-bundle} {only-testing}"
        let expanded = CommandTemplate.expand(
            command, tests: [suite], job: 3, resultBundle: URL(fileURLWithPath: "/w/results/mutant-7.xcresult")
        )
        #expect(expanded == "xcodebuild test-without-building -destination 'name=STE-3' "
            + "-resultBundlePath '/w/results/mutant-7.xcresult' '-only-testing:AppTests/StoreTests'")
    }
}
