import Foundation
import Testing
@testable import TestEffectivenessCore

struct CoverageMapTests {
    @Test func matchesFunctionByBodyBrace() throws {
        let json = """
        {"data":[{"functions":[
          {"name":"f","count":3,"regions":[[7,48,9,6,3,0,0,0]],"filenames":["/p/A.swift"]},
          {"name":"g","count":0,"regions":[[12,10,14,6,0,0,0,0]],"filenames":["/p/A.swift"]},
          {"name":"h","count":1,"regions":[[20,30,20,40,1,0,0,0]],"filenames":["/p/A.swift"]},
          {"name":"closure","count":0,"regions":[[20,60,20,70,0,0,0,0]],"filenames":["/p/A.swift"]}
        ]}]}
        """
        let map = try CoverageMap(jsonData: Data(json.utf8))
        #expect(map.wasExecuted(file: "/p/A.swift", bodyStart: SourcePosition(line: 7, column: 48)) == true)
        #expect(map.wasExecuted(file: "/p/A.swift", bodyStart: SourcePosition(line: 12, column: 10)) == false)
        #expect(map.wasExecuted(file: "/p/A.swift", bodyStart: SourcePosition(line: 20, column: 30)) == true)
        #expect(map.wasExecuted(file: "/p/A.swift", bodyStart: SourcePosition(line: 20, column: 55)) == false)
        #expect(map.wasExecuted(file: "/p/A.swift", bodyStart: SourcePosition(line: 99, column: 1)) == nil)
        #expect(map.wasExecuted(file: "/p/B.swift", bodyStart: SourcePosition(line: 7, column: 48)) == nil)
    }

    /// A function linked into several binaries (the app and a test bundle) is executed if any
    /// binary executed it.
    @Test func mergedMapsCountAnyExecution() throws {
        func map(count: Int) throws -> CoverageMap {
            try CoverageMap(jsonData: Data("""
            {"data":[{"functions":[
              {"name":"f","count":\(count),"regions":[[7,48,9,6,\(count),0,0,0]],"filenames":["/p/A.swift"]}
            ]}]}
            """.utf8))
        }
        let merged = CoverageMap(merging: [try map(count: 0), try map(count: 2)])
        #expect(merged.wasExecuted(file: "/p/A.swift", bodyStart: SourcePosition(line: 7, column: 48)) == true)
        let unexecuted = CoverageMap(merging: [try map(count: 0)])
        #expect(unexecuted.wasExecuted(file: "/p/A.swift", bodyStart: SourcePosition(line: 7, column: 48)) == false)
    }
}

struct CoverageArtifactsTests {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("ste-artifacts-\(UUID().uuidString)")

    private func write(_ path: String, _ bytes: [UInt8], modified: Date = Date()) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(bytes).write(to: url)
        try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
        return url
    }

    @Test func findsNewestProfileWrittenSinceTheBaseline() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let now = Date()
        _ = try write("ProfileData/OLD/Coverage.profdata", [0], modified: now.addingTimeInterval(-3600))
        let fresh = try write("ProfileData/NEW/Coverage.profdata", [0], modified: now)
        _ = try write("ProfileData/NEW/notes.txt", [0], modified: now)
        let directory = root.appendingPathComponent("ProfileData")
        // The enumerator resolves /var to /private/var; compare the part under the root.
        #expect(CoverageArtifacts.profile(at: directory, modifiedAfter: now.addingTimeInterval(-60))?
            .path.hasSuffix("ProfileData/NEW/Coverage.profdata") == true)
        #expect(CoverageArtifacts.profile(at: directory, modifiedAfter: now.addingTimeInterval(60)) == nil)
        #expect(CoverageArtifacts.profile(at: fresh, modifiedAfter: now.addingTimeInterval(-60))?.path == fresh.path)
    }

    @Test func findsMachOFilesOutsideDSYMs() throws {
        defer { try? FileManager.default.removeItem(at: root) }
        let machO: [UInt8] = [0xCF, 0xFA, 0xED, 0xFE, 0, 0]
        let app = try write("Products/App.app/App", machO)
        let dylib = try write("Products/App.app/App.debug.dylib", machO)
        _ = try write("Products/App.app/Info.plist", Array("<plist>".utf8))
        _ = try write("Products/App.app.dSYM/Contents/Resources/DWARF/App", machO)
        let binaries = CoverageArtifacts.binaries(at: root.appendingPathComponent("Products"))
        #expect(binaries.map(\.lastPathComponent) == [app.lastPathComponent, dylib.lastPathComponent])
        #expect(CoverageArtifacts.binaries(at: app) == [app])
    }
}

