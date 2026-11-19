import Testing
@testable import TestEffectivenessCore

struct ClosureUnitsTests {
    private func discover(
        _ source: String, closures: [String], defaultValues: [String] = [], caseMutants: Bool = false,
        path: String = "Sources/A/File.swift"
    ) -> [DiscoveredMethod] {
        MethodDiscovery.discover(
            source: source, relativePath: path,
            options: DiscoveryOptions(
                caseMutants: caseMutants, defaultValues: try! DefaultValues(parsing: defaultValues),
                closures: try! ClosureUnits(parsing: closures)
            )
        )
    }

    private func rewrite(_ source: String, closures: [String], defaultValues: [String] = []) -> String {
        let methods = discover(source, closures: closures, defaultValues: defaultValues)
        var nextID = 1
        let assignments = methods.map { method in
            (method, method.mutations.map { mutation in
                defer { nextID += 1 }
                return Mutant(id: nextID, mutation: mutation)
            })
        }
        let rewritten = SchemataRewriter.rewrite(source: source, methods: assignments)
        return String(rewritten.prefix(upTo: rewritten.range(of: "\n// MARK: - swift-test-effectiveness")!.lowerBound))
    }

    // MARK: - The option

    @Test(arguments: [
        ("Handler", "'Handler' is not NAME=TYPE"),
        ("=Command", "'=Command' names no function before `=`"),
        ("on change=Void", "'on change=Void' names no function before `=`"),
        ("Handler=", "'' is not a type, for `Handler`"),
        ("Handler=Command Other", "'Command Other' is not a type, for `Handler`"),
        ("Handler=some Shape", "'some Shape' is an opaque type, which a closure cannot return, for `Handler`"),
    ])
    func rejectsWhatIsNotANameAndAType(_ argument: String, _ message: String) {
        #expect(throws: ClosureUnits.ParseError(description: message)) { try ClosureUnits(parsing: [argument]) }
    }

