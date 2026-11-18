import Foundation
import Synchronization

/// What a resident host is asked to run: the tests of one test bundle, with one mutant active.
struct ResidentRequest: Codable, Equatable {
    var mutant: Int
    /// XCTest classes as `Module.Class`; empty: every XCTest test; `nil`: none.
    var xctest: [String]?
    /// Swift Testing filter patterns; empty: every test; `nil`: none.
    var testing: [String]?
    /// Where the output of the tests goes; appended to.
    var log: String
}

/// What became of a request.
enum ResidentOutcome: Equatable {
    /// The tests pass with the mutant. They may not in a process of their own: this one has run
    /// other tests before, and state they left can hide what the mutant does.
    case passed
    /// A test fails with the mutant, and what failed passes again without it in the same process.
    case killed
    /// A test fails with the mutant and again without it: the process is in a state in which the
    /// tests fail anyway.
    case polluted
    case timedOut
    /// The process ended, as it does when a test crashes or exits.
    case died
}

/// A process that has loaded one test bundle and runs the tests of one mutant after the other,
/// instead of a process for every run: starting `xctest` or `swiftpm-testing-helper` and loading
/// the bundle takes longer than most selections of tests do.
///
/// The process is `ResidentHostSource`, which says how it runs a request. The mutant schema of
/// the bundle reads the active mutant from a value the host changes between runs
/// (`SchemataRewriter.switchEnvironmentVariable`).
///
/// Used by one thread at a time.
final class ResidentHost: @unchecked Sendable {
    struct Unavailable: Error, CustomStringConvertible {
        var description: String
    }

    private let process: RunningProcess

    private init(process: RunningProcess) {
        self.process = process
    }

    /// Starts the host and waits until it has loaded the bundle.
    ///
    /// - Parameters:
    ///   - bundle: the binary inside the `.xctest` bundle.
    ///   - environment: what the test processes need (`DirectTestLauncher.environment`).
    static func start(
        executable: String, bundle: String, environment: [String: String], in directory: URL, errorLog: URL,
        readyTimeout: Double = 120
    ) throws(Unavailable) -> ResidentHost {
        let process: RunningProcess
        do {
            process = try ProcessRunner.start(
                [executable, bundle], in: directory, environment: environment, errorLog: errorLog
            )
        } catch {
            throw Unavailable(description: "\(error)")
        }
        switch process.receive(timeout: readyTimeout) {
        case .line(let line):
            let reply = Reply(line)
            if reply?.ready == true { return ResidentHost(process: process) }
            process.stop()
            throw Unavailable(description: "the test host could not load \(bundle): \(reply?.error ?? line)")
        case .timedOut:
            process.stop()
            throw Unavailable(description: "the test host did not load \(bundle) in \(Int(readyTimeout))s")
        case .closed:
            process.stop()
            throw Unavailable(description: "the test host ended while loading \(bundle) (see \(errorLog.path))")
        }
    }

    /// Runs `request`. After anything but `.passed` and `.killed`, the host is stopped or no
    /// longer to be used.
    func run(_ request: ResidentRequest, timeout: Double?) -> ResidentOutcome {
        guard let data = try? JSONEncoder().encode(request), process.send(String(decoding: data, as: UTF8.self)) else {
            process.stop()
            return .died
        }
        switch process.receive(timeout: timeout) {
        case .line(let line):
            switch Reply(line)?.outcome {
            case "passed": return .passed
            case "killed": return .killed
            case "polluted": return .polluted
            default:
                // Not an answer to the request; what the host does next is unknown.
                process.stop()
                return .died
            }
        case .timedOut:
            process.stop()
            return .timedOut
        case .closed:
            process.stop()
            return .died
        }
    }

    func stop() {
        process.stop()
    }

    /// One line the host writes.
    struct Reply: Equatable {
        var ready: Bool?
        var error: String?
        var outcome: String?
        var executed: Int?

