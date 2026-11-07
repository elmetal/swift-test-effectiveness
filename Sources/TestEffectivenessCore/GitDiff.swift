import Foundation

/// Lines changed relative to a git revision, used to restrict analysis to methods touched by a
/// change (the cheap, per-pull-request mode that extreme mutation makes practical).
public struct ChangedLines: Sendable {
    /// Absolute file path → changed (added or modified) line numbers in the working tree.
    public var linesByFile: [String: Set<Int>]

    public init(linesByFile: [String: Set<Int>]) {
        self.linesByFile = linesByFile
    }

    public func intersects(file: String, lines: ClosedRange<Int>) -> Bool {
        guard let changed = linesByFile[CoverageMap.normalize(file)] else { return false }
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
        return parse(diff: diff.output, root: URL(fileURLWithPath: rootPath))
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
                guard count > 0 else { continue }
                result[file, default: []].formUnion(start..<(start + count))
            }
        }
        return ChangedLines(linesByFile: result)
    }
}
