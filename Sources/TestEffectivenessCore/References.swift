import Foundation
import IndexStoreDB
import SwiftParser
import SwiftSyntax

/// The queries the referenced column needs from an index. `IndexStoreDB` provides them; tests use
/// an in-memory fake.
protocol SymbolIndex {
    func occurrences(inFile path: String) -> [SymbolOccurrence]
    func occurrences(ofUSR usr: String, roles: SymbolRole) -> [SymbolOccurrence]
    func occurrences(relatedToUSR usr: String, roles: SymbolRole) -> [SymbolOccurrence]
}

extension IndexStoreDB: SymbolIndex {
    func occurrences(inFile path: String) -> [SymbolOccurrence] {
        symbolOccurrences(inFilePath: path)
    }
}

/// A group of test code that shares its setup: an XCTestCase subclass or a Swift Testing suite
/// (with its extensions), or a free `@Test` function.
struct TestScope: Hashable {
    struct Range: Hashable {
        var path: String
        var lines: ClosedRange<Int>
    }

    var name: String
    var ranges: [Range]
    /// The type or function name a test runner selects the scope by (`StoreTests`, `percent`).
    var testName: String = ""
    /// A free `@Test` function rather than a type.
    var isFunction = false
}

enum TestScopeFinder {
    /// Top-level declarations of `source` that contain tests, keyed by type name so extensions of
    /// a test class join the class.
    static func scopes(
        source: String, path: String
    ) -> [(key: String, testName: String, isFunction: Bool, range: TestScope.Range, isTest: Bool)] {
        let tree = Parser.parse(source: source)
        let converter = SourceLocationConverter(fileName: path, tree: tree)
        var result: [(String, String, Bool, TestScope.Range, Bool)] = []
        for item in tree.statements {
            guard let decl = item.item.as(DeclSyntax.self) else { continue }
            let start = decl.startLocation(converter: converter, afterLeadingTrivia: true).line
            let end = decl.endLocation(converter: converter, afterTrailingTrivia: false).line
            let range = TestScope.Range(path: path, lines: start...max(start, end))
            if let function = decl.as(FunctionDeclSyntax.self) {
                let name = function.name.text
                result.append(("\(path):\(start) \(name)", name, true, range, hasAttribute("Test", function.attributes)))
            } else if let (name, isTest) = typeScope(decl) {
                result.append((name, name, false, range, isTest))
            }
        }
        return result
    }

    private static func typeScope(_ decl: DeclSyntax) -> (String, Bool)? {
        let name: String
        let attributes: AttributeListSyntax
        let inheritance: InheritanceClauseSyntax?
        var isClass = false
        if let node = decl.as(ClassDeclSyntax.self) {
            (name, attributes, inheritance, isClass) = (node.name.text, node.attributes, node.inheritanceClause, true)
        } else if let node = decl.as(StructDeclSyntax.self) {
            (name, attributes, inheritance) = (node.name.text, node.attributes, node.inheritanceClause)
        } else if let node = decl.as(EnumDeclSyntax.self) {
            (name, attributes, inheritance) = (node.name.text, node.attributes, node.inheritanceClause)
        } else if let node = decl.as(ActorDeclSyntax.self) {
            (name, attributes, inheritance) = (node.name.text, node.attributes, node.inheritanceClause)
        } else if let node = decl.as(ExtensionDeclSyntax.self) {
            (name, attributes, inheritance) = (node.extendedType.trimmedDescription, node.attributes, node.inheritanceClause)
        } else {
            return nil
        }
        let inheritsXCTestCase = inheritance?.inheritedTypes.contains {
            $0.type.trimmedDescription.hasSuffix("XCTestCase")
        } ?? false
        let finder = TestFunctionFinder(viewMode: .sourceAccurate)
        finder.walk(decl)
        // A class with `testXxx()` methods is most likely an XCTestCase through an intermediate base class.
        let isTest = inheritsXCTestCase || hasAttribute("Suite", attributes)
            || finder.foundSwiftTesting || (isClass && finder.foundXCTestStyle)
        return (name, isTest)
    }

    static func hasAttribute(_ name: String, _ attributes: AttributeListSyntax) -> Bool {
        attributes.contains {
            guard let attribute = $0.as(AttributeSyntax.self) else { return false }
            let written = attribute.attributeName.trimmedDescription
            return written == name || written == "Testing.\(name)"
        }
    }

