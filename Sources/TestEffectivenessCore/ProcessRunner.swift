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
            posix_spawn_file_actions_addchdir(&fileActions, directory.path)
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

    // MARK: - Commands that keep running

    /// Starts a command that keeps running and is talked to line by line through its standard
    /// input and output (see `RunningProcess`). Its standard error is appended to `errorLog`.
    ///
    /// `arguments[0]` is an absolute path and starts without a shell, so that `DYLD_*` variables
    /// reach it (see `run`). Like every command it has a process group of its own and is stopped
    /// when a termination signal arrives.
    static func start(
        _ arguments: [String], in directory: URL, environment: [String: String] = [:], errorLog: URL
    ) throws -> RunningProcess {
        #if canImport(Darwin)
        // Writing to a process that ended must be an error to handle, not the end of this one.
        signal(SIGPIPE, SIG_IGN)
        var mergedEnvironment = ProcessInfo.processInfo.environment
        for (key, value) in environment { mergedEnvironment[key] = value }
        let envp = mergedEnvironment.map { "\($0.key)=\($0.value)" }

        var pid: pid_t = 0
        var input: [Int32] = [-1, -1]
        var output: [Int32] = [-1, -1]
        // Under the lock, as every spawn is: no other command starts between the pipes being made
        // and being marked, so none inherits an end of them. An inherited end would keep a pipe
        // open after its process ended.
        let status: Int32? = children.withLock { state in
            if state.terminating { return nil }
            guard pipe(&input) == 0 else { return errno }
            guard pipe(&output) == 0 else {
                let code = errno
                close(input[0])
                close(input[1])
                return code
            }
            for descriptor in input + output { _ = fcntl(descriptor, F_SETFD, FD_CLOEXEC) }

            var fileActions: posix_spawn_file_actions_t?
            var attributes: posix_spawnattr_t?
            posix_spawn_file_actions_init(&fileActions)
            defer { posix_spawn_file_actions_destroy(&fileActions) }
            posix_spawnattr_init(&attributes)
            defer { posix_spawnattr_destroy(&attributes) }
            posix_spawn_file_actions_adddup2(&fileActions, input[0], 0)
            posix_spawn_file_actions_adddup2(&fileActions, output[1], 1)
            posix_spawn_file_actions_addopen(&fileActions, 2, errorLog.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
            posix_spawn_file_actions_addchdir(&fileActions, directory.path)
            posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP))
            posix_spawnattr_setpgroup(&attributes, 0)

            let status = withCStrings(arguments) { argvPointer in
                withCStrings(envp) { envPointer in
                    posix_spawn(&pid, arguments[0], &fileActions, &attributes, argvPointer, envPointer)
                }
            }
            // The command's ends.
            close(input[0])
            close(output[1])
            if status == 0 {
                state.groups.insert(pid)
            } else {
                close(input[1])
                close(output[0])
            }
            return status
        }
        guard let status else { parkForTermination() }
        guard status == 0 else {
            throw ProcessRunnerError.spawnFailed(command: arguments.joined(separator: " "), errno: status)
        }
        return RunningProcess(pid: pid, input: input[1], output: output[0])
        #else
        throw ProcessRunnerError.spawnFailed(command: arguments.joined(separator: " "), errno: ENOTSUP)
        #endif
    }

    /// Kills the command's process group and forgets it.
    fileprivate static func stop(_ pid: pid_t) {
        kill(-pid, SIGKILL)
        var status: Int32 = 0
        while waitpid(pid, &status, 0) == -1 && errno == EINTR {}
        let terminating = children.withLock { state in
            state.groups.remove(pid)
            return state.terminating
        }
        if terminating { parkForTermination() }
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

/// A command started with `ProcessRunner.start`. It reads lines from its standard input and
/// writes lines to its standard output. Used by one thread at a time.
final class RunningProcess: @unchecked Sendable {
    enum Line: Equatable {
        case line(String)
        /// Nothing complete arrived in time.
        case timedOut
        /// The command closed its output: it ended.
        case closed
    }

    let pid: pid_t
    private let input: Int32
    private let output: Int32
    /// Read, and not yet returned as a line.
    private var buffer = Data()
    private var stopped = false

    fileprivate init(pid: pid_t, input: Int32, output: Int32) {
        self.pid = pid
        self.input = input
        self.output = output
    }

    deinit { stop() }

    /// Writes `line` and a newline. `false` when the command no longer reads.
    func send(_ line: String) -> Bool {
        guard !stopped else { return false }
        let bytes = Array((line + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let written = bytes[offset...].withUnsafeBufferPointer { write(input, $0.baseAddress, $0.count) }
            if written < 0 {
                if errno == EINTR { continue }
                return false
            }
            offset += written
        }
        return true
    }

    /// The next line the command writes, waiting at most `timeout` seconds for it.
    func receive(timeout: Double?) -> Line {
        guard !stopped else { return .closed }
        let deadline = timeout.map { Date().addingTimeInterval($0) }
        while true {
            if let newline = buffer.firstIndex(of: 0x0A) {
                let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
                buffer.removeSubrange(buffer.startIndex...newline)
                return .line(line)
            }
            var descriptor = pollfd(fd: output, events: Int16(POLLIN), revents: 0)
            let wait: Int32
            if let deadline {
                let remaining = deadline.timeIntervalSinceNow
                if remaining <= 0 { return .timedOut }
                wait = Int32(min(remaining * 1000, 60_000).rounded(.up))
            } else {
                wait = -1
            }
            let ready = poll(&descriptor, 1, wait)
            if ready < 0 {
                if errno == EINTR { continue }
                return .closed
            }
            // The deadline is checked at the top.
            if ready == 0 { continue }
            var chunk = [UInt8](repeating: 0, count: 65_536)
            let count = read(output, &chunk, chunk.count)
            if count < 0 {
                if errno == EINTR { continue }
                return .closed
            }
            if count == 0 { return .closed }
            buffer.append(contentsOf: chunk[0..<count])
        }
    }

    /// Kills the command and what it started. Safe to call more than once.
    func stop() {
        guard !stopped else { return }
        stopped = true
        close(input)
        close(output)
        ProcessRunner.stop(pid)
    }
}
