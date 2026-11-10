# swift-test-effectiveness

English | [日本語](README.ja.md)

A tool that gives feedback on the effectiveness of a Swift project's test suite: its ability to detect faults.

Rather than a single score, it reports per declaration what the tests are missing (nothing executes it, nothing verifies what it does, …) and what to do about it.

Currently it reports, for each method, whether any test refers to it directly, using the compiler's index; methods that no test executes, using coverage; and methods that tests execute but do not verify, using extreme mutation: each method body is replaced with the simplest behaviour for its return type (an empty body, `nil`, `true`/`false`, …), and a method for which every replacement still passes the tests is reported as **pseudo-tested**.

```
Pseudo-tested (2)
  Tests execute these methods, but every extreme mutant survived: no test checks what they do.

  Sources/Sample/Calculator.swift:17  Calculator.greeting(for:) -> String
    survived: `return ""`, `return "A"`
    → `Calculator.greeting(for:)` can always return `""` without any test failing. Assert the exact string.
    ...

Partially tested (2)
  Sources/Sample/Calculator.swift:12  Calculator.isPositive(_:) -> Bool
    survived: `return true`
    detected: `return false`
    → `Calculator.isPositive(_:)` can always return `true` without any test failing. Add a case where it must return `false`.
```

## Why

Coverage tells you that code was *executed*, not that any test would fail if it were wrong. For a test to detect a fault, the faulty code has to be executed, the fault has to corrupt the program state, and the corruption has to reach an assertion. A test that never asserts on a return value can reach 100% coverage and still detect nothing.

The tool combines methods that check different parts of this chain, and reports for each declaration which part the tests are missing. It **never reports an aggregate score**. See [Concepts](docs/concepts.md) for the model and the reasons behind this design.

## Reading the report

Declarations are grouped by what the tests are missing, and each entry says what to do next. The current groups:

| Group | What is missing | Found by | What to do |
|---|---|---|---|
| `not-covered` | no test executes the method | [coverage](docs/methods/coverage.md) | write a test |
| `pseudo-tested` | tests execute it, but nothing checks what it does | [extreme mutation](docs/methods/extreme-mutation.md) | add an assertion on what it does |
| `partially-tested` | only part of its behaviour is checked | [extreme mutation](docs/methods/extreme-mutation.md) | add the cases named in the feedback |
| `tested` | nothing found | — | nothing |
| *Not analyzed* | the method cannot be analysed (the reason is shown) | — | — |

Each entry also carries the [referenced](docs/methods/static-references.md) column: whether a test refers to the method directly. The report adds a note where it changes the fix. A `pseudo-tested` method that no test calls directly needs a test of its own, not an assertion somewhere else. A `not-covered` method that a test does refer to points at a skipped test, an injected mock or dispatch to another type.

A test that injects a mock does not count as a reference to the real implementations. Calls through a protocol count only for the concrete types that the same test (or XCTestCase, or suite) names.

