import Foundation
import IndexStoreDB
import Testing
@testable import TestEffectivenessCore

struct TestScopeFinderTests {
    @Test func groupsTestDeclarationsByType() {
        let first = """
        import XCTest
        import Testing

        struct Mock: Repository {
            func fetch() -> Int { 1 }
        }

        final class StoreTests: XCTestCase {
            var sut: Store!
            override func setUp() { sut = Store() }
        }

        @Test func freeFunction() {}

        func helper() -> Int { 1 }

        @Suite struct Grouped {
            @Test func a() {}
        }

        struct Implicit {
            @Test func b() {}
        }
        """
        let second = """
        extension StoreTests {
            func testFetch() {}
        }

        class LegacyTests: BaseTestCase {
            func testOld() {}
        }
        """
        let scopes = TestScopeFinder.scopes(files: [("/t/A.swift", first), ("/t/B.swift", second)])
        let byName = Dictionary(uniqueKeysWithValues: scopes.map { ($0.name, $0.ranges) })
        #expect(byName["StoreTests"] == [
            TestScope.Range(path: "/t/A.swift", lines: 8...11),
            TestScope.Range(path: "/t/B.swift", lines: 1...3),
        ])
        #expect(byName["Grouped"] != nil)
        #expect(byName["Implicit"] != nil)
        #expect(byName["LegacyTests"] != nil)
        #expect(scopes.contains { $0.name.hasSuffix("freeFunction") })
        // Mocks and helpers are test code, but not tests: they are reached only through a test.
        #expect(byName["Mock"] == nil)
        #expect(!scopes.contains { $0.name.hasSuffix("helper") })
    }
}

/// An in-memory index with the same query semantics as IndexStoreDB: a query matches when the
/// occurrence (or relation) has any of the requested roles.
struct FakeIndex: SymbolIndex {
    var all: [SymbolOccurrence] = []

    func occurrences(inFile path: String) -> [SymbolOccurrence] {
        all.filter { $0.location.path == path }
    }

    func occurrences(ofUSR usr: String, roles: SymbolRole) -> [SymbolOccurrence] {
        all.filter { $0.symbol.usr == usr && !$0.roles.isDisjoint(with: roles) }
    }

    func occurrences(relatedToUSR usr: String, roles: SymbolRole) -> [SymbolOccurrence] {
        all.filter { $0.relations.contains { $0.symbol.usr == usr && !$0.roles.isDisjoint(with: roles) } }
    }

    static func symbol(_ usr: String, _ kind: IndexSymbolKind) -> Symbol {
        Symbol(usr: usr, name: usr, kind: kind, language: .swift)
    }

    mutating func add(
        _ usr: String, _ kind: IndexSymbolKind, _ roles: SymbolRole, at path: String, line: Int,
        _ relations: [(SymbolRole, String, IndexSymbolKind)] = []
    ) {
        all.append(SymbolOccurrence(
            symbol: Self.symbol(usr, kind),
            location: SymbolLocation(path: path, timestamp: Date(), moduleName: "M", line: line, utf8Column: 1),
            roles: roles,
            symbolProvider: .swift,
            relations: relations.map { SymbolRelation(symbol: Self.symbol($0.1, $0.2), roles: $0.0) }
        ))
    }
}

struct ReferenceResolverTests {
    static let source = "/p/Sources/Store.swift"
    static let tests = "/p/Tests/StoreTests.swift"

    /// The facts the compiler records for:
    ///
    ///     protocol Repository { func fetch(); func count() }          // Store.swift:1-3
    ///     extension Repository { func count() {} }                    // :5
    ///     struct SQL: Repository { func fetch() {} }                  // :7-8 (uses the default count)
    ///     struct Remote: Repository { func fetch() {}; func count() {} } // :10-12
    ///     class Shape { func area() {} }                              // :14-15
    ///     class Square: Shape { override func area() {} }            // :17-18
    ///     class Circle: Shape {}                                      // :20
    ///
    ///     struct Mock: Repository { func fetch() {} }                 // StoreTests.swift:1-2
    ///     func makeSQL() -> SQL { SQL() }                             // :4
    static func storeIndex() -> FakeIndex {
        var index = FakeIndex()
        let s = source
        index.add("Repository", .protocol, [.definition], at: s, line: 1)
        index.add("Repository.fetch", .instanceMethod, [.definition], at: s, line: 2, [(.childOf, "Repository", .protocol)])
        index.add("Repository.count", .instanceMethod, [.definition], at: s, line: 3, [(.childOf, "Repository", .protocol)])
        index.add("Repository", .protocol, [.reference], at: s, line: 5, [(.extendedBy, "ext:Repository", .extension)])
        index.add("default.count", .instanceMethod, [.definition], at: s, line: 5,
                  [(.overrideOf, "Repository.count", .instanceMethod), (.childOf, "ext:Repository", .extension)])

        index.add("SQL", .struct, [.definition], at: s, line: 7)
        index.add("default.count", .instanceMethod, [.implicit], at: s, line: 7,
                  [(.overrideOf, "Repository.count", .instanceMethod), (.containedBy, "SQL", .struct)])
        index.add("SQL.fetch", .instanceMethod, [.definition], at: s, line: 8,
                  [(.overrideOf, "Repository.fetch", .instanceMethod), (.childOf, "SQL", .struct)])

        index.add("Remote", .struct, [.definition], at: s, line: 10)
        index.add("Remote.fetch", .instanceMethod, [.definition], at: s, line: 11,
                  [(.overrideOf, "Repository.fetch", .instanceMethod), (.childOf, "Remote", .struct)])
        index.add("Remote.count", .instanceMethod, [.definition], at: s, line: 12,
                  [(.overrideOf, "Repository.count", .instanceMethod), (.childOf, "Remote", .struct)])

        index.add("Shape", .class, [.definition], at: s, line: 14)
        index.add("Shape.area", .instanceMethod, [.definition], at: s, line: 15, [(.childOf, "Shape", .class)])
        index.add("Square", .class, [.definition], at: s, line: 17)
        index.add("Shape", .class, [.reference], at: s, line: 17, [(.baseOf, "Square", .class)])
        index.add("Square.area", .instanceMethod, [.definition], at: s, line: 18,
                  [(.overrideOf, "Shape.area", .instanceMethod), (.childOf, "Square", .class)])
        index.add("Circle", .class, [.definition], at: s, line: 20)
        index.add("Shape", .class, [.reference], at: s, line: 20, [(.baseOf, "Circle", .class)])

        let t = tests
        index.add("Mock", .struct, [.definition], at: t, line: 1)
        index.add("Mock.fetch", .instanceMethod, [.definition], at: t, line: 2,
                  [(.overrideOf, "Repository.fetch", .instanceMethod), (.childOf, "Mock", .struct)])
        index.add("makeSQL", .function, [.definition], at: t, line: 4)
        index.add("SQL", .struct, [.reference], at: t, line: 4, [(.containedBy, "makeSQL", .function)])
        return index
    }