struct GitDiffTests {
    @Test func parsesAddedAndModifiedLines() {
        let diff = """
        diff --git a/Sources/A.swift b/Sources/A.swift
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -3,0 +4,2 @@ struct S {
        +    func f() {}
        +    func g() {}
        @@ -10 +12 @@
        -old
        +new
        @@ -20,3 +21,0 @@
        diff --git a/Sources/Gone.swift b/Sources/Gone.swift
        --- a/Sources/Gone.swift
        +++ /dev/null
        @@ -1,3 +0,0 @@
        """
        let changed = ChangedLines.parse(diff: diff, root: URL(fileURLWithPath: "/repo"))
        #expect(changed.linesByFile.count == 1)
        // `+21,0`: lines were deleted between new lines 21 and 22.
        #expect(changed.linesByFile.values.first == [4, 5, 12, 21, 22])
        #expect(changed.intersects(file: "/repo/Sources/A.swift", lines: 1...4))
        #expect(!changed.intersects(file: "/repo/Sources/A.swift", lines: 6...11))
    }

    @Test func deletionInsideAMethodSelectsIt() {
        let diff = """
        --- a/Sources/A.swift
        +++ b/Sources/A.swift
        @@ -11 +10,0 @@ struct S {
        -        log(x)
        @@ -1 +0,0 @@
        -// header
        """
        let changed = ChangedLines.parse(diff: diff, root: URL(fileURLWithPath: "/repo"))
        #expect(changed.linesByFile.values.first == [1, 10, 11])
        // func f() spanning lines 8...12 lost its line 11.
        #expect(changed.intersects(file: "/repo/Sources/A.swift", lines: 8...12))
        #expect(!changed.intersects(file: "/repo/Sources/A.swift", lines: 14...20))
    }

    @Test func untrackedFilesCountAsEntirelyChanged() throws {
        let fileManager = FileManager.default
        let repo = fileManager.temporaryDirectory.appendingPathComponent("ste-git-\(UUID().uuidString)")
        try fileManager.createDirectory(at: repo.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: repo) }
        func git(_ arguments: String...) throws {
            let result = try ProcessRunner.run(
                ["git", "-c", "user.name=t", "-c", "user.email=t@example.com"] + arguments, in: repo
            )
            #expect(result.exitCode == 0, "\(result.output)")
        }
        try git("init", "-q")
        try "func a() {}\n".write(to: repo.appendingPathComponent("Sources/Old.swift"), atomically: true, encoding: .utf8)
        try git("add", ".")
        try git("commit", "-q", "-m", "init")
        try "func b() {}\n".write(to: repo.appendingPathComponent("Sources/New.swift"), atomically: true, encoding: .utf8)

        // Run from a subdirectory: paths must still resolve against the repository root.
        let changed = try ChangedLines.load(since: "HEAD", in: repo.appendingPathComponent("Sources"))
        #expect(changed.intersects(file: repo.appendingPathComponent("Sources/New.swift").path, lines: 1...1))
        #expect(!changed.intersects(file: repo.appendingPathComponent("Sources/Old.swift").path, lines: 1...1))
    }
}

struct ReporterTests {
    private var report: AnalysisReport {
        let method = MethodInfo(
            file: "Sources/A.swift", name: "Calc.isPositive(_:)", kind: .function,
            declarationStart: SourcePosition(line: 3, column: 5), declarationEnd: SourcePosition(line: 5, column: 5),
            bodyStart: SourcePosition(line: 3, column: 40), returnType: "Bool"
        )
        let mutants = [
            MutantResult(mutant: Mutant(id: 1, mutation: .returnBool(true)), outcome: .survived),
            MutantResult(mutant: Mutant(id: 2, mutation: .returnBool(false)), outcome: .killed),
        ]
        return AnalysisReport(
            projectPath: "/p", coverageAvailable: true,
            methods: [MethodResult(method: method, executed: .executed, classification: .partiallyTested, mutants: mutants)],
            skipped: []
        )
    }

    @Test func textReportGivesActionableAdvice() throws {
        let text = try Reporter.render(report, format: .text)
        #expect(text.contains("Partially tested (1)"))
        #expect(text.contains("Sources/A.swift:3"))
        #expect(text.contains("can always return `true` without any test failing. Add a case where it must return `false`."))
    }

