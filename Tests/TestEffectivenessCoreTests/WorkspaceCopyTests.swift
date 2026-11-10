import Foundation
import Testing
@testable import TestEffectivenessCore

struct WorkspaceCopyTests {
    /// A project and a place for its copy, removed when the test ends.
    final class Sandbox {
        let root: URL
        var project: URL { root.appendingPathComponent("project") }
        var copy: URL { root.appendingPathComponent("work/copy") }
        var manifest: URL { root.appendingPathComponent("work/copied-files.json") }

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("ste-copy-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("work"), withIntermediateDirectories: true)
        }

        deinit { try? FileManager.default.removeItem(at: root) }

        func write(_ contents: String, to relativePath: String, in base: URL? = nil) throws {
            let url = (base ?? project).appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contents.utf8).write(to: url)
        }

        func read(_ relativePath: String) -> String? {
            try? String(contentsOf: copy.appendingPathComponent(relativePath), encoding: .utf8)
        }

        func exists(_ relativePath: String) -> Bool {
            FileManager.default.fileExists(atPath: copy.appendingPathComponent(relativePath).path)
        }

        /// What a build system looks at to decide whether a file changed.
        func identity(_ relativePath: String) throws -> [String] {
            let attributes = try FileManager.default.attributesOfItem(atPath: copy.appendingPathComponent(relativePath).path)
            return [
                "\(attributes[.systemFileNumber] ?? "")", "\(attributes[.size] ?? "")",
                "\((attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)",
            ]
        }

