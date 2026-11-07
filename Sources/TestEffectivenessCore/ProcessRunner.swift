import Foundation
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
public enum ProcessRunner {
    public static func run(
        _ arguments: [String],
        in directory: URL,
        environment: [String: String] = [:],
        timeout: Double? = nil,
        logFile: URL? = nil
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

        // posix_spawn has no working-directory parameter; go through `/bin/sh -c 'cd … && exec …'`.
        let script = "cd \(shellQuote(directory.path)) && exec " + arguments.map(shellQuote).joined(separator: " ")
        let argv = ["/bin/sh", "-c", script]
        let envp = mergedEnvironment.map { "\($0.key)=\($0.value)" }

        let start = Date()
        var pid: pid_t = 0
        let status = withCStrings(argv) { argvPointer in
            withCStrings(envp) { envPointer in
                posix_spawn(&pid, "/bin/sh", &fileActions, &attributes, argvPointer, envPointer)
            }
        }
        guard status == 0 else {
            throw ProcessRunnerError.spawnFailed(command: arguments.joined(separator: " "), errno: status)
        }

        var exitStatus: Int32 = 0
        var timedOut = false
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
            usleep(20_000)
        }
        let duration = Date().timeIntervalSince(start)
        let output = (try? String(contentsOf: outputURL, encoding: .utf8)) ?? ""
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
