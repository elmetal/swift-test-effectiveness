import Foundation
import Testing
@testable import TestEffectivenessCore

struct RunCacheTests {
    /// A directory removed when the test ends.
    final class Sandbox {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ste-cache-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ contents: String, to relativePath: String) throws {
            let url = root.appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }
    }

    private var filled: RunCache {
        RunCache(
            packageDescription: .init(inputs: "i", targetDirectories: ["Sources/App"], listing: "l", output: "{}"),
            toolchain: "t1", binPath: "/copy/.build/debug", builtWith: ["swift", "build"], verifiedLauncher: "v"
        )
    }

    // MARK: - File

    @Test func whatIsSavedIsLoaded() throws {
        let sandbox = try Sandbox()
        // The work directory may not exist yet.
        let file = sandbox.root.appendingPathComponent("work/cache.json")
        filled.save(to: file)
        #expect(RunCache.load(file) == filled)
    }

    @Test func aFileThatIsMissingOrCannotBeReadIsAnEmptyCache() throws {
        let sandbox = try Sandbox()
        #expect(RunCache.load(sandbox.root.appendingPathComponent("cache.json")) == RunCache())
        try sandbox.write("{ not json", to: "cache.json")
        #expect(RunCache.load(sandbox.root.appendingPathComponent("cache.json")) == RunCache())
    }

    @Test func aCacheOfAnotherFormatOrToolVersionIsNotUsed() throws {
        let sandbox = try Sandbox()
        let file = sandbox.root.appendingPathComponent("cache.json")
        var other = filled
        other.format += 1
        other.save(to: file)
        #expect(RunCache.load(file) == RunCache())
        other = filled
        other.tool += "-next"
        other.save(to: file)
        #expect(RunCache.load(file) == RunCache())
    }

    // MARK: - Toolchain

    @Test func anotherToolchainKeepsOnlyWhatDoesNotDependOnIt() {
        var cache = filled
        cache.adopt(toolchain: "t1")
        #expect(cache == filled)

        cache.adopt(toolchain: "t2")
        #expect(cache.toolchain == "t2")
        #expect(cache.binPath == nil)
        #expect(cache.builtWith == nil)
        #expect(cache.verifiedLauncher == nil)
        // Its key names the toolchain it was printed with.
        #expect(cache.packageDescription == filled.packageDescription)
    }

    @Test func anUnknownToolchainTrustsNothingFoundForOne() {
        var cache = filled
        cache.adopt(toolchain: nil)
        #expect(cache.toolchain == nil)
        #expect(cache.binPath == nil)
        #expect(cache.builtWith == nil)
        #expect(cache.verifiedLauncher == nil)
    }

    private let targetInfo = """
        warning: something about the SDK
        {
          "compilerVersion": "Apple Swift version 6.3",
          "paths": { "runtimeResourcePath": "/Toolchains/A.xctoolchain/usr/lib/swift" }
        }
        """

    @Test func toolchainReadsItsPathsFromTheTargetInfo() throws {
        let toolchain = try #require(Toolchain(targetInfo: targetInfo, swift: "swift", selectedTools: []))
        #expect(toolchain.runtimeResourcePath.path == "/Toolchains/A.xctoolchain/usr/lib/swift")
        #expect(toolchain.testingHelper == "/Toolchains/A.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper")
        #expect(Toolchain(targetInfo: "error: unknown argument", swift: "swift", selectedTools: []) == nil)
    }

    @Test func fingerprintDiffersWithTheCompilerTheExecutableAndTheSelectedXcode() throws {
        func fingerprint(_ info: String, swift: String = "swift", tools: [String] = ["/Xcode-A"]) throws -> String {
            try #require(Toolchain(targetInfo: info, swift: swift, selectedTools: tools)).fingerprint
        }
        let base = try fingerprint(targetInfo)
        #expect(try fingerprint(targetInfo) == base)
        // The warnings before the document are not the toolchain.
        #expect(try fingerprint(targetInfo.replacingOccurrences(of: "about the SDK", with: "else")) == base)
        #expect(try fingerprint(targetInfo.replacingOccurrences(of: "6.3", with: "6.4")) != base)
        #expect(try fingerprint(targetInfo, swift: "/usr/bin/swift") != base)
        #expect(try fingerprint(targetInfo, tools: ["/Xcode-B"]) != base)
    }

    // MARK: - Package inputs

    @Test func digestOfThePackageInputsFollowsTheManifestsTheToolchainAndTheEnvironment() throws {
        let sandbox = try Sandbox()
        func digest(toolchain: String = "t", environment: [String: String] = ["HOME": "/h"]) -> String? {
            PackageInputs.digest(package: sandbox.root, toolchain: toolchain, environment: environment)
        }
        // Not a package.
        #expect(digest() == nil)

        try sandbox.write("// 1", to: "Package.swift")
        let base = try #require(digest())
        #expect(digest() == base)
        #expect(digest(toolchain: "other") != base)
        // A manifest may read the environment.
        #expect(digest(environment: ["HOME": "/h", "USE_LOCAL_DEPENDENCIES": "1"]) != base)
        #expect(digest(environment: ["HOME": "/h", "PWD": "/somewhere", "SHLVL": "3"]) == base)

        try sandbox.write("// 2", to: "Package.swift")
        let edited = try #require(digest())
        #expect(edited != base)
        try sandbox.write("// for 6.0", to: "Package@swift-6.0.swift")
        #expect(digest() != edited)
        // Not a manifest.
        let withBoth = digest()
        try sandbox.write("{}", to: "Package.resolved")
        #expect(digest() == withBoth)
    }

    @Test func listingFollowsTheFilesOfTheDirectoriesNotTheirContents() throws {
        let sandbox = try Sandbox()
        func listing(_ directories: [String] = ["Sources/App", "Tests/AppTests"]) -> String {
            PackageInputs.listing(of: directories, in: sandbox.root)
        }
        try sandbox.write("a", to: "Sources/App/A.swift")
        try sandbox.write("t", to: "Tests/AppTests/ATests.swift")
        let base = listing()
        #expect(listing() == base)
        #expect(listing(["Tests/AppTests", "Sources/App"]) == base)

        try sandbox.write("changed", to: "Sources/App/A.swift")
        #expect(listing() == base)
        // Outside the targets.
        try sandbox.write("x", to: "Scripts/x.swift")
        #expect(listing() == base)

        try sandbox.write("b", to: "Sources/App/Nested/B.swift")
        let added = listing()
        #expect(added != base)
        try FileManager.default.moveItem(
            at: sandbox.root.appendingPathComponent("Sources/App/Nested/B.swift"),
            to: sandbox.root.appendingPathComponent("Sources/App/Nested/C.swift")
        )
        #expect(listing() != added)
        try FileManager.default.removeItem(at: sandbox.root.appendingPathComponent("Sources/App/Nested"))
        #expect(listing() == base)
    }

    @Test func listingFollowsLinksToDirectoriesAndEndsWhenTheyLeadBack() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a", to: "Sources/App/A.swift")
        try sandbox.write("s", to: "Shared/S.swift")
        let base = PackageInputs.listing(of: ["Sources/App"], in: sandbox.root)

        try FileManager.default.createSymbolicLink(
            at: sandbox.root.appendingPathComponent("Sources/App/Shared"),
            withDestinationURL: sandbox.root.appendingPathComponent("Shared")
        )
        let linked = PackageInputs.listing(of: ["Sources/App"], in: sandbox.root)
        #expect(linked != base)
        try sandbox.write("t", to: "Shared/T.swift")
        #expect(PackageInputs.listing(of: ["Sources/App"], in: sandbox.root) != linked)

        try FileManager.default.createSymbolicLink(
            at: sandbox.root.appendingPathComponent("Shared/Back"),
            withDestinationURL: sandbox.root.appendingPathComponent("Sources/App")
        )
        // Terminates.
        _ = PackageInputs.listing(of: ["Sources/App"], in: sandbox.root)
    }

    // MARK: - Local dependencies

    private func workspaceState(kinds: [String]) -> Data {
        let dependencies = kinds.map { #"{ "packageRef": { "identity": "x", "kind": "\#($0)" }, "subpath": "x" }"# }
        return Data(#"{ "object": { "artifacts": [], "dependencies": [\#(dependencies.joined(separator: ","))] }, "version": 7 }"#.utf8)
    }

    @Test func dependenciesFetchedIntoTheCopyAreNotLocal() {
        // A package without dependencies has no workspace state.
        #expect(!LocalDependencies.exist(workspaceState: nil))
        #expect(!LocalDependencies.exist(workspaceState: workspaceState(kinds: [])))
        #expect(!LocalDependencies.exist(workspaceState: workspaceState(kinds: ["remoteSourceControl", "registry"])))
    }

    @Test func aDependencyThatIsADirectoryOnThisMachineIsLocal() {
        #expect(LocalDependencies.exist(workspaceState: workspaceState(kinds: ["remoteSourceControl", "fileSystem"])))
        #expect(LocalDependencies.exist(workspaceState: workspaceState(kinds: ["localSourceControl"])))
        // Cannot tell: the copy is built to find out.
        #expect(LocalDependencies.exist(workspaceState: Data("{}".utf8)))
    }

    // MARK: - Digest

    @Test func digestTellsListsApartThatJoinToTheSameText() {
        #expect(Digest.of(["ab", "c"]) != Digest.of(["a", "bc"]))
        #expect(Digest.of(["ab"]) != Digest.of(["a", "b"]))
        #expect(Digest.of(["a", "b"]) == Digest.of(["a", "b"]))
    }
}

struct ExecutedMethodsTests {
    private func mutants(_ ids: Int...) -> [Mutant] {
        ids.map { Mutant(id: $0, mutation: .returnNumber("0")) }
    }

    /// A method records with its first mutant, whatever its cases recorded.
    @Test func aMethodWithMutantsRanWhenItsFirstMutantWasRecorded() {
        #expect(ExecutedMethods.wasRecorded([3], mutants: mutants(3, 4), cases: []) == true)
        #expect(ExecutedMethods.wasRecorded([4], mutants: mutants(3, 4), cases: []) == false)
        #expect(ExecutedMethods.wasRecorded([], mutants: mutants(3, 4), cases: [mutants(5)]) == false)
        #expect(ExecutedMethods.wasRecorded([5], mutants: mutants(3, 4), cases: [mutants(5)]) == false)
    }

    /// A method without mutants of its own may have returned before its switch, or taken a case
    /// without mutants.
    @Test func aMethodWithOnlyCaseMutantsRanWhenACaseWasRecordedAndIsUnknownOtherwise() {
        let cases = [mutants(5, 6), [], mutants(7)]
        #expect(ExecutedMethods.wasRecorded([7], mutants: [], cases: cases) == true)
        #expect(ExecutedMethods.wasRecorded([5], mutants: [], cases: cases) == true)
        // Only the first mutant of a case records.
        #expect(ExecutedMethods.wasRecorded([6], mutants: [], cases: cases) == nil)
        #expect(ExecutedMethods.wasRecorded([], mutants: [], cases: cases) == nil)
    }
}