    @Test(arguments: ReportFormat.allCases)
    func reportsContainNoAggregateScore(_ format: ReportFormat) throws {
        let rendered = try Reporter.render(report, format: format)
        #expect(!rendered.contains("%"))
        #expect(!rendered.lowercased().contains("score"))
    }

    @Test func jsonRoundTrips() throws {
        let json = try Reporter.render(report, format: .json)
        #expect(json.contains("\"executed\" : \"true\""))
        #expect(json.contains("\"referenced\" : \"unknown\""))
        let decoded = try JSONDecoder().decode(AnalysisReport.self, from: Data(json.utf8))
        #expect(decoded.methods.first?.executed == .executed)
        #expect(decoded.methods.first?.classification == .partiallyTested)
        #expect(decoded.methods.first?.survivingMutants.map(\.mutant.mutation) == [.returnBool(true)])
    }

    @Test func jsonCarriesSchemaAndToolVersion() throws {
        let json = try Reporter.render(report, format: .json)
        #expect(json.contains("\"schemaVersion\" : \(AnalysisReport.currentSchemaVersion)"))
        #expect(json.contains("\"toolVersion\" : \"\(ToolVersion.current)\""))
        let decoded = try JSONDecoder().decode(AnalysisReport.self, from: Data(json.utf8))
        #expect(decoded.schemaVersion == AnalysisReport.currentSchemaVersion)
        #expect(decoded.toolVersion == ToolVersion.current)
    }

    private func pseudoTested(executed: ExecutionStatus, coverageAvailable: Bool) -> AnalysisReport {
        let method = MethodInfo(
            file: "Sources/A.swift", name: "Log.write(_:)", kind: .function,
            declarationStart: SourcePosition(line: 8, column: 5), declarationEnd: SourcePosition(line: 9, column: 5),
            bodyStart: SourcePosition(line: 8, column: 30), returnType: nil
        )
        let mutants = [MutantResult(mutant: Mutant(id: 1, mutation: .emptyBody), outcome: .survived)]
        return AnalysisReport(
            projectPath: "/p", coverageAvailable: coverageAvailable,
            methods: [MethodResult(method: method, executed: executed, classification: .pseudoTested, mutants: mutants)],
            skipped: []
        )
    }

    @Test(arguments: [ReportFormat.text, .markdown])
    func unknownExecutionIsFlaggedPerMethod(_ format: ReportFormat) throws {
        let note = "executed: unknown"
        let unknown = try Reporter.render(pseudoTested(executed: .unknown, coverageAvailable: true), format: format)
        #expect(unknown.contains(note))
        let known = try Reporter.render(pseudoTested(executed: .executed, coverageAvailable: true), format: format)
        #expect(!known.contains(note))
        // Without coverage every method is unknown; the header says so once instead.
        let noCoverage = try Reporter.render(pseudoTested(executed: .unknown, coverageAvailable: false), format: format)
        #expect(!noCoverage.contains(note))
    }

    @Test(arguments: [ReportFormat.text, .markdown])
    func referencedColumnIsExplainedWhereItMatters(_ format: ReportFormat) throws {
        let info = { (name: String, line: Int) in
            MethodInfo(
                file: "Sources/A.swift", name: name, kind: .function,
                declarationStart: SourcePosition(line: line, column: 5), declarationEnd: SourcePosition(line: line, column: 30),
                bodyStart: SourcePosition(line: line, column: 20), returnType: "Int"
            )
        }
        let survived = [MutantResult(mutant: Mutant(id: 1, mutation: .returnNumber("0")), outcome: .survived)]
        let killed = [MutantResult(mutant: Mutant(id: 2, mutation: .returnNumber("0")), outcome: .killed)]
        let notRun = [MutantResult(mutant: Mutant(id: 3, mutation: .returnNumber("0")), outcome: .notRun)]
        let report = AnalysisReport(
            projectPath: "/p", coverageAvailable: true, referencesAvailable: true,
            methods: [
                MethodResult(method: info("Incidental.f()", 1), referenced: .notReferenced, executed: .executed,
                             classification: .pseudoTested, mutants: survived),
                MethodResult(method: info("Direct.g()", 2), referenced: .referenced, executed: .executed,
                             classification: .pseudoTested, mutants: survived),
                MethodResult(method: info("Mocked.h()", 3), referenced: .referenced, executed: .notExecuted,
                             classification: .notCovered, mutants: notRun),
                MethodResult(method: info("Indirect.i()", 4), referenced: .notReferenced, executed: .executed,
                             classification: .tested, mutants: killed),
            ],
            skipped: []
        )
        let rendered = try Reporter.render(report, format: format)
        #expect(rendered.contains("Write a test whose subject is `Incidental.f()`"))
        #expect(!rendered.contains("subject is `Direct.g()`"))
        #expect(rendered.contains("referenced by a test but never executed"))
        #expect(rendered.contains("tested only indirectly"))
        #expect(!rendered.contains("no index store"))

        let withoutIndex = AnalysisReport(projectPath: "/p", coverageAvailable: true, methods: [], skipped: [])
        #expect(try Reporter.render(withoutIndex, format: format).lowercased().contains("no index store"))
    }