    private func referenced(_ index: FakeIndex, lines: ClosedRange<Int>) -> Set<String> {
        let resolver = ReferenceResolver(index: index, testFiles: [Self.tests], projectRoots: ["/p/"])
        return resolver.referencedSymbols(scope: TestScope(name: "T", ranges: [.init(path: Self.tests, lines: lines)]))
    }

    private func call(_ index: inout FakeIndex, _ usr: String, line: Int, dynamic: Bool = false) {
        index.add(usr, .instanceMethod, dynamic ? [.reference, .call, .dynamic] : [.reference, .call],
                  at: Self.tests, line: line)
    }

    @Test func protocolCallReachesOnlyTypesTheTestNames() {
        var index = Self.storeIndex()
        index.add("SQL", .struct, [.reference], at: Self.tests, line: 10)
        call(&index, "Repository.fetch", line: 11, dynamic: true)
        call(&index, "Repository.count", line: 12, dynamic: true)
        let result = referenced(index, lines: 10...12)
        #expect(result.isSuperset(of: ["SQL.fetch", "default.count"]))
        #expect(result.isDisjoint(with: ["Remote.fetch", "Remote.count", "Mock.fetch"]))
    }

    @Test func injectedMockDoesNotReferenceRealImplementations() {
        var index = Self.storeIndex()
        index.add("Mock", .struct, [.reference], at: Self.tests, line: 10)
        call(&index, "Repository.fetch", line: 11, dynamic: true)
        let result = referenced(index, lines: 10...11)
        #expect(result.contains("Mock.fetch"))
        #expect(result.isDisjoint(with: ["SQL.fetch", "Remote.fetch"]))
    }

    @Test func typesNamedInTestHelpersCount() {
        var index = Self.storeIndex()
        call(&index, "makeSQL", line: 10)
        call(&index, "Repository.fetch", line: 11, dynamic: true)
        let result = referenced(index, lines: 10...11)
        #expect(result.contains("SQL.fetch"))
        #expect(!result.contains("Remote.fetch"))
    }

    @Test func classCallReachesNearestImplementation() {
        var index = Self.storeIndex()
        index.add("Square", .class, [.reference], at: Self.tests, line: 10)
        index.add("Circle", .class, [.reference], at: Self.tests, line: 11)
        call(&index, "Shape.area", line: 12, dynamic: true)
        let result = referenced(index, lines: 10...12)
        // Circle inherits Shape.area; the call through the base type names Shape.area anyway.
        #expect(result.isSuperset(of: ["Square.area", "Shape.area"]))
    }

    @Test func callsOutsideTheScopeDoNotCount() {
        var index = Self.storeIndex()
        index.add("SQL", .struct, [.reference], at: Self.tests, line: 10)
        call(&index, "Repository.fetch", line: 30, dynamic: true)
        #expect(!referenced(index, lines: 10...12).contains("SQL.fetch"))
    }

    @Test func productionCodeIsNotFollowed() {
        var index = Self.storeIndex()
        // SQL.fetch calls Remote.fetch; a test calling SQL.fetch refers only to SQL.fetch.
        index.add("Remote.fetch", .instanceMethod, [.reference, .call], at: Self.source, line: 8,
                  [(.containedBy, "SQL.fetch", .instanceMethod)])
        call(&index, "SQL.fetch", line: 10)
        let result = referenced(index, lines: 10...10)
        #expect(result.contains("SQL.fetch"))
        #expect(!result.contains("Remote.fetch"))
    }

    @Test func columnMapsMethodsByDeclarationLine() {
        let index = Self.storeIndex()
        let method = { (line: Int) in
            MethodInfo(
                file: "Sources/Store.swift", name: "m\(line)", kind: .function,
                declarationStart: SourcePosition(line: line, column: 1), declarationEnd: SourcePosition(line: line, column: 9),
                bodyStart: SourcePosition(line: line, column: 5), returnType: nil
            )
        }
        let column = ReferenceColumn.compute(
            index: index, projectRoot: URL(fileURLWithPath: "/p"),
            productionFiles: ["Sources/Store.swift"], methods: [method(8), method(11), method(99)]
        )
        // No test file on disk, so no scope refers to anything; line 99 declares nothing.
        #expect(column[method(8)] == .notReferenced)
        #expect(column[method(11)] == .notReferenced)
        #expect(column[method(99)] == .unknown)
    }
}