        init?(_ line: String) {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return nil
            }
            ready = object["ready"] as? Bool
            error = object["error"] as? String
            outcome = object["outcome"] as? String
            executed = object["executed"] as? Int
        }
    }
}

/// Compiles `ResidentHostSource` with the toolchain of the package under analysis.
enum ResidentHostBuilder {
    /// What the executable is built from. An executable built for the same key is used again.
    static func key(toolchain: Toolchain, platformPath: String) -> String {
        Digest.of([toolchain.fingerprint, platformPath, ResidentHostSource.swift])
    }

    /// - Parameters:
    ///   - platformPath: `xcrun --show-sdk-platform-path`, where XCTest is.
    ///   - builtKey: the key of the executable an earlier run left in `directory`, if any.
    /// - Returns: the executable.
    static func build(
        toolchain: Toolchain, platformPath: String, into directory: URL, builtKey: String?
    ) throws(ResidentHost.Unavailable) -> URL {
        let executable = directory.appendingPathComponent("ste-host")
        if builtKey == key(toolchain: toolchain, platformPath: platformPath),
           FileManager.default.isExecutableFile(atPath: executable.path) {
            return executable
        }
        let compiler = toolchain.runtimeResourcePath.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("bin/swiftc").path
        guard FileManager.default.isExecutableFile(atPath: compiler) else {
            throw ResidentHost.Unavailable(description: "no swiftc at \(compiler)")
        }
        let source = directory.appendingPathComponent("STEHost.swift")
        let log = directory.appendingPathComponent("build.log")
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try? FileManager.default.removeItem(at: executable)
            try Data(ResidentHostSource.swift.utf8).write(to: source)
        } catch {
            throw ResidentHost.Unavailable(description: "\(error)")
        }
        var arguments = [
            compiler, "-O", "-swift-version", "5", "-parse-as-library", "-module-name", "STEHost",
            "-F", "\(platformPath)/Developer/Library/Frameworks",
            "-I", "\(platformPath)/Developer/usr/lib", "-L", "\(platformPath)/Developer/usr/lib",
        ]
        // The SDK as `xcrun` names it, which is how the build of the package names it: compiled
        // under another name of the same directory, the SDK's modules would be built once more.
        if let result = try? ProcessRunner.run(["xcrun", "--sdk", "macosx", "--show-sdk-path"], in: directory),
           result.exitCode == 0, let sdk = result.output.split(separator: "\n").last {
            arguments += ["-sdk", sdk.trimmingCharacters(in: .whitespaces)]
        }
        arguments += [source.path, "-o", executable.path]
        guard let result = try? ProcessRunner.run(arguments, in: directory, logFile: log), result.exitCode == 0,
              FileManager.default.isExecutableFile(atPath: executable.path)
        else {
            throw ResidentHost.Unavailable(description: "the test host does not compile (see \(log.path))")
        }
        return executable
    }
}

/// Runs mutants in resident hosts: one per worker and test bundle, started when first needed.
///
/// A host only ever says that a mutant is detected (`ResidentOutcome.killed`): a test failed with
/// it and passed again without it, in the same process. Everything else is left to a process of
/// its own, which is what decided every run before: a mutant that survives in a host, because
/// state that earlier tests left may hide it; a run that times out or ends the host, because the
/// host cannot be asked again; and tests that fail without the mutant too.
final class ResidentRunner: Sendable {
    struct Statistics: Equatable {
        /// Mutant runs that a host found detected.
        var detected = 0
        /// Runs left to a process of their own, by what the host said.
        var passed = 0
        var timedOut = 0
        var died = 0
        var polluted = 0

        /// Runs that cost a host and decided nothing.
        var lostHosts: Int { died + polluted }
    }

    private struct Key: Hashable {
        var worker: Int
        var bundle: String
    }

    private struct State {
        var hosts: [Key: ResidentHost] = [:]
        var statistics = Statistics()
        /// Why hosts are no longer used.
        var disabled: String?
    }