        @discardableResult
        func sync(contents: [String: String] = [:]) throws -> WorkspaceCopy.Summary {
            try WorkspaceCopy.sync(
                from: project, to: copy, manifest: manifest,
                contents: contents.mapValues { Data($0.utf8) }
            )
        }
    }

    @Test func copiesTheProjectWithoutBuildDirectories() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a", to: "Sources/A/A.swift")
        try sandbox.write("p", to: "Package.swift")
        try sandbox.write("x", to: ".build/debug/x")
        try sandbox.write("x", to: ".git/HEAD")
        try sandbox.write("x", to: "Packages/Inner/.build/debug/x")
        try sandbox.write("i", to: "Packages/Inner/Package.swift")
        // Only `.build` is left out below the top level.
        try sandbox.write("d", to: "Sources/A/DerivedData/kept.txt")

        let summary = try sandbox.sync()
        #expect(summary == WorkspaceCopy.Summary(written: 4, unchanged: 0, removed: 0))
        #expect(sandbox.read("Sources/A/A.swift") == "a")
        #expect(sandbox.read("Packages/Inner/Package.swift") == "i")
        #expect(sandbox.read("Sources/A/DerivedData/kept.txt") == "d")
        #expect(!sandbox.exists(".build"))
        #expect(!sandbox.exists(".git"))
        #expect(!sandbox.exists("Packages/Inner/.build"))
    }

    @Test func leavesUnchangedFilesUntouched() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a", to: "Sources/A.swift")
        try sandbox.write("b", to: "Sources/B.swift")
        try sandbox.sync(contents: ["Sources/B.swift": "b with schema"])
        let a = try sandbox.identity("Sources/A.swift")
        let b = try sandbox.identity("Sources/B.swift")

        let summary = try sandbox.sync(contents: ["Sources/B.swift": "b with schema"])
        #expect(summary == WorkspaceCopy.Summary(written: 0, unchanged: 2, removed: 0))
        #expect(try sandbox.identity("Sources/A.swift") == a)
        #expect(try sandbox.identity("Sources/B.swift") == b)
        #expect(sandbox.read("Sources/B.swift") == "b with schema")
    }

    @Test func copiesChangedFilesAndReplacesOldSchemata() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a", to: "Sources/A.swift")
        try sandbox.write("b", to: "Sources/B.swift")
        try sandbox.sync(contents: ["Sources/B.swift": "b with schema"])

        // A changes in the project; B is no longer mutated, A is.
        try sandbox.write("a changed", to: "Sources/A.swift")
        let summary = try sandbox.sync(contents: ["Sources/A.swift": "a changed with schema"])
        #expect(summary == WorkspaceCopy.Summary(written: 2, unchanged: 0, removed: 0))
        #expect(sandbox.read("Sources/A.swift") == "a changed with schema")
        #expect(sandbox.read("Sources/B.swift") == "b")
    }

    @Test func removesWhatTheProjectNoLongerHasButKeepsBuildOutput() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a", to: "Sources/A.swift")
        try sandbox.write("old", to: "Sources/Old/Old.swift")
        try sandbox.write("gone", to: "Gone/Gone.swift")
        try sandbox.sync()
        // What a build writes into the copy.
        try sandbox.write("o", to: ".build/debug/a.o", in: sandbox.copy)
        try sandbox.write("o", to: "build/Products/a.o", in: sandbox.copy)
        try sandbox.write("generated", to: "Sources/Old/Generated.swift", in: sandbox.copy)

        try FileManager.default.removeItem(at: sandbox.project.appendingPathComponent("Sources/Old"))
        try FileManager.default.removeItem(at: sandbox.project.appendingPathComponent("Gone"))
        let summary = try sandbox.sync()
        // Old.swift, Gone.swift and the directory Gone; Sources/Old still holds a generated file.
        #expect(summary == WorkspaceCopy.Summary(written: 0, unchanged: 1, removed: 3))
        #expect(!sandbox.exists("Sources/Old/Old.swift"))
        #expect(!sandbox.exists("Gone"))
        #expect(sandbox.read("Sources/Old/Generated.swift") == "generated")
        #expect(sandbox.read(".build/debug/a.o") == "o")
        #expect(sandbox.read("build/Products/a.o") == "o")
    }

    /// A copy made before there was a manifest: nothing says which files are stale.
    @Test func withoutManifestStartsOverButKeepsBuildDirectory() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a", to: "Sources/A.swift")
        try sandbox.write("stale", to: "Sources/Stale.swift", in: sandbox.copy)
        try sandbox.write("o", to: ".build/debug/a.o", in: sandbox.copy)

        let summary = try sandbox.sync()
        #expect(summary == WorkspaceCopy.Summary(written: 1, unchanged: 0, removed: 0))
        #expect(!sandbox.exists("Sources/Stale.swift"))
        #expect(sandbox.read(".build/debug/a.o") == "o")
        #expect(FileManager.default.fileExists(atPath: sandbox.manifest.path))
    }

    @Test func copiesSymbolicLinksAsLinks() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a", to: "Sources/A.swift")
        let link = sandbox.project.appendingPathComponent("Link.swift")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Sources/A.swift")

        #expect(try sandbox.sync().written == 2)
        let copied = sandbox.copy.appendingPathComponent("Link.swift").path
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied) == "Sources/A.swift")
        #expect(try sandbox.sync() == WorkspaceCopy.Summary(written: 0, unchanged: 2, removed: 0))

        try FileManager.default.removeItem(at: link)
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: "Sources")
        #expect(try sandbox.sync() == WorkspaceCopy.Summary(written: 1, unchanged: 1, removed: 0))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: copied) == "Sources")
    }

    @Test func fileAndDirectoryCanTakeEachOthersPlace() throws {
        let sandbox = try Sandbox()
        try sandbox.write("file", to: "Thing")
        try sandbox.write("a", to: "Other/A.swift")
        try sandbox.sync()

        try FileManager.default.removeItem(at: sandbox.project.appendingPathComponent("Thing"))
        try FileManager.default.removeItem(at: sandbox.project.appendingPathComponent("Other"))
        try sandbox.write("inside", to: "Thing/Inside.swift")
        try sandbox.write("file", to: "Other")
        try sandbox.sync()
        #expect(sandbox.read("Thing/Inside.swift") == "inside")
        #expect(sandbox.read("Other") == "file")
    }

    @Test func skipsTheWorkDirectoryInsideTheProject() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a", to: "Sources/A.swift")
        let work = sandbox.project.appendingPathComponent("work")
        try sandbox.write("log", to: "work/logs/build.log")
        try WorkspaceCopy.sync(
            from: sandbox.project, to: work.appendingPathComponent("project"),
            manifest: work.appendingPathComponent("copied-files.json"), skipping: [work]
        )
        #expect(FileManager.default.fileExists(atPath: work.appendingPathComponent("project/Sources/A.swift").path))
        #expect(!FileManager.default.fileExists(atPath: work.appendingPathComponent("project/work").path))
    }

    /// The schema of a file must be in the copy even if the walk did not list the file.
    @Test func writesContentsForPathsItDidNotComeAcross() throws {
        let sandbox = try Sandbox()
        try sandbox.write("a", to: "Sources/A.swift")
        try sandbox.sync(contents: ["Generated/New.swift": "schema"])
        #expect(sandbox.read("Generated/New.swift") == "schema")
    }
}
