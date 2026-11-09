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

    /// Combines maps exported from several binaries. A function linked into more than one binary
    /// counts as executed if any of them executed it.
    init(merging maps: [CoverageMap]) {
        functionsByFile = maps.reduce(into: [:]) { result, map in
            result.merge(map.functionsByFile) { $0 + $1 }
        }
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

/// Finds the files `xcodebuild -enableCodeCoverage YES` writes, for custom mode.
enum CoverageArtifacts {
    /// `path` itself if it is a file, otherwise the most recently modified `.profdata` under it.
    /// Profiles older than `modifiedAfter` are ignored, so a profile left over from an earlier run
    /// is never read.
    static func profile(at path: URL, modifiedAfter: Date) -> URL? {
        let candidates = isDirectory(path)
            ? files(under: path).filter { $0.pathExtension == "profdata" }
            : [path]
        return candidates
            .compactMap { url in modificationDate(url).map { (url, $0) } }
            .filter { $0.1 >= modifiedAfter }
            .max { $0.1 < $1.1 }?.0
    }

    /// `path` itself if it is a file, otherwise every Mach-O file under it (outside `.dSYM` bundles).
    static func binaries(at path: URL) -> [URL] {
        guard isDirectory(path) else { return [path] }
        return files(under: path).filter(isMachO).sorted { $0.path < $1.path }
    }

    static func isMachO(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 4), data.count == 4 else { return false }
        let magic = data.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }
        // 64-bit, 32-bit and universal binaries, in either byte order.
        return [0xFEEDFACF, 0xCFFAEDFE, 0xFEEDFACE, 0xCEFAEDFE, 0xCAFEBABE, 0xBEBAFECA].contains(magic)
    }

    private static func files(under directory: URL) -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]
        ) else { return [] }
        var result: [URL] = []
        for case let url as URL in enumerator {
            if url.pathExtension == "dSYM" {
                enumerator.skipDescendants()
                continue
            }
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values?.isRegularFile == true && values?.isSymbolicLink != true { result.append(url) }
        }
        return result
    }

    private static func isDirectory(_ url: URL) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    private static func modificationDate(_ url: URL) -> Date? {
        try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
    }
}
