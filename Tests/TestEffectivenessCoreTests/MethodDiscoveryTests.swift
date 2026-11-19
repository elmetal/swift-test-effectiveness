import Testing
@testable import TestEffectivenessCore

struct MethodDiscoveryTests {
    private func discover(
        _ source: String, path: String = "Sources/A/File.swift", throwMutants: Bool = false, arid: Bool = true,
        defaultValues: [String] = []
    ) -> [DiscoveredMethod] {
        MethodDiscovery.discover(
            source: source, relativePath: path,
            options: DiscoveryOptions(
                includeThrowMutants: throwMutants, arid: arid ? AridDetector() : nil,
                defaultValues: try! DefaultValues(parsing: defaultValues)
            )
        )
    }

    @Test func qualifiesNamesWithEnclosingTypes() {
        let methods = discover("""
        struct Outer {
            struct Inner {
                func run(_ a: Int, label b: Int) -> Int { a + b }
            }
        }
        extension Outer {
            var size: Int { 1 }
        }
        func free() {}
        """)
        #expect(methods.map(\.info.name) == ["Outer.Inner.run(_:label:)", "Outer.size", "free()"])
        #expect(methods.map(\.info.kind) == [.function, .getter, .function])
    }

    @Test func recordsBodyPositionsForCoverageMatching() throws {
        let methods = discover("""
        struct S {
            func f() -> Int {
                1
            }
        }
        """)
        let method = try #require(methods.first)
        #expect(method.info.declarationStart == SourcePosition(line: 2, column: 5))
        #expect(method.info.bodyStart == SourcePosition(line: 2, column: 21))
        #expect(method.info.declarationEnd.line == 4)
    }

    @Test func ignoresInitializersSubscriptsProtocolsAndLocalFunctions() {
        let methods = discover("""
        protocol P { func required() -> Int }
        struct S {
            init() {}
            subscript(i: Int) -> Int { i }
            var stored = 0
            var observed = 0 { didSet { print("x") } }
            func outer() {
                func inner() -> Int { 1 }
                _ = { () -> Int in 2 }
            }
        }
        """)
        #expect(methods.map(\.info.name) == ["S.outer()"])
    }

    @Test func explicitGetterIsTargeted() {
        let methods = discover("""
        struct S {
            var x: Int {
                get { stored }
                set {}
            }
        }
        """)
        #expect(methods.map(\.info.name) == ["S.x"])
        #expect(methods.first?.mutations == [.returnNumber("0"), .returnNumber("1")])
    }

    @Test func inlinableAndMainSwiftAreSkipped() {
        let inlinable = discover("@inlinable public func f() -> Int { 1 }")
        let main = discover("func g() {}", path: "Sources/App/main.swift")
        guard case .skip = inlinable.first?.decision, case .skip = main.first?.decision else {
            Issue.record("expected both to be skipped")
            return
        }
    }

