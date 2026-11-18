/// The program of the resident test host (see `ResidentHost`), compiled with the toolchain of the
/// package under analysis into the work directory. It is a program of its own, not a mode of
/// this tool: a test bundle may contain the libraries this tool is made of, and two copies of a
/// library do not live in one process.
enum ResidentHostSource {
    static let swift = ##"""
    import Foundation
    import XCTest

    // The resident test host of swift-test-effectiveness (generated, see `ResidentHost`).
    //
    // Loads one test bundle and then runs the tests named by each request it reads from standard
    // input, with the mutant the request names active. Answers on what was its standard output;
    // what the tests print goes to the log the request names.

    /// What `swt_abiv0_getEntryPoint` returns: Swift Testing's entry point for tools.
    typealias EntryPoint = @convention(thin) @Sendable (
        UnsafeRawBufferPointer?, @escaping @Sendable (UnsafeRawBufferPointer) -> Void
    ) async throws -> Bool

    struct Request: Decodable {
        var mutant: Int
        /// XCTest classes to run as `Module.Class`; empty: every XCTest test; absent: none.
        var xctest: [String]?
        /// Swift Testing filter patterns; empty: every test; absent: none.
        var testing: [String]?
        var log: String
    }

    /// What a run of Swift Testing reported.
    final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var functions = Set<String>()
        private var startedTests = [String]()
        private var failedTests = Set<String>()
        /// When each test started and ended, in seconds.
        private var started = [String: Double]()
        private var ended = [String: Double]()

