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

### A body that only returns a value

A mutant that returns what the body returns already is the body as it is: no test could detect it, and the method would be reported as `pseudo-tested` whatever its tests assert. Such a mutant is left out.

| Body | Mutants |
|---|---|
| `var isEnabled: Bool { true }` | `return false` only |
| `func retries() -> Int { return 0 }` | `return 1` only |
| `var delegate: Delegate? { nil }`, `func items() -> [Item] { [] }` | none: the method is listed under *Not analyzed* |
| `func total() -> Money { .zero }` with `--default-value 'Money=.zero'` | none, likewise |
| `func load() throws -> Item? { nil }` with `--throw-mutants` | `throw` only |
| `func reset() {}`, a body of comments only, `{ return }` | none, likewise |
| `func prepare() throws {}` with `--throw-mutants` | `throw` only |

The body has to be one `return` or one expression, and the value a literal of the table above or the expression given with `--default-value` (compared as code: spacing and comments make no difference), as for [a case of a switch](#mutants-per-case). Anything else keeps its mutants: a body that does something before it returns, and another spelling of the value (`Optional.none`, `Money.zero` for `.zero`).

The empty-body mutant is the body as it is where a body does nothing: it has no statement, or only `return` without a value.

### Values for other return types

The rules above cover the standard library. A type of the project or of a library often has a simplest value as well (`.zero`, `.empty`, `.none`), but only the project knows it. `--default-value` names it:

```sh
swift-test-effectiveness --default-value 'Money=.zero' --default-value 'Tint=.gray'
```

A method that returns `Money` then gets the mutant `return .zero`. With `--case-mutants`, so does each case of its switch, instead of doing what another case does.

Which types to name is in the report: after the methods it lists under *Not analyzed*, it names the return types without a simplest value, the ones most methods return first. `--dry-run` prints the same line without building anything.

```
Not analyzed (2)
  Sources/Switches/Switches.swift:106  LoadState.tint — unsupported return type `Tint`
  Sources/Switches/Switches.swift:117  LoadState.severity(threshold:) — unsupported return type `Severity`
  → To analyze the methods that return a type without a simplest value, give the type one with `--default-value TYPE=EXPRESSION`: `Severity` (1 method) and `Tint` (1 method).
```

A type is named as `--default-value` takes it: without its generic arguments (`Box` for `Box<Int>`). The line is a list of candidates, not of types that have such a value: a generic type parameter (`T`) is in it as well, and has none. A method around a closure that `--closure` [names](#closures) is not counted: its logic is analysed as the closure.

- The expression is written into every method that returns the type, so it has to compile in all of them: a leading dot (`.zero`) or an initializer (`Money(cents: 0)`) rather than a local name.
- Return types are compared as they are written, because the tool does not resolve types. `Money=…` matches `Money`, `Shop.Money` and `Money<Yen>`. `Shop.Money=…` and `Money<Yen>=…` are more specific, and win over `Money=…`. The whole type can be named as well (`'Result<Int, Error>=.success(0)'`, `'(Int, Int)=(0, 0)'`). A type alias is another name and needs a value of its own. `Money?` and `[Money]` keep the rules of the table.
- Several values for one type are a mutant each, like `true` and `false`.
- A value for a type of the table replaces its mutants.
- `some` types and result builders take no value: every `return` of a `some` type has the same concrete type.

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
| returns the literal a mutant returns (`case .none: return nil`, `case .a: true`), or the expression given with `--default-value` (compared as code: spacing and comments make no difference) | that mutant is left out (`true` still gets `return false`) |
| in a `Void` method, does nothing (`break`, a bare `return`) or only logs ([arid](#arid-bodies)) | none |
| only calls `fatalError()` or `preconditionFailure()` | none |
| throws, with `--throw-mutants` | no `throw` mutant |

### Return types without a simplest value

A method returning an enum, a type of the project or any other type without a general default value has no mutant of its own (see [Not targeted](#not-targeted)), unless `--default-value` [gives its type a value](#values-for-other-return-types). With `--case-mutants`, such a method is analysed through its cases alone, and each case does what another case does instead:

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

## Closures

Off by default; `--closure` names the calls whose closures are analysed.

Some logic is not written as methods. A handler that is passed to the type that calls it for every event is a closure, and the method it is written in only makes it:

```swift
var handler: Handler<State, Event> {
    Handler { state, event in
        switch event {
        case .received:
            state.unread += 1
            return .none
        case .opened:
            state.unread = 0
            return .save
        case .muted:
            state.isMuted = true
            return .save
        }
    }
}
```

`handler` returns a `Handler`, which has no simplest value, and a closure is not a method: nothing of this is analysed. `--closure` names the call and the type its closure returns:

```sh
swift-test-effectiveness --closure 'Handler=Command' --default-value 'Command=.none' --case-mutants
```

The trailing closure of every call to `Handler` is then a method of its own. It is reported under the name of the method it is written in and the name of the call, gets the mutants of the type given for it, and with `--case-mutants` each case of the switch it ends with is mutated as well:

```
Partially tested (1)
  Sources/Closures/Closures.swift:42  Inbox.handler, Handler { } -> Command
    detected: `return .none`
    → In `case .opened` (line 47), `Inbox.handler, Handler { }` can `return .none` without any test failing. Add a test of this case that asserts the result.
    → No test runs `case .muted` (line 50) of `Inbox.handler, Handler { }`. Add a test of this case.
```

- **The type.** A closure does not say what it returns, so the option does. The type follows the rules of every return type: the [table](#mutants-per-return-type), `Void` for a closure that returns nothing (`--closure 'subscribe=Void'`), and the values of `--default-value`. A closure that writes its return type (`{ item -> Bool in … }`) is taken at its word. An opaque type cannot be named.
- **The name.** Calls are compared as they are written, because the tool does not resolve names: by the last components of what is called. `subscribe` matches `subscribe { }`, `store.subscribe { }` and `.subscribe { }`; `store.subscribe` matches only calls that end with both. Generic arguments are not part of the name (`Handler<State, Event> { }` is `Handler`), and `.init { }` is `init`. When several names match a call, the one with the most components gives the type.
- **Several in one body.** Closures of one name in the same body are numbered in the order they are written: `Recorder.record(_:), subscribe { } #1`, `Recorder.record(_:), subscribe { } #2`. A closure inside another counts for the body of the method. The only closure of its name has no number.
- **Which closures.** The trailing closure of the call (the first one, when there are several), in the body of a function or a computed property that the tool finds. A closure inside another is found as well. Closures elsewhere (the initial value of a stored property, an initializer, top-level code) are not.
- **A closure that only returns the value** (`{ _, _ in .none }` with `--default-value 'Command=.none'`) or does nothing (`{ _ in }`) has no mutant a test could detect, [like such a method](#a-body-that-only-returns-a-value), and is listed under *Not analyzed*.
- **The method around it** is analysed as before. Where it only makes the closure, it stays under *Not analyzed* for its return type; the line that names types for `--default-value` leaves it out.
- **Executed and referenced.** Whether tests execute the closure is found out for the closure itself. The [referenced](static-references.md) column is `unknown`: no test can refer to a closure, and the index has no symbol for one.

### Limits of closures

- The mutants are statements at the start of the closure, so a closure of one expression becomes one of several statements. Its type then has to be known from the call, not from its body, and a closure that a result builder transforms (`VStack { … }`) must not be named. If the schema does not build, the analysis stops: run without that name.
- Every call with the name is taken, whatever it calls: a name that two functions share needs more components, or cannot be used.

## What a body returns

Off by default; enable with `--return-mutants`.

An extreme mutant leaves a body at its start, so what the body does goes with what it returns. A test that asserts either detects the mutant:

```swift
mutating func withdraw(_ amount: Int) -> Bool {
    if amount > balance { return false }
    balance -= amount
    return true
}
```

A test that only asserts `balance` detects both `return true` and `return false`, and the method is `tested`, although nothing checks what it returns. With `--return-mutants`, a body that does something before it returns gets one more mutant for each value of its return type: the statements stay, and every `return` gives the value instead of its own.

```
Sources/Closures/Closures.swift:201  Outbox.send(_:in:) -> Bool
    survived: `return true` after its statements, `return false` after its statements
    detected: `return true`, `return false`
    → `Outbox.send(_:in:)` can do what it does and then return `false` without any test failing: tests check what it changes, not what it returns. Assert the value it returns.
```

A body gets such a mutant only where it would differ from the mutant that leaves at the start:

| Body | Mutant |
|---|---|
| does something and returns something else than the value (`balance -= amount; return true`) | yes: `return false` after its statements |
| every `return` gives the value already (`count += 1; return .none`) | none: nothing would change |
| only computes what it returns (`guard x > 0 else { return nil }; return x`, `let y = x * 2; return y`) | none: leaving at the start does the same |
| is one expression | none, likewise |
| returns nothing, or a type without a simplest value | none: there is no value to return |

- **What counts as doing something** is a statement that is an expression: an assignment or a call, also inside an `if`, a `guard`, a loop or a `defer`. A declaration alone does not count (`let id = next()`), and neither does a call that only logs ([arid](#arid-bodies)). What a closure or a local function in the body does and returns is its own.
- **The value** is the one the mutants of the return type return: a row of the [table](#mutants-per-return-type) or the expression given with `--default-value`. `Bool`, numbers and strings have two, and get a mutant for each. A `return` that gives the value already is left as it is.
- **The expression of a `return` is not evaluated** in the mutant: in `return save()`, `save()` is not called.
- **With `--case-mutants`**, a method that ends with a switch gets these mutants case by case, not for its whole body: each case that does something before it returns. A case of a switch expression is one expression, and gets none.

  ```
  Sources/Closures/Closures.swift:183  Outbox.handler, Handler { } -> Command
      detected: `return .none`
      → In `case .opened` (line 188), `Outbox.handler, Handler { }` can `return .none` after the statements of the case without any test failing: tests check what the case changes, not what it returns. Assert the result.
  ```

- **Results.** The mutants are mutants of the method, or of the case, like the others: one that survives makes the method `partially-tested`. Where the mutant that leaves at the start survived with the same value, the report says only that.

### Limits of return mutants

- Every body or case that qualifies costs one more run for each value, also where the mutant that leaves at the start survives and this one says nothing more.
- Whether a body does something is decided on the syntax. A side effect in a declaration (`let id = generator.next()`) or in a condition (`if queue.removeFirst() == x`) is not seen, and such a body gets no mutant.
- With `--case-mutants`, a `return` in front of the switch (`guard isEnabled else { return .none }`) belongs to no case and is not replaced.
- Methods returning `some View` and result builders get none.

## Not targeted

| Declaration | Reason |
|---|---|
| `init` / `deinit` / `subscript` | no meaningful "default behaviour" to substitute |
| methods returning `Never` | same |
| accessors other than `get` (`set`, `willSet`, `didSet`, `_modify`) | same |
| protocol requirements (no body) | nothing to replace; default implementations in protocol extensions *are* targeted |
| local functions and closures | outside per-method classification. `--closure` makes the closures of the calls it names [methods of their own](#closures) |
| `@inlinable` / `@_transparent` / `@_alwaysEmitIntoClient` | the mutant switch cannot be reached from their bodies ([details](../../ARCHITECTURE.md#mutant-schemata)) |
| declarations in `main.swift` | top-level code initialisation order |
| methods whose body does nothing (`{}`), or only returns the value of their only mutant (`{ nil }`, `{ [] }`) | the mutant would be the body as it is: no test could detect it ([details](#a-body-that-only-returns-a-value)) |
| methods returning `Void` whose body only logs (unless `--no-arid`) | no test should assert on a log message ([arid bodies](#arid-bodies)) |
| `some View` returned from a `rethrows` function | the local function that keeps the original body cannot be `rethrows` ([details](../../ARCHITECTURE.md#mutant-schemata)) |
| an expression next to `#if` blocks that may all be compiled out | whether it is returned implicitly depends on the build configuration ([details](../../ARCHITECTURE.md#mutant-schemata)) |
| result builders other than `View` | unknown which constructs the builder supports |
| tuples, `Result`, generic type parameters, user-defined types, opaque types other than `some View`, … | no general default value. `--default-value` [gives a type one](#values-for-other-return-types), except an opaque type. With `--case-mutants`, a method that ends with a switch is analysed [case by case](#return-types-without-a-simplest-value) |

Methods that are not targeted are not silently dropped: the report lists them under *Not analyzed* with the reason. For the return types without a default value, it also says [which types to give one](#values-for-other-return-types).

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
- Methods with unsupported return types cannot be analysed (see [Not targeted](#not-targeted)), except with a value from `--default-value`, or case by case when they end with a switch (see [Cases of a switch](#cases-of-a-switch)).
- Logic written as closures is not analysed, except the closures of the calls `--closure` names (see [Closures](#closures)).
- A test of what a method changes detects every mutant of its whole body, whatever the method returns. Without `--return-mutants`, such a method is `tested` although no test checks its result (see [What a body returns](#what-a-body-returns)).
- One test of one case of a switch detects every mutant of the whole body. Without `--case-mutants`, such a method is `tested` however few of its cases the tests check.

## Implementation

All mutants are compiled into a single binary and selected at runtime (mutant schemata). Each mutant runs against the tests that execute its method, which the tool records by running each test scope on its own; a mutant that survives them is run against the whole suite only when those tests may not be every test that executes the method ([test selection](../../README.md#test-selection)). See [ARCHITECTURE.md](../../ARCHITECTURE.md#mutant-schemata).

## References

- Niedermayr, Juergens, Wagner (2016). Will My Tests Tell Me If I Break This Code? *CSED@ICSE*.
- Vera-Pérez, Monperrus, Baudry (2018). Descartes: A PITest Engine to Detect Pseudo-Tested Methods. *ASE*.
- Vera-Pérez, Danglot, Monperrus, Baudry (2019). A Comprehensive Study of Pseudo-tested Methods. *Empirical Software Engineering*.
- Petrović, Ivanković (2018). State of Mutation Testing at Google. *ICSE-SEIP*.
- Budd, Angluin (1982). Two Notions of Correctness and Their Relation to Testing. *Acta Informatica*.
