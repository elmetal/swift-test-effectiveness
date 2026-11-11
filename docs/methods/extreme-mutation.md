# Extreme mutation

English | [日本語](../ja/methods/extreme-mutation.md)

Fills the **verified** column (see [Concepts](../concepts.md)): for each executed method, does any test notice when its body is replaced with the simplest possible behaviour?

## What it does

Instead of traditional mutation operators (swapping `+` for `-`, etc.), each method body is replaced as a whole with the simplest behaviour for its return type: an empty body, `nil`, `true`/`false`, `0`/`1`, `""`, `[]`, and so on. A method for which every such replacement still passes the whole test suite is **pseudo-tested**: tests run it, but nothing checks what it does.

## Background

- Niedermayr, Juergens & Wagner (2016), *Will My Tests Tell Me If I Break This Code?*: replace the whole method body with an empty body or a default return value; methods whose tests still pass are *pseudo-tested*.
- Vera-Pérez, Monperrus & Baudry (2018), *Descartes: A PITest Engine to Detect Pseudo-Tested Methods*: tool support for Java (PIT).
- Vera-Pérez et al. (2019), *A Comprehensive Study of Pseudo-tested Methods* (EMSE): across 21 open-source projects, pseudo-tested methods exist even in mature projects, and developers considered a substantial share of them worth fixing.

## Why extreme mutation

1. **Low cost.** One to three mutants per method (and per case of a switch, with `--case-mutants`), so with `--since` it fits into per-pull-request CI.
2. **Hard-to-dispute output.** "No test fails when this method's body is removed" is a binary fact that needs no interpretation.
3. **Few equivalent mutants.** Deciding whether a mutant behaves like the original is undecidable (Budd & Angluin 1982), but a mutant that replaces the whole body with a default value is equivalent essentially only when the method itself returns a trivial value.

