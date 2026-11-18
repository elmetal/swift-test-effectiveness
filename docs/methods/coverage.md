# Coverage

English | [日本語](../ja/methods/coverage.md)

Fills the **executed** column (see [Concepts](../concepts.md)): did any test run this method at all?

## What it does

How the tool finds out which methods the baseline executed depends on the kind of project:

- **Swift package**: the [mutant schema](../../ARCHITECTURE.md#mutant-schemata) records it. Every method that has mutants notes that it ran the first time it is called, and the baseline collects these notes. The build needs no coverage instrumentation, and there is no coverage data to export or read.
- **Custom mode**: the tool does not measure coverage itself. It reads the coverage profile that the baseline's test command writes (`xcodebuild -enableCodeCoverage YES`), exports it with `llvm-cov export`, and matches each function in it to a discovered method by the position of the method body's opening `{`.

The result is used in two ways:

1. Methods that no test executes are reported as `not-covered` (PIE step E fails). This is a different problem from `pseudo-tested` and needs a different fix: write a test, rather than add an assertion.
2. Unexecuted methods are excluded from the more expensive methods that fill the verified column. A fault in code that never runs cannot be detected, so checking would only cost time.

## Output

Each analysed method carries the column as `executed` in the JSON report: `"true"`, `"false"` or `"unknown"`. Coverage fills it, but a killed mutant overrides it with `"true"`: a test observed the method's behaviour change, so the method ran (dynamic evidence wins, see [Concepts](../concepts.md)). A timed-out mutant does not count, since a slow machine can time out too.

As a result, only methods whose mutants all survived can stay `unknown`. In text and Markdown reports such a method gets a note, because its surviving mutants do not say whether it is unverified or not executed at all. When coverage is unavailable for the whole run, the header says so once instead.

## When coverage is unavailable

| Situation | Behaviour |
|---|---|
| `--no-coverage` | coverage is not collected |
| custom mode without `--coverage-profdata` and `--coverage-binary` | coverage is not collected |
| custom mode: the baseline wrote no `.profdata` (no `-enableCodeCoverage YES`), or no binary has coverage data | a message is logged and coverage is treated as unavailable |
| custom mode: coverage data cannot be read or parsed | a message is logged and coverage is treated as unavailable |
| custom mode: a method has no matching function in the data | that method is treated as unknown (but see [Conditional compilation](#conditional-compilation)) |
| Swift package: what the baseline recorded cannot be read | coverage is treated as unavailable |
| Swift package: a method that has only mutants of its cases (`--case-mutants`), none of which ran | that method is treated as unknown: it may have returned before its switch |

In all of these cases the executed column is unknown, and the methods that fill the verified column run on every affected method. A method that no test executes then fails verification instead of being reported as `not-covered` (extreme mutation, for example, reports it as `pseudo-tested`). The report says whether coverage was available.

## Conditional compilation

The tool parses every clause of an `#if`, active or not, because which clause is active is only known to the build (`-D` flags, target platform, available modules). A method declared inside `#if` that was compiled out is reported under *Not analyzed* instead of being mutated. What tells that it was compiled out:

- **Swift package**: the baseline did not execute the method, and the compiler's index has no definition for it; the index has one for every declaration that was compiled. Without the index (`--no-index`) there is no telling, and the method is reported as `not-covered`.
- **Custom mode**: the coverage data has no function for the method; llvm-cov lists every function that was compiled, including ones no test ran.

Without coverage this is not possible, and a method in an inactive `#if` clause is reported as `pseudo-tested` (its mutants cannot be detected because they do not exist in the binary).

## Limits

- Coverage counts *incidental* execution as executed. A method reached only through deep calls in an integration-style test is `executed` even though no test is responsible for it; the `referenced` column is meant to show this (see [Concepts](../concepts.md#four-meanings-of-a-missing-test)).
- Conditional compilation, platform branches and asynchronous timing can make coverage vary between runs.
- Swift package: a method is recorded in the process that runs it, which finds the file to write to in its environment. A method of a target that the tests do not link, such as an executable, is `not-covered` unless the tests start that executable; and a process the tests start with an environment of its own records nothing, so what only it runs is `not-covered` too.
