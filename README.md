# swift-test-effectiveness

English | [日本語](README.ja.md)

A tool that checks whether the tests of a Swift project actually *verify* the code they *execute*, and gives per-method feedback.

It replaces the body of each method with the simplest possible behaviour for its return type (an empty body, `nil`, `true`/`false`, `0`/`1`, `""`, `[]`, …). A method for which every such replacement still passes the whole test suite is reported as **pseudo-tested**: tests run it, but nothing checks what it does.

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

This README is organised in three parts: the theory of why the approach works, the method this tool implements, and the evidence for it (and its limits). To get started right away, jump to [Usage](#usage).

---

## 1. Theory: mutation analysis and the PIE model

### Mutation analysis

The foundation is mutation analysis (DeMillo, Lipton & Sayward 1978, *Hints on Test Data Selection*): introduce small artificial faults (*mutants*) and check whether the tests detect (*kill*) them. Its validity rests on two hypotheses:

- **Competent programmer hypothesis** — real faults are small deviations from a correct program.
- **Coupling effect** — tests that detect simple mutants also detect more complex faults.

### The PIE model: why coverage is not enough

Voas's PIE model (1992) splits the conditions for a test to reveal a fault into three steps:

| Step | Meaning |
|---|---|
| **E**xecution | the faulty location is executed |
| **I**nfection | the program state becomes corrupted |
| **P**ropagation | the corruption reaches an assertion and the test fails |

**Coverage measures only E; mutation analysis measures E + I + P.** That one sentence is the reason this tool exists. A test that never asserts on a return value reaches 100% coverage while satisfying only E, and detects nothing.

The tool uses both. Methods that fail E (no test executes them) are reported as `not-covered`; mutants are run only for methods that pass E, to check I + P. A `pseudo-tested` method is one that satisfies E but not I + P — a missing oracle that coverage cannot see.

## 2. Method: extreme mutation (pseudo-tested methods)

Instead of traditional mutation operators (swapping `+` for `-`, etc.), this tool is built around **extreme mutation**:

- Niedermayr, Juergens & Wagner (2016), *Will My Tests Tell Me If I Break This Code?* — replace the whole method body with an empty body or a default return value; methods whose tests still pass are *pseudo-tested*.
- Vera-Pérez, Monperrus & Baudry (2018), *Descartes: A PITest Engine to Detect Pseudo-Tested Methods* — tool support for Java (PIT).
- Vera-Pérez et al. (2019), *A Comprehensive Study of Pseudo-tested Methods* (EMSE) — across 21 open-source projects, pseudo-tested methods exist even in mature projects, and developers considered a substantial share of them worth fixing.

Three reasons for choosing extreme mutation:

1. **Low cost.** One to three mutants per method, so with `--since` it fits into per-pull-request CI.
2. **Hard-to-dispute output.** "No test fails when this method's body is removed" is a binary fact that needs no interpretation.
3. **Few equivalent mutants.** Deciding whether a mutant behaves like the original is undecidable (Budd & Angluin 1982), but a mutant that replaces the whole body with a default value is equivalent essentially only when the method itself returns a trivial value.

Traditional, operator-level mutation testing is left to existing tools such as swift-mutation-testing and is out of scope here.

### Classification

The tool uses Descartes' definitions unchanged, so results are comparable with the literature.

| Classification | Condition | Meaning in PIE |
|---|---|---|
| `not-covered` | no test executes the method (mutants are not run) | E fails |
| `pseudo-tested` | every mutant survived | E holds, I + P fail |
| `partially-tested` | some mutants survived | only part of the behaviour is verified |
| `tested` | every mutant was detected | — |

As in PIT/Descartes, a mutant that times out counts as detected.

## 3. Evidence, and limits

### Evidence

- **Just et al. (2014, FSE)**, *Are Mutants a Valid Substitute for Real Faults in Software Testing?* — mutant detection is statistically correlated with real fault detection.
- **Inozemtseva & Holmes (2014, ICSE)**, *Coverage Is Not Strongly Correlated with Test Suite Effectiveness* — once test-suite size is controlled for, coverage barely correlates with effectiveness. This is the basis for "coverage is not enough".

### Limits, and the design decision they lead to: no score

**Papadakis et al. (2018, ICSE)**, *Are Mutation Scores Correlated with Real Fault Detection?* showed that when test-suite size is controlled for, the correlation between mutation score and real fault detection weakens as well.

In response, this tool **never outputs an aggregate score** (mutation score, percentage). Its primary output is a per-method classification plus concrete feedback for every surviving mutant.

The other reason is Goodhart's law. When a score becomes the target, people and AI agents alike optimise the score itself (for example by padding assertions). Feedback such as "`isPositive(_:)` can always return `true` without any test failing; add a case where it must return `false`" can only be satisfied by improving the tests.

Other limits:

- Extreme mutation checks whether a method is verified *at all*, not whether it is verified *well*. `tested` is not a quality guarantee; it means there is no obvious hole. Use traditional mutation testing for finer-grained checks.
- Methods with unsupported return types cannot be analysed. They are listed under *Not analyzed* in the report, with the reason.

---

## Usage

### Swift packages

```bash
swift run swift-test-effectiveness /path/to/package
```

What happens:

1. Non-test targets are listed with `swift package describe`, and their methods are discovered.
2. The project is copied to `<package>/.build/test-effectiveness/project` and rewritten into a *mutant schema* that contains every mutant.
3. It is built **once** with `swift build --build-tests --enable-code-coverage`.
4. The tests run without mutations (baseline). If they fail, the analysis stops. Coverage is collected.
5. For every mutant of an executed method, `STE_MUTANT=<id> swift test --skip-build` is run.
6. Methods are classified and the report is printed.

Your original sources are never modified.

### Options

| Option | Description |
|---|---|
| `--since <rev>` | Only analyse methods whose declaration overlaps lines changed since `<rev>` (for pull requests) |
| `--target <name>` | Only analyse this target (repeatable) |
| `--test-filter <pattern>` | Passed to `swift test --filter` |
| `--exclude <substring>` | Skip files whose path contains this string (repeatable) |
| `--throw-mutants` | Add a `throw` mutant for methods declared with untyped `throws` |
| `--no-coverage` | Do not use coverage; run every mutant |
| `--format text\|markdown\|json` | Report format (markdown is meant for PR comments) |
| `-o, --output <file>` | Write the report to a file |
| `--dry-run` | Only list methods and their mutants |
| `--fail-on-pseudo-tested` | Exit with status 1 if any method is pseudo-tested |
| `--swift <path>` | The `swift` executable to use |
| `--timeout-factor`, `--minimum-timeout` | Per-mutant timeout (baseline duration × factor, with a minimum in seconds) |

Exit status: `0` success, `1` pseudo-tested methods found with `--fail-on-pseudo-tested`, `2` analysis error (build failure, failing baseline, …).

### Xcode and other projects (custom mode)

Pass `--source-dir`, `--build-command` and `--test-command` to use any build system. Commands run with `/bin/sh -c` inside the copied project. The active mutant is exported as both `STE_MUTANT` and `TEST_RUNNER_STE_MUTANT` (`xcodebuild test` forwards `TEST_RUNNER_`-prefixed variables to the test process).

```bash
swift run swift-test-effectiveness /path/to/App \
  --source-dir App \
  --build-command "xcodebuild build-for-testing -scheme App -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'" \
  --test-command  "xcodebuild test-without-building -scheme App -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.2'"
```

Custom mode does not use coverage, so methods that no test executes are reported as `pseudo-tested`.

### In CI

```bash
swift run swift-test-effectiveness . --since origin/main --format markdown -o effectiveness.md
```

Posting the generated Markdown as a PR comment shows only the changed methods that are not verified, each with how to fix it.

---

## Applying it to Swift: design decisions

### Default values (mutation operators)

| Return type | Mutants |
|---|---|
| none / `Void` / `()` | empty body (`return`) |
| `T?` / `T!` / `Optional<T>` | `return nil` |
| `Bool` | `return true` and `return false` (both, as in Descartes) |
| integer and floating-point types (`Int`, `UInt8`, `Double`, `CGFloat`, `Decimal`, …) | `return 0` and `return 1` |
| `String` / `Substring` | `return ""` and `return "A"` |
| `[T]` / `Array` / `Set` / `ContiguousArray` | `return []` |
| `[K: V]` / `Dictionary` | `return [:]` |
| `Data` | `return Data()` |
| `some View` inside a result builder (`var body`, `@ViewBuilder`) | `EmptyView()` |
| untyped `throws` (only with `--throw-mutants`) | `throw`, in addition to the above |
| `async` | unchanged (the rules above apply as-is) |

### Not targeted

| Declaration | Reason |
|---|---|
| `init` / `deinit` / `subscript` | no meaningful "default behaviour" to substitute |
| methods returning `Never` | same |
| accessors other than `get` (`set`, `willSet`, `didSet`, `_modify`) | same |
| protocol requirements (no body) | nothing to replace; default implementations in protocol extensions *are* targeted |
| local functions and closures | outside per-method classification |
| `@inlinable` / `@_transparent` / `@_alwaysEmitIntoClient` | their bodies cannot reference the `fileprivate` mutant switch |
| declarations in `main.swift` | top-level code initialisation order |
| `some View` returned outside a result builder | an opaque type needs the same concrete type on every branch |
| result builders other than `View` | unknown which constructs the builder supports |
| tuples, `Result`, generic type parameters, user-defined types, … | no general default value |

Methods that are not targeted are not silently dropped: the report lists them under *Not analyzed* with the reason.

### Mutant schemata

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

- All insertions are made within existing lines, so **line numbers match the original source**. Coverage (llvm-cov function regions start at the body's `{`) maps directly onto the original methods, and compiler diagnostics point at the same lines as the original.
- Single-expression bodies (implicit `return`) get an explicit `return`. The same applies to `if`/`switch` expressions, unless they contain `return` statements, in which case they are statements.
- The switch variable is generated at the end of each file as a `nonisolated fileprivate let` read with `getenv`. Because it is per-file, no build settings or project files need changing, and it works in modules using `defaultIsolation(MainActor.self)`.

## Related work and possible extensions

- **Checked coverage** (Schuler & Zeller 2011) — slices backwards from assertions to count only statements that influence an assertion. It measures oracle quality directly, but dynamic slicing is not practical for Swift, so it is not implemented.
- **Oracle gap** — the difference between coverage and mutation detection. In this tool, covered methods that are `pseudo-tested` are exactly that gap; the *Pseudo-tested* section of the report is the list.

## Development

```bash
swift test
```

Integration tests against the fixtures (slow):

```bash
STE_INTEGRATION=1 swift test --filter IntegrationTests
```

- `Tests/Fixtures/SampleProject` — a small package in which every classification appears at least once. The integration test checks the classification of each method.
- `Tests/Fixtures/EdgeCases` — constructs that must still compile after rewriting: `if`/`switch` expressions, result builders, `throws`, actors, `defaultIsolation(MainActor)`, and more.

If the toolchain installed through swiftly (or similar) does not match Xcode's `Testing.framework`, point the tool at Xcode's toolchain with `--swift /usr/bin/swift` (`STE_SWIFT=/usr/bin/swift` for the integration tests).

### Known limitations

- The project is analysed in a copy, so local path dependencies (`.package(path: "../Foo")`) do not resolve.
- `swift test` locks `.build`, so mutants run one at a time.
