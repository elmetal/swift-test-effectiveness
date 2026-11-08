# Static test references

English | [日本語](../ja/methods/static-references.md)

Fills the **referenced** column (see [Concepts](../concepts.md)): does any test refer to this method directly?

## What it does

The column is about intent, not execution. Coverage says a method ran. It does not say whether any test is *about* the method, or whether the method only ran because a test of something else called it. The referenced column answers that from the source alone, without running anything.

The tool reads the index the compiler writes during the build (`swift build --enable-index-store`). The index records every reference with the symbol already resolved: overloads, extensions and the conformances behind each protocol member are told apart.

A method is **referenced** when a test refers to it directly. Here "a test" means:

- a *test scope*: an `XCTestCase` subclass, a type with `@Suite` or `@Test` functions, or a free `@Test` function. A type and its extensions form one scope, so a subject created in `setUp()` and used in `testXxx()` counts.
- the test-target code that a scope calls: helpers such as `makeSUT()`, mocks and custom assertions. These are followed as far as they go, because they are part of the test.

Production code is not followed. If a test calls `a()` and `a()` calls `b()`, the test refers to `a()` only. Following calls transitively would reach almost every declaration and only repeat coverage.

## Calls through a protocol or a superclass

When a test calls a method through a protocol (`let repo: any Repository`) or through an overridable class method, the compiler does not know which implementation runs. The tool resolves the call with *rapid type analysis* restricted to the test scope. The call refers to the implementation of each concrete type that the scope names (in the test code itself or in the test helpers it calls). For a class, that is the type's own implementation or its nearest superclass's.

| Test code | Referenced | Not referenced |
|---|---|---|
| `let repo: any Repository = SQLRepository(); repo.fetch(id: 1)` | `SQLRepository.fetch` | other conformers' `fetch` |
| `UserService(repo: MockRepository()).name(of: 1)` | `UserService.name(of:)` | every real `Repository.fetch` |
| `repo.count()` where `SQLRepository` uses the protocol extension's default | the default `count()` | conformers with their own `count()` |
| `shape = Square(side: 2)` in `setUp()`, `shape.area()` in a test | `Square.area`, and `Shape.area` (the call names it) | `Circle.area` |

The mock row is the point of the design. A test that injects a mock does not exercise the real implementation, and the column says so. The two alternatives are worse:

- Marking every conformer as referenced (class hierarchy analysis) would mark the real implementation as referenced by a mock-based test.
- Marking no conformer would make every protocol-based test look as if it referred to nothing.

Calls to requirements of protocols declared outside the project (`Equatable`, `CustomStringConvertible`, …) are not resolved. Stringifying a value in a test does not count as a test of its `description`.

## Output

Each analysed method carries the column as `referenced` in the JSON report: `"true"`, `"false"` or `"unknown"`. It is unknown when there is no index (see below), or when the index has no declaration on the method's lines.

Text and Markdown reports point out the combinations that change what to do (see [Reading the columns together](../concepts.md#reading-the-columns-together)):

| Finding | referenced | Note in the report |
|---|---|---|
| `pseudo-tested`, `partially-tested` | false | no test calls it directly; write a test whose subject is this method, rather than adding an assertion somewhere else |
| `not-covered` | true | a test refers to it, but it never ran: a skipped test, an injected mock or dispatch to another type |
| `tested` | false | tested only indirectly; low priority |

The column does not change the classification. Static references and dynamic evidence are reported side by side, and the dynamic columns decide the finding.

## When the index is unavailable

| Situation | Behaviour |
|---|---|
| `--no-index` | the index is not read, and the build does not write one |
| custom mode without `--index-store-path` | the index is not read |
| the index store or `libIndexStore.dylib` cannot be found or opened | a message is logged, and the column is unknown |

For Xcode projects, pass the index store that the custom build command writes with `--index-store-path`. A relative path is resolved inside the copied project, where the build command runs. For example, add `-derivedDataPath build` to the `xcodebuild` command and pass `--index-store-path build/Index.noindex/DataStore`. The index must come from building the copy, because declarations are matched by path.

`libIndexStore.dylib` is loaded from the toolchain of the `swift` executable (`--swift`), so the index format always matches the compiler that wrote it.

## Limits

- The index records what the compiler resolved. Calls that are not visible statically do not count: `@objc` dynamic dispatch, selectors, key paths passed as strings, reflection.
- Test scopes are found by syntax: `XCTestCase` in the inheritance clause, `@Suite`, `@Test`, or a class with `testXxx()` methods (for a class that inherits `XCTestCase` through a base class of its own).
- A type named anywhere in a scope counts for every call in that scope. A test class that creates `SQLRepository` in one test and injects a mock in another refers to `SQLRepository.fetch` from both.
- A call through the base class always refers to the base class's method, even when every instance in the test is a subclass that overrides it. The report then shows it as referenced but never executed, which is accurate.
