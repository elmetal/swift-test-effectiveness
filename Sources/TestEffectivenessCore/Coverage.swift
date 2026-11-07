import Foundation

/// Function-level execution counts from an `llvm-cov export` JSON file (what
/// `swift test --enable-code-coverage` writes to `--show-codecov-path`).
///
/// Coverage measures only the *Execution* step of the PIE model. It is used here to (1) label
/// methods that no test reaches as `not-covered`, and (2) avoid running mutants that cannot
/// possibly be detected.
public struct CoverageMap: Sendable {
    struct FunctionEntry: Sendable {
        var start: SourcePosition
        var count: Int
    }

    /// Keyed by absolute (standardized) file path.
    var functionsByFile: [String: [FunctionEntry]]

    public init(jsonData: Data) throws {
        let export = try JSONDecoder().decode(Export.self, from: jsonData)
        var map: [String: [FunctionEntry]] = [:]
        for data in export.data {
            for function in data.functions {
                guard let region = function.regions.first, region.count >= 5,
                      let file = function.filenames.first
                else { continue }
                let entry = FunctionEntry(
                    start: SourcePosition(line: region[0], column: region[1]),
                    count: function.count
                )
                map[Self.normalize(file), default: []].append(entry)
            }
        }
        functionsByFile = map
    }

    /// Whether the function whose body starts at `bodyStart` was executed. `nil` when the
    /// coverage data has no matching function (treated as unknown → mutants are run).
    public func wasExecuted(file: String, bodyStart: SourcePosition) -> Bool? {
        guard let entries = functionsByFile[Self.normalize(file)] else { return nil }
        let sameLine = entries.filter { $0.start.line == bodyStart.line }
        guard !sameLine.isEmpty else { return nil }
        // Several functions may start on one line (one-liners, closures); take the nearest column
        // at or after the brace, since schema insertions only ever shift columns to the right.
        let best = sameLine
            .filter { $0.start.column >= bodyStart.column }
            .min { $0.start.column < $1.start.column }
            ?? sameLine.min { abs($0.start.column - bodyStart.column) < abs($1.start.column - bodyStart.column) }
        // Generic or multiply-instantiated functions can appear more than once.
        let matching = sameLine.filter { $0.start == best?.start }
        return matching.contains { $0.count > 0 }
    }

    static func normalize(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }

    private struct Export: Decodable {
        var data: [ExportData]
    }

    private struct ExportData: Decodable {
        var functions: [Function]
    }

    private struct Function: Decodable {
        var count: Int
        var regions: [[Int]]
        var filenames: [String]
    }
}
