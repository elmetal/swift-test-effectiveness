import Foundation

/// A test scope as a test runner selects it: a test type (XCTestCase subclass or suite) or a free
/// `@Test` function, in the module of its test target.
struct TestSelector: Hashable, Comparable, Sendable {
    var module: String
    /// The type name, or the function's base name.
    var name: String
    var isFunction: Bool

    static func < (lhs: TestSelector, rhs: TestSelector) -> Bool {
        (lhs.module, lhs.name, lhs.isFunction ? 1 : 0) < (rhs.module, rhs.name, rhs.isFunction ? 1 : 0)
    }

    /// `xcodebuild -only-testing` identifier: `Target/Type` or `Target/function()`. The index
    /// records the module name, which is the target name unless the target's product module name
    /// differs.
    var onlyTestingIdentifier: String {
        "\(module)/\(name)\(isFunction ? "()" : "")"
    }

    /// Regular expression for `swift test --filter`, which matches `Module.Type/test` and
    /// `Module.function()`.
    var filterPattern: String {
        let module = NSRegularExpression.escapedPattern(for: module)
        let name = NSRegularExpression.escapedPattern(for: name)
        return isFunction ? "^\(module)\\.\(name)\\(" : "^\(module)\\.\(name)(/|$)"
    }
}

/// Runs each mutant against the tests that may execute its method first; only a mutant that
/// survives them runs against the whole suite. A test that fails with a subset fails with the
/// whole suite too, so the outcomes are those of running the whole suite every time.
enum TestSelection {
    /// Replaced in a custom test command with `-only-testing:` arguments, or with nothing when the
    /// whole suite runs.
    static let placeholder = "{only-testing}"

    /// The test command with the placeholder replaced. `nil` runs the whole suite.
    static func expand(_ command: String, tests: [TestSelector]?) -> String {
        let arguments = (tests ?? []).sorted().map { shellQuoted("-only-testing:\($0.onlyTestingIdentifier)") }
        return command.replacingOccurrences(of: placeholder, with: arguments.joined(separator: " "))
    }

    /// `swift test` arguments that select `tests`.
    static func filterArguments(_ tests: [TestSelector]) -> [String] {
        ["--filter", tests.sorted().map(\.filterPattern).joined(separator: "|")]
    }

    /// The tests to run first for a method, or `nil` to run the whole suite at once: when no test
    /// reaches the method, or every test does.
    static func tests(reaching method: Set<TestSelector>?, all: Set<TestSelector>) -> [TestSelector]? {
        guard let method, !method.isEmpty, method != all else { return nil }
        return method.sorted()
    }

    static func shellQuoted(_ argument: String) -> String {
        ProcessRunner.shellQuote(argument)
    }
}