    @Test func aNameHasOneType() throws {
        #expect(throws: ClosureUnits.ParseError(description: "`Handler` returns `Command` and `Void`")) {
            try ClosureUnits(parsing: ["Handler=Command", "Handler=Void"])
        }
        #expect(try ClosureUnits(parsing: ["Handler=Command", " Handler = Command "]) == ClosureUnits(parsing: ["Handler=Command"]))
        #expect(try ClosureUnits(parsing: []).isEmpty)
        #expect(try !ClosureUnits(parsing: ["Handler=Command"]).isEmpty)
    }

    // MARK: - Discovery

    @Test func theTrailingClosureOfANamedCallIsAMethod() throws {
        let methods = discover("""
        struct Inbox {
            var handler: Handler<State, Event> {
                Handler { state, event in
                    state.unread += 1
                    return .save
                }
            }
        }
        """, closures: ["Handler=Command"], defaultValues: ["Command=.none"])
        #expect(methods.map(\.info.name) == ["Inbox.handler", "Inbox.handler, Handler { }"])
        #expect(methods.map(\.info.kind) == [.getter, .closure])
        #expect(methods[0].decision == .skip(reason: "unsupported return type `Handler<State, Event>`"))

        let closure = methods[1]
        #expect(closure.decision == .mutate([.returnValue(".none")]))
        #expect(closure.info.returnType == "Command")
        // The closure's `{`: where its coverage region starts.
        #expect(closure.info.declarationStart == SourcePosition(line: 3, column: 17))
        #expect(closure.info.bodyStart == SourcePosition(line: 3, column: 17))
        #expect(closure.info.declarationEnd.line == 6)
        // The index knows the getter, not the closure.
        #expect(closure.enclosing == methods[0].info)
        #expect(closure.indexed == methods[0].info)
        #expect(methods[0].indexed == methods[0].info)
    }

    /// A call is matched by the last components of what is called.
    @Test func aNameMatchesTheEndOfWhatIsCalled() {
        let source = """
        func f(store: Store) {
            subscribe { _ in a() }
            store.subscribe { _ in b() }
            self.store.subscribe { _ in c() }
            store?.subscribe { _ in d() }
            Store.shared.subscribe { _ in e() }
            Box<Int>.subscribe { _ in g() }
            resubscribe { _ in h() }
            subscribe(i)
            subscribe({ _ in j() })
            subscribe.now { _ in k() }
        }
        """
        func lines(_ name: String) -> [Int] {
            discover(source, closures: ["\(name)=Void"]).filter { $0.info.kind == .closure }.map(\.info.declarationStart.line)
        }
        #expect(lines("subscribe") == [2, 3, 4, 5, 6, 7])
        #expect(lines("store.subscribe") == [3, 4])
        #expect(lines("shared.subscribe") == [6])
        #expect(lines("now") == [11])
        // An implicit member is called by its name.
        #expect(discover("var h: Handler { .init { _, _ in .save } }", closures: [".init=Command"]).map(\.info.name) == ["h", "h, init { }"])
        // The name with the most components decides the type.
        let both = discover(source, closures: ["subscribe=Void", "store.subscribe=Bool"]).filter { $0.info.kind == .closure }
        #expect(both.map(\.info.returnType) == ["Void", "Bool", "Bool", "Void", "Void", "Void"])
    }

    @Test func genericArgumentsAreNotPartOfTheName() {
        let methods = discover("func make() -> Any { Handler<Int, Event> { _, _ in .save } }", closures: ["Handler=Command"])
        #expect(methods.map(\.info.name) == ["make()", "make(), Handler { }"])
    }

    @Test func closuresOfAClosureAreMethodsOfTheirOwn() {
        let methods = discover("""
        func start(_ store: Store) {
            store.subscribe { event in
                store.subscribe { _ in log(event) }
                helper()
            }
            func local() { store.subscribe { _ in } }
            struct Local { func f(_ store: Store) { store.subscribe { _ in } } }
        }
        """, closures: ["subscribe=Void"])
        #expect(methods.map { "\($0.info.name) \($0.info.declarationStart.line)" } == [
            "start(_:) 1", "start(_:), subscribe { } 2", "start(_:), subscribe { } 3", "start(_:), subscribe { } 6",
        ])
        #expect(methods.dropFirst().allSatisfy { $0.enclosing == methods[0].info })
    }

    @Test func withoutANameNoClosureIsAMethod() {
        let methods = discover("func f(store: Store) { store.subscribe { _ in a() } }", closures: [])
        #expect(methods.map(\.info.name) == ["f(store:)"])
    }

    /// A closure that writes its return type says more than the name of the call.
    @Test func theWrittenReturnTypeWins() {
        let methods = discover("func f() { run { () -> Bool in check() } }", closures: ["run=Void"])
        #expect(methods[1].decision == .mutate([.returnBool(true), .returnBool(false)]))
        #expect(methods[1].info.returnType == "Bool")
    }

    @Test func aClosureFollowsTheRulesOfItsReturnType() {
        func decisions(_ type: String, body: String = "work()") -> [MutationOperators.Decision] {
            discover("func f() { run { \(body) } }", closures: ["run=\(type)"]).dropFirst().map(\.decision)
        }
        #expect(decisions("Void") == [.mutate([.emptyBody])])
        #expect(decisions("Int?") == [.mutate([.returnNil])])
        #expect(decisions("Token") == [.skip(reason: "unsupported return type `Token`")])
        #expect(decisions("Never") == [.skip(reason: "returns `Never`")])
        // Only logs: no test should assert on it.
        #expect(decisions("Void", body: "print(1)") == [.skip(reason: AridDetector.skipReason)])
    }

    /// A closure that only returns the value has nothing a test could detect.
    @Test func aClosureThatOnlyReturnsTheValueOfItsMutantIsNotAnalyzed() {
        let methods = discover("""
        func f() {
            a(Handler { _, _ in .none })
            b(Handler { _, _ in
                return .none
            })
            c(Handler { state, _ in
                state.count += 1
                return .none
            })
            d(Check { _ in true })
        }
        """, closures: ["Handler=Command", "Check=Bool"], defaultValues: ["Command=.none"])
        let reason = "body only returns the value of its mutant (`return .none`)"
        #expect(methods.dropFirst().map(\.decision) == [
            .skip(reason: reason), .skip(reason: reason), .mutate([.returnValue(".none")]), .mutate([.returnBool(false)]),
        ])
    }

    @Test func whatKeepsABodyFromTheMutantSwitchKeepsItsClosuresFromIt() {
        let inlinable = discover("@inlinable func f() { run { work() } }", closures: ["run=Void"])
        #expect(inlinable.map(\.decision) == Array(
            repeating: .skip(reason: "`@inlinable` body cannot reference the mutant switch"), count: 2
        ))
        let main = discover("func f() { run { work() } }", closures: ["run=Void"], path: "Sources/App/main.swift")
        #expect(main.map(\.decision) == Array(repeating: .skip(reason: "declared in main.swift (top-level code)"), count: 2))
    }

    @Test func aClosureInsideIfConfigMayNotBeCompiled() {
        let methods = discover("""
        func f() {
            run { always() }
            #if DEBUG
            run { sometimes() }
            #endif
        }
        """, closures: ["run=Void"])
        #expect(methods.map(\.isConditionallyCompiled) == [false, false, true])
    }

    @Test func theCasesOfTheSwitchAClosureEndsWithAreMutated() {
        let methods = discover("""
        var handler: Handler<State, Event> {
            Handler { state, event in
                switch event {
                case .received:
                    state.unread += 1
                    return .none
                case .refreshed:
                    return .reload
                case .ignored:
                    return .none
                }
            }
        }
        """, closures: ["Handler=Command"], defaultValues: ["Command=.none"], caseMutants: true)
        #expect(methods[1].cases.map { "\($0.label) \($0.mutations.map(\.summary))" } == [
            "case .received [\"`return .none`\"]", "case .refreshed [\"`return .none`\"]", "case .ignored []",
        ])
        // Without a value for the type, each case does what another one does.
        let other = discover("""
        func f() {
            route { event in
                switch event {
                case .a: return .first
                case .b: return .second
                }
            }
        }
        """, closures: ["route=Screen"], caseMutants: true)
        #expect(other[1].decision == .mutate([]))
        #expect(other[1].cases.map(\.mutations) == [[.otherCase("case .b")], [.otherCase("case .a")]])
    }

    // MARK: - The schema

    /// The mutants stand after the `in` of the closure's signature.
    @Test func theSwitchOfAClosureFollowsItsSignature() {
        let output = rewrite("""
        var handler: Handler<State, Event> {
            Handler { [weak self] state, event in
                state.unread += 1
                return .save
            }
        }
        """, closures: ["Handler=Command"], defaultValues: ["Command=.none"])
        #expect(output == """
        var handler: Handler<State, Event> {
            Handler { [weak self] state, event in switch __steActiveMutant { case 1: return .none; case -2: __steReached(1); default: break };
                state.unread += 1
                return .save
            }
        }

        """)
    }

    @Test func aClosureWithoutSignatureStartsAtItsBrace() {
        let output = rewrite("func f(feed: Feed) { feed.subscribe { self.lines.append($0) } }", closures: ["subscribe=Void"])
        #expect(output == "func f(feed: Feed) { switch __steActiveMutant { case 1: return; case -2: __steReached(1); default: break }; "
            + "feed.subscribe { switch __steActiveMutant { case 2: return; case -2: __steReached(2); default: break }; "
            + "self.lines.append($0) } }\n")
    }

    /// The expression a closure returns implicitly needs `return` once statements stand before it.
    @Test func theExpressionOfAClosureIsReturned() {
        let output = rewrite("""
        var isEmpty: Check {
            Check { items in items.isEmpty }
        }
        """, closures: ["Check=Bool"])
        #expect(output == """
        var isEmpty: Check {
            Check { items in switch __steActiveMutant { case 1: return true; case 2: return false; case -2: __steReached(1); default: break }; return items.isEmpty }
        }

        """)
    }
}
