import Testing
@testable import TestEffectivenessCore

struct ResultMutantsTests {
    private func discover(
        _ source: String, returnMutants: Bool = true, caseMutants: Bool = false, throwMutants: Bool = false,
        defaultValues: [String] = [], closures: [String] = []
    ) -> [DiscoveredMethod] {
        MethodDiscovery.discover(
            source: source, relativePath: "Sources/A/File.swift",
            options: DiscoveryOptions(
                includeThrowMutants: throwMutants, caseMutants: caseMutants,
                defaultValues: try! DefaultValues(parsing: defaultValues), closures: try! ClosureUnits(parsing: closures),
                returnMutants: returnMutants
            )
        )
    }

    private func rewrite(
        _ source: String, caseMutants: Bool = false, defaultValues: [String] = [], closures: [String] = []
    ) -> String {
        let methods = discover(source, caseMutants: caseMutants, defaultValues: defaultValues, closures: closures)
        var nextID = 1
        func mutants(_ mutations: [ExtremeMutation]) -> [Mutant] {
            mutations.map { mutation in
                defer { nextID += 1 }
                return Mutant(id: nextID, mutation: mutation)
            }
        }
        var assignments: [(DiscoveredMethod, [Mutant])] = []
        var cases: [[[Mutant]]] = []
        for method in methods {
            assignments.append((method, mutants(method.mutations)))
            cases.append(method.cases.map { mutants($0.mutations) })
        }
        let rewritten = SchemataRewriter.rewrite(source: source, methods: assignments, cases: cases)
        return String(rewritten.prefix(upTo: rewritten.range(of: "\n// MARK: - swift-test-effectiveness")!.lowerBound))
    }

    private let account = """
    struct Account {
        var balance = 0
        mutating func withdraw(_ amount: Int) -> Bool {
            if amount > balance { return false }
            balance -= amount
            return true
        }
    }
    """

    // MARK: - Discovery

    /// The statements stay, and each `return` that gives something else gives the value.
    @Test func aBodyThatDoesSomethingGetsAMutantOfWhatItReturns() {
        let method = discover(account)[0]
        #expect(method.mutations == [.returnBool(true), .returnBool(false), .resultOnly("true"), .resultOnly("false")])
        // `return false` is replaced by `true`, and `return true` by `false`.
        #expect(method.resultSites.mapValues(\.count) == ["true": 1, "false": 1])
        #expect(method.resultSites["true"]! != method.resultSites["false"]!)
    }

    @Test func theMutantsAreOnlyMadeWhenAskedFor() {
        #expect(discover(account, returnMutants: false)[0].mutations == [.returnBool(true), .returnBool(false)])
    }

    /// Leaving at the start of such a body is the same as replacing what it returns.
    @Test func aBodyThatOnlyComputesWhatItReturnsHasNoSuchMutant() {
        let methods = discover("""
        func a(_ x: Int) -> Int? { x > 0 ? x : nil }
        func b(_ x: Int) -> Int? {
            guard x > 0 else { return nil }
            return x
        }
        func c(_ x: Int) -> Int? {
            let doubled = x * 2
            return doubled
        }
        func d(_ x: Int) -> Int? {
            logger.info("d")
            return x
        }
        func e(_ x: Int) -> Int? {
            if x > 0 { return x } else { return nil }
        }
        """)
        #expect(methods.map(\.mutations) == Array(repeating: [.returnNil], count: 5))
        #expect(methods.allSatisfy { $0.resultSites.isEmpty })
    }

