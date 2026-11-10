import Testing
@testable import TestEffectivenessCore

struct SwitchCasesTests {
    private func discover(_ source: String, caseMutants: Bool = true) -> [DiscoveredMethod] {
        MethodDiscovery.discover(
            source: source, relativePath: "Sources/A/File.swift", options: DiscoveryOptions(caseMutants: caseMutants)
        )
    }

    /// `label: mutations` of each case of the first method.
    private func cases(_ source: String) -> [String] {
        discover(source)[0].cases.map { "\($0.label): \($0.mutations.map(\.summary).joined(separator: ", "))" }
    }

    /// The schema with ids assigned as `Analyzer` does: a method's mutants, then its cases'.
    private func rewrite(_ source: String) -> String {
        var nextID = 1
        func mutants(_ mutations: [ExtremeMutation]) -> [Mutant] {
            mutations.map { mutation in
                defer { nextID += 1 }
                return Mutant(id: nextID, mutation: mutation)
            }
        }
        var cases: [[[Mutant]]] = []
        let assignments = discover(source).map { method in
            let own = mutants(method.mutations)
            cases.append(method.cases.map { mutants($0.mutations) })
            return (method, own)
        }
        let rewritten = SchemataRewriter.rewrite(source: source, methods: assignments, cases: cases)
        return String(rewritten.prefix(upTo: rewritten.range(of: "\n// MARK: - swift-test-effectiveness")!.lowerBound))
    }

    // MARK: Discovery

    @Test func casesAreOnlyDiscoveredWhenAskedFor() {
        let source = """
        func f(_ x: E) -> Int {
            switch x {
            case .a: return 2
            case .b: return 3
            }
        }
        """
        #expect(discover(source, caseMutants: false)[0].cases.isEmpty)
        #expect(cases(source) == ["case .a: `return 0`, `return 1`", "case .b: `return 0`, `return 1`"])
        #expect(discover(source)[0].cases.map(\.line) == [3, 4])
    }

