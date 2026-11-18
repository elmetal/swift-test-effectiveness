import Foundation
import Testing
@testable import TestEffectivenessCore

/// A directory with a script that stands in for the test host, removed when the test ends.
///
/// The script answers by the mutant of the request: 11 is detected, 12 passes, 13 fails again
/// without the mutant, 14 ends the process, 15 never answers. It appends a line to `starts` every
/// time it starts.
private final class FakeHost {
    let root: URL
    var executable: URL { root.appendingPathComponent("host.sh") }
    var starts: URL { root.appendingPathComponent("starts") }
    var logs: URL { root.appendingPathComponent("logs") }

    init(ready: String = #"{"ready":true}"#) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("ste-host-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let script = """
            #!/bin/sh
            echo "$1" >> '\(starts.path)'
            echo '\(ready)'
            while IFS= read -r line; do
              case "$line" in
                *'"mutant":11'*) echo '{"outcome":"killed","executed":2}' ;;
                *'"mutant":12'*) echo '{"outcome":"passed","executed":2}' ;;
                *'"mutant":13'*) echo '{"outcome":"polluted","executed":2}' ;;
                *'"mutant":14'*) exit 3 ;;
                *'"mutant":15'*) sleep 30 ;;
                *) echo 'what?' ;;
              esac
            done
            """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    }

    deinit { try? FileManager.default.removeItem(at: root) }

    /// The bundles the script was started for, in order.
    var startedFor: [String] {
        ((try? String(contentsOf: starts, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }
}

struct ResidentHostTests {
    private func request(_ mutant: Int) -> ResidentRequest {
        ResidentRequest(mutant: mutant, xctest: nil, testing: [], log: "/dev/null")
    }

    private func start(_ fake: FakeHost) throws -> ResidentHost {
        try ResidentHost.start(
            executable: fake.executable.path, bundle: "/bin/Tests", environment: [:], in: fake.root,
            errorLog: fake.logs.appendingPathComponent("host.log")
        )
    }

    @Test func answersOneRequestAfterTheOtherInOneProcess() throws {
        let fake = try FakeHost()
        let host = try start(fake)
        defer { host.stop() }
        #expect(host.run(request(11), timeout: 10) == .killed)
        #expect(host.run(request(12), timeout: 10) == .passed)
        #expect(host.run(request(13), timeout: 10) == .polluted)
        #expect(host.run(request(11), timeout: 10) == .killed)
        #expect(fake.startedFor == ["/bin/Tests"])
    }

    @Test func aHostThatEndsDoesNotAnswerAgain() throws {
        let fake = try FakeHost()
        let host = try start(fake)
        #expect(host.run(request(14), timeout: 10) == .died)
        #expect(host.run(request(11), timeout: 10) == .died)
    }

    @Test func aHostThatDoesNotAnswerInTimeIsStopped() throws {
        let fake = try FakeHost()
        let host = try start(fake)
        let start = Date()
        #expect(host.run(request(15), timeout: 0.3) == .timedOut)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(host.run(request(11), timeout: 10) == .died)
    }

    /// Whatever the host does after a line that is no answer is not to be relied on.
    @Test func anAnswerThatIsNoneStopsTheHost() throws {
        let fake = try FakeHost()
        let host = try start(fake)
        #expect(host.run(request(99), timeout: 10) == .died)
    }

    @Test func aHostThatCannotLoadTheBundleIsUnavailable() throws {
        let fake = try FakeHost(ready: #"{"error":"image not found"}"#)
        #expect { try start(fake) } throws: { error in
            "\(error)".contains("could not load /bin/Tests: image not found")
        }
    }

    @Test func repliesAreReadFromJSONLines() {
        #expect(ResidentHost.Reply(#"{"ready":true}"#)?.ready == true)
        let reply = ResidentHost.Reply(#"{"executed":3,"outcome":"killed"}"#)
        #expect(reply?.outcome == "killed")
        #expect(reply?.executed == 3)
        #expect(ResidentHost.Reply("Test run started.") == nil)
    }

    /// The host decodes these names (`ResidentHostSource`).
    @Test func requestIsOneJSONObjectWithTheNamesTheHostReads() throws {
        let data = try JSONEncoder().encode(
            ResidentRequest(mutant: 7, xctest: ["App.StoreTests"], testing: nil, log: "/logs/7.log")
        )
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["mutant"] as? Int == 7)
        #expect(object["xctest"] as? [String] == ["App.StoreTests"])
        // Absent: the host runs no Swift Testing tests.
        #expect(object["testing"] == nil)
        #expect(object["log"] as? String == "/logs/7.log")
        #expect(!String(decoding: data, as: UTF8.self).contains("\n"))
        for name in ["var mutant: Int", "var xctest: [String]?", "var testing: [String]?", "var log: String"] {
            #expect(ResidentHostSource.swift.contains(name))
        }
    }
}

struct ResidentRunnerTests {
    typealias Bundle = DirectTestLauncher.Bundle

    let app = Bundle(path: "/bin/AppTests.xctest", executable: "/bin/AppTests.xctest/Contents/MacOS/AppTests", module: "AppTests")
    let core = Bundle(path: "/bin/CoreTests.xctest", executable: "/bin/CoreTests.xctest/Contents/MacOS/CoreTests", module: "CoreTests")
    let storeTests = TestSelector(module: "AppTests", name: "StoreTests", isFunction: false)

    private func runner(_ fake: FakeHost, bundles: [Bundle], messages: Messages = Messages()) -> ResidentRunner {
        ResidentRunner(
            executable: fake.executable,
            launcher: DirectTestLauncher(xctest: "/tools/xctest", helper: "/tools/helper", bundles: bundles, environment: [:]),
            directory: fake.root, logDirectory: fake.logs
        ) { messages.append($0) }
    }

    private func detects(_ runner: ResidentRunner, _ mutant: Int, worker: Int = 1, timeout: Double = 10) -> Bool {
        runner.detects(
            mutant: mutant, tests: nil, timeout: timeout, worker: worker, logFile: URL(fileURLWithPath: "/dev/null")
        )
    }

    /// Only a mutant that a test fails with, and passes again without, is detected in a host.
    @Test func onlyAKilledMutantIsDetected() throws {
        let fake = try FakeHost()
        let runner = runner(fake, bundles: [app])
        defer { runner.shutdown() }
        #expect(detects(runner, 11))
        #expect(!detects(runner, 12))
        #expect(!detects(runner, 13))
        #expect(!detects(runner, 14))
        #expect(!detects(runner, 15, timeout: 0.3))
        #expect(runner.statistics == .init(detected: 1, passed: 1, timedOut: 1, died: 1, polluted: 1))
    }

    /// A host stays for the next mutant; one that failed without the mutant, ended or did not
    /// answer is replaced.
    @Test func aHostIsKeptUntilItCanNoLongerBeTrusted() throws {
        let fake = try FakeHost()
        let runner = runner(fake, bundles: [app])
        defer { runner.shutdown() }
        #expect(detects(runner, 11))
        #expect(!detects(runner, 12))
        #expect(detects(runner, 11))
        #expect(fake.startedFor.count == 1)

        #expect(!detects(runner, 13))
        #expect(detects(runner, 11))
        #expect(fake.startedFor.count == 2)

        #expect(!detects(runner, 14))
        #expect(detects(runner, 11))
        #expect(fake.startedFor.count == 3)
    }

    @Test func everyWorkerHasAHostOfItsOwnForEveryBundle() throws {
        let fake = try FakeHost()
        let runner = runner(fake, bundles: [app, core])
        defer { runner.shutdown() }
        // Passes in the first bundle, so the second runs too.
        #expect(!detects(runner, 12, worker: 1))
        #expect(!detects(runner, 12, worker: 2))
        #expect(!detects(runner, 12, worker: 1))
        #expect(fake.startedFor.sorted() == [app.executable, app.executable, core.executable, core.executable])
        // Detected in the first bundle: the second is not asked.
        #expect(detects(runner, 11, worker: 3))
        #expect(fake.startedFor.count == 5)
    }

    @Test func onlyTheBundlesOfTheSelectedTestsAreAsked() throws {
        let fake = try FakeHost()
        let runner = runner(fake, bundles: [app, core])
        defer { runner.shutdown() }
        #expect(!runner.detects(
            mutant: 12, tests: [storeTests], timeout: 10, worker: 1, logFile: URL(fileURLWithPath: "/dev/null")
        ))
        #expect(fake.startedFor == [app.executable])
    }

    /// Tests that often end the process, or do not pass in a process that has run them before,
    /// cost a host each time and a process for the run as well.
    @Test func givesUpWhenHostsAreLostMoreOftenThanMutantsAreDetected() throws {
        let fake = try FakeHost()
        let messages = Messages()
        let runner = runner(fake, bundles: [app], messages: messages)
        defer { runner.shutdown() }
        #expect(detects(runner, 11))
        for _ in 1..<ResidentRunner.lostHostsBeforeGivingUp { #expect(!detects(runner, 13)) }
        #expect(messages.all.isEmpty)
        #expect(detects(runner, 11))

        #expect(!detects(runner, 14))
        #expect(messages.all.count == 1)
        #expect(messages.all.first?.hasPrefix("No longer keeping test processes:") == true)
        let starts = fake.startedFor.count
        let statistics = runner.statistics
        // Not even a mutant that a host would detect.
        #expect(!detects(runner, 11))
        #expect(fake.startedFor.count == starts)
        #expect(runner.statistics == statistics)
        #expect(messages.all.count == 1)
    }

    @Test func keepsGoingWhileMoreMutantsAreDetectedThanHostsLost() throws {
        let fake = try FakeHost()
        let messages = Messages()
        let runner = runner(fake, bundles: [app], messages: messages)
        defer { runner.shutdown() }
        for _ in 0...ResidentRunner.lostHostsBeforeGivingUp { #expect(detects(runner, 11)) }
        for _ in 0..<ResidentRunner.lostHostsBeforeGivingUp { #expect(!detects(runner, 14)) }
        #expect(messages.all.isEmpty)
        #expect(detects(runner, 11))
    }

    @Test func aHostThatDoesNotStartEndsTheirUse() throws {
        let fake = try FakeHost(ready: #"{"error":"image not found"}"#)
        let messages = Messages()
        let runner = runner(fake, bundles: [app], messages: messages)
        #expect(!detects(runner, 11))
        #expect(!detects(runner, 11))
        #expect(fake.startedFor.count == 1)
        #expect(messages.all.count == 1)
        #expect(messages.all.first?.contains("image not found") == true)
    }
}

struct ResidentSelectionTests {
    typealias Bundle = DirectTestLauncher.Bundle
    typealias Pass = DirectTestLauncher.Pass
    typealias Selection = DirectTestLauncher.ResidentSelection

    let app = Bundle(path: "/bin/AppTests.xctest", executable: "/bin/AppTests.xctest/Contents/MacOS/AppTests", module: "AppTests")
    let core = Bundle(path: "/bin/CoreTests.xctest", executable: "/bin/CoreTests.xctest/Contents/MacOS/CoreTests", module: "CoreTests")
    let storeTests = TestSelector(module: "AppTests", name: "StoreTests", isFunction: false)
    let percent = TestSelector(module: "AppTests", name: "percent", isFunction: true)

    private func launcher(_ bundles: [Bundle], emptyPasses: Set<Pass> = []) -> DirectTestLauncher {
        DirectTestLauncher(
            xctest: "/tools/xctest", helper: "/tools/helper", bundles: bundles, environment: [:], emptyPasses: emptyPasses
        )
    }

    @Test func wholeSuiteRunsEveryTestOfBothLibrariesInEveryBundle() {
        #expect(launcher([app, core]).residentSelections(for: nil) == [
            Selection(bundle: app, xctest: [], testing: []),
            Selection(bundle: core, xctest: [], testing: []),
        ])
    }

    /// As the processes started for a run: XCTest by `Module.Class`, Swift Testing by the filter
    /// pattern, and only in the bundles of the selected modules.
    @Test func selectionNamesClassesForXCTestAndPatternsForSwiftTesting() {
        #expect(launcher([app, core]).residentSelections(for: [percent, storeTests]) == [
            Selection(
                bundle: app, xctest: ["AppTests.StoreTests"],
                testing: [TestSelection.filterArguments([storeTests, percent])[1]]
            ),
        ])
    }

    /// A free `@Test` function is never an XCTest test.
    @Test func functionsAloneRunNoXCTest() {
        #expect(launcher([app]).residentSelections(for: [percent]) == [
            Selection(bundle: app, xctest: nil, testing: [percent.filterPattern]),
        ])
    }

    @Test func passesThatRanNoTestAreLeftOut() {
        let onlyTesting = launcher([app, core], emptyPasses: [
            Pass(bundle: app, library: .xctest), Pass(bundle: core, library: .xctest), Pass(bundle: core, library: .swiftTesting),
        ])
        #expect(onlyTesting.residentSelections(for: nil) == [Selection(bundle: app, xctest: nil, testing: [])])
        let onlyXCTest = launcher([app], emptyPasses: [Pass(bundle: app, library: .swiftTesting)])
        #expect(onlyXCTest.residentSelections(for: [storeTests, percent]) == [
            Selection(bundle: app, xctest: ["AppTests.StoreTests"], testing: nil),
        ])
        // Nothing left to run in the bundle.
        #expect(onlyXCTest.residentSelections(for: [percent]) == [])
    }
}

struct RunningProcessTests {
    private let directory = FileManager.default.temporaryDirectory

    @Test func linesGoInAndComeOut() throws {
        let process = try ProcessRunner.start(["/bin/cat"], in: directory, errorLog: URL(fileURLWithPath: "/dev/null"))
        defer { process.stop() }
        #expect(process.send("one"))
        #expect(process.send("two"))
        #expect(process.receive(timeout: 10) == .line("one"))
        #expect(process.receive(timeout: 10) == .line("two"))
        #expect(process.receive(timeout: 0.2) == .timedOut)
    }

    @Test func aCommandThatEndsClosesItsOutput() throws {
        let process = try ProcessRunner.start(["/usr/bin/true"], in: directory, errorLog: URL(fileURLWithPath: "/dev/null"))
        #expect(process.receive(timeout: 10) == .closed)
        // Writing to it is an error, not the end of this process.
        _ = process.send("anyone?")
        process.stop()
        #expect(!process.send("anyone?"))
        #expect(process.receive(timeout: 1) == .closed)
    }

    @Test func stoppingEndsTheCommand() throws {
        let process = try ProcessRunner.start(["/bin/sleep", "60"], in: directory, errorLog: URL(fileURLWithPath: "/dev/null"))
        let pid = process.pid
        #expect(kill(pid, 0) == 0)
        process.stop()
        process.stop()
        #expect(kill(pid, 0) != 0)
    }
}
