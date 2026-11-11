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
| 2 | Discover declarations with SwiftSyntax and decide how each layer will analyse them (or why they are skipped, including bodies that only log: `AridDetection.swift`); with `--since`, keep only declarations that overlap changed lines | shared | `MethodDiscovery.swift`, `MutationOperators.swift`, `SwitchCases.swift`, `AridDetection.swift`, `GitDiff.swift` |
| 3 | Copy the project to `<package>/.build/test-effectiveness/project` and prepare the copy for the layers that need it | shared | `Analyzer.swift`, `SchemataRewriter.swift` |
| 4 | Build **once** (`swift build --build-tests --enable-code-coverage --enable-index-store`, or the custom build command) | shared | `Analyzer.swift` |
| 5 | Static reference layer: read the build's index to fill the referenced column | layer | `References.swift` |
| 6 | Run the tests on the unmodified behaviour (baseline). Stop if they fail | shared | `Analyzer.swift` |
| 7 | Coverage layer: read the baseline's coverage to fill the executed column | layer | `Coverage.swift` |
| 8 | Extreme mutation layer: for each mutant of an executed method, run the tests with that mutant active, to fill the verified column | layer | `Analyzer.swift`, `DirectTestLauncher.swift`, `ProcessRunner.swift` |
| 9 | Combine the columns into a finding per declaration and render the report | shared | `Models.swift` (`Classifier`), `Reporter.swift` |

`--dry-run` stops after stage 2 (`Analyzer.plan()`).

Workspace details:

- The copy is updated in place (`WorkspaceCopy.swift`), not deleted and copied again. A file that did not change is not touched, so the build system sees the same file and rebuilds nothing for it; a file counts as unchanged when its size and modification time equal the project's (copies keep the time), and a file with a mutant schema when its contents equal the new schema.
- What the build writes into the copy stays between runs: `.build` with the dependency checkouts, or a derived data directory given to `xcodebuild`. `copied-files.json` in the work directory lists what the last run copied; files in it that the project no longer has are removed from the copy, and files that are not in it belong to the build. Without the list (a copy from an older version, or a run that failed while copying), everything except `.build` is removed first.
- Not copied: `.git`, `.swiftpm`, `DerivedData` and `xcuserdata` at the top of the project, and `.build` wherever it is (also the one of a package or a worktree inside the project).
- Logs for the build, the baseline and each test run go to `.build/test-effectiveness/logs`.

## Layers

### Static references

