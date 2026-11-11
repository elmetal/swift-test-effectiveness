import Foundation
import Synchronization
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public struct ProcessResult: Sendable {
    public var exitCode: Int32
    public var timedOut: Bool
    public var duration: Double
    public var output: String
}

public enum ProcessRunnerError: Error, CustomStringConvertible {
    case spawnFailed(command: String, errno: Int32)

    public var description: String {
        switch self {
        case .spawnFailed(let command, let code):
            "failed to launch `\(command)`: \(String(cString: strerror(code)))"
        }
    }
}

/// Runs a command in its own process group so that a timeout can kill the whole tree
/// (`swift test` spawns the actual test runner as a child process).
///
/// Because of that, a Ctrl-C in the terminal reaches only this process, not the command. Call
/// `forwardTerminationSignals()` once so that the running command is stopped too.
public enum ProcessRunner {
    private struct Children {
        /// Process groups of the commands that are running.
        var groups: Set<pid_t> = []
        /// Set once a termination signal arrived; no further command is started.
        var terminating = false
        var signalSources: [any DispatchSourceSignal] = []
    }

    private static let children = Mutex(Children())

    /// On SIGINT, SIGTERM or SIGHUP, stop the running commands (SIGTERM, then SIGKILL after a grace
    /// period) and exit with `128 + signal`.
    public static func forwardTerminationSignals(gracePeriod: Double = 5) {
        children.withLock { state in
            guard state.signalSources.isEmpty else { return }
            for signalNumber in [SIGINT, SIGTERM, SIGHUP] {
                signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
                source.setEventHandler { terminateChildren(signal: signalNumber, gracePeriod: gracePeriod) }
                source.resume()
                state.signalSources.append(source)
            }
        }
    }

    private static func terminateChildren(signal signalNumber: Int32, gracePeriod: Double) -> Never {
        let groups = children.withLock { state in
            state.terminating = true
            return state.groups
        }
        if !groups.isEmpty {
            FileHandle.standardError.write(Data("\nInterrupted; stopping the running command…\n".utf8))
        }
        for group in groups { kill(-group, SIGTERM) }
        let deadline = Date().addingTimeInterval(gracePeriod)
        // `kill(-group, 0)` succeeds while any process of the group is left.
        while Date() < deadline, groups.contains(where: { kill(-$0, 0) == 0 }) {
            usleep(50_000)
        }
        for group in groups { kill(-group, SIGKILL) }
        exit(128 + signalNumber)
    }

    /// Blocks the caller for good once termination started; the signal handler exits the process.
    private static func parkForTermination() -> Never {
        while true { pause() }
    }

    /// - Parameter withoutShell: start `arguments[0]` (an absolute path) itself instead of going
    ///   through `/bin/sh`. On macOS, `/bin/sh` is a protected binary and drops `DYLD_*` variables
    ///   from the environment, so a command that needs them must start this way. Only on Darwin;
    ///   ignored elsewhere.
    public static func run(
        _ arguments: [String],
        in directory: URL,
        environment: [String: String] = [:],
        timeout: Double? = nil,
        logFile: URL? = nil,
        withoutShell: Bool = false
    ) throws -> ProcessResult {
        let outputURL = logFile ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ste-\(UUID().uuidString).log")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        defer { if logFile == nil { try? FileManager.default.removeItem(at: outputURL) } }

        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment { mergedEnvironment[key] = value }

        #if canImport(Darwin)
        var fileActions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        #else
        var fileActions = posix_spawn_file_actions_t()
        var attributes = posix_spawnattr_t()
        #endif
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }

        posix_spawn_file_actions_addopen(&fileActions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&fileActions, 1, outputURL.path, O_WRONLY | O_TRUNC, 0o644)
        posix_spawn_file_actions_adddup2(&fileActions, 1, 2)
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
        posix_spawnattr_setpgroup(&attributes, 0)

        // posix_spawn has no portable working-directory parameter; go through
        // `/bin/sh -c 'cd … && exec …'` unless asked not to.
        let script = "cd \(shellQuote(directory.path)) && exec " + arguments.map(shellQuote).joined(separator: " ")
        var argv = ["/bin/sh", "-c", script]
        #if canImport(Darwin)
        if withoutShell {
            posix_spawn_file_actions_addchdir_np(&fileActions, directory.path)
            argv = arguments
        }
        #endif
        let executable = argv[0]
        let envp = mergedEnvironment.map { "\($0.key)=\($0.value)" }

        let start = Date()
        var pid: pid_t = 0
        // Spawn and register under the lock, so a signal handler either sees the new group or
        // stops this call from starting it.
        let status: Int32? = children.withLock { state in
            if state.terminating { return nil }
            let status = withCStrings(argv) { argvPointer in
                withCStrings(envp) { envPointer in
                    posix_spawn(&pid, executable, &fileActions, &attributes, argvPointer, envPointer)
                }
            }
            if status == 0 { state.groups.insert(pid) }
            return status
        }
        guard let status else { parkForTermination() }
        guard status == 0 else {
            throw ProcessRunnerError.spawnFailed(command: arguments.joined(separator: " "), errno: status)
        }

        var exitStatus: Int32 = 0
        var timedOut = false
        // Short commands (a test bundle started directly ends within 0.1s) should not wait for a
        // long poll; long ones should not poll often.
        var pollInterval: useconds_t = 500
        while true {
            let result = waitpid(pid, &exitStatus, WNOHANG)
            if result == pid { break }
            if result == -1 && errno != EINTR { break }
            if let timeout, Date().timeIntervalSince(start) > timeout {
                timedOut = true
                kill(-pid, SIGKILL)
                _ = waitpid(pid, &exitStatus, 0)
                break
            }
            usleep(pollInterval)
            pollInterval = min(pollInterval * 2, 20_000)
        }
        let duration = Date().timeIntervalSince(start)
        let terminating = children.withLock { state in
            state.groups.remove(pid)
            return state.terminating
        }
        // The command ended because of the signal; its result must not be read as a test outcome.
        if terminating { parkForTermination() }
        // Not `String(contentsOf:encoding:)`, which gives nothing at all when a byte is not UTF-8:
        // a command that is killed can stop in the middle of a character.
        let output = String(decoding: (try? Data(contentsOf: outputURL)) ?? Data(), as: UTF8.self)
        return ProcessResult(
            exitCode: timedOut ? -1 : decodeExitStatus(exitStatus),
            timedOut: timedOut,
            duration: duration,
            output: output
        )
    }

    /// Runs a shell command line (used for user-supplied build/test commands).
    public static func runShell(
        _ commandLine: String, in directory: URL, environment: [String: String] = [:],
        timeout: Double? = nil, logFile: URL? = nil
    ) throws -> ProcessResult {
        try run(["/bin/sh", "-c", commandLine], in: directory, environment: environment, timeout: timeout, logFile: logFile)
    }

    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    private static func decodeExitStatus(_ status: Int32) -> Int32 {
        let signal = status & 0x7f
        if signal == 0 { return (status >> 8) & 0xff }
        return 128 + signal
    }

    private static func withCStrings<R>(
        _ strings: [String], _ body: (UnsafePointer<UnsafeMutablePointer<CChar>?>) -> R
    ) -> R {
        var pointers: [UnsafeMutablePointer<CChar>?] = strings.map { strdup($0) }
        pointers.append(nil)
        defer { pointers.forEach { free($0) } }
        return pointers.withUnsafeBufferPointer { body($0.baseAddress!) }
    }
}