    private final class TestFunctionFinder: SyntaxVisitor {
        var foundSwiftTesting = false
        var foundXCTestStyle = false

        override func visit(_ node: FunctionDeclSyntax) -> SyntaxVisitorContinueKind {
            if TestScopeFinder.hasAttribute("Test", node.attributes) { foundSwiftTesting = true }
            if node.name.text.hasPrefix("test"), node.signature.parameterClause.parameters.isEmpty,
               !node.modifiers.contains(where: { $0.name.tokenKind == .keyword(.static) }) {
                foundXCTestStyle = true
            }
            return .skipChildren
        }
    }

    /// Groups the test declarations of all test files into scopes.
    static func scopes(files: [(path: String, source: String)]) -> [TestScope] {
        var ranges: [String: [TestScope.Range]] = [:]
        var isTest: [String: Bool] = [:]
        var names: [String: (String, Bool)] = [:]
        var order: [String] = []
        for file in files {
            for (key, testName, isFunction, range, test) in scopes(source: file.source, path: file.path) {
                if ranges[key] == nil { order.append(key) }
                if names[key] == nil { names[key] = (testName, isFunction) }
                ranges[key, default: []].append(range)
                isTest[key] = (isTest[key] ?? false) || test
            }
        }
        return order.filter { isTest[$0] == true }.map {
            TestScope(name: $0, ranges: ranges[$0]!, testName: names[$0]!.0, isFunction: names[$0]!.1)
        }
    }
}

/// Computes the referenced column: the declarations a test refers to directly.
///
/// "Directly" means from test code: the test scope itself and the test-target helpers it calls
/// (`makeSUT()`, mocks, custom assertions), but not further into production code. Following
/// production code transitively would reach nearly everything and only repeat coverage.
///
/// A dynamically dispatched call (through a protocol or an overridable class method) is resolved
/// with rapid type analysis restricted to the test scope: it refers to the implementation of each
/// concrete type the scope names. A test that injects a mock therefore does not refer to the real
/// implementations. Calls to requirements of protocols declared outside the project (`Equatable`,
/// `CustomStringConvertible`, …) are not resolved.
final class ReferenceResolver {
    private let index: any SymbolIndex
    private let testFiles: Set<String>
    private let projectRoots: [String]

    private var definitionCache: [String: [SymbolOccurrence]] = [:]
    private var fileCache: [String: [SymbolOccurrence]] = [:]
    private var implementationCache: [String: [(implementation: String, owner: String)]] = [:]
    private var superclassCache: [String: [String]] = [:]
    private var extendedTypeCache: [String: String?] = [:]
    private var contentsCache: [String: [SymbolOccurrence]] = [:]

    /// - Parameters:
    ///   - testFiles: paths of test files, as the index records them.
    ///   - projectRoots: directory prefixes (ending in `/`) of the project's files, as the index
    ///     records them.
    init(index: any SymbolIndex, testFiles: Set<String>, projectRoots: [String]) {
        self.index = index
        self.testFiles = testFiles
        self.projectRoots = projectRoots
    }

    /// USRs that at least one scope refers to directly.
    func referencedSymbols(scopes: [TestScope]) -> Set<String> {
        scopes.reduce(into: Set<String>()) { $0.formUnion(referencedSymbols(scope: $1)) }
    }

    /// - Parameter throughProductionCode: also follow calls inside production code. The referenced
    ///   column does not; test selection does, to find every test that may execute a method.
    func referencedSymbols(scope: TestScope, throughProductionCode: Bool = false) -> Set<String> {
        var referenced = Set<String>()
        var namedTypes = Set<String>()
        var dynamicCalls = Set<String>()
        var pending: [String] = []

        func reach(_ usr: String) {
            guard referenced.insert(usr).inserted,
                  throughProductionCode ? isProjectCode(usr) : isTestCode(usr)
            else { return }
            pending.append(usr)
        }
        func consume(_ occurrences: [SymbolOccurrence]) {
            for occurrence in occurrences
            where occurrence.roles.contains(.reference) && !occurrence.roles.contains(.definition) {
                let symbol = occurrence.symbol
                if Self.concreteTypeKinds.contains(symbol.kind) {
                    namedTypes.insert(symbol.usr)
                } else if Self.memberKinds.contains(symbol.kind) {
                    if occurrence.roles.contains(.dynamic) { dynamicCalls.insert(symbol.usr) }
                    // The static target counts too: a class method called through the base type.
                    reach(symbol.usr)
                }
            }
        }

        for range in scope.ranges {
            consume(occurrences(inFile: range.path).filter { range.lines.contains($0.location.line) })
        }
        while true {
            while let usr = pending.popLast() {
                consume(contents(of: usr))
            }
            for call in dynamicCalls.sorted() {
                for implementation in implementations(of: call, forTypes: namedTypes) {
                    reach(implementation)
                }
            }
            if pending.isEmpty { break }
        }
        return referenced
    }

