import Foundation

/// Lines changed relative to a git revision, used to restrict analysis to methods touched by a
/// change (the cheap, per-pull-request mode that extreme mutation makes practical).
public struct ChangedLines: Sendable {
    /// Absolute file path → changed line numbers in the working tree. Added and modified lines are
    /// included, and so are the two lines around a deletion.
    public var linesByFile: [String: Set<Int>]
    /// Absolute paths of new files that git does not track yet. Every line of them counts as changed.
    public var addedFiles: Set<String>

    public init(linesByFile: [String: Set<Int>], addedFiles: Set<String> = []) {
        self.linesByFile = linesByFile
        self.addedFiles = addedFiles
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

        let diff = try ProcessRunner.run(
            ["git", "diff", "--unified=0", "--no-color", "--no-ext-diff", revision, "--", "*.swift"],
            in: directory
        )
        guard diff.exitCode == 0 else { throw AnalysisError.git(diff.output) }

        // `git diff <revision>` does not show files that were never added.
        let untracked = try ProcessRunner.run(
            ["git", "ls-files", "--others", "--exclude-standard", "--full-name", "--", "*.swift"],
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
        var result: [String: Set<Int>] = [:]
        var currentFile: String?
        for line in diff.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("+++ ") {
                let path = line.dropFirst(4)
                if path == "/dev/null" {
                    currentFile = nil
                } else {
                    let relative = path.hasPrefix("b/") ? String(path.dropFirst(2)) : String(path)
                    currentFile = CoverageMap.normalize(root.appendingPathComponent(relative).path)
                }
            } else if line.hasPrefix("@@"), let file = currentFile {
                // @@ -a,b +c,d @@
                guard let plus = line.split(separator: " ").first(where: { $0.hasPrefix("+") }) else { continue }
                let parts = plus.dropFirst().split(separator: ",")
                guard let start = Int(parts[0]) else { continue }
                let count = parts.count > 1 ? Int(parts[1]) ?? 1 : 1
                if count > 0 {
                    result[file, default: []].formUnion(start..<(start + count))
                } else {
                    // Lines were only deleted, between new lines `start` and `start + 1`. Mark both
                    // so that a method whose body lost lines is still analysed. (A deletion between
                    // two methods may also select a neighbour; analysing too much is the safe side.)
                    result[file, default: []].formUnion([start, start + 1].filter { $0 > 0 })
                }
            }
        }
        return ChangedLines(linesByFile: result)
    }
}
