import Foundation
import Testing
@testable import TestEffectivenessCore

struct DirectTestLauncherTests {
    typealias Bundle = DirectTestLauncher.Bundle
    typealias Pass = DirectTestLauncher.Pass

    let app = Bundle(path: "/bin/AppTests.xctest", executable: "/bin/AppTests.xctest/Contents/MacOS/AppTests", module: "AppTests")
    let core = Bundle(path: "/bin/CoreTests.xctest", executable: "/bin/CoreTests.xctest/Contents/MacOS/CoreTests", module: "CoreTests")
    let combined = Bundle(path: "/bin/AppPackageTests.xctest", executable: "/bin/AppPackageTests.xctest/Contents/MacOS/AppPackageTests", module: nil)

    let storeTests = TestSelector(module: "AppTests", name: "StoreTests", isFunction: false)
    let percent = TestSelector(module: "AppTests", name: "percent", isFunction: true)
    let parserTests = TestSelector(module: "CoreTests", name: "ParserTests", isFunction: false)

    private func launcher(_ bundles: [Bundle], emptyPasses: Set<Pass> = []) -> DirectTestLauncher {
        DirectTestLauncher(
            xctest: "/tools/xctest", helper: "/tools/helper", bundles: bundles, environment: [:], emptyPasses: emptyPasses
        )
    }

    @Test func wholeSuiteRunsBothLibrariesOfEveryBundle() {
        let commands = launcher([app, core]).commands(for: nil)
        #expect(commands.map(\.arguments) == [
            ["/tools/xctest", app.path],
            ["/tools/helper", "--test-bundle-path", app.executable, app.executable, "--testing-library", "swift-testing"],
            ["/tools/xctest", core.path],
            ["/tools/helper", "--test-bundle-path", core.executable, core.executable, "--testing-library", "swift-testing"],
        ])
    }

    /// `xctest` would also run the Swift Testing tests, which then run twice and ignore `--filter`.
    @Test func xctestPassDisablesSwiftTesting() {
        let commands = launcher([app]).commands(for: nil)
        #expect(commands.map(\.environment) == [["SWIFT_TESTING_ENABLED": "0"], [:]])
    }

    @Test func selectionStartsOnlyTheBundlesOfTheSelectedModules() {
        let commands = launcher([app, core]).commands(for: [storeTests, percent])
        #expect(commands.map(\.pass.bundle) == [app, app])
        #expect(commands[0].arguments == ["/tools/xctest", "-XCTest", "AppTests.StoreTests", app.path])
        #expect(commands[1].arguments == [
            "/tools/helper", "--test-bundle-path", app.executable,
            "--filter", "^AppTests\\.StoreTests(/|$)|^AppTests\\.percent\\(",
            app.executable, "--testing-library", "swift-testing",
        ])
    }

    @Test func freeTestFunctionsNeedNoXCTestPass() {
        let commands = launcher([app, core]).commands(for: [percent])
        #expect(commands.map(\.pass) == [Pass(bundle: app, library: .swiftTesting)])
    }

    @Test func bundleWithEveryTargetGetsEverySelector() {
        let commands = launcher([combined]).commands(for: [parserTests, storeTests])
        #expect(commands[0].arguments == ["/tools/xctest", "-XCTest", "AppTests.StoreTests,CoreTests.ParserTests", combined.path])
        #expect(commands.count == 2)
    }

    @Test func passesWithoutTestsAreNotStarted() {
        let empty: Set<Pass> = [Pass(bundle: app, library: .xctest), Pass(bundle: core, library: .swiftTesting)]
        let launcher = launcher([app, core], emptyPasses: empty)
        #expect(launcher.commands(for: nil).map(\.pass) == [
            Pass(bundle: app, library: .swiftTesting), Pass(bundle: core, library: .xctest),
        ])
        #expect(launcher.commands(for: [storeTests, parserTests]).map(\.pass) == [
            Pass(bundle: app, library: .swiftTesting), Pass(bundle: core, library: .xctest),
        ])
    }

    @Test func swiftTestingWithoutMatchingTestsIsNotAFailure() {
        #expect(DirectTestLauncher.passed(.swiftTesting, exitCode: 0))
        #expect(DirectTestLauncher.passed(.swiftTesting, exitCode: 69))
        #expect(!DirectTestLauncher.passed(.swiftTesting, exitCode: 1))
        #expect(DirectTestLauncher.passed(.xctest, exitCode: 0))
        #expect(!DirectTestLauncher.passed(.xctest, exitCode: 1))
        #expect(!DirectTestLauncher.passed(.xctest, exitCode: 69))
    }

    @Test func moduleNameReplacesNonIdentifierCharacters() {
        #expect(DirectTestLauncher.moduleName("AppTests") == "AppTests")
        #expect(DirectTestLauncher.moduleName("app-kit Tests") == "app_kit_Tests")
        #expect(DirectTestLauncher.moduleName("3DTests") == "_DTests")
    }

    @Test func countsExecutedTestsOfBothLibraries() {
        let output = """
        Test Suite 'All tests' started at 2026-11-10 08:58:24.120.
        Test Case '-[ATests.AlphaTests testOne]' started.
        Test Case '-[ATests.AlphaTests testOne]' passed (0.001 seconds).
        Test Case '-[ATests.AlphaTests testTwo]' started.
        Test Case '-[ATests.AlphaTests testTwo]' failed (0.000 seconds).
        \t Executed 2 tests, with 1 failure (0 unexpected) in 0.001 (0.002) seconds
        􀟈  Test run started.
        􁁛  Test run with 2 tests in 1 suite passed after 0.001 seconds.
        ◇ Test run started.
        ✘ Test run with 1 test in 0 suites failed after 0.001 seconds with 1 issue.
        """
        #expect(TestOutput.executedTests(in: output) == 5)
        #expect(TestOutput.executedTests(in: "Build complete!") == 0)
    }
}

struct ProcessRunnerTests {
    /// Without a shell, the command still starts in the directory and gets the environment.
    @Test func runsWithoutShellInDirectory() throws {
        let directory = FileManager.default.temporaryDirectory
        let result = try ProcessRunner.run(
            ["/bin/sh", "-c", "pwd -P; echo $STE_TEST_VALUE; exit 3"], in: directory,
            environment: ["STE_TEST_VALUE": "from the environment"], withoutShell: true
        )
        #expect(result.exitCode == 3)
        #expect(!result.timedOut)
        let lines = result.output.split(separator: "\n").map(String.init)
        #expect(lines == [ReferenceColumn.realPath(directory.path), "from the environment"])
    }

    @Test func withoutShellStillTimesOut() throws {
        let result = try ProcessRunner.run(
            ["/bin/sleep", "30"], in: FileManager.default.temporaryDirectory, timeout: 0.2, withoutShell: true
        )
        #expect(result.timedOut)
        #expect(result.duration < 10)
    }
}
