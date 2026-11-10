import Foundation

/// Starts the test bundles of a Swift package itself, instead of through `swift test`.
///
/// `swift test --skip-build` loads the package and plans the build before it starts the tests,
/// which takes about a second per run, and it locks `.build`, so two runs cannot overlap. A run
/// with a mutant only needs what `swift test` does last: for each test bundle, start
/// `xctest <bundle>` for the XCTest tests and `swiftpm-testing-helper` for the Swift Testing tests.
///
/// The baseline still runs through `swift test`, which also merges the coverage data. `verify`
/// then runs the whole suite directly and compares it with the baseline; the launcher is only used
/// when both executed the same number of tests and passed.
struct DirectTestLauncher: Sendable {
    struct Unavailable: Error, CustomStringConvertible {
        var description: String
    }

    struct Bundle: Hashable, Sendable {
        /// The `.xctest` bundle.
        var path: String
        /// The binary inside it.
        var executable: String
        /// The module whose tests the bundle contains; `nil` for one bundle with every test
        /// target's tests (`<Package>PackageTests.xctest`).
        var module: String?
    }

    enum Library: Hashable, Sendable {
        case xctest
        case swiftTesting
    }

    /// One process: the tests of one library in one bundle.
    struct Pass: Hashable, Sendable {
        var bundle: Bundle
        var library: Library
    }

    struct Command: Equatable {
        var pass: Pass
        var arguments: [String]

        /// `xctest` also runs a bundle's Swift Testing tests unless told not to; `swift test`
        /// tells it so and runs them in a process of their own, where `--filter` applies.
        var environment: [String: String] {
            pass.library == .xctest ? ["SWIFT_TESTING_ENABLED": "0"] : [:]
        }
    }

    /// Swift Testing's exit code when no test matches the filter (`EX_UNAVAILABLE`). `swift test`
    /// does not treat it as a failure either.
    static let noTestsFoundExitCode: Int32 = 69

    var xctest: String
    var helper: String
    var bundles: [Bundle]
    /// What `swift test` adds for the test processes, and a place for the profile data of a build
    /// with coverage that does not overwrite the baseline's.
    var environment: [String: String]
    /// Passes that ran no test in the whole suite; they are not started again.
    var emptyPasses: Set<Pass> = []

    // MARK: - Commands

    /// The processes to start for `tests` (`nil`: the whole suite), in order.
    func commands(for tests: [TestSelector]?) -> [Command] {
        var result: [Command] = []
        for bundle in bundles {
            var selected: [TestSelector]?
            if let tests {
                let inBundle = tests.filter { bundle.module == nil || $0.module == bundle.module }.sorted()
                if inBundle.isEmpty { continue }
                selected = inBundle
            }

            let xctestPass = Pass(bundle: bundle, library: .xctest)
            if !emptyPasses.contains(xctestPass) {
                if let selected {
                    // XCTest selects by `Module.Class`; a free `@Test` function is never an XCTest test.
                    let types = selected.filter { !$0.isFunction }.map { "\($0.module).\($0.name)" }
                    if !types.isEmpty {
                        result.append(Command(
                            pass: xctestPass, arguments: [xctest, "-XCTest", types.joined(separator: ","), bundle.path]
                        ))
                    }
                } else {
                    result.append(Command(pass: xctestPass, arguments: [xctest, bundle.path]))
                }
            }

            let testingPass = Pass(bundle: bundle, library: .swiftTesting)
            if !emptyPasses.contains(testingPass) {
                // As `swift test` starts it: its own arguments between the two bundle paths.
                result.append(Command(
                    pass: testingPass,
                    arguments: [helper, "--test-bundle-path", bundle.executable]
                        + (selected.map(TestSelection.filterArguments) ?? [])
                        + [bundle.executable, "--testing-library", "swift-testing"]
                ))
            }
        }
        return result
    }

    static func passed(_ library: Library, exitCode: Int32) -> Bool {
        switch library {
        case .xctest: exitCode == 0
        case .swiftTesting: exitCode == 0 || exitCode == noTestsFoundExitCode
        }
    }

    // MARK: - Running

    /// Runs `tests` (`nil`: the whole suite). The result is that of the first process that fails
    /// or times out, or a success when every process passes; `timeout` is for all of them
    /// together. The output of every process goes to `logFile`.
    func run(
        tests: [TestSelector]?, environment: [String: String], timeout: Double?, in directory: URL, logFile: URL
    ) throws -> ProcessResult {
        try execute(commands(for: tests), environment: environment, timeout: timeout, in: directory, logFile: logFile)
            .result
    }

    private func execute(
        _ commands: [Command], environment: [String: String], timeout: Double?, in directory: URL, logFile: URL
    ) throws -> (result: ProcessResult, outputs: [(pass: Pass, output: String)]) {
        let start = Date()
        var merged = self.environment
        for (key, value) in environment { merged[key] = value }

        var outputs: [(pass: Pass, output: String)] = []
        var exitCode: Int32 = 0
        var timedOut = false
        for command in commands {
            let remaining = timeout.map { $0 - Date().timeIntervalSince(start) }
            if let remaining, remaining <= 0 {
                timedOut = true
                break
            }
            let result = try ProcessRunner.run(
                command.arguments, in: directory,
                environment: merged.merging(command.environment) { $1 },
                timeout: remaining, withoutShell: true
            )
            outputs.append((command.pass, result.output))
            if result.timedOut {
                timedOut = true
                break
            }
            if !Self.passed(command.pass.library, exitCode: result.exitCode) {
                exitCode = result.exitCode
                break
            }
        }
        let output = outputs.map(\.output).joined()
        try? output.write(to: logFile, atomically: false, encoding: .utf8)
        return (
            ProcessResult(
                exitCode: timedOut ? -1 : exitCode, timedOut: timedOut,
                duration: Date().timeIntervalSince(start), output: output
            ),
            outputs
        )
    }

