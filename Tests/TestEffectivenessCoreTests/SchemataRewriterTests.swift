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
        return String(rewritten.prefix(upTo: rewritten.range(of: SchemataRewriter.footer)!.lowerBound))
    }

    @Test func insertsSwitchAndImplicitReturn() {
        let output = rewrite("""
        func add(_ a: Int, _ b: Int) -> Int {
            a + b
        }
        """)
        #expect(output == """
        func add(_ a: Int, _ b: Int) -> Int { switch __steActiveMutant { case 1: return 0; case 2: return 1; default: break };
            return a + b
        }

        """)
    }

    @Test func voidBodyUsesBareReturn() {
        let output = rewrite("func log() { print(1) }")
        #expect(output == "func log() { switch __steActiveMutant { case 1: return; default: break }; print(1) }\n")
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
            var body: some View { if __steActiveMutant == 1 { EmptyView() } else {
                Text("a")
             } }
        }

        """)
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
        }
        """
        let output = rewrite(source)
        #expect(output.split(separator: "\n", omittingEmptySubsequences: false).count
            == source.split(separator: "\n", omittingEmptySubsequences: false).count + 1)
    }

    @Test func handlesMultipleMethodsOnOneLine() {
        let output = rewrite("func a() -> Bool { true }; func b() -> Bool { false }")
        #expect(output == "func a() -> Bool { switch __steActiveMutant { case 1: return true; case 2: return false; default: break }; return true }; func b() -> Bool { switch __steActiveMutant { case 3: return true; case 4: return false; default: break }; return false }\n")
    }

    @Test func footerReadsEnvironmentVariable() {
        let output = SchemataRewriter.rewrite(
            source: "func f() {}",
            methods: MethodDiscovery.discover(source: "func f() {}", relativePath: "f.swift").map { ($0, [Mutant(id: 9, mutation: .emptyBody)]) }
        )
        #expect(output.contains("getenv(\"STE_MUTANT\")"))
        #expect(output.contains("fileprivate let __steActiveMutant"))
    }

    @Test func untouchedFileIsReturnedVerbatim() {
        #expect(SchemataRewriter.rewrite(source: "let x = 1", methods: []) == "let x = 1")
    }
}