    /// Hosts that end or fail without the mutant this often, and more often than they detect a
    /// mutant, cost more than they save.
    static let lostHostsBeforeGivingUp = 5

    private let executable: String
    private let launcher: DirectTestLauncher
    private let directory: URL
    private let logDirectory: URL
    private let log: @Sendable (String) -> Void
    private let state = Mutex(State())

    /// - Parameters:
    ///   - executable: the compiled `ResidentHostSource`.
    ///   - launcher: says which bundles there are, how tests are selected in them and what the
    ///     test processes need in their environment.
    ///   - directory: where the tests run (the copy of the project).
    init(
        executable: URL, launcher: DirectTestLauncher, directory: URL, logDirectory: URL,
        log: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.executable = executable.path
        self.launcher = launcher
        self.directory = directory
        self.logDirectory = logDirectory
        self.log = log
    }

    var statistics: Statistics { state.withLock { $0.statistics } }

    /// Whether the hosts of `worker` find `mutant` detected by `tests` (`nil`: the whole suite).
    /// `false` says nothing about the mutant.
    ///
    /// - Parameters:
    ///   - timeout: for the runs in all bundles together.
    ///   - logFile: where the output of the tests goes; appended to.
    func detects(mutant: Int, tests: [TestSelector]?, timeout: Double, worker: Int, logFile: URL) -> Bool {
        guard state.withLock({ $0.disabled == nil }) else { return false }
        let start = Date()
        for selection in launcher.residentSelections(for: tests) {
            let key = Key(worker: worker, bundle: selection.bundle.executable)
            let remaining = timeout - Date().timeIntervalSince(start)
            guard remaining > 0 else {
                record { $0.timedOut += 1 }
                return false
            }
            guard let host = host(key) else { return false }
            let request = ResidentRequest(
                mutant: mutant, xctest: selection.xctest, testing: selection.testing, log: logFile.path
            )
            switch host.run(request, timeout: remaining) {
            case .passed:
                continue
            case .killed:
                record { $0.detected += 1 }
                return true
            case .polluted:
                drop(key)
                record { $0.polluted += 1 }
                return false
            case .timedOut:
                drop(key)
                record { $0.timedOut += 1 }
                return false
            case .died:
                drop(key)
                record { $0.died += 1 }
                return false
            }
        }
        record { $0.passed += 1 }
        return false
    }

    /// Stops every host.
    func shutdown() {
        let hosts = state.withLock { state in
            defer { state.hosts = [:] }
            return Array(state.hosts.values)
        }
        for host in hosts { host.stop() }
    }

    private func host(_ key: Key) -> ResidentHost? {
        if let host = state.withLock({ $0.hosts[key] }) { return host }
        do {
            let host = try ResidentHost.start(
                executable: executable, bundle: key.bundle, environment: launcher.environment, in: directory,
                errorLog: logDirectory.appendingPathComponent("resident-host-\(key.worker).log")
            )
            state.withLock { $0.hosts[key] = host }
            return host
        } catch {
            giveUp("\(error)")
            return nil
        }
    }

    /// A host that stopped, or whose state can no longer be trusted, is not used again.
    private func drop(_ key: Key) {
        state.withLock { $0.hosts.removeValue(forKey: key) }?.stop()
    }

    private func record(_ change: (inout Statistics) -> Void) {
        let unproductive = state.withLock { state in
            change(&state.statistics)
            let statistics = state.statistics
            return statistics.lostHosts >= Self.lostHostsBeforeGivingUp && statistics.lostHosts > statistics.detected
        }
        if unproductive {
            giveUp("the tests end the process or fail in it without a mutant more often than they detect one there")
        }
    }

    private func giveUp(_ reason: String) {
        let first = state.withLock { state in
            defer { if state.disabled == nil { state.disabled = reason } }
            return state.disabled == nil
        }
        if first { log("No longer keeping test processes: \(reason); starting processes for every run.") }
    }
}
