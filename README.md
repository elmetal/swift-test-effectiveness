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

## Requirements

- macOS 26 or later
- Swift 6.2 or later (Xcode 26 or later). Tested with Swift 6.4 (Xcode 27).
- A Swift toolchain that matches the selected Xcode's macOS SDK. A swift.org or swiftly toolchain older than that SDK cannot compile package manifests: `swift build` fails with `unknown argument: '-target-arch-variant'` and a compiler crash. Use Xcode's toolchain instead (`xcrun swift`, or `/usr/bin/swift` when `xcode-select` points at Xcode).

The `swift` that runs the analysis (`--swift`) also builds and tests the target project, and its `libIndexStore.dylib` reads the index, so the same applies to it.

## Usage

### Swift packages

```bash
swift run swift-test-effectiveness /path/to/package
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
| `--format text\|markdown\|json` | Report format (markdown is meant for PR comments) |
| `-o, --output <file>` | Write the report to a file |
| `--fail-on-pseudo-tested` | Exit with status 1 if any method is pseudo-tested |

Options for a specific method:

| Option | Method | Description |
|---|---|---|
| `--no-index` | static references | Do not write or read the compiler's index; the referenced column is unknown |
| `--index-store-path <path>` | static references | Index store to read (default for packages: the one the build writes; needed in custom mode) |
| `--no-coverage` | coverage | Do not collect coverage; run the later methods on every declaration |
| `--throw-mutants` | extreme mutation | Add a `throw` mutant for methods declared with untyped `throws` |
| `--timeout-factor`, `--minimum-timeout` | extreme mutation | Timeout for each mutant's test run (baseline duration × factor, with a minimum in seconds) |

Exit status: `0` success, `1` pseudo-tested methods found with `--fail-on-pseudo-tested`, `2` analysis error (build failure, failing baseline, …).

### Xcode and other projects (custom mode)

Pass `--source-dir`, `--build-command` and `--test-command` to use any build system. Commands run with `/bin/sh -c` inside the copied project.

```bash
swift run swift-test-effectiveness /path/to/App \
  --source-dir App \
  --build-command "xcodebuild build-for-testing -scheme App -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'" \
  --test-command  "xcodebuild test-without-building -scheme App -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'"
```

The test command is run once per mutant, with the active mutant exported as both `STE_MUTANT` and `TEST_RUNNER_STE_MUTANT` (`xcodebuild test` forwards `TEST_RUNNER_`-prefixed variables to the test process).

Custom mode does not collect coverage, so methods that no test executes are reported as `pseudo-tested` rather than `not-covered`. For the referenced column, pass the index store your build writes with `--index-store-path` (see [Static test references](docs/methods/static-references.md#when-the-index-is-unavailable)).

### In CI

```bash
swift run swift-test-effectiveness . --since origin/main --format markdown -o effectiveness.md
```

Posting the generated Markdown as a PR comment shows, for the changed declarations only, what the tests are missing and how to fix it.

### Known limitations

- The project is analysed in a copy, so local path dependencies (`.package(path: "../Foo")`) do not resolve.
- `swift test` locks `.build`, so the test runs (one per mutant) cannot run in parallel.

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
```

Integration tests against the fixtures in `Tests/Fixtures` (slow):

```bash
STE_INTEGRATION=1 swift test --filter IntegrationTests
```

If the toolchain installed through swiftly (or similar) does not match Xcode's `Testing.framework`, point the tool at Xcode's toolchain with `--swift /usr/bin/swift` (`STE_SWIFT=/usr/bin/swift` for the integration tests).