    @Test func marksMethodsInsideIfConfig() {
        let methods = discover("""
        struct S {
            func always() {}
            #if DEBUG
            func debug() {}
            #elseif os(Linux)
            func linux() {}
            #else
            #if FOO
            func nested() {}
            #endif
            #endif
            func after() {}
        }
        #if canImport(UIKit)
        extension S { func ui() {} }
        #endif
        """)
        let conditional = Dictionary(uniqueKeysWithValues: methods.map { ($0.info.name, $0.isConditionallyCompiled) })
        #expect(conditional == [
            "S.always()": false, "S.debug()": true, "S.linux()": true,
            "S.nested()": true, "S.after()": false, "S.ui()": true,
        ])
    }

    @Test func viewBodyIsAResultBuilder() {
        let methods = discover("""
        struct V: View {
            var body: some View { Text("a") }
            @ViewBuilder func row() -> some View { Text("b") }
            func plain() -> some View { Text("c") }
        }
        """)
        #expect(methods.map(\.isResultBuilder) == [true, true, false])
        #expect(methods.map(\.mutations) == [[.emptyView], [.emptyView], [.emptyView]])
        // Only the body outside a result builder moves into a local function.
        #expect(methods.map { $0.opaqueBody != nil } == [false, false, true])
    }

    /// The local function repeats the effects and the result type, and is a view builder unless
    /// the body returns explicitly (a `return` in a closure is not one of the body).
    @Test func someViewOutsideAResultBuilderKeepsItsBodyInALocalFunction() {
        let methods = discover("""
        func single() -> some View { Text("a") }
        func returning() -> some View { let a = "a"; return Text(a) }
        func nested() -> some View { ForEach(items) { item in return Text(item) } }
        func effects() async throws -> some SwiftUI.View { try await load() }
        func typed() throws(E) -> some View { if flag { return Text("a") }; return Text("b") }
        var getter: some View { get async { Text("a") } }
        func value() -> Int { 1 }
        """)
        #expect(methods.map(\.opaqueBody) == [
            OpaqueBody(isViewBuilder: true, signature: "-> some View", callEffects: ""),
            OpaqueBody(isViewBuilder: false, signature: "-> some View", callEffects: ""),
            OpaqueBody(isViewBuilder: true, signature: "-> some View", callEffects: ""),
            OpaqueBody(isViewBuilder: true, signature: "async throws -> some SwiftUI.View", callEffects: "try await "),
            OpaqueBody(isViewBuilder: false, signature: "throws(E) -> some View", callEffects: "try "),
            OpaqueBody(isViewBuilder: true, signature: "async -> some View", callEffects: "await "),
            nil,
        ])
        // The body stays as it is: no `return` is inserted.
        #expect(methods.dropLast().allSatisfy { $0.implicitReturnInsertions.isEmpty })
    }

    /// With an explicit `return` the builder is off, so the `if`/`else` of the result builder
    /// schema would not compile: the body is an ordinary one.
    @Test func explicitReturnTurnsAResultBuilderOff() {
        let methods = discover("""
        struct V: View {
            var body: some View { let title = "a"; return Text(title) }
            @ViewBuilder func row() -> some View { return Text("b") }
            @ViewBuilder func list() -> some View { ForEach(items) { item in return Text(item) } }
            @ArrayBuilder func numbers() -> [Int] { return [1] }
            func local() -> some View { var title: String { return "c" }; Text(title) }
        }
        """)
        #expect(methods.map(\.isResultBuilder) == [false, false, true, false, false])
        #expect(methods.map { $0.opaqueBody?.isViewBuilder } == [false, false, nil, nil, true])
        #expect(methods.map(\.mutations) == [[.emptyView], [.emptyView], [.emptyView], [.returnEmptyArray], [.emptyView]])
    }

    @Test func someViewFromARethrowingFunctionIsSkipped() {
        let methods = discover("func make(_ f: () throws -> String) rethrows -> some View { Text(try f()) }")
        #expect(methods[0].decision == .skip(reason: "`some View` returned from a `rethrows` function"))
        #expect(methods[0].opaqueBody == nil)
    }

    @Test func throwMutantFollowsTheViewMutant() {
        let methods = discover("func load() throws -> some View { Text(try text()) }", throwMutants: true)
        #expect(methods[0].mutations == [.emptyView, .throwError])
    }

    @Test func throwMutantsAreOptInAndOnlyForUntypedThrows() {
        let source = """
        func a() throws -> Int { 1 }
        func b() throws(MyError) -> Int { 1 }
        func c() rethrows {}
        """
        #expect(discover(source).allSatisfy { !$0.mutations.contains(.throwError) })
        let methods = discover(source, throwMutants: true)
        #expect(methods.map { $0.mutations.contains(.throwError) } == [true, false, false])
    }

    @Test func implicitReturnIsDetectedOnlyForSingleExpressions() {
        let methods = discover("""
        func expr() -> Int { 1 + 2 }
        func ifExpr(_ b: Bool) -> Int { if b { 1 } else { 2 } }
        func ifStmt(_ b: Bool) -> Int { if b { return 1 } else { return 2 } }
        func multi() -> Int { let x = 1; return x }
        func crash() -> Int { fatalError() }
        func void() { print("x") }
        func closure() -> [Int] { [1].map { x in return x } }
        """)
        #expect(methods.map { !$0.implicitReturnInsertions.isEmpty } == [true, true, false, false, false, false, true])
    }

    /// A body that is one `#if` block returns what its active clause is, so each clause that is a
    /// single expression needs its `return`.
    @Test func implicitReturnIsDetectedInEveryClauseOfASingleIfConfigBlock() {
        let source = """
        func both() -> Int {
            #if DEBUG
            1
            #else
            0
            #endif
        }
        func nested() -> String {
            #if os(iOS)
              #if DEBUG
              "a"
              #else
              "b"
              #endif
            #elseif os(macOS)
            "c"
            #endif
        }
        func mixed() -> Int {
            #if DEBUG
            if flag { 1 } else { 2 }
            #elseif TRACE
            #else
            let x = 1
            return x
            #endif
        }
        func explicit() -> Int {
            #if DEBUG
            return 1
            #else
            fatalError()
            #endif
        }
        func void() {
            #if DEBUG
            log()
            #endif
        }
        """
        let methods = discover(source)
        let lines = methods.map { method in
            method.implicitReturnInsertions.map { offset in
                source.utf8.prefix(offset).count { $0 == UInt8(ascii: "\n") } + 1
            }
        }
        #expect(lines == [[3, 5], [11, 13, 16], [21], [], []])
        #expect(methods.allSatisfy { !$0.mutations.isEmpty })
    }

    /// Among several statements an expression is returned implicitly only when the `#if` blocks
    /// around it leave nothing, which the build decides: `return ` would be wrong either way.
    @Test func skipsBodiesWhoseImplicitReturnDependsOnTheBuildConfiguration() {
        let methods = discover("""
        func afterBlock() -> Int {
            #if TRACE
            log()
            #endif
            1
        }
        func twoBlocks() -> Int {
            #if os(iOS)
            1
            #endif
            #if os(macOS)
            2
            #endif
        }
        func inClause() -> Int {
            #if DEBUG
              #if TRACE
              log()
              #endif
              1
            #else
            0
            #endif
        }
        func returning() -> Int {
            #if TRACE
            log()
            #endif
            return 1
        }
        func void() {
            #if TRACE
            log()
            #endif
            reset()
        }
        var body: some View {
            #if TRACE
            Banner()
            #endif
            Text("a")
        }
        """)
        let reason = "`#if` in the body decides whether its value is returned implicitly"
        #expect(methods.map { $0.decision == .skip(reason: reason) } == [true, true, true, false, false, false])
        #expect(methods.allSatisfy { $0.implicitReturnInsertions.isEmpty })
    }

    // MARK: - A body that only returns a value

    private func onlyReturns(_ mutant: String) -> MutationOperators.Decision {
        .skip(reason: "body only returns the value of its mutant (`return \(mutant)`)")
    }

    /// The mutant would be the body as it is: no test could detect it.
    @Test func aMutantThatReturnsWhatTheBodyReturnsIsLeftOut() {
        let methods = discover("""
        func a() -> Bool { true }
        func b() -> Bool { return false }
        var c: Int { 1 }
        func d() -> Double { 0.0 }
        func e() -> String { "" }
        func f() -> String { "A" }
        """)
        #expect(methods.map(\.decision) == [
            .mutate([.returnBool(false)]), .mutate([.returnBool(true)]),
            .mutate([.returnNumber("0")]), .mutate([.returnNumber("1")]),
            .mutate([.returnString("A")]), .mutate([.returnString("")]),
        ])
        // The value is still returned implicitly behind the mutants that are left.
        #expect(methods.map(\.implicitReturnInsertions.count) == [1, 0, 1, 1, 1, 1])
    }

    @Test func aBodyThatOnlyReturnsTheValueOfItsOnlyMutantIsNotAnalyzed() {
        let methods = discover("""
        func a() -> Int? { nil }
        func b() -> Int? {
            return nil
        }
        var c: [Int] { [] }
        var d: [String: Int] { [:] }
        func e() -> Data { Data() }
        """)
        #expect(methods.map(\.decision) == [
            onlyReturns("nil"), onlyReturns("nil"), onlyReturns("[]"), onlyReturns("[:]"), onlyReturns("Data()"),
        ])
    }

    @Test func aBodyThatDoesMoreKeepsItsMutants() {
        let methods = discover("""
        func a() -> Int? { log(); return nil }
        func b() -> Int? { flag ? nil : 1 }
        func c() -> Int? {
            guard flag else { return nil }
            return nil
        }
        func d() -> Int? { .none }
        func e() -> [Int] { [1] }
        func f() -> Int? { fatalError() }
        func g() { reset() }
        var body: some View { EmptyView() }
        """)
        #expect(methods.map(\.decision) == [
            .mutate([.returnNil]), .mutate([.returnNil]), .mutate([.returnNil]), .mutate([.returnNil]),
            .mutate([.returnEmptyArray]), .mutate([.returnNil]), .mutate([.emptyBody]), .mutate([.emptyView]),
        ])
    }

    /// A value from the user is compared as code, as in a case.
    @Test func aValueFromTheUserIsWhatABodyReturnsWhateverItsSpacing() {
        let methods = discover("""
        func a() -> Command { .none }
        func b() -> Command {
            return Command . none // nothing to do
        }
        func c() -> Command { .save }
        func d() -> Tint { .gray }
        func e() -> Tint { Tint.gray }
        """, defaultValues: ["Command=.none", "Command=Command.none", "Tint=.gray", "Tint=.clear"])
        #expect(methods.map(\.decision) == [
            .mutate([.returnValue("Command.none")]), .mutate([.returnValue(".none")]),
            .mutate([.returnValue(".none"), .returnValue("Command.none")]),
            .mutate([.returnValue(".clear")]), .mutate([.returnValue(".gray"), .returnValue(".clear")]),
        ])
        let only = discover("func a() -> Command { .none }", defaultValues: ["Command=.none"])
        #expect(only.map(\.decision) == [onlyReturns(".none")])
    }

    /// Throwing instead is something a test can detect.
    @Test func theThrowMutantOfABodyThatOnlyReturnsAValueStays() {
        let methods = discover("func a() throws -> Int? { nil }", throwMutants: true)
        #expect(methods.map(\.decision) == [.mutate([.throwError])])
        #expect(methods.map(\.implicitReturnInsertions.count) == [1])
    }

    // MARK: - A body that does nothing

    /// The empty-body mutant would be the body as it is.
    @Test func aBodyThatDoesNothingIsNotAnalyzed() {
        let methods = discover("""
        func a() {}
        func b() -> Void {
            // Nothing to do yet.
        }
        func c() async throws {}
        func d() { reset() }
        func e() { if check() { return } }
        func f() { _ = 1 }
        """)
        let nothing = MutationOperators.Decision.skip(reason: "body does nothing, like its mutant")
        #expect(methods.map(\.decision) == [
            nothing, nothing, nothing, .mutate([.emptyBody]), .mutate([.emptyBody]), .mutate([.emptyBody]),
        ])
    }

    /// A `return` without a value is arid as well, which is the reason given unless that is off.
    @Test func aBodyThatOnlyReturnsDoesNothing() {
        let source = "func a() { return }"
        #expect(discover(source).map(\.decision) == [.skip(reason: AridDetector.skipReason)])
        #expect(discover(source, arid: false).map(\.decision) == [.skip(reason: "body does nothing, like its mutant")])
    }

    /// Throwing instead is something a test can detect.
    @Test func theThrowMutantOfABodyThatDoesNothingStays() {
        let methods = discover("func a() throws {}", throwMutants: true)
        #expect(methods.map(\.decision) == [.mutate([.throwError])])
    }
}
