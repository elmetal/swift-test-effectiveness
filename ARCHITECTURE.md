# Architecture

English | [日本語](ARCHITECTURE.ja.md)

How swift-test-effectiveness is built. For what the tool reports and why, see [docs/concepts.md](docs/concepts.md) and the documents under [docs/methods/](docs/methods/).

## Targets

| Target | Role |
|---|---|
| `swift-test-effectiveness` | command-line interface (swift-argument-parser); turns options into an `AnalysisConfiguration` and prints the report |
| `TestEffectivenessCore` | the analysis itself. Not a library product: its `indexstore-db` dependency is pinned to a revision, which SwiftPM does not allow in packages depended on by version |
| `TestEffectivenessCoreTests` | unit tests, plus integration tests against `Tests/Fixtures` |

## Pipeline

`Analyzer.run()` drives the analysis. The original project is never modified; everything happens in a copy.

The pipeline is a set of shared stages around a sequence of method layers, ordered from cheap to expensive so that each layer narrows down what the next one has to run (see [Methods as a funnel](docs/concepts.md#methods-as-a-funnel)).

| # | Stage | Kind | File |
|---|---|---|---|
| 1 | List source files: non-test targets from `swift package describe`, or `--source-dir` in custom mode; apply `--exclude` | shared | `Analyzer.swift` |
| 2 | Discover declarations with SwiftSyntax and decide how each layer will analyse them (or why they are skipped, including bodies that only log: `AridDetection.swift`); with `--since`, keep only declarations that overlap changed lines | shared | `MethodDiscovery.swift`, `MutationOperators.swift`, `AridDetection.swift`, `GitDiff.swift` |
| 3 | Copy the project to `<package>/.build/test-effectiveness/project` and prepare the copy for the layers that need it | shared | `Analyzer.swift`, `SchemataRewriter.swift` |
| 4 | Build **once** (`swift build --build-tests --enable-code-coverage --enable-index-store`, or the custom build command) | shared | `Analyzer.swift` |
| 5 | Static reference layer: read the build's index to fill the referenced column | layer | `References.swift` |
| 6 | Run the tests on the unmodified behaviour (baseline). Stop if they fail | shared | `Analyzer.swift` |
| 7 | Coverage layer: read the baseline's coverage to fill the executed column | layer | `Coverage.swift` |
| 8 | Extreme mutation layer: for each mutant of an executed method, run the tests with that mutant active, to fill the verified column | layer | `Analyzer.swift`, `ProcessRunner.swift` |
| 9 | Combine the columns into a finding per declaration and render the report | shared | `Models.swift` (`Classifier`), `Reporter.swift` |

`--dry-run` stops after stage 2 (`Analyzer.plan()`).

Workspace details:

- The copy keeps its own `.build` between runs, so later runs build incrementally and reuse dependency checkouts. `.git`, `.swiftpm`, `DerivedData` and `xcuserdata` are not copied.
- Logs for the build, the baseline and each test run go to `.build/test-effectiveness/logs`.

## Layers

### Static references

The build writes an index store (`<bin path>/index/store`; `--index-store-path` overrides it). `ReferenceColumn` opens it with [IndexStoreDB](https://github.com/swiftlang/indexstore-db), loading `libIndexStore.dylib` from the toolchain of the `swift` executable. The database goes to `.build/test-effectiveness/index-db` and is rebuilt on every run.

- Test files are the project files that import `XCTest` or `Testing` and are not production sources. `TestScopeFinder` groups their test declarations into scopes with SwiftSyntax.
- `ReferenceResolver` collects, for each scope, the members the scope refers to and the concrete types it names. It follows calls into test-target code but not into production code. Each dynamic call (`dynamic` role) is resolved through `overrideOf` relations to the implementation of each named type, walking `baseOf` up to superclasses and `extendedBy` from extensions to their types. Implicit `overrideOf` occurrences record which conformers use a protocol extension's default implementation.
- A method is matched to the index by the definitions on its lines, from the start of the declaration to the body's `{`. For a computed property, that is the property and its getter.

The layer never fails the analysis: without an index the column is unknown. It does not narrow down later layers, because a method that no test refers to can still be executed and verified.

### Coverage

The baseline runs with `--enable-code-coverage`, and the resulting `llvm-cov export` JSON is loaded into a `CoverageMap`. Each function is matched to a declaration by the position of its body's opening `{`. When coverage is missing or unreadable, the column is unknown and later layers run on every declaration. The column is stored per declaration (`MethodResult.executed`); `ExecutionStatus.resolve` combines it with the mutant outcomes, letting a killed mutant override coverage.

### Extreme mutation

Each mutant run executes `STE_MUTANT=<id> swift test --skip-build` (or the custom test command) with a timeout of the baseline duration × `--timeout-factor`, with `--minimum-timeout` seconds as the minimum. Mutant runs write their profile data to a separate file, so they do not overwrite the baseline coverage.

#### Mutant schemata

Rebuilding for every mutant is slow, so every mutant is compiled into one binary and selected at runtime through an environment variable (Untch, Offutt & Harrold 1993, *Mutation Analysis Using Mutant Schemata*).

```swift
// Original
func add(_ a: Int, _ b: Int) -> Int {
    a + b
}

// Mutant schema
func add(_ a: Int, _ b: Int) -> Int { switch __steActiveMutant { case 1: return 0; case 2: return 1; default: break };
    return a + b
}

// Result builder body
var body: some View { if __steActiveMutant == 7 { EmptyView() } else {
    Text("Hello")
} }
```

Invariants the rewriter must keep:

- **Line numbers match the original source.** All insertions are made within existing lines. Coverage (llvm-cov function regions start at the body's `{`) therefore maps directly onto the original declarations, and compiler diagnostics point at the same lines as the original. Insertions only ever shift columns to the right, which `CoverageMap.wasExecuted` relies on when several functions start on one line. Any other layer that rewrites the copy must keep this invariant too.
- **Single-expression bodies get an explicit `return`.** The same applies to `if`/`switch` expressions, unless they contain `return` statements, in which case they are statements.
- **The switch is per file.** `__steActiveMutant` is generated at the end of each file as a `nonisolated fileprivate let` read with `getenv`. No build settings or project files need changing, and it works in modules using `defaultIsolation(MainActor.self)`.

Consequences for which declarations can be mutated (see [Not targeted](docs/methods/extreme-mutation.md#not-targeted)):

- `@inlinable`, `@_transparent` and `@_alwaysEmitIntoClient` bodies cannot reference a `fileprivate` declaration.
- In `main.swift`, top-level code runs in order, so a method could run before the switch is initialised.
- `some View` outside a result builder would need the same concrete type on both branches of the inserted check.

In custom mode, the active mutant is exported as both `STE_MUTANT` and `TEST_RUNNER_STE_MUTANT`, because `xcodebuild test` forwards `TEST_RUNNER_`-prefixed variables to the test process.

## Tests

- Unit tests cover discovery, mutation operators, the rewriter, classification and reporting.
- `Tests/Fixtures/SampleProject` is a small package in which every finding appears at least once. The integration test checks the finding for each method.
- `Tests/Fixtures/ReferencedProject` covers the referenced column: calls through a protocol and a superclass, mock injection, a default implementation, `setUp()` in an XCTestCase, and a method executed only through another one.
- `Tests/Fixtures/EdgeCases` collects constructs that must still compile after rewriting: `if`/`switch` expressions, result builders, `throws`, actors, `defaultIsolation(MainActor)`, and more. Add a case here when changing the rewriter.

## Adding a method

Each method fills one of the columns in [docs/concepts.md](docs/concepts.md#three-columns-referenced-executed-verified). When adding one:

- Document it in `docs/methods/<name>.md` (and `docs/ja/methods/<name>.md`): what it does, background, results, limits. Add it to the list in the README.
- Add a subsection under [Layers](#layers) for how it is implemented.
- Keep its result as a separate column. Do not merge it with other columns into a score.
- Place it in the pipeline by cost, so that a cheaper layer narrows down what a more expensive one runs. Decide what it does when an earlier column is unknown.