        func record(_ bytes: UnsafeRawBufferPointer) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any],
                  let payload = object["payload"] as? [String: Any]
            else { return }
            lock.lock()
            defer { lock.unlock() }
            if object["kind"] as? String == "test" {
                if payload["kind"] as? String == "function", let id = payload["id"] as? String { functions.insert(id) }
                return
            }
            guard let id = payload["testID"] as? String else { return }
            let instant = (payload["instant"] as? [String: Any])?["absolute"] as? Double
            switch payload["kind"] as? String {
            case "testStarted":
                startedTests.append(id)
                started[id] = instant
            case "testEnded":
                ended[id] = instant
            case "issueRecorded":
                let issue = payload["issue"] as? [String: Any]
                let known = issue?["isKnown"] as? Bool ?? false
                if issue?["isFailure"] as? Bool ?? !known { failedTests.insert(id) }
            default:
                break
            }
        }

        /// The test functions that started; a suite starts too, and is not a test.
        var executed: Int {
            lock.lock()
            defer { lock.unlock() }
            return startedTests.filter { functions.contains($0) }.count
        }

        /// The test that failed and took the least time, if any is known to have failed.
        var quickestFailed: String? {
            lock.lock()
            defer { lock.unlock() }
            func duration(_ id: String) -> Double {
                guard let start = started[id], let end = ended[id] else { return .infinity }
                return end - start
            }
            return failedTests.sorted().min { duration($0) < duration($1) }
        }
    }

    @main
    enum Host {
        /// The cell every mutated file of the bundle reads its active mutant from.
        nonisolated(unsafe) static let activeMutant: UnsafeMutablePointer<Int> = {
            let cell = UnsafeMutablePointer<Int>.allocate(capacity: 1)
            cell.initialize(to: -1)
            return cell
        }()
        nonisolated(unsafe) static var entryPoint: EntryPoint?
        nonisolated(unsafe) static var replies: Int32 = -1

        static func activate(_ mutant: Int?) {
            activeMutant.pointee = mutant ?? -1
            // For the processes the tests start, which have a switch of their own.
            if let mutant { setenv("STE_MUTANT", String(mutant), 1) } else { unsetenv("STE_MUTANT") }
        }

        static func send(_ fields: [String: Any]) {
            guard var data = try? JSONSerialization.data(withJSONObject: fields) else { return }
            data.append(0x0A)
            data.withUnsafeBytes { bytes in
                var offset = 0
                while offset < bytes.count {
                    let written = write(replies, bytes.baseAddress! + offset, bytes.count - offset)
                    if written <= 0 { exit(1) }
                    offset += written
                }
            }
        }

        @MainActor
        static func main() async {
            guard CommandLine.arguments.count == 2 else { exit(2) }
            replies = dup(STDOUT_FILENO)
            setvbuf(stdout, nil, _IOLBF, 0)
            unsetenv("STE_MUTANT")
            unsetenv("STE_REACHED")
            setenv("STE_SWITCH", "\(getpid()):\(UInt(bitPattern: activeMutant))", 1)

            guard dlopen(CommandLine.arguments[1], RTLD_NOW) != nil else {
                send(["error": String(cString: dlerror())])
                exit(1)
            }
            if let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "swt_abiv0_getEntryPoint") {
                let getter = unsafeBitCast(symbol, to: (@convention(c) () -> UnsafeRawPointer).self)
                entryPoint = unsafeBitCast(getter(), to: EntryPoint.self)
            }
            send(["ready": true])

            let decoder = JSONDecoder()
            while let line = readLine(strippingNewline: true) {
                guard let request = try? decoder.decode(Request.self, from: Data(line.utf8)) else {
                    send(["error": "cannot read the request"])
                    continue
                }
                let log = open(request.log, O_WRONLY | O_CREAT | O_APPEND, 0o644)
                if log >= 0 {
                    dup2(log, STDOUT_FILENO)
                    dup2(log, STDERR_FILENO)
                    close(log)
                }
                let (outcome, executed) = await run(request)
                activate(nil)
                fflush(stdout)
                fflush(stderr)
                send(["outcome": outcome, "executed": executed])
            }
        }

        /// "passed": the tests pass with the mutant. "killed": a test fails with it and passes again
        /// without it. "polluted": it does not pass again, so this process no longer says what the
        /// mutant does.
        ///
        /// One test that fails with the mutant and passes without it is what detecting the mutant
        /// means, so only one of the failed tests runs again: the one that took the least time.
        @MainActor
        static func run(_ request: Request) async -> (outcome: String, executed: Int) {
            var executed = 0
            activate(request.mutant)

            if let names = request.xctest {
                for suite in classSuites(names) {
                    suite.run()
                    executed += suite.testRun?.executionCount ?? 0
                    guard suite.testRun?.hasSucceeded == false else { continue }
                    activate(nil)
                    print("swift-test-effectiveness: running a failed test of \(suite.name) again without the mutant")
                    var again = quickestFailedTest(of: suite)
                    again?.run()
                    // The name selected nothing: the whole class.
                    if (again?.testRun?.executionCount ?? 0) == 0 {
                        again = sameClass(as: suite)
                        again?.run()
                    }
                    let passesAgain = again?.testRun?.hasSucceeded == true && (again?.testRun?.executionCount ?? 0) > 0
                    return (passesAgain ? "killed" : "polluted", executed)
                }
            }

            if let filter = request.testing, entryPoint != nil {
                let withMutant = await runTesting(filter: filter)
                executed += withMutant.recorder.executed
                if !withMutant.passed {
                    activate(nil)
                    print("swift-test-effectiveness: running a failed test again without the mutant")
                    var again: (passed: Bool, recorder: Recorder)?
                    if let failed = withMutant.recorder.quickestFailed { again = await runTesting(filter: [pattern(failed)]) }
                    // The pattern matched nothing, or nothing says which tests failed: all of them.
                    if again == nil || again!.recorder.executed == 0 { again = await runTesting(filter: filter) }
                    let passesAgain = again!.passed && again!.recorder.executed > 0
                    return (passesAgain ? "killed" : "polluted", executed)
                }
            }
            return ("passed", executed)
        }

        // MARK: - XCTest

        /// One suite per test class, so that a run can stop after the first class that fails.
        @MainActor
        static func classSuites(_ names: [String]) -> [XCTestSuite] {
            func classes(in suite: XCTestSuite) -> [XCTestSuite] {
                if suite.tests.contains(where: { !($0 is XCTestSuite) }) { return [suite] }
                return suite.tests.flatMap { ($0 as? XCTestSuite).map(classes) ?? [] }
            }
            return names.isEmpty ? classes(in: XCTestSuite.default) : names.map { XCTestSuite(forTestCaseWithName: $0) }
        }

        /// A new suite with the test of `suite` that failed and took the least time. A test is named
        /// `-[Module.Class method]` and selected as `Module.Class/method`.
        @MainActor
        static func quickestFailedTest(of suite: XCTestSuite) -> XCTestSuite? {
            let failed = suite.tests.filter { $0 is XCTestCase && $0.testRun?.hasSucceeded == false }
            guard let test = failed.min(by: { ($0.testRun?.totalDuration ?? 0) < ($1.testRun?.totalDuration ?? 0) }),
                  test.name.hasPrefix("-["), test.name.hasSuffix("]")
            else { return nil }
            let parts = test.name.dropFirst(2).dropLast().split(separator: " ")
            guard parts.count == 2 else { return nil }
            return XCTestSuite(forTestCaseWithName: "\(parts[0])/\(parts[1])")
        }

        /// A new suite of the class whose tests `suite` ran; test cases run once.
        @MainActor
        static func sameClass(as suite: XCTestSuite) -> XCTestSuite? {
            guard let testCase = suite.tests.first(where: { $0 is XCTestCase }) else { return nil }
            return XCTestSuite(forTestCaseClass: type(of: testCase) as! XCTestCase.Type)
        }

        // MARK: - Swift Testing

        static func runTesting(filter: [String]) async -> (passed: Bool, recorder: Recorder) {
            let recorder = Recorder()
            var configuration: [String: Any] = ["eventStreamSchemaVersion": "0"]
            if !filter.isEmpty { configuration["filter"] = filter }
            guard let entryPoint, let data = try? JSONSerialization.data(withJSONObject: configuration) else {
                return (true, recorder)
            }
            let buffer = UnsafeMutableRawBufferPointer.allocate(byteCount: data.count, alignment: 1)
            defer { buffer.deallocate() }
            data.copyBytes(to: buffer)
            nonisolated(unsafe) let bytes = UnsafeRawBufferPointer(buffer)
            let passed = (try? await entryPoint(bytes) { recorder.record($0) }) ?? false
            return (passed, recorder)
        }

        /// A filter pattern for one test from its id, `Module.Suite/function()/File.swift:1:2`.
        static func pattern(_ testID: String) -> String {
            var components = testID.split(separator: "/", omittingEmptySubsequences: false)
            if let last = components.last, last.range(of: #"\.swift:\d+:\d+$"#, options: .regularExpression) != nil {
                components.removeLast()
            }
            return "^" + NSRegularExpression.escapedPattern(for: components.joined(separator: "/")) + "(/|$)"
        }
    }
    """##
}