    @Test func mutantsThatReturnWhatTheCaseReturnsAreLeftOut() {
        #expect(cases("""
        func f(_ x: E) -> Int {
            switch x {
            case .a: return 0
            case .b: return 1.0
            case .c: return 1_0
            default: return x.rawValue
            }
        }
        """) == ["case .a: `return 1`", "case .b: `return 0`", "case .c: `return 0`, `return 1`", "default: `return 0`, `return 1`"])
        #expect(cases("""
        func f(_ x: E) -> String {
            switch x {
            case .a: ""
            case .b: "A"
            case .c: "\\(x)"
            }
        }
        """) == ["case .a: `return \"A\"`", "case .b: `return \"\"`", "case .c: `return \"\"`, `return \"A\"`"])
        #expect(cases("""
        var flag: Bool {
            switch self {
            case .a, .b: true
            case .c: false
            }
        }
        """) == ["case .a, .b: `return false`", "case .c: `return true`"])
        #expect(cases("""
        func f(_ x: E) -> [Int]? {
            switch x {
            case .a: return nil
            case .b: return []
            }
        }
        """) == ["case .a: ", "case .b: `return nil`"])
    }

    @Test func casesThatDoNothingOrNeverReturnHaveNoMutants() {
        #expect(cases("""
        func handle(_ x: E) {
            switch x {
            case .a: count += 1
            case .b: break
            case .c: print("c")
            case .d: return
            default: fatalError()
            }
        }
        """) == ["case .a: empty body", "case .b: ", "case .c: ", "case .d: ", "default: "])
    }

    @Test func labelIsOnOneLine() {
        #expect(cases("""
        func f(_ x: E) -> Int {
            switch x {
            case .a(let value)
                where value > 0:
                return value
            @unknown default: return 5
            }
        }
        """).map { $0.prefix(while: { $0 != ":" }) } == ["case .a(let value) where value > 0", "@unknown default"])
    }

    @Test func onlyASwitchTheBodyEndsWithIsTaken() {
        // After the switch, `return` at the start of a case would skip more than the case.
        #expect(cases("""
        func f(_ x: E) -> Int {
            var y = 0
            switch x {
            case .a: y = 2
            case .b: y = 3
            }
            return y
        }
        """).isEmpty)
        // Nothing to compare: one case is the whole body.
        #expect(cases("""
        func f(_ x: E) -> Int {
            switch x {
            default: return 2
            }
        }
        """).isEmpty)
        // Which cases exist depends on the build configuration.
        #expect(cases("""
        func f(_ x: E) -> Int {
            switch x {
            case .a: return 2
            #if DEBUG
            case .b: return 3
            #endif
            default: return 4
            }
        }
        """).isEmpty)
        // Every mutant would return what its case returns.
        #expect(cases("""
        func f(_ x: E) -> Int? {
            switch x {
            case .a: nil
            case .b: nil
            }
        }
        """).isEmpty)
    }

    // MARK: Return types without a simplest value

    /// `label: mutation {statement}` of each case of the first method.
    private func otherCases(_ source: String) -> [String] {
        discover(source)[0].cases.map { discovered in
            let mutations = discovered.mutations.map(\.summary).joined(separator: ", ")
            return "\(discovered.label): \(mutations)\(discovered.otherCaseStatement.map { " {\($0)}" } ?? "")"
        }
    }

    @Test func aCaseDoesWhatTheNextCaseDoesOrTheStatementsOfAnother() {
        let source = """
        var tint: Tint {
            switch self {
            case .a: .x
            case .b(let n): .y(n)
            case .c: .z
            case .d: fatalError()
            }
        }
        """
        // A switch expression: nothing can fall through, so every case takes an expression.
        // `.b` binds a variable its expression needs, so `.a` takes that of `.c`; `.c` cannot do
        // what `fatalError()` does, and takes that of the first case.
        #expect(otherCases(source) == [
            "case .a: as `case .c` {.z}",
            "case .b(let n): as `case .c` {.z}",
            "case .c: as `case .a` {.x}",
            "case .d: ",
        ])
        let method = discover(source)[0]
        #expect(method.decision == .mutate([]))
        #expect(method.implicitReturnInsertion == nil)
        // Without case mutants the method is not analyzed, as before.
        #expect(discover(source, caseMutants: false)[0].decision == .skip(reason: "unsupported return type `Tint`"))
    }

    /// The body of a method returning an opaque type may be a result builder without saying so.
    @Test func opaqueTypesStayUnanalysed() {
        let method = discover("""
        var body: some ToolbarContent {
            switch mode {
            case .a: ToolbarItem { Text("a") }
            case .b: ToolbarItem { Image("b") }
            }
        }
        """)[0]
        #expect(method.cases.isEmpty)
        #expect(method.decision == .skip(reason: "unsupported return type `some ToolbarContent`"))
    }

    @Test func statementsThatCannotMoveAreNotTaken() {
        // For `.a`: `.b` binds variables, a statement of `.c` is more than one line, and `.d` uses
        // a name that the variable of `.a` would hide. A comment after the statements stays
        // where it is.
        #expect(otherCases("""
        func severity(_ count: Int) -> Severity {
            switch self {
            case .a(let count):
                return Severity(count)
            case .b(let n):
                return Severity(n)
            case .c:
                return Severity(
                    2
                )
            case .d: return Severity(count)
            case .e: return Severity(1) // one
            }
        }
        """) == [
            "case .a(let count): as `case .e` {return Severity(1)}",
            "case .b(let n): as `case .c` {fallthrough}",
            "case .c: as `case .d` {fallthrough}",
            "case .d: as `case .e` {fallthrough}",
            "case .e: as `case .d` {return Severity(count)}",
        ])
    }

    @Test func severalStatementsMoveOntoOneLine() {
        #expect(otherCases("""
        func severity() -> Severity {
            switch self {
            case .a(let n): return Severity(n)
            case .b(let n): return Severity(n + 1)
            case .c:
                let level = 2
                return Severity(level)
            }
        }
        """) == [
            "case .a(let n): as `case .c` {let level = 2; return Severity(level)}",
            "case .b(let n): as `case .c` {fallthrough}",
            "case .c: ",
        ])
    }

    @Test func casesThatAllDoTheSameHaveNoMutants() {
        let source = """
        func tint(_ x: E) -> Tint {
            switch x {
            case .a: return .x
            default: return .x
            }
        }
        """
        #expect(discover(source)[0].cases.isEmpty)
        #expect(discover(source)[0].decision == .skip(reason: "unsupported return type `Tint`"))
    }

    @Test func otherCaseMutantsStandInTheCaseItself() {
        // In a switch statement: `fallthrough` to the next case, or the statements of another.
        #expect(rewrite("""
        func tint(_ x: E) -> Tint {
            switch x {
            case .a: return .x
            case .b(let n):
                return .y(n)
            case .c: return .z
            }
        }
        func after() -> Int { 2 }
        """) == """
        func tint(_ x: E) -> Tint {
            switch x {
            case .a: if __steMutantIs(1) { return .z }; return .x
            case .b(let n): if __steMutantIs(2) { fallthrough };
                return .y(n)
            case .c: if __steMutantIs(3) { return .x }; return .z
            }
        }
        func after() -> Int { switch __steActiveMutant { case 4: return 0; case 5: return 1; case -2: __steReached(4); default: break }; return 2 }

        """)
        // In a switch expression: the expression of another case.
        #expect(rewrite("""
        var tint: Tint {
            switch self {
            case .a: .x
            case .b(let n):
                .y(n)
            case .c: .z
            }
        }
        """) == """
        var tint: Tint {
            switch self {
            case .a: if __steMutantIs(1) { .z } else { .x }
            case .b(let n):
                if __steMutantIs(2) { .z } else { .y(n) }
            case .c: if __steMutantIs(3) { .x } else { .z }
            }
        }

        """)
    }

    // MARK: Schema

    @Test func eachCaseGetsItsOwnSwitch() {
        #expect(rewrite("""
        func f(_ x: E) -> Int {
            guard enabled else { return 0 }
            switch x {
            case .a:
                return 2
            default: return 0
            }
        }
        """) == """
        func f(_ x: E) -> Int { switch __steActiveMutant { case 1: return 0; case 2: return 1; case -2: __steReached(1); default: break };
            guard enabled else { return 0 }
            switch x {
            case .a: switch __steActiveMutant { case 3: return 0; case 4: return 1; case -2: __steReached(3); default: break };
                return 2
            default: switch __steActiveMutant { case 5: return 1; case -2: __steReached(5); default: break }; return 0
            }
        }

        """)
    }

    /// A statement in front of a case's expression would turn the switch into a statement, so the
    /// mutants are the branches of an `if` expression around it. The switch is still returned,
    /// and a case without mutants stays as it is, whatever it evaluates to.
    @Test func casesOfASwitchExpressionGetAnIfExpression() {
        #expect(rewrite("""
        func f(_ x: E) throws -> Int {
            switch x {
            case .a: 2
            case .b: 0
            case .c: throw Failure()
            case .d: unreachable()
            case .e:
                compute(
                    x
                );
            }
        }
        """) == """
        func f(_ x: E) throws -> Int { switch __steActiveMutant { case 1: return 0; case 2: return 1; case -2: __steReached(1); default: break };
            return switch x {
            case .a: if __steMutantIs(3) { 0 } else if __steActiveMutant == 4 { 1 } else { 2 }
            case .b: if __steMutantIs(5) { 1 } else { 0 }
            case .c: if __steMutantIs(6) { 0 } else if __steActiveMutant == 7 { 1 } else { throw Failure() }
            case .d: if __steMutantIs(8) { 0 } else if __steActiveMutant == 9 { 1 } else { unreachable() }
            case .e:
                if __steMutantIs(10) { 0 } else if __steActiveMutant == 11 { 1 } else { compute(
                    x
                ) };
            }
        }

        """)
    }

    @Test func voidCasesReturnAtOnce() {
        #expect(rewrite("""
        func handle(_ x: E) {
            switch x {
            case .a: count += 1
            case .b: break
            }
        }
        """) == """
        func handle(_ x: E) { switch __steActiveMutant { case 1: return; case -2: __steReached(1); default: break };
            switch x {
            case .a: switch __steActiveMutant { case 2: return; case -2: __steReached(2); default: break }; count += 1
            case .b: break
            }
        }

        """)
    }

    /// The flags that remember what was recorded cover the ids of the cases as well.
    @Test func footerCoversTheCaseMutants() {
        let method = discover("""
        func f(_ x: E) -> Int {
            switch x {
            case .a: return 2
            case .b: return 3
            }
        }
        """)[0]
        let output = SchemataRewriter.rewrite(
            source: "func f(_ x: E) -> Int {\n    switch x {\n    case .a: return 2\n    case .b: return 3\n    }\n}",
            methods: [(method, [Mutant(id: 10, mutation: .returnNumber("0"))])],
            cases: [[[Mutant(id: 11, mutation: .returnNumber("0"))], [Mutant(id: 14, mutation: .returnNumber("1"))]]]
        )
        #expect(output.contains("allocate(capacity: 5)"))
        #expect(output.contains("__steReachedFlags + (id - 10)"))
    }

    // MARK: Classification and report

    private func result(_ label: String, line: Int, executed: ExecutionStatus, _ outcomes: [(ExtremeMutation, MutantOutcome)]) -> CaseResult {
        CaseResult(
            label: label, line: line, executed: executed,
            mutants: outcomes.enumerated().map { MutantResult(mutant: Mutant(id: $0.offset, mutation: $0.element.0), outcome: $0.element.1) }
        )
    }

    @Test func anUnverifiedCaseMakesATestedMethodPartiallyTested() {
        let detected = [MutantResult(mutant: Mutant(id: 1, mutation: .returnNil), outcome: .killed)]
        let survived = [MutantResult(mutant: Mutant(id: 1, mutation: .returnNil), outcome: .survived)]
        let verified = result("case .a", line: 3, executed: .executed, [(.returnNil, .killed)])
        let unverified = result("case .b", line: 4, executed: .executed, [(.returnNil, .survived)])
        let notRun = result("case .c", line: 5, executed: .notExecuted, [(.returnNil, .notRun)])

        #expect(Classifier.classify(detected, cases: nil) == .tested)
        #expect(Classifier.classify(detected, cases: [verified]) == .tested)
        #expect(Classifier.classify(detected, cases: [verified, unverified]) == .partiallyTested)
        #expect(Classifier.classify(detected, cases: [verified, notRun]) == .partiallyTested)
        // The cases never make a method look better.
        #expect(Classifier.classify(survived, cases: [verified]) == .pseudoTested)

        // A method without mutants of its own is classified by its cases.
        #expect(Classifier.classify([], cases: nil) == .notCovered)
        #expect(Classifier.classify([], cases: [verified]) == .tested)
        #expect(Classifier.classify([], cases: [verified, unverified]) == .partiallyTested)
        #expect(Classifier.classify([], cases: [verified, notRun]) == .partiallyTested)
        #expect(Classifier.classify([], cases: [unverified, notRun]) == .pseudoTested)
        #expect(Classifier.classify([], cases: [notRun]) == .pseudoTested)
    }

    @Test func reportNamesTheUnverifiedCases() throws {
        let method = MethodInfo(
            file: "Sources/A/File.swift", name: "Presenter.title(for:)", kind: .function,
            declarationStart: SourcePosition(line: 2, column: 5), declarationEnd: SourcePosition(line: 9, column: 5),
            bodyStart: SourcePosition(line: 2, column: 40), returnType: "String"
        )
        let cases = [
            result("case .idle", line: 4, executed: .executed, [(.returnString(""), .killed), (.returnString("A"), .killed)]),
            result("case .loaded(let count)", line: 5, executed: .executed, [(.returnString(""), .survived), (.returnString("A"), .survived)]),
            result("case .failed", line: 6, executed: .notExecuted, [(.returnString(""), .notRun), (.returnString("A"), .notRun)]),
        ]
        let mutants = [MutantResult(mutant: Mutant(id: 1, mutation: .returnString("")), outcome: .killed)]
        let report = AnalysisReport(
            projectPath: "/p", coverageAvailable: true, referencesAvailable: true,
            methods: [MethodResult(
                method: method, referenced: .referenced, executed: .executed,
                classification: Classifier.classify(mutants, cases: cases), mutants: mutants, cases: cases
            )],
            skipped: []
        )
        let text = try Reporter.render(report, format: .text)
        #expect(text.contains("Partially tested (1)"))
        #expect(!text.contains("survived:"))
        #expect(text.contains("""
            → In `case .loaded(let count)` (line 5), `Presenter.title(for:)` can `return ""` or `return "A"` \
        without any test failing. Add a test of this case that asserts the result.
            → No test runs `case .failed` (line 6) of `Presenter.title(for:)`. Add a test of this case.
        """))
        #expect(!text.contains("case .idle"))
        let markdown = try Reporter.render(report, format: .markdown)
        #expect(markdown.contains("  - No test runs `case .failed` (line 6) of `Presenter.title(for:)`. Add a test of this case.\n"))
        let json = try Reporter.render(report, format: .json)
        #expect(json.contains("\"label\" : \"case .failed\""))
    }
}