    // MARK: - Verification

    /// Runs the whole suite directly, without mutations, and compares it with the baseline that
    /// `swift test` ran. Returns why the launcher cannot be used, or `nil` when it can.
    ///
    /// A launcher that starts the tests wrongly would make every mutant look detected (a process
    /// that fails to load the bundle) or look survived (a process that runs no test), so the
    /// direct run has to pass and execute as many tests as the baseline did.
    mutating func verify(
        baselineOutput: String, timeout: Double?, in directory: URL, logFile: URL
    ) throws -> Unavailable? {
        let expected = TestOutput.executedTests(in: baselineOutput)
        guard expected > 0 else {
            return Unavailable(description: "could not read the number of tests the baseline executed")
        }
        let (result, outputs) = try execute(
            commands(for: nil), environment: [:], timeout: timeout, in: directory, logFile: logFile
        )
        guard !result.timedOut, result.exitCode == 0 else {
            return Unavailable(description: "the tests do not pass when started directly (see \(logFile.path))")
        }
        let counts = outputs.map { (pass: $0.pass, count: TestOutput.executedTests(in: $0.output)) }
        let executed = counts.reduce(0) { $0 + $1.count }
        guard executed == expected else {
            return Unavailable(description: "starting the tests directly executed \(executed) tests, "
                + "the baseline \(expected) (see \(logFile.path))")
        }
        emptyPasses = Set(counts.filter { $0.count == 0 }.map(\.pass))
        return nil
    }

    // MARK: - Setup

    /// Finds the test bundles the build wrote to `binPath` and the tools that run them.
    ///
    /// - Parameters:
    ///   - packageName: the package's name, for the bundle with every target's tests.
    ///   - testTargets: names of the package's test targets, for a bundle per target.
    static func resolve(
        swift: String, binPath: URL, packageName: String, testTargets: [String], in directory: URL
    ) throws(Unavailable) -> DirectTestLauncher {
        var bundles: [Bundle] = []
        for target in testTargets.sorted() {
            let module = moduleName(target)
            if let bundle = bundle(named: target, module: module, in: binPath)
                ?? (module != target ? bundle(named: module, module: module, in: binPath) : nil) {
                bundles.append(bundle)
            }
        }
        if bundles.isEmpty, let bundle = bundle(named: "\(packageName)PackageTests", module: nil, in: binPath) {
            bundles.append(bundle)
        }
        guard !bundles.isEmpty else {
            throw Unavailable(description: "no test bundle in \(binPath.path)")
        }

        func tool(_ arguments: [String]) -> String? {
            guard let result = try? ProcessRunner.run(arguments, in: directory), result.exitCode == 0,
                  let line = result.output.split(separator: "\n").last
            else { return nil }
            return line.trimmingCharacters(in: .whitespaces)
        }
        guard let xctest = tool(["xcrun", "--sdk", "macosx", "--find", "xctest"]),
              FileManager.default.isExecutableFile(atPath: xctest)
        else { throw Unavailable(description: "`xcrun --find xctest` found no xctest") }
        guard let platform = tool(["xcrun", "--sdk", "macosx", "--show-sdk-platform-path"]) else {
            throw Unavailable(description: "`xcrun --show-sdk-platform-path` failed")
        }
        // <toolchain>/usr/lib/swift → <toolchain>/usr/libexec/swift/pm/swiftpm-testing-helper
        guard let resources = ReferenceColumn.runtimeResourcePath(swift: swift) else {
            throw Unavailable(description: "`\(swift) -print-target-info` failed")
        }
        let helper = resources.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libexec/swift/pm/swiftpm-testing-helper").path
        guard FileManager.default.isExecutableFile(atPath: helper) else {
            throw Unavailable(description: "no swiftpm-testing-helper at \(helper)")
        }

        // XCTest.framework and Testing.framework are in the platform, not on the default search path.
        let current = ProcessInfo.processInfo.environment
        var environment = ["LLVM_PROFILE_FILE": "/dev/null"]
        for (key, path) in [
            ("DYLD_FRAMEWORK_PATH", "\(platform)/Developer/Library/Frameworks"),
            ("DYLD_LIBRARY_PATH", "\(platform)/Developer/usr/lib"),
        ] {
            environment[key] = ([path] + (current[key].map { [$0] } ?? [])).joined(separator: ":")
        }
        return DirectTestLauncher(xctest: xctest, helper: helper, bundles: bundles, environment: environment)
    }

    private static func bundle(named name: String, module: String?, in binPath: URL) -> Bundle? {
        let path = binPath.appendingPathComponent("\(name).xctest")
        let executable = path.appendingPathComponent("Contents/MacOS/\(name)")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { return nil }
        return Bundle(path: path.path, executable: executable.path, module: module)
    }

    /// The module name SwiftPM derives from a target name: characters that cannot be part of an
    /// identifier become `_`.
    static func moduleName(_ target: String) -> String {
        var name = String(target.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        if let first = name.first, first.isNumber { name = "_" + name.dropFirst() }
        return name
    }
}

/// Reads what XCTest and Swift Testing print about a run.
enum TestOutput {
    /// The number of tests a run executed: XCTest test cases that started, plus the tests Swift
    /// Testing reports at the end of each run (`Test run with 3 tests in 1 suite passed`).
    static func executedTests(in output: String) -> Int {
        var count = 0
        for line in output.split(separator: "\n") {
            if line.hasPrefix("Test Case '") && line.hasSuffix("' started.") {
                count += 1
            } else if let match = line.firstMatch(of: #/Test run with (\d+) tests? /#), let tests = Int(match.1) {
                count += tests
            }
        }
        return count
    }
}