The build writes an index store (`<bin path>/index/store`; `--index-store-path` overrides it). `ReferenceColumn` opens it with [IndexStoreDB](https://github.com/swiftlang/indexstore-db), loading `libIndexStore.dylib` from the toolchain of the `swift` executable. The database goes to `.build/test-effectiveness/index-db` and is kept between runs, so IndexStoreDB only reads the units that changed in the store; a database it cannot open is deleted and built again.

- Test files are the project files that import `XCTest` or `Testing` and are not production sources. `TestScopeFinder` groups their test declarations into scopes with SwiftSyntax.
- `ReferenceResolver` collects, for each scope, the members the scope refers to and the concrete types it names. It follows calls into test-target code but not into production code. Each dynamic call (`dynamic` role) is resolved through `overrideOf` relations to the implementation of each named type, walking `baseOf` up to superclasses and `extendedBy` from extensions to their types. Implicit `overrideOf` occurrences record which conformers use a protocol extension's default implementation.
- A method is matched to the index by the definitions on its lines, from the start of the declaration to the body's `{`. For a computed property, that is the property and its getter.

The layer never fails the analysis: without an index the column is unknown. It does not narrow down later layers, because a method that no test refers to can still be executed and verified.

### Coverage

The baseline runs with `--enable-code-coverage`, and the resulting `llvm-cov export` JSON is loaded into a `CoverageMap`. Each function is matched to a declaration by the position of its body's opening `{`. When coverage is missing or unreadable, the column is unknown and later layers run on every declaration. The column is stored per declaration (`MethodResult.executed`); `ExecutionStatus.resolve` combines it with the mutant outcomes, letting a killed mutant override coverage.

In custom mode, the baseline's test command writes the profile (`xcodebuild -enableCodeCoverage YES`). `CoverageArtifacts` picks the newest `.profdata` under `--coverage-profdata` that is not older than the baseline, and every Mach-O file under `--coverage-binary` (outside `.dSYM` bundles). Each binary is exported on its own with `xcrun llvm-cov export`, because one binary without coverage data makes an export of several fail; the maps are merged, and a function counts as executed if any binary executed it.

### Extreme mutation

Each mutant run executes the tests with `STE_MUTANT=<id>` in the environment: for a Swift package the test bundles, started directly (see [Direct launch](#direct-launch)), or `swift test --skip-build`; otherwise the custom test command. A run is stopped after a timeout (`RunTimeout.swift`) that follows what it is expected to take: the baseline duration for the whole suite, and for selected scopes the sum of the durations `scopesFailingAlone` measured when each ran alone (never more than the whole suite gets), each × `--timeout-factor` and at least `--minimum-timeout` seconds. Without the option the minimum is 30 seconds, or 5 when the test bundles are started directly: only there is the fixed cost of a run small and a failing run as quick as a passing one. Mutant runs write their profile data elsewhere, so they do not overwrite the baseline coverage.

#### Direct launch

`DirectTestLauncher.swift`. `swift test --skip-build` loads the package and plans the build before it starts the tests (about a second per run) and locks `.build`. For the runs after the baseline, the tool does what `swift test` does last instead: for each test bundle in the build's bin path (`<target>.xctest` per test target, or `<Package>PackageTests.xctest` with the older build system) it starts `xctest <bundle>` for XCTest and `swiftpm-testing-helper --test-bundle-path <binary> … --testing-library swift-testing` for Swift Testing.

- The processes get `DYLD_FRAMEWORK_PATH` and `DYLD_LIBRARY_PATH` for the platform's `XCTest.framework` and `Testing.framework`. `/bin/sh` is a protected binary and drops `DYLD_*`, so `ProcessRunner` starts these commands without a shell (`withoutShell`, `posix_spawn_file_actions_addchdir`).
- `xctest` gets `SWIFT_TESTING_ENABLED=0`; without it, it runs the bundle's Swift Testing tests as well.
- A selection becomes `-XCTest <Module>.<Type>,…` for the type selectors and `--filter` for Swift Testing; only the bundles of the selected modules start. Swift Testing exits with 69 when no test matches, which is not a failure.
- A run stops at the first process that fails; the timeout is for all of its processes together.
- `verify` runs the whole suite once without mutations and compares it with the baseline's output (`TestOutput.executedTests`: XCTest cases started, plus the tests Swift Testing reports). The launcher is used only if the run passes and executes the same number of tests: a wrong launch would otherwise make every mutant look detected (the bundle does not load) or survived (no test runs). Passes that executed no test are not started again, so a bundle with tests of one library costs one process per run.

The baseline stays with `swift test`, which also merges the coverage data. With `--test-filter` (XCTest would need the list of tests to apply a regular expression) or `--no-direct-launch`, or when the check fails, every run goes through `swift test`.

#### Parallel runs

`Analyzer.runMutants` runs the mutants on `--jobs` workers (`DispatchQueue.concurrentPerform`); each worker takes the next mutant from a shared index under a `Mutex`, and results go back to their positions, so the report does not depend on scheduling. `CommandTemplate` replaces `{job}` with the worker's number and `{result-bundle}` with `<work dir>/results/<log name>.xcresult`, removed before the run and, except for the baseline's, after it. The first error stops the workers from taking more mutants. For a Swift package, runs through `swift test` are always one at a time, because it locks `.build`; test bundles started directly use the workers.

#### Test selection

`TestSelection.swift`. The test scopes come from the index: when the static reference layer reads it, `ReferenceColumn` lists every scope as a `TestSelector` (the module from the index, the type or function name from `TestScopeFinder`).

Which scopes execute a method is recorded. Each run of `scopesFailingAlone` (below) gets a file in `<work dir>/reached` through `STE_REACHED`, and the mutant schema appends the methods the run executes to it (see [Mutant schemata](#mutant-schemata)); `selectableTests` turns the files into `RecordedReach.scopes`, the scopes that executed each method. When the runs record nothing, the index stands in (`ReferenceAnalysis.reachingTests`, computed only then, because it is by far the most expensive part of reading the index): `ReferenceColumn` also follows each scope's calls through production code (`ReferenceResolver.referencedSymbols(scope:throughProductionCode:)`, with the same scope-restricted RTA for dynamic calls) and gives, per method, the scopes that reach it.

A mutant runs against those scopes first (`-XCTest` and `--filter` for test bundles started directly, `swift test --filter` otherwise, or `{only-testing}` expanded to `-only-testing:` in custom mode). Whether a mutant that survives them also runs the whole suite depends on `RecordedReach.coversSuite`:

- A test that never calls the method runs the same code with and without the mutant. So when every test of the suite belongs to a recorded scope, a mutant that survives the scopes that executed its method survives the whole suite, and it is not run again. The scopes come from the index and the test sources and could miss a test, so this holds only if every scope can be selected and passes alone, and the scopes together executed as many tests as the baseline (`TestOutput.executedTests`). `--rerun-survivors` runs the whole suite regardless.
- Otherwise, and always with the index's scopes, the whole suite runs, so the outcome is the one the whole suite gives; the reported duration is the sum.

Before the mutants, `selectableTests` runs every selector once without mutations and drops modules whose selection fails, since a failing selection (an unknown target in `xcodebuild`) would look like a detected mutant.

`scopesFailingAlone` then runs each remaining selector on its own, without mutations, on the `--jobs` workers (one run per scope; skipped when there is only one scope, which the previous check already ran alone). A scope that fails alone depends on tests that run before it or shares state with them, so selecting it alone would make a mutant look detected. It is removed from the selectable set, so a mutant that only such scopes reach runs the whole suite, and it goes into `AnalysisReport.testsFailingAlone`, which `Reporter` renders as a section about the tests, separate from the per-declaration findings (`nil` when selection is off: the check did not run). This is a finding about the tests rather than a limitation of selection: tests that depend on each other's order are fragile on their own.

The recorded scopes are what ran when each scope ran alone. Two things can make the whole suite differ, and they are the limits of skipping it: a scope that executes a method only after other tests ran, and a test that fails because of state a mutant made an earlier test leave behind, without calling the method itself. Both are tests that depend on each other; `--rerun-survivors` is for suites that have them.

The index's scopes contain every test that executes the method only as far as the index sees the calls. Calls the index cannot resolve (closures stored and called later, framework callbacks) mean fewer selected tests, which costs a whole-suite run but never changes an outcome.

#### Mutant schemata

Rebuilding for every mutant is slow, so every mutant is compiled into one binary and selected at runtime through an environment variable (Untch, Offutt & Harrold 1993, *Mutation Analysis Using Mutant Schemata*).

```swift
// Original
func add(_ a: Int, _ b: Int) -> Int {
    a + b
}

// Mutant schema
func add(_ a: Int, _ b: Int) -> Int { switch __steActiveMutant { case 1: return 0; case 2: return 1; case -2: __steReached(1); default: break };
    return a + b
}

// Result builder body
var body: some View { if __steMutantIs(7) { EmptyView() } else {
    Text("Hello")
} }

// `some View` outside a result builder
func badge() -> some View { func __steOriginal() -> some View {
    return Circle().frame(width: 8)
}; return __steMutantIs(8) ? ViewBuilder.buildEither(first: EmptyView()) : ViewBuilder.buildEither(second: __steOriginal()) }
```

Invariants the rewriter must keep:

- **Line numbers match the original source.** All insertions are made within existing lines. Coverage (llvm-cov function regions start at the body's `{`) therefore maps directly onto the original declarations, and compiler diagnostics point at the same lines as the original. Insertions only ever shift columns to the right, which `CoverageMap.wasExecuted` relies on when several functions start on one line. Any other layer that rewrites the copy must keep this invariant too.
- **Single-expression bodies get an explicit `return`.** The same applies to `if`/`switch` expressions, unless they contain `return` statements, in which case they are statements. A body that is one `#if` block returns what its active clause is, so every clause that is a single expression gets the `return`, nested blocks included: an inactive clause is not type-checked, and which one is active is only known to the build.
- **An opaque result keeps its body in a local function.** Every `return` of a method returning `some View` must have the same concrete type, so a mutant cannot return in front of the original body. The body moves into the local function `__steOriginal`, where its `return`s are on their own, and the method returns once: `buildEither` is what an `if`/`else` in a view builder becomes, so the type is the one the result builder schema gives. The local function repeats the method's `async` and `throws`. It is a `@ViewBuilder` when the body has no `return`: a requirement such as `ViewModifier.body(content:)` makes the body a view builder without the attribute being written, an explicit `return` turns that off, and a body without one is valid as a builder either way. For the same reason a `var body` or a `@ViewBuilder` body that returns explicitly gets this schema and not the `if`/`else` one, which only compiles inside a builder.
- **The switch is per file.** `__steActiveMutant` is generated at the end of each file as a `nonisolated fileprivate let` read with `getenv`. No build settings or project files need changing, and it works in modules using `defaultIsolation(MainActor.self)`.
- **The switch also records.** With `STE_REACHED=<file>` in the environment, no mutant is active and the switch has the value `-2`: the `case -2` of each method (`__steMutantIs` for `some View`) calls `__steReached` with the id of the method's first mutant, which appends the id as a line to the file the first time the method runs. A per-file byte per mutant id remembers what was written; the write is one `write(2)` to a descriptor opened with `O_APPEND`, so the processes and threads of a run can share the file and a crash loses nothing. Without `STE_REACHED` the extra case costs nothing.

Consequences for which declarations can be mutated (see [Not targeted](docs/methods/extreme-mutation.md#not-targeted)):

- `@inlinable`, `@_transparent` and `@_alwaysEmitIntoClient` bodies cannot reference a `fileprivate` declaration.
- In `main.swift`, top-level code runs in order, so a method could run before the switch is initialised.
- `some View` returned from a `rethrows` function: a local function has no throwing parameter of its own, so it cannot be `rethrows`.
- An expression next to `#if` blocks that may all be compiled out (`#if TRACE` … `#endif` followed by `1`): it is returned implicitly when they are, and is a statement of its own when they are not, so `return` would be right in one build configuration and wrong in the other.

In custom mode, the active mutant is exported as both `STE_MUTANT` and `TEST_RUNNER_STE_MUTANT`, because `xcodebuild test` forwards `TEST_RUNNER_`-prefixed variables to the test process. `STE_REACHED` is exported the same way.

#### Case mutants

With `--case-mutants`, `MethodDiscovery` asks `SwitchCases.discover` for the cases of the switch a body ends with (`DiscoveredMethod.cases`); see [Cases of a switch](docs/methods/extreme-mutation.md#cases-of-a-switch) for which switches and cases qualify. A method whose return type has no simplest value is then kept with `.mutate([])`: no mutant of its own, only those of its cases.

`Analyzer.run()` gives the mutants of a method's cases the ids after the method's own, and `SchemataRewriter` puts them at the start of each case, after the label's colon:

```swift
// A switch statement: the switch over the mutants, at the start of each case
func isBusy(_ state: LoadState) -> Bool { switch __steActiveMutant { case 1: return true; case 2: return false; case -2: __steReached(1); default: break };
    switch state {
    case .loading: switch __steActiveMutant { case 3: return false; case -2: __steReached(3); default: break };
        return true
    default: switch __steActiveMutant { case 4: return true; case -2: __steReached(4); default: break };
        return false
    }
}

// A switch expression: an `if` expression around the expression of each case
func title(for state: LoadState) -> String { switch __steActiveMutant { case 5: return ""; case 6: return "A"; case -2: __steReached(5); default: break };
    return switch state {
    case .idle: if __steMutantIs(7) { "" } else if __steActiveMutant == 8 { "A" } else { "Idle" }
    case .loading: if __steMutantIs(9) { "" } else if __steActiveMutant == 10 { "A" } else { "Loading" }
    }
}

// A return type without a simplest value: each case does what another case does
func tint(for state: LoadState) -> Tint {
    switch state {
    case .idle: if __steMutantIs(11) { fallthrough }; return .gray
    case .failed: if __steMutantIs(12) { return .gray }; return .red
    }
}
```

- **A switch expression stays an expression.** A statement in front of a case's expression would turn the switch into a statement, and every case would then need a `return`, which does not compile in front of a call that never returns (`return unreachable()`; only the compiler knows which calls those are). The mutants are therefore the branches of an `if` expression around the case's expression: whatever the case evaluates to (a value, `throw`, a call that never returns) is as valid in the last branch as it was on its own. `__steMutantIs` in the first condition records the case.
- **`fallthrough` stands in the case itself.** Inside the switch over `__steActiveMutant` it would fall through to that switch's next case, so an `otherCase` mutant is an `if __steMutantIs(id) { … }`. The statements of another case are inserted on the line of the label, which keeps the line numbers. In a switch expression nothing can fall through, and the other case always lends its expression.
- **Each case records that it ran**, under the id of its first mutant, the same way a method does. `RecordedReach.scopes` therefore has the test scopes that execute a case, and a case's mutants run against those.

The case mutants are a second round of `runMutants`, after the mutants of the whole bodies: the outcomes of the first decide which methods' cases run. `CaseResult` holds a case's outcomes, and `Classifier.classify(_:cases:)` combines them with the method's.

## Tests

- Unit tests cover discovery, mutation operators, the rewriter, classification and reporting.
- `Tests/Fixtures/SampleProject` is a small package in which every finding appears at least once. The integration test checks the finding for each method.
- `Tests/Fixtures/ReferencedProject` covers the referenced column: calls through a protocol and a superclass, mock injection, a default implementation, `setUp()` in an XCTestCase, and a method executed only through another one.
- `Tests/Fixtures/HangingProject` has a mutant that makes a loop endless. The integration test checks that it is reported as timed out, after the short timeout of the selected tests.
- `Tests/Fixtures/OrderDependentProject` has a test scope that passes only after another test ran. The integration test checks that it is reported under *Tests that fail alone* and not selected.
- `Tests/Fixtures/SwitchProject` has methods whose logic is a switch, each `tested` by the mutants of its whole body or not analysed at all. The integration test checks which cases `--case-mutants` reports.
- `Tests/Fixtures/EdgeCases` collects constructs that must still compile after rewriting: `if`/`switch` expressions, result builders, `some View` outside a result builder, `throws`, actors, `defaultIsolation(MainActor)`, and more. Add a case here when changing the rewriter.

## Adding a method

Each method fills one of the columns in [docs/concepts.md](docs/concepts.md#three-columns-referenced-executed-verified). When adding one:

- Document it in `docs/methods/<name>.md` (and `docs/ja/methods/<name>.md`): what it does, background, results, limits. Add it to the list in the README.
- Add a subsection under [Layers](#layers) for how it is implemented.
- Keep its result as a separate column. Do not merge it with other columns into a score.
- Place it in the pipeline by cost, so that a cheaper layer narrows down what a more expensive one runs. Decide what it does when an earlier column is unknown.
