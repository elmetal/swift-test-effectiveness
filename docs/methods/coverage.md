# Coverage

English | [日本語](../ja/methods/coverage.md)

Fills the **executed** column (see [Concepts](../concepts.md)): did any test run this method at all?

## What it does

The tool does not measure coverage itself. It reads the `llvm-cov export` JSON that `swift test --enable-code-coverage` produces, and matches each function in it to a discovered method by the position of the method body's opening `{`.

The result is used in two ways:

1. Methods that no test executes are reported as `not-covered` (PIE step E fails). This is a different problem from `pseudo-tested` and needs a different fix: write a test, rather than add an assertion.
2. Unexecuted methods are excluded from the more expensive methods that fill the verified column. A fault in code that never runs cannot be detected, so checking would only cost time.

## When coverage is unavailable

| Situation | Behaviour |
|---|---|
| `--no-coverage` | coverage is not collected |
| custom mode (`--build-command` / `--test-command`) | coverage is not collected |
| coverage data cannot be read or parsed | a message is logged and coverage is treated as unavailable |
| a method has no matching function in the data | that method is treated as unknown |

In all of these cases the executed column is unknown, and the verified methods run on every affected method. A method that no test executes then fails verification instead of being reported as `not-covered` (extreme mutation, for example, reports it as `pseudo-tested`). The report says whether coverage was available.

## Limits

- Coverage counts *incidental* execution as executed. A method reached only through deep calls in an integration-style test is `executed` even though no test is responsible for it; the `referenced` column is meant to show this (see [Concepts](../concepts.md#four-meanings-of-a-missing-test)).
- Conditional compilation, platform branches and asynchronous timing can make coverage vary between runs.