Traditional, operator-level mutation fills the same column at a finer grain and a higher cost (see [Concepts](../concepts.md#mutation-analysis)). It is a separate method, not a replacement: extreme mutation finds the obvious holes cheaply, and finer methods can then focus on what it reports as `tested`.

## Results

The method runs only on methods that the executed column reports as executed (or on every method when that column is unavailable). It uses Descartes' definitions unchanged, so results are comparable with the literature.

| Result | Condition | Meaning in PIE |
|---|---|---|
| `pseudo-tested` | every mutant survived | E holds, I + P fail |
| `partially-tested` | some mutants survived, or with `--case-mutants` a [case of its switch](#cases-of-a-switch) is not verified | only part of the behaviour is verified |
| `tested` | every mutant was detected | no obvious hole |

As in PIT/Descartes, a mutant that times out counts as detected.

## Mutants per return type

| Return type | Mutants |
|---|---|
| none / `Void` / `()` | empty body (`return`) |
| `T?` / `T!` / `Optional<T>` | `return nil` |
| `Bool` | `return true` and `return false` (both, as in Descartes) |
| integer and floating-point types (`Int`, `UInt8`, `Double`, `CGFloat`, `Decimal`, …) | `return 0` and `return 1` |
| `String` / `Substring` | `return ""` and `return "A"` |
| `[T]` / `Array` / `Set` / `ContiguousArray` / `ArraySlice` | `return []` |
| `[K: V]` / `Dictionary` | `return [:]` |
| `Data` | `return Data()` |
| `some View` (`var body`, `@ViewBuilder`, or a function or getter without a result builder) | `EmptyView()` |
| untyped `throws` (only with `--throw-mutants`) | `throw`, in addition to the above |
| `async` | unchanged (the rules above apply as-is) |

## Cases of a switch

Off by default; `--case-mutants` turns it on.

A method whose logic is a switch is verified case by case, but one test of one case detects every mutant of the whole body:

```swift
func title(for state: LoadState) -> String {
    switch state {
    case .idle: "Idle"
    case .loading: "Loading"
    case .failed(let message): "Failed: \(message)"
    }
}
```

A test that asserts the title of `.idle` detects both `return ""` and `return "A"`, so the method is `tested` whatever the other cases return. With `--case-mutants`, each case of the switch a method ends with is mutated as a body of its own: at the start of the case, the method returns the simplest value for its return type, or returns at once for `Void`. The report then names the cases the tests leave out:

```
Sources/App/Presenter.swift:18  Presenter.title(for:) -> String
    detected: `return ""`, `return "A"`
    → No test runs `case .loading` (line 21) of `Presenter.title(for:)`. Add a test of this case.
    → In `case .failed(let message)` (line 22), `Presenter.title(for:)` can `return ""` or `return "A"` without any test failing. Add a test of this case that asserts the result.
```

### Which switches

Only a switch that is the last statement of the body, with at least two cases. Leaving the method at the start of a case is then the same as the case doing nothing; after a switch in the middle of a body, the statements that follow would be skipped as well. A switch expression that the method returns implicitly counts, and so does a switch after other statements (`guard`, …).

Not taken: a switch in a result builder body or in a method returning `some View`, and a switch with `#if` around its cases (which cases exist depends on the build configuration).

### Mutants per case

Each case gets the mutants of the method's return type (see [Mutants per return type](#mutants-per-return-type)), except those that could not be detected:

| Case | Mutants |
|---|---|
| returns the literal a mutant returns (`case .none: return nil`, `case .a: true`) | that mutant is left out (`true` still gets `return false`) |
| in a `Void` method, does nothing (`break`, a bare `return`) or only logs ([arid](#arid-bodies)) | none |
| only calls `fatalError()` or `preconditionFailure()` | none |
| throws, with `--throw-mutants` | no `throw` mutant |

### Return types without a simplest value

A method returning an enum, a type of the project or any other type without a general default value has no mutant of its own (see [Not targeted](#not-targeted)). With `--case-mutants`, such a method is analysed through its cases alone, and each case does what another case does instead:

```swift
var tint: Tint {
    switch self {
    case .idle: .gray       // mutant: does what `case .loading` does
    case .loading: .blue    // mutant: does what `case .loaded` does
    case .loaded: .green    // mutant: does what `case .failed` does
    case .failed: .red      // mutant: does what `case .idle` does
    }
}
```

The other case is the nearest following case, then from the first, that binds no variables (its statements would need them) and does something else:

- the next case is reached with `fallthrough`;
- any other case lends its statements, which then run in this case. They are taken only when every statement fits on one line, none is a `fallthrough` or a `defer`, and they use no name that a variable of this case would hide. In a switch expression nothing can fall through, so the next case lends its expression in the same way.

A case that only calls `fatalError()` is never the other case: the mutant would only crash. A case for which no other case qualifies gets no mutant, and a method none of whose cases gets one stays *Not analyzed*. So does a method returning an opaque type (`some ToolbarContent`): its body may be a result builder without saying so.

```
Sources/App/LoadState.swift:106  LoadState.tint: Tint
    → In `case .loading` (line 109), `LoadState.tint` can do what `case .loaded` does without any test failing. Add a test of this case that asserts the result.
```

### Results of the cases

The mutants of the cases run after those of the whole bodies, and only for methods of which at least one mutant of the whole body was detected: where every one survived, the method is `pseudo-tested` and the cases would say nothing more. A method without mutants of its own has only its cases, which run unless coverage shows that no test executes the method.

Each mutant runs against the tests that execute its case, which is recorded together with the methods each test scope executes ([test selection](../../README.md#test-selection)). When the scopes are the whole suite, a case that none of them executed is reported as one that no test runs, and its mutants are not run. Otherwise its mutants run against the whole suite, and the case is reported like any other whose mutants survive.

| Method | Cases | Result |
|---|---|---|
| `tested` | every case is run by a test, and no mutant of a case survived | `tested` |
| `tested` | a case is not run by any test, or a mutant of a case survived | `partially-tested` |
| `partially-tested`, `pseudo-tested`, `not-covered` | — | unchanged: the cases never make a method look better |
| no mutants of its own | every mutant that ran survived, or none ran | `pseudo-tested` |
| no mutants of its own | every case is run by a test, and no mutant survived | `tested` |
| no mutants of its own | anything else | `partially-tested` |

In the JSON report a method whose cases ran has `cases`: for each case with mutants its `label`, `line`, `executed` and `mutants`.

### Limits of case mutants

- A case without a mutant is not reported, even when no test runs it.
- The statements of another case are moved as text. The conditions above are checked on the syntax alone; if statements do not compile in their new place, the schema does not build and the analysis stops. Run without `--case-mutants` then, and please report the construct.
- A switch in the middle of a body, in a result builder or in a method returning `some View` is not analysed case by case.

## Not targeted

| Declaration | Reason |
|---|---|
| `init` / `deinit` / `subscript` | no meaningful "default behaviour" to substitute |
| methods returning `Never` | same |
| accessors other than `get` (`set`, `willSet`, `didSet`, `_modify`) | same |
| protocol requirements (no body) | nothing to replace; default implementations in protocol extensions *are* targeted |
| local functions and closures | outside per-method classification |
| `@inlinable` / `@_transparent` / `@_alwaysEmitIntoClient` | the mutant switch cannot be reached from their bodies ([details](../../ARCHITECTURE.md#mutant-schemata)) |
| declarations in `main.swift` | top-level code initialisation order |
| methods returning `Void` whose body only logs (unless `--no-arid`) | no test should assert on a log message ([arid bodies](#arid-bodies)) |
| `some View` returned from a `rethrows` function | the local function that keeps the original body cannot be `rethrows` ([details](../../ARCHITECTURE.md#mutant-schemata)) |
| an expression next to `#if` blocks that may all be compiled out | whether it is returned implicitly depends on the build configuration ([details](../../ARCHITECTURE.md#mutant-schemata)) |
| result builders other than `View` | unknown which constructs the builder supports |
| tuples, `Result`, generic type parameters, user-defined types, opaque types other than `some View`, … | no general default value. With `--case-mutants`, a method that ends with a switch is analysed [case by case](#return-types-without-a-simplest-value) |

Methods that are not targeted are not silently dropped: the report lists them under *Not analyzed* with the reason.

### Arid bodies

The empty-body mutant of `func didTapRetry() { logger.info("retry") }` survives, but the fix the report would ask for, an assertion on a log message, is not one anyone should make. Such feedback teaches people to stop reading the report. Google's mutation testing suppresses mutants in this kind of code as *arid nodes* (Petrović & Ivanković 2018); the tool applies the same idea to whole method bodies.

A body is arid if it has at least one statement and every statement is arid:

- a call to `print`, `debugPrint`, `dump`, `NSLog`, `os_log`, `os_signpost`, `assert` or `assertionFailure`;
- a call to `log`, `trace`, `debug`, `info`, `notice`, `warning`, `error`, `critical` or `fault` on a logger-like receiver: one with a component named `log` or ending in `logger` (`logger`, `self.logger`, `Self.logger`, `Log.network`, `Logger(…)`);
- a call named with `--arid-call` (compared with the called expression, leading `self.` removed);
- a bare `return`;
- an `if`, `guard`, `defer` or `#if` whose statements are all arid, and whose conditions call nothing (a call in a condition may have a side effect).

`try` and `await` are looked through. Only methods returning `Void` are affected: for any other return type the mutants replace the result, which tests should check whatever else the body does.

The check is syntactic, so the receiver's type is not known: `logger.info(…)` counts even if `logger` is not a logger. Arguments are not inspected, so a side effect inside a log message (`print(queue.removeFirst())`) is missed. Analytics calls such as `track(…)` are not arid by default, because some teams do test them; add them with `--arid-call`. To analyse a module whose job is logging, pass `--no-arid`.

## Limits

- Extreme mutation checks whether a method is verified *at all*, not whether it is verified *well*. `tested` is not a quality guarantee; it means there is no obvious hole. Use traditional mutation testing for finer-grained checks.
- Methods with unsupported return types cannot be analysed (see [Not targeted](#not-targeted)), except case by case when they end with a switch (see [Cases of a switch](#cases-of-a-switch)).
- One test of one case of a switch detects every mutant of the whole body. Without `--case-mutants`, such a method is `tested` however few of its cases the tests check.

## Implementation

All mutants are compiled into a single binary and selected at runtime (mutant schemata). Each mutant runs against the tests that execute its method, which the tool records by running each test scope on its own; a mutant that survives them is run against the whole suite only when those tests may not be every test that executes the method ([test selection](../../README.md#test-selection)). See [ARCHITECTURE.md](../../ARCHITECTURE.md#mutant-schemata).

## References

- Niedermayr, Juergens, Wagner (2016). Will My Tests Tell Me If I Break This Code? *CSED@ICSE*.
- Vera-Pérez, Monperrus, Baudry (2018). Descartes: A PITest Engine to Detect Pseudo-Tested Methods. *ASE*.
- Vera-Pérez, Danglot, Monperrus, Baudry (2019). A Comprehensive Study of Pseudo-tested Methods. *Empirical Software Engineering*.
- Petrović, Ivanković (2018). State of Mutation Testing at Google. *ICSE-SEIP*.
- Budd, Angluin (1982). Two Notions of Correctness and Their Relation to Testing. *Acta Informatica*.