    /// USRs declared by a method: the function, or the property and its getter.
    func declaredSymbols(path: String, lines: ClosedRange<Int>) -> Set<String> {
        Set(occurrences(inFile: path).filter {
            $0.roles.contains(.definition) && lines.contains($0.location.line)
                && Self.memberKinds.contains($0.symbol.kind)
        }.map(\.symbol.usr))
    }

    // MARK: - Index queries

    static let concreteTypeKinds: Set<IndexSymbolKind> = [.class, .struct, .enum]
    static let memberKinds: Set<IndexSymbolKind> = [
        .function, .instanceMethod, .classMethod, .staticMethod, .constructor,
        .instanceProperty, .classProperty, .staticProperty, .variable,
    ]

    private func occurrences(inFile path: String) -> [SymbolOccurrence] {
        if let cached = fileCache[path] { return cached }
        let result = index.occurrences(inFile: path)
        fileCache[path] = result
        return result
    }

    private func definitions(of usr: String) -> [SymbolOccurrence] {
        if let cached = definitionCache[usr] { return cached }
        let result = index.occurrences(ofUSR: usr, roles: .definition)
        definitionCache[usr] = result
        return result
    }

    private func isTestCode(_ usr: String) -> Bool {
        definitions(of: usr).contains { testFiles.contains($0.location.path) }
    }

    private func isProjectCode(_ usr: String) -> Bool {
        definitions(of: usr).contains { definition in
            projectRoots.contains { definition.location.path.hasPrefix($0) }
        }
    }

    /// Occurrences inside a declaration's body, including the bodies of a property's accessors.
    private func contents(of usr: String) -> [SymbolOccurrence] {
        if let cached = contentsCache[usr] { return cached }
        var result = index.occurrences(relatedToUSR: usr, roles: .containedBy)
        for accessor in index.occurrences(relatedToUSR: usr, roles: .accessorOf)
        where accessor.roles.contains(.definition) {
            result += index.occurrences(relatedToUSR: accessor.symbol.usr, roles: .containedBy)
        }
        contentsCache[usr] = result
        return result
    }

    /// The module a scope's test code is compiled into, as the index records it.
    func moduleName(of scope: TestScope) -> String? {
        scope.ranges.lazy.compactMap { range in
            self.occurrences(inFile: range.path).first { !$0.location.moduleName.isEmpty }?.location.moduleName
        }.first
    }

    /// The implementations a dynamic call to `requirement` reaches when the receiver is one of
    /// `types`: for each type, the implementation of the type itself or its nearest superclass.
    private func implementations(of requirement: String, forTypes types: Set<String>) -> [String] {
        guard isProjectCode(requirement) else { return [] }
        let byOwner = Dictionary(grouping: implementations(of: requirement), by: \.owner)
        var result: [String] = []
        for type in types.sorted() {
            var chain = [type]
            var seen: Set<String> = [type]
            var index = 0
            while index < chain.count {
                if let found = byOwner[chain[index]] {
                    result += found.map(\.implementation)
                    break
                }
                for superclass in superclasses(of: chain[index]) where seen.insert(superclass).inserted {
                    chain.append(superclass)
                }
                index += 1
            }
        }
        return result
    }

