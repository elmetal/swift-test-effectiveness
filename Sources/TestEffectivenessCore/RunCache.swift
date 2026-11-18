import CryptoKit
import Foundation

/// What a run of a Swift package found out that the next run in the same work directory can use
/// instead of asking again. Each of the questions is a `swift` command that takes most of a
/// second, or a build that has nothing to do.
///
/// Kept in `<work directory>/cache.json`. Every entry says what it was found for, and is only
/// used when that is still the case; a file that cannot be read is an empty cache.
struct RunCache: Codable, Equatable {
    /// What `swift package describe` printed.
    struct PackageDescription: Codable, Equatable {
        /// `PackageInputs.digest` of what the manifest was read with.
        var inputs: String
        /// The directories of the targets in `output`, relative to the package.
        var targetDirectories: [String]
        /// `PackageInputs.listing` of `targetDirectories` when `output` was printed.
        var listing: String
        /// The JSON document.
        var output: String
    }

    /// Raised when an entry comes to mean something else.
    static let currentFormat = 1

    /// The format and the version of the tool that wrote the cache; another starts with an empty
    /// one.
    var format = RunCache.currentFormat
    var tool = ToolVersion.current
    var packageDescription: PackageDescription?

    /// `Toolchain.fingerprint` of the toolchain the entries below belong to.
    var toolchain: String?
    /// What `swift build --show-bin-path` printed in the copy.
    var binPath: String?
    /// The arguments of the last build of the copy that succeeded. Removed before the copy is
    /// updated and only put back when nothing in it changed, so a run that stops between the two
    /// leaves no claim that the copy is built.
    var builtWith: [String]?
    /// `DirectTestLauncher.identity` of the launcher that ran the tests the baseline of
    /// `swift test` ran.
    var verifiedLauncher: String?

    static func load(_ file: URL) -> RunCache {
        guard let data = try? Data(contentsOf: file),
              let cache = try? JSONDecoder().decode(RunCache.self, from: data),
              cache.format == currentFormat, cache.tool == ToolVersion.current
        else { return RunCache() }
        return cache
    }

    func save(to file: URL) {
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? JSONEncoder().encode(self).write(to: file, options: .atomic)
    }

    /// Forgets what was found for another toolchain. `nil`: the toolchain is unknown, and nothing
    /// found for a toolchain can be trusted.
    mutating func adopt(toolchain fingerprint: String?) {
        guard fingerprint == nil || fingerprint != toolchain else { return }
        toolchain = fingerprint
        binPath = nil
        builtWith = nil
        verifiedLauncher = nil
    }
}

/// The toolchain a `swift` executable belongs to, from one call of `swift -print-target-info`.
struct Toolchain: Equatable, Sendable {
    /// `<toolchain>/usr/lib/swift`.
    var runtimeResourcePath: URL
    /// Differs when `swift` is another compiler, or when Xcode's tools (`xcrun`) are another
    /// Xcode's.
    var fingerprint: String

    /// `libIndexStore.dylib` of the toolchain.
    var indexStoreLibrary: URL? {
        let library = runtimeResourcePath.deletingLastPathComponent().appendingPathComponent("libIndexStore.dylib")
        return FileManager.default.fileExists(atPath: library.path) ? library : nil
    }

    /// `<toolchain>/usr/libexec/swift/pm/swiftpm-testing-helper`.
    var testingHelper: String {
        runtimeResourcePath.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("libexec/swift/pm/swiftpm-testing-helper").path
    }

    static func resolve(swift: String) -> Toolchain? {
        guard let result = try? ProcessRunner.run([swift, "-print-target-info"], in: FileManager.default.temporaryDirectory),
              result.exitCode == 0
        else { return nil }
        let environment = ProcessInfo.processInfo.environment
        return Toolchain(targetInfo: result.output, swift: swift, selectedTools: [
            environment["DEVELOPER_DIR"] ?? "", environment["TOOLCHAINS"] ?? "",
            // What `xcode-select` chose.
            (try? FileManager.default.destinationOfSymbolicLink(atPath: "/var/db/xcode_select_link")) ?? "",
        ])
    }