    /// Nothing would change.
    @Test func aBodyWhoseReturnsAllGiveTheValueHasNoSuchMutant() {
        let methods = discover("""
        func a() -> Int? {
            reset()
            return nil
        }
        func b() -> Command {
            count += 1
            return .none
        }
        func c() -> Command {
            count += 1
            guard ready else { return .none }
            return .save
        }
        """, defaultValues: ["Command=.none"])
        #expect(methods.map(\.mutations) == [
            [.returnNil], [.returnValue(".none")], [.returnValue(".none"), .resultOnly(".none")],
        ])
        // Only the `return` that gives something else is replaced.
        #expect(methods[2].resultSites[".none"]?.count == 1)
    }

    @Test func whatIsDoneMayBeInsideAStatement() {
        let methods = discover("""
        func a(_ items: [Int]) -> Int? {
            for item in items { total += item }
            return total
        }
        func b(_ flag: Bool) -> Int? {
            if flag { try? save() }
            return 1
        }
        func c() async throws -> Int? {
            try await store.load()
            return store.count
        }
        func d() -> Int? {
            defer { unlock() }
            return 1
        }
        """)
        #expect(methods.map(\.mutations) == Array(repeating: [.returnNil, .resultOnly("nil")], count: 4))
    }

    /// What a closure or a local function does and returns is its own.
    @Test func closuresAndLocalFunctionsAreNotPartOfTheBody() {
        let methods = discover("""
        func a(_ items: [Int]) -> Int? {
            let doubled = items.map { item in return item * 2 }
            func local() -> Int? { reset(); return 1 }
            return doubled.first
        }
        func b(_ items: [Int]) -> Int? {
            reset()
            let doubled = items.map { item in return item * 2 }
            return doubled.first
        }
        """)
        #expect(methods[0].mutations == [.returnNil])
        #expect(methods[1].mutations == [.returnNil, .resultOnly("nil")])
        #expect(methods[1].resultSites["nil"]?.count == 1)
    }

    @Test func onlyAValueCanTakeThePlaceOfWhatIsReturned() {
        let methods = discover("""
        func a() { reset(); return }
        func b() -> Token { reset(); return Token() }
        func c() -> some View { reset(); return Text("c") }
        func d() throws -> Int? { reset(); return 1 }
        """, throwMutants: true)
        #expect(methods[0].mutations == [.emptyBody])
        #expect(methods[1].decision == .skip(reason: "unsupported return type `Token`"))
        #expect(methods[2].mutations == [.emptyView])
        // The value is replaced; nothing throws in its place.
        #expect(methods[3].mutations == [.returnNil, .throwError, .resultOnly("nil")])
    }

    // MARK: - Cases

    private let handler = """
    var handler: Handler<State, Event> {
        Handler { state, event in
            switch event {
            case .received:
                state.unread += 1
                return .reload
            case .opened:
                state.unread = 0
                return .none
            case .refreshed:
                return .reload
            case .muted(let on):
                state.isMuted = on
                guard on else { return .none }
                return .save
            }
        }
    }
    """

    /// Where the cases are mutated one by one, each case that does something gets the mutant.
    @Test func withCaseMutantsEachCaseGetsTheMutant() {
        let closure = discover(handler, caseMutants: true, defaultValues: ["Command=.none"], closures: ["Handler=Command"])[1]
        // All cases at once would say less than each of them.
        #expect(closure.mutations == [.returnValue(".none")])
        #expect(closure.resultSites.isEmpty)
        #expect(closure.cases.map { "\($0.label): \($0.mutations.map(\.summary).joined(separator: ", "))" } == [
            "case .received: `return .none`, `return .none` after its statements",
            // Returns the value already.
            "case .opened: `return .none`",
            // Does nothing before it returns.
            "case .refreshed: `return .none`",
            "case .muted(let on): `return .none`, `return .none` after its statements",
        ])
        #expect(closure.cases.map { $0.resultSites[".none"]?.count ?? 0 } == [1, 0, 0, 1])
    }

    @Test func withoutCaseMutantsTheBodyGetsTheMutant() {
        let closure = discover(handler, defaultValues: ["Command=.none"], closures: ["Handler=Command"])[1]
        #expect(closure.mutations == [.returnValue(".none"), .resultOnly(".none")])
        // The three `return`s that give something else.
        #expect(closure.resultSites[".none"]?.count == 3)
        #expect(closure.cases.isEmpty)
    }

    /// A case of a switch expression is one expression: nothing stands before its value.
    @Test func casesOfASwitchExpressionHaveNoSuchMutant() {
        let method = discover("""
        func title(_ state: LoadState) -> String {
            switch state {
            case .idle: "Idle"
            case .loading: "Loading"
            }
        }
        """, caseMutants: true)[0]
        #expect(method.cases.allSatisfy { $0.mutations == [.returnString(""), .returnString("A")] })
    }

    // MARK: - The schema

    /// The mutants that leave the body stand at its start, the others in front of the `return`s.
    @Test func theMutantStandsInFrontOfEachReturnItReplaces() {
        #expect(rewrite(account) == """
        struct Account {
            var balance = 0
            mutating func withdraw(_ amount: Int) -> Bool { switch __steActiveMutant { case 1: return true; case 2: return false; case -2: __steReached(1); default: break };
                if amount > balance { if __steActiveMutant == 3 { return true }; return false }
                balance -= amount
                if __steActiveMutant == 4 { return false }; return true
            }
        }

        """)
    }

    @Test func theMutantOfACaseStandsInFrontOfTheReturnsOfTheCase() {
        let output = rewrite(handler, caseMutants: true, defaultValues: ["Command=.none"], closures: ["Handler=Command"])
        #expect(output == """
        var handler: Handler<State, Event> {
            Handler { state, event in switch __steActiveMutant { case 1: return .none; case -2: __steReached(1); default: break };
                switch event {
                case .received: switch __steActiveMutant { case 2: return .none; case -2: __steReached(2); default: break };
                    state.unread += 1
                    if __steActiveMutant == 3 { return .none }; return .reload
                case .opened: switch __steActiveMutant { case 4: return .none; case -2: __steReached(4); default: break };
                    state.unread = 0
                    return .none
                case .refreshed: switch __steActiveMutant { case 5: return .none; case -2: __steReached(5); default: break };
                    return .reload
                case .muted(let on): switch __steActiveMutant { case 6: return .none; case -2: __steReached(6); default: break };
                    state.isMuted = on
                    guard on else { return .none }
                    if __steActiveMutant == 7 { return .none }; return .save
                }
            }
        }

        """)
    }

    // MARK: - Report

    @Test func theAdviceSaysWhatTestsCheckAndWhatTheyDoNot() {
        #expect(ExtremeMutation.resultOnly("false").summary == "`return false` after its statements")
        #expect(Reporter.advice(for: .resultOnly("false"), method: "Account.withdraw(_:)")
            == "`Account.withdraw(_:)` can do what it does and then return `false` without any test failing: "
            + "tests check what it changes, not what it returns. Assert the value it returns.")
    }

    @Test func theAdviceForACaseNamesTheStatementsOfTheCase() {
        let result = CaseResult(label: "case .received", line: 4, executed: .executed, mutants: [
            MutantResult(mutant: Mutant(id: 2, mutation: .returnValue(".none")), outcome: .killed),
            MutantResult(mutant: Mutant(id: 3, mutation: .resultOnly(".none")), outcome: .survived),
        ])
        #expect(Reporter.advice(for: result, method: "handler, Handler { }")
            == "In `case .received` (line 4), `handler, Handler { }` can `return .none` after the statements of the "
            + "case without any test failing: tests check what the case changes, not what it returns. Assert the result.")

        // Several values are named together; next to another mutant, each says what it is.
        func advice(_ survived: [ExtremeMutation]) -> String {
            Reporter.advice(for: CaseResult(label: "case .a", line: 2, executed: .executed, mutants: survived.enumerated().map {
                MutantResult(mutant: Mutant(id: $0.offset + 1, mutation: $0.element), outcome: .survived)
            }), method: "f()")
        }
        #expect(advice([.resultOnly("true"), .resultOnly("false")])
            == "In `case .a` (line 2), `f()` can `return true` or `return false` after the statements of the case without "
            + "any test failing: tests check what the case changes, not what it returns. Assert the result.")
        #expect(advice([.returnBool(true), .resultOnly("false")])
            == "In `case .a` (line 2), `f()` can `return true` or `return false` after the statements of the case without "
            + "any test failing. Add a test of this case that asserts the result.")
    }

    /// Where leaving at the start survived as well, returning the same value later says nothing more.
    @Test(arguments: [ReportFormat.text, .markdown])
    func aSurvivorOfBothIsAdvisedOnce(_ format: ReportFormat) throws {
        #expect(Reporter.advised([.returnBool(true), .resultOnly("true"), .resultOnly("false")])
            == [.returnBool(true), .resultOnly("false")])
        let position = SourcePosition(line: 3, column: 5)
        let method = MethodInfo(
            file: "Sources/A.swift", name: "Account.withdraw(_:)", kind: .function,
            declarationStart: position, declarationEnd: position, bodyStart: position, returnType: "Bool"
        )
        let mutants = [
            MutantResult(mutant: Mutant(id: 1, mutation: .returnBool(true)), outcome: .survived),
            MutantResult(mutant: Mutant(id: 2, mutation: .returnBool(false)), outcome: .killed),
            MutantResult(mutant: Mutant(id: 3, mutation: .resultOnly("true")), outcome: .survived),
            MutantResult(mutant: Mutant(id: 4, mutation: .resultOnly("false")), outcome: .survived),
        ]
        let report = AnalysisReport(
            projectPath: "/p", coverageAvailable: true,
            methods: [MethodResult(method: method, executed: .executed, classification: .partiallyTested, mutants: mutants)],
            skipped: []
        )
        let rendered = try Reporter.render(report, format: format)
        #expect(rendered.contains("can always return `true` without any test failing"))
        #expect(rendered.contains("can do what it does and then return `false` without any test failing"))
        #expect(!rendered.contains("can do what it does and then return `true`"))
    }

    @Test func aSurvivorOfTheMutantAloneMakesTheMethodPartiallyTested() {
        let results = [
            MutantResult(mutant: Mutant(id: 1, mutation: .returnNil), outcome: .killed),
            MutantResult(mutant: Mutant(id: 2, mutation: .resultOnly("nil")), outcome: .survived),
        ]
        #expect(Classifier.classify(results, cases: nil) == .partiallyTested)
    }
}