    /// Every implementation of `requirement` with the concrete type that owns it, following
    /// overrides of overrides. The requirement itself is included when it belongs to a class.
    private func implementations(of requirement: String) -> [(implementation: String, owner: String)] {
        if let cached = implementationCache[requirement] { return cached }
        var result: [(implementation: String, owner: String)] = []
        for definition in definitions(of: requirement) {
            if let owner = owner(of: definition) { result.append((requirement, owner)) }
        }
        var visited: Set<String> = [requirement]
        var queue = [requirement]
        while let current = queue.popLast() {
            for occurrence in index.occurrences(relatedToUSR: current, roles: .overrideOf) {
                let usr = occurrence.symbol.usr
                if let owner = owner(of: occurrence) { result.append((usr, owner)) }
                if visited.insert(usr).inserted { queue.append(usr) }
            }
        }
        implementationCache[requirement] = result
        return result
    }

    /// The concrete type a member belongs to. For an implicit occurrence (a conforming type that
    /// uses a protocol extension's default implementation) that is the conforming type.
    private func owner(of occurrence: SymbolOccurrence) -> String? {
        for relation in occurrence.relations
        where relation.roles.contains(.childOf) || relation.roles.contains(.containedBy) {
            let symbol = relation.symbol
            if Self.concreteTypeKinds.contains(symbol.kind) { return symbol.usr }
            if symbol.kind == .extension, let extended = extendedType(of: symbol.usr),
               !extended.isEmpty {
                return extended
            }
        }
        return nil
    }

    private func extendedType(of extensionUSR: String) -> String? {
        if let cached = extendedTypeCache[extensionUSR] { return cached }
        let result = index.occurrences(relatedToUSR: extensionUSR, roles: .extendedBy)
            .first { Self.concreteTypeKinds.contains($0.symbol.kind) }?.symbol.usr
        extendedTypeCache[extensionUSR] = .some(result)
        return result
    }

    private func superclasses(of type: String) -> [String] {
        if let cached = superclassCache[type] { return cached }
        let result = index.occurrences(relatedToUSR: type, roles: .baseOf)
            .filter { $0.symbol.kind == .class }.map(\.symbol.usr)
        superclassCache[type] = result
        return result
    }
}

/// What the index says about the analyzed methods.
struct ReferenceAnalysis {
    /// The referenced column.
    var status: [MethodInfo: ReferenceStatus]
    /// For each method, the tests that may execute it: the scopes that reach one of its symbols,
    /// following calls through test and production code. Empty unless test selection asked for it.
    ///
    /// Computed when called: following every scope through the production code is by far the
    /// most expensive part of reading the index, and test selection only needs it when the test
    /// runs did not record what they execute.
    var reachingTests: () -> [MethodInfo: Set<TestSelector>] = { [:] }
    /// Every test scope found, as a selector.
    var allTests: Set<TestSelector> = []
}

/// Opens an index store and fills the referenced column for a set of methods.
enum ReferenceColumn {
    struct Unavailable: Error, CustomStringConvertible {
        var description: String
    }

    /// Module USRs whose import marks a file as test code.
    static let testFrameworkModules = ["c:@M@XCTest", "c:@M@Testing"]

    /// - Parameters:
    ///   - projectRoot: the root the methods' relative paths are resolved against (the build copy).
    ///   - productionFiles: relative paths of the analyzed sources; never treated as test code.
    ///   - selectTests: also compute the tests that reach each method.
    static func compute(
        storePath: URL, libraryPath: URL, databasePath: URL,
        projectRoot: URL, productionFiles: Set<String>, methods: [MethodInfo], selectTests: Bool = false
    ) throws -> ReferenceAnalysis {
        guard FileManager.default.fileExists(atPath: storePath.path) else {
            throw Unavailable(description: "no index store at \(storePath.path)")
        }
        // The database of the last run is kept: IndexStoreDB then only reads the units that
        // changed in the store. A database it cannot open is thrown away and built again.
        func open() throws -> IndexStoreDB {
            try FileManager.default.createDirectory(at: databasePath, withIntermediateDirectories: true)
            return try IndexStoreDB(
                storePath: storePath.path, databasePath: databasePath.path,
                library: IndexStoreLibrary(dylibPath: libraryPath.path),
                waitUntilDoneInitializing: true, listenToUnitEvents: false
            )
        }
        let index: IndexStoreDB
        do {
            index = try open()
        } catch {
            try? FileManager.default.removeItem(at: databasePath)
            do {
                index = try open()
            } catch {
                throw Unavailable(description: "could not open the index store: \(error)")
            }
        }
        index.pollForUnitChangesAndWait()
        return compute(
            index: index, projectRoot: projectRoot, productionFiles: productionFiles,
            methods: methods, selectTests: selectTests
        )
    }

