import Testing
@testable import TestEffectivenessCore

struct SchemataRewriterTests {
    private func rewrite(_ source: String) -> String {
        let methods = MethodDiscovery.discover(source: source, relativePath: "Sources/A/File.swift")
        var nextID = 1
        let assignments = methods.map { method in
            (method, method.mutations.map { mutation in
                defer { nextID += 1 }
                return Mutant(id: nextID, mutation: mutation)
            })
        }
        let rewritten = SchemataRewriter.rewrite(source: source, methods: assignments)
        // Drop the footer to keep expectations short.
        return String(rewritten.prefix(upTo: rewritten.range(of: "\n// MARK: - swift-test-effectiveness")!.lowerBound))
    }

    @Test func insertsSwitchAndImplicitReturn() {
        let output = rewrite("""
        func add(_ a: Int, _ b: Int) -> Int {
            a + b
        }
        """)
        #expect(output == """
        func add(_ a: Int, _ b: Int) -> Int { switch __steActiveMutant { case 1: return 0; case 2: return 1; case -2: __steReached(1); default: break };
            return a + b
        }

        """)
    }

    @Test func voidBodyUsesBareReturn() {
        let output = rewrite("func reset() { count = 0 }")
        #expect(output == "func reset() { switch __steActiveMutant { case 1: return; case -2: __steReached(1); default: break }; count = 0 }\n")
    }

    @Test func resultBuilderBodyIsWrappedInIfElse() {
        let output = rewrite("""
        struct V: View {
            var body: some View {
                Text("a")
            }
        }
        """)
        #expect(output == """
        struct V: View {
            var body: some View { if __steMutantIs(1) { EmptyView() } else {
                Text("a")
             } }
        }

        """)
    }

    /// Every `return` of a method with an opaque result must have one type, so the original body
    /// moves into a local function and the method returns once.
    @Test func someViewOutsideAResultBuilderMovesTheBodyIntoALocalFunction() {
        let output = rewrite("""
        func label(_ done: Bool) -> some View {
            guard done else { return Text("todo") }
            return Text("done")
        }
        """)
        #expect(output == """
        func label(_ done: Bool) -> some View { func __steOriginal() -> some View {
            guard done else { return Text("todo") }
            return Text("done")
         }; return __steMutantIs(1) ? ViewBuilder.buildEither(first: EmptyView()) : ViewBuilder.buildEither(second: __steOriginal()) }

        """)
    }

    /// Without a `return` the body may be a view builder through a protocol requirement.
    @Test func bodyWithoutReturnBecomesAViewBuilder() {
        let output = rewrite("""
        struct Card: ViewModifier {
            func body(content: Content) -> some View {
                content
                Divider()
            }
            var title: some View { Text("a") }
        }
        """)
        #expect(output == """
        struct Card: ViewModifier {
            func body(content: Content) -> some View { @ViewBuilder func __steOriginal() -> some View {
                content
                Divider()
             }; return __steMutantIs(1) ? ViewBuilder.buildEither(first: EmptyView()) : ViewBuilder.buildEither(second: __steOriginal()) }
            var title: some View { @ViewBuilder func __steOriginal() -> some View { Text("a")  }; return __steMutantIs(2) ? ViewBuilder.buildEither(first: EmptyView()) : ViewBuilder.buildEither(second: __steOriginal()) }
        }

        """)
    }

    @Test func localFunctionRepeatsEffectsAndThrowMutantComesFirst() {
        let source = "func load() async throws -> some View { try await view() }"
        let methods = MethodDiscovery.discover(
            source: source, relativePath: "f.swift", options: DiscoveryOptions(includeThrowMutants: true)
        )
        let output = SchemataRewriter.rewrite(source: source, methods: [
            (methods[0], [Mutant(id: 4, mutation: .emptyView), Mutant(id: 5, mutation: .throwError)]),
        ])
        #expect(output.hasPrefix(
            "func load() async throws -> some View { @ViewBuilder func __steOriginal() async throws -> some View { try await view()  }; "
                + "if __steActiveMutant == 5 { throw __STEExtremeMutationError() }; "
                + "return try await __steMutantIs(4) ? ViewBuilder.buildEither(first: EmptyView()) : ViewBuilder.buildEither(second: __steOriginal()) }\n"
        ))
    }

    @Test func preservesLineNumbers() {
        let source = """
        struct S {
            func a() -> Bool { true }

            var b: String {
                "x"
            }
            func c() -> Int? {
                nil
            }
            func d() -> some View {
                Text("d")
            }
        }
        """
        let output = rewrite(source)
        #expect(output.split(separator: "\n", omittingEmptySubsequences: false).count
            == source.split(separator: "\n", omittingEmptySubsequences: false).count + 1)
    }

    @Test func handlesMultipleMethodsOnOneLine() {
        let output = rewrite("func a() -> Bool { true }; func b() -> Bool { false }")
        #expect(output == "func a() -> Bool { switch __steActiveMutant { case 1: return true; case 2: return false; case -2: __steReached(1); default: break }; return true }; func b() -> Bool { switch __steActiveMutant { case 3: return true; case 4: return false; case -2: __steReached(3); default: break }; return false }\n")
    }

    @Test func footerReadsEnvironmentVariable() {
        let output = SchemataRewriter.rewrite(
            source: "func f() {}",
            methods: MethodDiscovery.discover(source: "func f() {}", relativePath: "f.swift").map { ($0, [Mutant(id: 9, mutation: .emptyBody)]) }
        )
        #expect(output.contains("getenv(\"STE_MUTANT\")"))
        #expect(output.contains("fileprivate let __steActiveMutant"))
    }

    /// While recording, no mutant is active, and each method has a flag at the offset of its
    /// first mutant from the file's smallest id.
    @Test func footerRecordsReachedMethods() {
        let source = "func a() -> Bool { true }; func b() {}"
        let methods = MethodDiscovery.discover(source: source, relativePath: "f.swift")
        let output = SchemataRewriter.rewrite(source: source, methods: [
            (methods[0], [Mutant(id: 7, mutation: .returnBool(true)), Mutant(id: 8, mutation: .returnBool(false))]),
            (methods[1], [Mutant(id: 9, mutation: .emptyBody)]),
        ])
        #expect(output.contains("case -2: __steReached(7)"))
        #expect(output.contains("case -2: __steReached(9)"))
        #expect(output.contains("getenv(\"STE_REACHED\")"))
        #expect(output.contains("if __steReachedFile >= 0 { return -2 }"))
        #expect(output.contains("allocate(capacity: 3)"))
        #expect(output.contains("__steReachedFlags + (id - 7)"))
        #expect(output.contains("let line = Array(\"\\(id)\\n\".utf8)"))
    }

    @Test func parsesReachedMethods() {
        #expect(ReachedMethods.parse("3\n11\n3\n") == [3, 11])
        #expect(ReachedMethods.parse("") == [])
        // A process that was killed while writing.
        #expect(ReachedMethods.parse("3\n1") == [3, 1])
        #expect(ReachedMethods.parse("3\nx\n\n8\n") == [3, 8])
    }

    @Test func untouchedFileIsReturnedVerbatim() {
        #expect(SchemataRewriter.rewrite(source: "let x = 1", methods: []) == "let x = 1")
    }
}
