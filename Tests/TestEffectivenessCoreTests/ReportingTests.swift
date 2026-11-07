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
        let decoded = try JSONDecoder().decode(AnalysisReport.self, from: Data(json.utf8))
        #expect(decoded.methods.first?.executed == .executed)
        #expect(decoded.methods.first?.classification == .partiallyTested)
        #expect(decoded.methods.first?.survivingMutants.map(\.mutant.mutation) == [.returnBool(true)])
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