Apart from the declarations, the report has a section about the tests themselves. *Tests that fail alone* lists test scopes that pass in the whole suite but fail when run on their own, without mutations: they depend on tests that run before them, or share state with them. Tests should not depend on each other; make each one set up what it needs. The check runs with [test selection](#test-selection).

## Requirements

- macOS 26 or later
- A git repository, for `--since` only
- Swift 6.2 or later (Xcode 26 or later). Tested with Swift 6.4 (Xcode 27).
- A Swift toolchain that matches the selected Xcode's macOS SDK. A swift.org or swiftly toolchain older than that SDK cannot compile package manifests: `swift build` fails with `unknown argument: '-target-arch-variant'` and a compiler crash. Use Xcode's toolchain instead (`xcrun swift`, or `/usr/bin/swift` when `xcode-select` points at Xcode).

The `swift` that runs the analysis (`--swift`) also builds and tests the target project, and its `libIndexStore.dylib` reads the index, so the same applies to it.

## Installation

Build from source and put the binary on your `PATH`:

```bash
git clone https://github.com/elmetal/swift-test-effectiveness.git
cd swift-test-effectiveness
git checkout 0.0.1
swift build -c release
cp .build/release/swift-test-effectiveness /usr/local/bin/
```

Check the installed version with `swift-test-effectiveness --version`.

## Usage

### Swift packages

```bash
swift-test-effectiveness /path/to/package
```

The project is copied to `<package>/.build/test-effectiveness` and analysed there, so your original sources are never modified. The test suite must first pass on the unmodified code (the baseline); otherwise the analysis stops. See [ARCHITECTURE.md](ARCHITECTURE.md#pipeline) for the pipeline.

### Options

| Option | Description |
|---|---|
| `--since <rev>` | Only analyse declarations that overlap lines changed since `<rev>`, including lines deleted from them and new untracked files (for pull requests) |
| `--target <name>` | Only analyse this target (repeatable) |
| `--test-filter <pattern>` | Passed to `swift test --filter` |
| `--exclude <substring>` | Skip files whose path contains this string (repeatable) |
| `--swift <path>` | The `swift` executable to use |
| `--dry-run` | List what would be analysed, without building or running anything |
| `--format text\|markdown\|json` | Report format (markdown is meant for PR comments; JSON is described below) |
| `-o, --output <file>` | Write the report to a file |
| `--fail-on-pseudo-tested` | Exit with status 1 if any method is pseudo-tested |

Options for a specific method:

| Option | Method | Description |
|---|---|---|
| `--no-index` | static references | Do not write or read the compiler's index; the referenced column is unknown |
| `--index-store-path <path>` | static references | Index store to read (default for packages: the one the build writes; needed in custom mode) |
| `--no-coverage` | coverage | Do not collect coverage; run the later methods on every declaration |
| `--coverage-profdata <path>` | coverage | Custom mode: the `.profdata` the test command writes, or a directory to search for the newest one |
| `--coverage-binary <path>` | coverage | Custom mode: a binary built with coverage, or a directory to search for binaries (repeatable) |
| `--throw-mutants` | extreme mutation | Add a `throw` mutant for methods declared with untyped `throws` |
| `--no-arid` | extreme mutation | Also mutate methods returning `Void` whose body only logs (skipped by default, see [Not targeted](docs/methods/extreme-mutation.md#not-targeted)) |
| `--arid-call <name>` | extreme mutation | Also treat calls to this function as logging, e.g. `track` or `Analytics.shared.track` (repeatable) |
| `--jobs <n>` | extreme mutation | Run this many test runs at once (see [Parallel runs](#parallel-runs)) |
| `--no-direct-launch` | extreme mutation | Swift packages: run every test run through `swift test` instead of [starting the test bundles directly](#starting-swift-package-tests-directly) |
| `--timeout-factor`, `--minimum-timeout` | extreme mutation | Timeout for each mutant's test run (baseline duration × factor, with a minimum in seconds) |
| `--no-test-selection` | extreme mutation | Run the whole test suite for every mutant instead of [the tests that execute its method](#test-selection) |
| `--rerun-survivors` | extreme mutation | Run a mutant that survives [the tests that execute its method](#test-selection) against the whole suite as well |

Exit status: `0` success, `1` pseudo-tested methods found with `--fail-on-pseudo-tested`, `2` analysis error (build failure, failing baseline, …), `128 + signal` when interrupted (`130` for Ctrl-C). On interruption the running build or test command is stopped as well.

The JSON report starts with `schemaVersion` and `toolVersion`. `schemaVersion` is incremented when a field is removed, renamed or changes meaning; new fields may be added without changing it, so ignore keys you do not know. `testsFailingAlone` lists the [tests that fail alone](#reading-the-report) (`test`, `timedOut`, `log`); it is absent when the check did not run.

### Xcode and other projects (custom mode)

Pass `--source-dir`, `--build-command` and `--test-command` to use any build system. Commands run with `/bin/sh -c` inside the copied project.

```bash
swift-test-effectiveness /path/to/App \
  --source-dir App \
  --build-command "xcodebuild build-for-testing -scheme App -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'" \
  --test-command  "xcodebuild test-without-building -scheme App -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'"
```

The test command is run once per mutant, with the active mutant exported as both `STE_MUTANT` and `TEST_RUNNER_STE_MUTANT` (`xcodebuild test` forwards `TEST_RUNNER_`-prefixed variables to the test process). The runs that record which methods a test scope executes get the file to write to as `STE_REACHED` and `TEST_RUNNER_STE_REACHED`.

The other methods need files that the build and the test run write. Build into a known derived data path (relative paths are resolved inside the copied project) and point the tool at them:

```bash
swift-test-effectiveness /path/to/App \
  --source-dir App \
  --build-command "xcodebuild build-for-testing -scheme App -derivedDataPath build -enableCodeCoverage YES -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'" \
  --test-command  "xcodebuild test-without-building -scheme App -derivedDataPath build -enableCodeCoverage YES -collect-test-diagnostics never -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2' {only-testing}" \
  --index-store-path build/Index.noindex/DataStore \
  --coverage-profdata build/Build/ProfileData \
  --coverage-binary build/Build/Products
```

- `--index-store-path`: the referenced column (see [Static test references](docs/methods/static-references.md#when-the-index-is-unavailable)) and [test selection](#test-selection).
- `{only-testing}`: [test selection](#test-selection).
- `-collect-test-diagnostics never`: most mutants make a test fail, and by default xcodebuild then collects diagnostics, which made a failing run take 39s instead of 5s in our measurements.
- `-enableCodeCoverage YES`, `--coverage-profdata` and `--coverage-binary`: the executed column. After the baseline, the tool reads the newest `.profdata` the baseline wrote and exports the coverage of every Mach-O binary under `--coverage-binary` with `xcrun llvm-cov export`; binaries without coverage data are skipped. Without coverage, methods that no test executes are reported as `pseudo-tested` rather than `not-covered`, and their mutants run.

### Test selection

Each mutant run executes the test suite, so a large suite makes the analysis slow. The tool therefore runs each mutant against the tests that execute its method. A test that never calls the method runs the same code with and without the mutant, so it cannot detect it: a mutant that survives the tests that execute its method survives the whole suite. Most mutants need only a few tests.

- Which tests execute a method is recorded: each selectable test scope (XCTestCase subclass, suite, free `@Test` function) runs once on its own without mutations (see below), and the mutant schema writes down the methods that run executes. A method that no scope executes on its own, or that every scope executes, runs the whole suite directly.
- A mutant that survives the selected scopes is not run again when the scopes are the whole suite: every scope can be selected and passes alone, and together they executed as many tests as the baseline. Otherwise it runs the whole suite as well, and the log says why. The test counts are read from the test output, so in custom mode they are unknown when `xcodebuild` runs with `-quiet`. `--rerun-survivors` always runs a survivor against the whole suite.
- When the runs record nothing (for example a sandboxed test host, which cannot write the file), the selected tests are the scopes that reach one of the method's symbols in the compiler's index, following calls through test helpers and production code. The index sees only the calls the compiler can resolve, so a mutant that survives these scopes always runs the whole suite.
- It needs the index, which lists the test scopes. SwiftPM: on by default, but not with `--test-filter`. Custom mode: on when the test command contains `{only-testing}`, which is replaced with `'-only-testing:<module>/<Type>'` and `'-only-testing:<module>/<function>()'` arguments (and with nothing when the whole suite runs).
- Before the mutants, every selectable test runs once without mutations. If that fails, each test module is tried on its own and a module that still fails is never selected (for example a target the scheme does not contain, or a target whose name differs from its module name). The logs are `selection-check*.log`.
- Then each selectable test scope runs once on its own, without mutations (one run per scope, on the `--jobs` workers). A scope that fails alone passes in the whole suite only because other tests ran first or share state with it; selected alone, it would fail and make a mutant look detected. Such scopes are never selected, so mutants that only they reach run the whole suite, and the report lists them under *Tests that fail alone*. The logs are `isolation-*.log`, and the methods each run executed are in `<work dir>/reached`. On a large suite this check is the main fixed cost of test selection; the log shows how long it took.
- At the end the log shows how many mutants the selected tests detected, how many survived them without another run, and how many ran the whole suite.

### Parallel runs

`--jobs <n>` runs up to `n` test runs at once, each mutant on the next free worker. The default is one at a time: tests that share something outside their process (a file, a port, a database) can fail when two runs overlap, and a mutant then looks detected.

#### Starting Swift package tests directly

After the baseline, the tool starts the test bundles itself (`xctest` for XCTest, SwiftPM's `swiftpm-testing-helper` for Swift Testing) instead of running `swift test` for every run. `swift test` loads the package before it starts the tests, which takes about a second per run, and it locks `.build`, so its runs cannot overlap. Started directly, a run costs little more than the tests themselves, and `--jobs` applies.

Before relying on it, the tool runs the whole suite directly once, without mutations, and checks that it passes and executes as many tests as the baseline did (`direct-launch-check.log`). If not, every run goes through `swift test`, one at a time, and the log says why. The same happens with `--test-filter` and `--no-direct-launch`.

#### Custom mode

Two placeholders keep the runs apart:

- `{job}` becomes the worker's number, `1` to `n`. A simulator runs one test session at a time, so give each worker its own, e.g. clones named `STE-1` … `STE-n`.
- `{result-bundle}` becomes a fresh path for the run's result bundle. xcodebuild names its default bundles by the second a run starts, so runs that start together collide; it also refuses a path that exists.

```bash
for n in 1 2 3 4; do xcrun simctl clone "iPhone 17" "STE-$n"; done

swift-test-effectiveness /path/to/App \
  --jobs 4 \
  --test-command "xcodebuild test-without-building -scheme App -derivedDataPath build -enableCodeCoverage YES -collect-test-diagnostics never -destination 'platform=iOS Simulator,name=STE-{job},OS=26.2' -resultBundlePath {result-bundle} {only-testing}" \
  …
```

The baseline and the check that every selectable test can be selected run alone, as worker 1; running each test scope alone uses all workers. Result bundles go to `<work dir>/results`; only the baseline's is kept. Timeouts still use the baseline duration, which was measured without other runs; on a loaded machine raise `--timeout-factor`.

### In CI

```bash
swift-test-effectiveness . --since origin/main --format markdown -o effectiveness.md
```

Posting the generated Markdown as a PR comment shows, for the changed declarations only, what the tests are missing and how to fix it.

### Known limitations

- The project is analysed in a copy, so local path dependencies (`.package(path: "../Foo")`) do not resolve.
- `swift test` locks `.build`, so runs that go through it cannot overlap. For Swift packages, [`--jobs`](#parallel-runs) therefore needs the test bundles to be started directly, which `--test-filter` rules out.
- Test selection runs each test scope alone without mutations and never selects a scope that fails on its own (see [Test selection](#test-selection)), so a test that depends on other tests running first does not make a mutant look detected. Scopes that pass alone but fail only in a particular combination with other selected scopes are not detected; use `--no-test-selection` if you suspect such a suite.
- A mutant that survives the tests that execute its method is not run against the whole suite (see [Test selection](#test-selection)). This relies on two things: a test scope executes the same methods alone as in the whole suite, and no test detects a mutant only through state that another test left behind (for example a mutant in a cleanup method that makes a later test fail). In a suite where either does not hold, a mutant the whole suite would detect can be reported as survived; `--rerun-survivors` runs every survivor against the whole suite.

## Documentation

- [Concepts](docs/concepts.md): what test effectiveness is, the PIE model, what "a missing test" means, the referenced / executed / verified columns, and why there is no score
- Methods currently implemented
  - [Static test references](docs/methods/static-references.md): fills the referenced column
  - [Coverage](docs/methods/coverage.md): fills the executed column
  - [Extreme mutation](docs/methods/extreme-mutation.md): fills the verified column
- [ARCHITECTURE.md](ARCHITECTURE.md): the pipeline, how each method is implemented, and how to add one

## Development

```bash
swift test
swift run swift-test-effectiveness /path/to/package
```

Integration tests against the fixtures in `Tests/Fixtures` (slow):

```bash
STE_INTEGRATION=1 swift test --filter IntegrationTests
```

If the toolchain installed through swiftly (or similar) does not match Xcode's `Testing.framework`, point the tool at Xcode's toolchain with `--swift /usr/bin/swift` (`STE_SWIFT=/usr/bin/swift` for the integration tests).
