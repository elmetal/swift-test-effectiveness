import Testing
@testable import TestEffectivenessCore

struct MethodDiscoveryTests {
    private func discover(_ source: String, path: String = "Sources/A/File.swift", throwMutants: Bool = false) -> [DiscoveredMethod] {
        MethodDiscovery.discover(
            source: source, relativePath: path, options: DiscoveryOptions(includeThrowMutants: throwMutants)
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
                get { 1 }
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
        #expect(methods[0].mutations == [.emptyView])
        #expect(methods[2].mutations.isEmpty)
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
        #expect(methods.map { $0.implicitReturnInsertion != nil } == [true, true, false, false, false, false, true])
    }
}
