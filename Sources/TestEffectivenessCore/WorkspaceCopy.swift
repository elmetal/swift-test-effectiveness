import Foundation

/// Keeps the copy of the project that the analysis builds up to date.
///
/// The copy is updated in place instead of being deleted and copied again: a file that did not
/// change is not touched, so the build system sees the same file (inode, size, modification time)
/// and does not rebuild what depends on it, and whatever the build wrote into the copy (`.build`,
/// a derived data directory given to `xcodebuild`) stays for the next run.
///
/// A manifest lists what the last run copied. Files in it that are gone from the project are
/// removed from the copy; files that are not in it were written by the build and are left alone.
enum WorkspaceCopy {
    /// Never copied when they are at the top of the project: build output, and data that is not
    /// needed to build.
    static let excludedAtTopLevel: Set<String> = [".build", ".git", ".swiftpm", "DerivedData", "xcuserdata"]
    /// Never copied, wherever they are: SwiftPM's build directory, also of a package or a
    /// worktree inside the project.
    static let excludedEverywhere: Set<String> = [".build"]

    struct Summary: Equatable {
        /// Files and symbolic links copied or written.
        var written = 0
        /// Files and symbolic links that were already up to date.
        var unchanged = 0
        /// Files, symbolic links and directories removed because the project no longer has them.
        var removed = 0
    }

    struct Manifest: Codable, Equatable {
        /// Relative paths of files and symbolic links.
        var files: Set<String> = []
        var directories: Set<String> = []
    }

    /// - Parameters:
    ///   - manifest: where the list of copied files is kept between runs. Without one, everything
    ///     in the copy except `.build` is removed first, as there is no telling what is stale.
    ///   - skipping: directories inside the project that are not copied (the work directory).
    ///   - contents: files that get these contents instead of the project's, by relative path
    ///     (the mutant schema).
    @discardableResult
    static func sync(
        from project: URL, to copy: URL, manifest manifestFile: URL, skipping: [URL] = [],
        contents: [String: Data] = [:]
    ) throws -> Summary {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: copy, withIntermediateDirectories: true)

        let previous = (try? Data(contentsOf: manifestFile)).flatMap { try? JSONDecoder().decode(Manifest.self, from: $0) }
        // If this run fails halfway, the old manifest no longer describes the copy.
        try? fileManager.removeItem(at: manifestFile)
        if previous == nil {
            for item in try fileManager.contentsOfDirectory(atPath: copy.path) where item != ".build" {
                try fileManager.removeItem(at: copy.appendingPathComponent(item))
            }
        }

        var summary = Summary()
        var current = Manifest()
        let skipped = Set(skipping.map { $0.standardizedFileURL.path })

        func attributes(_ url: URL) -> (type: FileAttributeType, size: Int, modified: Date?)? {
            // Does not follow symbolic links.
            guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
                  let type = attributes[.type] as? FileAttributeType
            else { return nil }
            return (type, (attributes[.size] as? NSNumber)?.intValue ?? 0, attributes[.modificationDate] as? Date)
        }
        /// Makes room for something of another kind (a file where a directory was, …).
        func removeUnless(_ type: FileAttributeType, _ url: URL) throws -> Bool {
            guard let existing = attributes(url) else { return false }
            if existing.type == type { return true }
            try fileManager.removeItem(at: url)
            return false
        }
        func write(_ data: Data, to destination: URL) throws {
            if try removeUnless(.typeRegular, destination), (try? Data(contentsOf: destination)) == data {
                summary.unchanged += 1
                return
            }
            try data.write(to: destination, options: .atomic)
            summary.written += 1
        }

        func visit(_ relativeDirectory: String) throws {
            let directory = relativeDirectory.isEmpty ? project : project.appendingPathComponent(relativeDirectory)
            for name in try fileManager.contentsOfDirectory(atPath: directory.path).sorted() {
                if excludedEverywhere.contains(name) { continue }
                if relativeDirectory.isEmpty && excludedAtTopLevel.contains(name) { continue }
                let relative = relativeDirectory.isEmpty ? name : "\(relativeDirectory)/\(name)"
                let source = project.appendingPathComponent(relative)
                if skipped.contains(source.standardizedFileURL.path) { continue }
                guard let found = attributes(source) else { continue }
                let destination = copy.appendingPathComponent(relative)

                switch found.type {
                case .typeDirectory:
                    if try !removeUnless(.typeDirectory, destination) {
                        try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)
                    }
                    current.directories.insert(relative)
                    try visit(relative)
                case .typeSymbolicLink:
                    let target = try fileManager.destinationOfSymbolicLink(atPath: source.path)
                    current.files.insert(relative)
                    if try removeUnless(.typeSymbolicLink, destination) {
                        if (try? fileManager.destinationOfSymbolicLink(atPath: destination.path)) == target {
                            summary.unchanged += 1
                            continue
                        }
                        try fileManager.removeItem(at: destination)
                    }
                    try fileManager.createSymbolicLink(atPath: destination.path, withDestinationPath: target)
                    summary.written += 1
                case .typeRegular:
                    current.files.insert(relative)
                    if let data = contents[relative] {
                        try write(data, to: destination)
                        continue
                    }
                    // Copies keep the modification time, so the same size and time mean the same
                    // file. A file that had other contents last time (a schema) differs in both.
                    if try removeUnless(.typeRegular, destination), let existing = attributes(destination),
                       existing.size == found.size, existing.modified == found.modified {
                        summary.unchanged += 1
                        continue
                    }
                    try? fileManager.removeItem(at: destination)
                    try fileManager.copyItem(at: source, to: destination)
                    if let modified = found.modified, attributes(destination)?.modified != modified {
                        try fileManager.setAttributes([.modificationDate: modified], ofItemAtPath: destination.path)
                    }
                    summary.written += 1
                default:
                    continue
                }
            }
        }
        try visit("")

        // Contents for a path the walk did not come across still have to be there: without its
        // schema, a file's mutants would never be active.
        for (relative, data) in contents where !current.files.contains(relative) {
            let destination = copy.appendingPathComponent(relative)
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try write(data, to: destination)
            current.files.insert(relative)
        }

        if let previous {
            for relative in previous.files.subtracting(current.files) {
                let stale = copy.appendingPathComponent(relative)
                // Not what is inside a directory that took the file's place.
                guard let existing = attributes(stale), existing.type != .typeDirectory else { continue }
                try fileManager.removeItem(at: stale)
                summary.removed += 1
            }
            // Deepest first; a directory the build wrote into is not empty and stays.
            for relative in previous.directories.subtracting(current.directories).sorted(by: { $0.count > $1.count }) {
                if rmdir(copy.appendingPathComponent(relative).path) == 0 { summary.removed += 1 }
            }
        }

        try JSONEncoder().encode(current).write(to: manifestFile, options: .atomic)
        return summary
    }
}