    static func compute(
        index: any SymbolIndex, projectRoot: URL, productionFiles: Set<String>, methods: [MethodInfo],
        selectTests: Bool = false
    ) -> ReferenceAnalysis {
        // The compiler records real paths; the project may sit behind a symlink (e.g. /tmp → /private/tmp).
        // Foundation's `resolvingSymlinksInPath` drops `/private` again, so ask `realpath(3)`.
        let roots = Array(Set([projectRoot.standardizedFileURL.path, realPath(projectRoot.path)]))
            .map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        func relative(_ path: String) -> String? {
            roots.first { path.hasPrefix($0) }.map { String(path.dropFirst($0.count)) }
        }

        var testFiles = Set<String>()
        for module in testFrameworkModules {
            for occurrence in index.occurrences(ofUSR: module, roles: .reference) {
                let path = occurrence.location.path
                if let relativePath = relative(path), !productionFiles.contains(relativePath) {
                    testFiles.insert(path)
                }
            }
        }
        let sources = testFiles.sorted().compactMap { path in
            (try? String(contentsOfFile: path, encoding: .utf8)).map { (path: path, source: $0) }
        }
        let scopes = TestScopeFinder.scopes(files: sources)
        let resolver = ReferenceResolver(index: index, testFiles: testFiles, projectRoots: roots)
        let referenced = resolver.referencedSymbols(scopes: scopes)

        var selectors: [(scope: TestScope, selector: TestSelector)] = []
        if selectTests {
            for scope in scopes {
                guard let module = resolver.moduleName(of: scope) else { continue }
                selectors.append((scope, TestSelector(module: module, name: scope.testName, isFunction: scope.isFunction)))
            }
        }

        var analysis = ReferenceAnalysis(status: [:], allTests: Set(selectors.map(\.selector)))
        var declaredSymbols: [(method: MethodInfo, symbols: Set<String>)] = []
        for method in methods {
            let lines = method.declarationStart.line...max(method.declarationStart.line, method.bodyStart.line)
            let declared = roots.lazy
                .map { resolver.declaredSymbols(path: $0 + method.file, lines: lines) }
                .first { !$0.isEmpty } ?? []
            if declared.isEmpty {
                analysis.status[method] = .unknown
                continue
            }
            analysis.status[method] = declared.isDisjoint(with: referenced) ? .notReferenced : .referenced
            declaredSymbols.append((method, declared))
        }
        if selectTests {
            analysis.reachingTests = {
                // Selection follows production code too, so a helper reached only through a
                // public method still gets the tests of that method.
                let reachable = selectors.map {
                    (selector: $0.selector, symbols: resolver.referencedSymbols(scope: $0.scope, throughProductionCode: true))
                }
                return Dictionary(declaredSymbols.map { method, declared in
                    (method, Set(reachable.filter { !$0.symbols.isDisjoint(with: declared) }.map(\.selector)))
                }, uniquingKeysWith: { $1 })
            }
        }
        return analysis
    }

    static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// `libIndexStore.dylib` of the toolchain that `swift` belongs to.
    static func libraryPath(swift: String) -> URL? {
        guard let resources = runtimeResourcePath(swift: swift) else { return nil }
        let library = resources.deletingLastPathComponent().appendingPathComponent("libIndexStore.dylib")
        return FileManager.default.fileExists(atPath: library.path) ? library : nil
    }

    /// `<toolchain>/usr/lib/swift` of the toolchain that `swift` belongs to.
    static func runtimeResourcePath(swift: String) -> URL? {
        guard let result = try? ProcessRunner.run([swift, "-print-target-info"], in: FileManager.default.temporaryDirectory),
              result.exitCode == 0,
              let start = result.output.firstIndex(of: "{"),
              let data = String(result.output[start...]).data(using: .utf8),
              let info = try? JSONDecoder().decode(TargetInfo.self, from: data)
        else { return nil }
        return URL(fileURLWithPath: info.paths.runtimeResourcePath)
    }

    private struct TargetInfo: Decodable {
        struct Paths: Decodable { var runtimeResourcePath: String }
        var paths: Paths
    }
}
