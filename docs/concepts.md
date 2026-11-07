# Concepts

English | [日本語](ja/concepts.md)

The model behind swift-test-effectiveness, independent of any particular method: what test effectiveness is, what "a missing test" means, how separate methods fit together, and why the tool reports per-declaration findings instead of a score. Each method that fills part of this model has its own document under [methods/](methods/).

## Test effectiveness

*Test effectiveness* is a test suite's ability to detect faults (the term used by Just et al. 2014 and Inozemtseva & Holmes 2014). The tool gives feedback on the effectiveness of a test suite, looked at per declaration: for each declaration, which of the conditions for detecting a fault in it the tests do not meet, and what to do about it.

## The PIE model

Voas's PIE model (1992) splits the conditions for a test to reveal a fault into three steps:

| Step | Meaning |
|---|---|
| **E**xecution | the faulty location is executed |
| **I**nfection | the program state becomes corrupted |
| **P**ropagation | the corruption reaches an assertion and the test fails |

All three are needed, and a measurement tells only about the steps it covers. **Coverage measures only E.** A test that never asserts on a return value reaches 100% coverage while satisfying only E, and detects nothing. This is why the tool does not stop at coverage, and why every method is described by which steps it measures.

## Mutation analysis

The standard way to measure E + I + P together is mutation analysis (DeMillo, Lipton & Sayward 1978, *Hints on Test Data Selection*): introduce small artificial faults (*mutants*) and check whether the tests detect (*kill*) them. Its validity rests on two hypotheses:

- **Competent programmer hypothesis**: real faults are small deviations from a correct program.
- **Coupling effect**: tests that detect simple mutants also detect more complex faults.

Just et al. (2014) found that mutant detection is statistically correlated with real fault detection.

Variants differ in how they mutate. Traditional, operator-level mutation makes many small local changes (`+` to `-`, `<` to `<=`), which is fine-grained but expensive. Extreme mutation replaces whole method bodies, which is coarse but cheap. Both rest on the same hypotheses.

## Four meanings of "a missing test"

"This code is missing a test" can mean four different things, at different granularities:

| # | Meaning | Missing PIE step | Found by | Fix | Scope |
|---|---|---|---|---|---|
| 1 | not executed | E | coverage | write a test | in scope |
| 1' | no test calls it directly (only executed incidentally) | E (intent) | static call graph from tests | write a test about that API | in scope |
| 2 | executed but not verified | I + P | mutation analysis (extreme or traditional) | add an assertion | in scope (the core) |
| 3 | input space not explored | partly | traditional mutation, MC/DC, boundary analysis, property-based testing | add boundary cases | out of scope |
| 4 | specified behaviour not verified | depends on the spec | comparing tests against the specification | write a test for the spec | out of scope for now |

1 and 2 need different fixes (write a test vs. add an assertion), so the output always keeps them apart.

1' is invisible to coverage: a declaration reached only through deep calls in integration-style tests counts as executed, yet no test is responsible for its contract.

3 cannot be pointed out statically as "missing"; traditional mutation (relational operator replacement, for example) catches part of it. 4 needs a specification to compare against.

## Three columns: referenced, executed, verified

The in-scope meanings map to three independent columns per declaration:

| Column | Question | Nature | Methods |
|---|---|---|---|
| referenced | does a test call this declaration directly? | intent, static | call graph from test functions |
| executed | was it run during the tests? | fact, dynamic | [coverage](methods/coverage.md) |
| verified | is a fault in it detected? | fact, dynamic | [extreme mutation](methods/extreme-mutation.md) (coarse), traditional mutation (fine) |

Rules that hold whichever methods fill the columns:

- **Columns are not combined** into one number (see [No score](#no-score)).
- **Dynamic evidence wins over static inference** when they disagree.
- **`verified` is only computed for executed declarations.** If nothing executes a declaration, any fault in it goes undetected, so checking tells nothing new; it already belongs to "not executed".
- **`referenced` means direct references only.** Followed transitively, almost every declaration is reachable and the column would duplicate `executed`.

### Reading the columns together

| referenced | executed | verified | State | Fix |
|---|---|---|---|---|
| ✗ | ✗ | — | no test | write a test |
| ✗ | ✓ | ✗ | executed incidentally, not verified | write a test about that API |
| ✗ | ✓ | ✓ | executed incidentally, but verified | low priority; a direct test is still preferable |
| ✓ | ✓ | ✗ | called but not verified | add an assertion |
| ✓ | ✓ | partly | only part of the behaviour verified | add a check for each outcome |
| ✓ | ✓ | ✓ | tested | nothing |
| ✓ | ✗ | — | referenced but never run (skipped tests, conditional compilation, injected mocks) | check the tests |

### Methods as a funnel

Methods are ordered by cost, like a funnel. A cheaper method narrows down what a more expensive one below it has to run: a static call graph needs no test run, coverage needs one, and mutation needs one run per mutant. Adding a method therefore tends to make the analysis faster, not slower.

Which columns and methods are currently available is listed in the [README](../README.md#documentation).

## No score

The tool **never outputs an aggregate score** (mutation score, percentage). Its primary output is a per-declaration finding plus concrete feedback on what to do next. There are two reasons.

**The evidence does not support a score.** Papadakis et al. (2018, ICSE), *Are Mutation Scores Correlated with Real Fault Detection?*, showed that once test-suite size is controlled for, the correlation between mutation score and real fault detection weakens. Inozemtseva & Holmes (2014) found that coverage, too, is not strongly correlated with effectiveness once size is controlled for.

**Goodhart's law.** When a score becomes the target, people and AI agents alike optimise the score itself (for example by padding assertions). Feedback such as "`isPositive(_:)` can always return `true` without any test failing; add a case where it must return `false`" can only be satisfied by improving the tests.

For the same reason, the columns are not merged: a number that adds points for one method and subtracts for another would hide what each one found.

## Related work

- **Checked coverage** (Schuler & Zeller 2011) slices backwards from assertions to count only statements that influence an assertion. It measures oracle quality directly, but dynamic slicing is not practical for Swift.
- **Oracle gap**: the difference between coverage and mutation detection. In terms of the columns, it is the set of declarations that are executed but not verified.

## References

- DeMillo, Lipton, Sayward (1978). Hints on Test Data Selection: Help for the Practicing Programmer. *IEEE Computer*.
- Voas (1992). PIE: A Dynamic Failure-Based Technique. *IEEE TSE*.
- Just, Jalali, Inozemtseva, Ernst, Holmes, Fraser (2014). Are Mutants a Valid Substitute for Real Faults in Software Testing? *FSE*.
- Inozemtseva, Holmes (2014). Coverage Is Not Strongly Correlated with Test Suite Effectiveness. *ICSE*.
- Papadakis, Shin, Yoo, Bae (2018). Are Mutation Scores Correlated with Real Fault Detection? *ICSE*.
- Schuler, Zeller (2011). Assessing Oracle Quality with Checked Coverage. *ICST*.