    private func withTestsFailingAlone(_ tests: [TestFailingAlone]?) -> AnalysisReport {
        var report = report
        report.testsFailingAlone = tests
        return report
    }

    private let failingAlone = [
        TestFailingAlone(test: "AppTests/LookupTests", timedOut: false, log: "/w/logs/isolation-1.log"),
        TestFailingAlone(test: "AppTests/slow()", timedOut: true, log: "/w/logs/isolation-2.log"),
    ]

    @Test(arguments: [ReportFormat.text, .markdown])
    func reportsTestsFailingAloneInTheirOwnSection(_ format: ReportFormat) throws {
        let rendered = try Reporter.render(withTestsFailingAlone(failingAlone), format: format)
        #expect(rendered.contains("\(Reporter.testsFailingAloneTitle)"))
        #expect(rendered.contains("depend on tests that run before them"))
        #expect(rendered.contains("AppTests/LookupTests"))
        #expect(rendered.contains("/w/logs/isolation-1.log"))
        #expect(rendered.contains("timed out"))
        // A section of its own, after the per-declaration findings.
        let section = try #require(rendered.range(of: Reporter.testsFailingAloneTitle))
        let method = try #require(rendered.range(of: "Calc.isPositive(_:)"))
        #expect(method.lowerBound < section.lowerBound)
        #expect(!rendered[section.lowerBound...].contains("Calc.isPositive(_:)"))
    }

    @Test(arguments: [ReportFormat.text, .markdown])
    func omitsTheSectionWhenEveryTestPassesAloneOrTheCheckDidNotRun(_ format: ReportFormat) throws {
        for tests in [[], nil] as [[TestFailingAlone]?] {
            let rendered = try Reporter.render(withTestsFailingAlone(tests), format: format)
            #expect(!rendered.contains(Reporter.testsFailingAloneTitle))
        }
    }

    @Test func jsonCarriesTestsFailingAlone() throws {
        let json = try Reporter.render(withTestsFailingAlone(failingAlone), format: .json)
        #expect(json.contains("\"testsFailingAlone\""))
        let decoded = try JSONDecoder().decode(AnalysisReport.self, from: Data(json.utf8))
        #expect(decoded.testsFailingAlone == failingAlone)
        #expect(decoded.schemaVersion == 1)

        // Not checked: the field is absent, and reports without it still decode.
        let unchecked = try Reporter.render(withTestsFailingAlone(nil), format: .json)
        #expect(!unchecked.contains("testsFailingAlone"))
        #expect(try JSONDecoder().decode(AnalysisReport.self, from: Data(unchecked.utf8)).testsFailingAlone == nil)
        let checked = try Reporter.render(withTestsFailingAlone([]), format: .json)
        #expect(checked.contains("\"testsFailingAlone\" : ["))
    }
}

struct ExecutionStatusTests {
    private func result(_ outcome: MutantOutcome) -> MutantResult {
        MutantResult(mutant: Mutant(id: 1, mutation: .emptyBody), outcome: outcome)
    }

    @Test func coverageFillsTheColumn() {
        #expect(ExecutionStatus.resolve(coverage: true, mutants: [result(.survived)]) == .executed)
        #expect(ExecutionStatus.resolve(coverage: false, mutants: [result(.notRun)]) == .notExecuted)
        #expect(ExecutionStatus.resolve(coverage: nil, mutants: [result(.survived)]) == .unknown)
    }

    @Test func killedMutantProvesExecution() {
        #expect(ExecutionStatus.resolve(coverage: nil, mutants: [result(.survived), result(.killed)]) == .executed)
        #expect(ExecutionStatus.resolve(coverage: false, mutants: [result(.killed)]) == .executed)
        // A timeout can come from a slow machine as well as from the mutant, so it proves nothing.
        #expect(ExecutionStatus.resolve(coverage: nil, mutants: [result(.timedOut)]) == .unknown)
    }
}