    /// - Parameters:
    ///   - targetInfo: what `swift -print-target-info` printed; warnings may precede the JSON.
    ///   - selectedTools: what decides which Xcode `xcrun` finds its tools in.
    init?(targetInfo: String, swift: String, selectedTools: [String]) {
        struct TargetInfo: Decodable {
            struct Paths: Decodable { var runtimeResourcePath: String }
            var paths: Paths
        }
        guard let start = targetInfo.firstIndex(of: "{"),
              let info = try? JSONDecoder().decode(TargetInfo.self, from: Data(targetInfo[start...].utf8))
        else { return nil }
        runtimeResourcePath = URL(fileURLWithPath: info.paths.runtimeResourcePath)
        fingerprint = Digest.of([swift, String(targetInfo[start...])] + selectedTools)
    }
}

/// What `swift package describe` reads: when none of it changed, it prints the same again.
enum PackageInputs {
    /// Environment variables that differ between two shells without the manifest being meant to
    /// see them. A manifest may read any other, so all others are part of the digest.
    static let volatileEnvironment: Set<String> = [
        "PWD", "OLDPWD", "SHLVL", "_", "TERM_SESSION_ID", "ITERM_SESSION_ID", "SECURITYSESSIONID", "WINDOWID",
        "COLUMNS", "LINES", "SSH_AUTH_SOCK", "SSH_CLIENT", "SSH_CONNECTION", "SSH_TTY",
    ]

    /// A digest of the manifests at the top of `package`, the toolchain and the environment.
    /// `nil` without a manifest.
    static func digest(
        package: URL, toolchain: String, environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> String? {
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: package.path)) ?? [])
            .filter { $0 == "Package.swift" || ($0.hasPrefix("Package@swift-") && $0.hasSuffix(".swift")) }
            .sorted()
        guard !names.isEmpty else { return nil }
        var parts = [toolchain]
        for name in names {
            guard let contents = try? String(contentsOf: package.appendingPathComponent(name), encoding: .utf8) else {
                return nil
            }
            parts += [name, contents]
        }
        parts += environment.filter { !volatileEnvironment.contains($0.key) }
            .sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }
        return Digest.of(parts)
    }

    /// A digest of the paths of every file under `directories`, which are relative to `package`.
    /// A target's sources are the files in its directory, so a file that is added, removed or
    /// renamed changes what `swift package describe` prints without the manifest changing.
    /// Follows symbolic links to directories, as SwiftPM does.
    static func listing(of directories: [String], in package: URL) -> String {
        let fileManager = FileManager.default
        var paths: [String] = []
        // Real paths: a link may lead back to a directory above it.
        var visited = Set<String>()
        func visit(_ relative: String) {
            let directory = package.appendingPathComponent(relative).path
            guard visited.insert(ReferenceColumn.realPath(directory)).inserted,
                  let names = try? fileManager.contentsOfDirectory(atPath: directory)
            else { return }
            for name in names.sorted() where !WorkspaceCopy.excludedEverywhere.contains(name) {
                let child = "\(relative)/\(name)"
                var isDirectory: ObjCBool = false
                // Follows symbolic links.
                guard fileManager.fileExists(atPath: package.appendingPathComponent(child).path, isDirectory: &isDirectory)
                else { continue }
                if isDirectory.boolValue { visit(child) } else { paths.append(child) }
            }
        }
        for directory in Set(directories).sorted() { visit(directory) }
        return Digest.of(paths)
    }
}

/// The packages a build of the copy reads from outside it.
enum LocalDependencies {
    /// Whether SwiftPM's `workspace-state.json` names a dependency whose sources are a directory
    /// on this machine. Such a package can change without anything in the copy changing, so the
    /// copy has to be built to find out.
    ///
    /// - Parameter workspaceState: the file's contents; `nil` when there is none, which is the
    ///   case for a package without dependencies.
    static func exist(workspaceState: Data?) -> Bool {
        struct State: Decodable {
            struct Object: Decodable {
                struct Dependency: Decodable {
                    struct Reference: Decodable { var kind: String }
                    var packageRef: Reference
                }
                var dependencies: [Dependency]
            }
            var object: Object
        }
        guard let workspaceState else { return false }
        // A file that cannot be read may name one.
        guard let state = try? JSONDecoder().decode(State.self, from: workspaceState) else { return true }
        return state.object.dependencies.contains { !["remoteSourceControl", "registry"].contains($0.packageRef.kind) }
    }
}

enum Digest {
    /// SHA-256 of `parts`. Each part is preceded by its length, so that two lists never give the
    /// same bytes.
    static func of(_ parts: [String]) -> String {
        var hash = SHA256()
        for part in parts {
            hash.update(data: Data("\(part.utf8.count):".utf8))
            hash.update(data: Data(part.utf8))
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
