import Foundation

/// Lines changed relative to a git revision, used to restrict analysis to methods touched by a
/// change (the cheap, per-pull-request mode that extreme mutation makes practical).
public struct ChangedLines: Sendable {
    /// Absolute file path → changed line numbers in the working tree. Added and modified lines are
    /// included, and so are the two lines around a deletion.
    public var linesByFile: [String: Set<Int>]
    /// Absolute paths of new files that git does not track yet. Every line of them counts as changed.
    public var addedFiles: Set<String>
    /// Absolute paths of the files the change deleted → what they contained.
    public var deletedFiles: [String: String]

    public init(linesByFile: [String: Set<Int>], addedFiles: Set<String> = [], deletedFiles: [String: String] = [:]) {
        self.linesByFile = linesByFile
        self.addedFiles = addedFiles
        self.deletedFiles = deletedFiles
    }

    public func intersects(file: String, lines: ClosedRange<Int>) -> Bool {
        let path = CoverageMap.normalize(file)
        if addedFiles.contains(path) { return true }
        guard let changed = linesByFile[path] else { return false }
        return changed.contains { lines.contains($0) }
    }

    public static func load(since revision: String, in directory: URL) throws -> ChangedLines {
        let root = try ProcessRunner.run(["git", "rev-parse", "--show-toplevel"], in: directory)
        guard root.exitCode == 0 else { throw AnalysisError.git(root.output) }
        let rootPath = root.output.trimmingCharacters(in: .whitespacesAndNewlines)

        // The user's git configuration must not change how paths are written: `core.quotePath`
        // escapes non-ASCII names, `diff.mnemonicPrefix` and `diff.noprefix` change the `b/` in
        // front of them, and `diff.relative` makes them relative to `directory`.
        let git = ["git", "-c", "core.quotePath=false"]
        let diff = try ProcessRunner.run(
            git + [
                "diff", "--unified=0", "--no-color", "--no-ext-diff", "--no-relative",
                "--src-prefix=a/", "--dst-prefix=b/", revision, "--", "*.swift",
            ],
            in: directory
        )
        guard diff.exitCode == 0 else { throw AnalysisError.git(diff.output) }

        // `git diff <revision>` does not show files that were never added.
        let untracked = try ProcessRunner.run(
            git + ["ls-files", "--others", "--exclude-standard", "--full-name", "--", "*.swift"],
            in: directory
        )
        guard untracked.exitCode == 0 else { throw AnalysisError.git(untracked.output) }

        let rootURL = URL(fileURLWithPath: rootPath)
        var changed = parse(diff: diff.output, root: rootURL)
        changed.addedFiles = parseFileList(untracked.output, root: rootURL)
        return changed
    }

    /// Parses `git ls-files --full-name` output (paths relative to the repository root).
    static func parseFileList(_ output: String, root: URL) -> Set<String> {
        Set(output.split(separator: "\n").map {
            CoverageMap.normalize(root.appendingPathComponent(String($0)).path)
        })
    }

    /// Parses `git diff --unified=0` output.
    public static func parse(diff: String, root: URL) -> ChangedLines {
        var result = ChangedLines(linesByFile: [:])
        // A deleted file cannot be asked for its real path, as `CoverageMap.normalize` does: only
        // the root's symbolic links are resolved for it.
        let deletedRoot = URL(fileURLWithPath: CoverageMap.normalize(root.path))
        var oldPath: String?
        var currentFile: String?
        var deletedFile: String?
        // The lines of the current hunk that are still to come. They are counted, because a line
        // of code can look like a header once its `-` or `+` is in front of it (`-- a` → `--- a`).
        var hunkLines = 0
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if hunkLines > 0 {
                if line.hasPrefix("-") || line.hasPrefix("+") {
                    hunkLines -= 1
                    if let deletedFile, line.hasPrefix("-") {
                        result.deletedFiles[deletedFile, default: ""] += line.dropFirst() + "\n"
                    }
                    continue
                }
                // "\ No newline at end of file" is not one of the counted lines.
                if line.hasPrefix("\\") { continue }
                // Without context lines nothing else is part of a hunk: the count was wrong.
                hunkLines = 0
            }
            if line.hasPrefix("--- ") {
                oldPath = path(in: line, prefix: "a/")
            } else if line.hasPrefix("+++ ") {
                currentFile = path(in: line, prefix: "b/").map {
                    CoverageMap.normalize(root.appendingPathComponent($0).path)
                }
                deletedFile = currentFile == nil ? oldPath.map { deletedRoot.appendingPathComponent($0).path } : nil
                if let deletedFile { result.deletedFiles[deletedFile] = "" }
            } else if line.hasPrefix("@@") {
                // @@ -a,b +c,d @@
                let ranges = line.split(separator: " ").dropFirst().prefix(2)
                guard ranges.count == 2, let minus = ranges.first, let plus = ranges.last,
                      minus.hasPrefix("-"), plus.hasPrefix("+"),
                      let old = range(minus), let new = range(plus) else { continue }
                hunkLines = old.count + new.count
                guard let file = currentFile else { continue }
                if new.count > 0 {
                    result.linesByFile[file, default: []].formUnion(new.start..<(new.start + new.count))
                } else {
                    // Lines were only deleted, between new lines `start` and `start + 1`. Mark both
                    // so that a method whose body lost lines is still analysed. (A deletion between
                    // two methods may also select a neighbour; analysing too much is the safe side.)
                    result.linesByFile[file, default: []].formUnion([new.start, new.start + 1].filter { $0 > 0 })
                }
            }
        }
        return result
    }

    /// The file a `--- ` or `+++ ` line names, relative to the repository root; `nil` for `/dev/null`.
    private static func path(in line: Substring, prefix: String) -> String? {
        // git ends a path that contains a space with a tab.
        var path = line.dropFirst(4)
        if path.hasSuffix("\t") { path = path.dropLast() }
        guard path != "/dev/null" else { return nil }
        return path.hasPrefix(prefix) ? String(path.dropFirst(prefix.count)) : String(path)
    }

    /// `-a,b` or `+c,d` of a hunk header; the count is 1 when it is not written.
    private static func range(_ written: Substring) -> (start: Int, count: Int)? {
        let parts = written.dropFirst().split(separator: ",")
        guard let first = parts.first, let start = Int(first) else { return nil }
        return (start, parts.count > 1 ? Int(parts[1]) ?? 1 : 1)
    }
}

/// The test files a change touches.
///
/// `--since` selects declarations of the analysed sources by their own changed lines, so a change
/// to a test selects nothing, although it can change what the tests detect. These are the files
/// to tell the user about.
enum ChangedTests {
    /// - Parameter analyzed: absolute paths of the analysed sources (as `CoverageMap.normalize`
    ///   writes them), which are never test files.
    /// - Returns: absolute paths, sorted; files the change deleted are among them.
    static func files(in changed: ChangedLines, analyzed: Set<String>) -> [String] {
        var files: [String] = []
        for path in Set(changed.linesByFile.keys).union(changed.addedFiles) where !analyzed.contains(path) {
            guard let source = try? String(contentsOfFile: path, encoding: .utf8) else { continue }
            if TestScopeFinder.importsTestFramework(source) { files.append(path) }
        }
        for (path, source) in changed.deletedFiles where !analyzed.contains(path) {
            if TestScopeFinder.importsTestFramework(source) { files.append(path) }
        }
        return files.sorted()
    }
}
