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

1. **Low cost.** One to three mutants per method, so with `--since` it fits into per-pull-request CI.
2. **Hard-to-dispute output.** "No test fails when this method's body is removed" is a binary fact that needs no interpretation.
3. **Few equivalent mutants.** Deciding whether a mutant behaves like the original is undecidable (Budd & Angluin 1982), but a mutant that replaces the whole body with a default value is equivalent essentially only when the method itself returns a trivial value.

Traditional, operator-level mutation fills the same column at a finer grain and a higher cost (see [Concepts](../concepts.md#mutation-analysis)). It is a separate method, not a replacement: extreme mutation finds the obvious holes cheaply, and finer methods can then focus on what it reports as `tested`.

## Results

The method runs only on methods that the executed column reports as executed (or on every method when that column is unavailable). It uses Descartes' definitions unchanged, so results are comparable with the literature.

| Result | Condition | Meaning in PIE |
|---|---|---|
| `pseudo-tested` | every mutant survived | E holds, I + P fail |
| `partially-tested` | some mutants survived | only part of the behaviour is verified |
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
| `[T]` / `Array` / `Set` / `ContiguousArray` | `return []` |
| `[K: V]` / `Dictionary` | `return [:]` |
| `Data` | `return Data()` |
| `some View` inside a result builder (`var body`, `@ViewBuilder`) | `EmptyView()` |
| untyped `throws` (only with `--throw-mutants`) | `throw`, in addition to the above |
| `async` | unchanged (the rules above apply as-is) |

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
| `some View` returned outside a result builder | an opaque type needs the same concrete type on every branch |
| result builders other than `View` | unknown which constructs the builder supports |
| tuples, `Result`, generic type parameters, user-defined types, … | no general default value |

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
- Methods with unsupported return types cannot be analysed (see [Not targeted](#not-targeted)).

## Implementation

All mutants are compiled into a single binary and selected at runtime (mutant schemata). See [ARCHITECTURE.md](../../ARCHITECTURE.md#mutant-schemata).

## References

- Niedermayr, Juergens, Wagner (2016). Will My Tests Tell Me If I Break This Code? *CSED@ICSE*.
- Vera-Pérez, Monperrus, Baudry (2018). Descartes: A PITest Engine to Detect Pseudo-Tested Methods. *ASE*.
- Vera-Pérez, Danglot, Monperrus, Baudry (2019). A Comprehensive Study of Pseudo-tested Methods. *Empirical Software Engineering*.
- Petrović, Ivanković (2018). State of Mutation Testing at Google. *ICSE-SEIP*.
- Budd, Angluin (1982). Two Notions of Correctness and Their Relation to Testing. *Acta Informatica*.
