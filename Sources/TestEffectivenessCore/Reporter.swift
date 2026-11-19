import Foundation

public enum ReportFormat: String, CaseIterable, Sendable {
    case text
    case markdown
    case json
}

/// Renders an `AnalysisReport`.
///
/// By design the report contains no aggregate score or percentage: only per-method
/// classifications with concrete, actionable feedback (see README, "Why no score").
public enum Reporter {
    public static func render(_ report: AnalysisReport, format: ReportFormat) throws -> String {
        switch format {
        case .json:
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            return String(decoding: try encoder.encode(report), as: UTF8.self) + "\n"
        case .text:
            return text(report)
        case .markdown:
            return markdown(report)
        }
    }

    static let sectionOrder: [MethodClassification] = [.pseudoTested, .partiallyTested, .notCovered, .tested]

    static func title(_ classification: MethodClassification) -> String {
        switch classification {
        case .pseudoTested: "Pseudo-tested"
        case .partiallyTested: "Partially tested"
        case .notCovered: "Not covered"
        case .tested: "Tested"
        }
    }

    static func explanation(_ classification: MethodClassification) -> String {
        switch classification {
        case .pseudoTested:
            "Tests execute these methods, but every extreme mutant survived: no test checks what they do."
        case .partiallyTested:
            "Some extreme mutants survived, of the whole body or of one case of its switch: "
                + "tests check these methods only for part of their behaviour."
        case .notCovered:
            "No test executes these methods (mutants were not run)."
        case .tested:
            "Every extreme mutant was detected."
        }
    }

    /// Actionable feedback for one surviving mutant.
    public static func advice(for mutation: ExtremeMutation, method: String) -> String {
        switch mutation {
        case .emptyBody:
            "Removing the whole body of `\(method)` breaks no test. Assert its side effects (state changes, calls made, output)."
        case .returnNil:
            "`\(method)` can return `nil` without any test failing. Assert the value it returns."
        case .returnBool(let value):
            "`\(method)` can always return `\(value)` without any test failing. Add a case where it must return `\(!value)`."
        case .returnNumber(let literal):
            "`\(method)` can always return `\(literal)` without any test failing. Assert the exact value."
        case .returnString(let literal):
            "`\(method)` can always return `\"\(literal)\"` without any test failing. Assert the exact string."
        case .returnEmptyArray, .returnEmptyDictionary, .returnEmptyData:
            "`\(method)` can always return an empty collection without any test failing. Assert the elements."
        case .returnValue(let expression):
            "`\(method)` can always return `\(expression)` without any test failing. Assert the value it returns."
        case .emptyView:
            "`\(method)` can render nothing without any test failing. Add a UI, snapshot or view-inspection test."
        case .throwError:
            "`\(method)` can always throw without any test failing. Assert that it succeeds for valid input."
        case .otherCase(let label):
            "`\(method)` can do what `\(label)` does without any test failing. Assert the result."
        }
    }

    /// Actionable feedback for a case that no test runs, or whose mutants survived.
    public static func advice(for result: CaseResult, method: String) -> String {
        let place = "`\(result.label)` (line \(result.line))"
        if result.executed == .notExecuted {
            return "No test runs \(place) of `\(method)`. Add a test of this case."
        }
        let survived = result.survivingMutants.map(\.mutant.mutation)
        let behaviours = survived.map { mutation in
            switch mutation {
            case .emptyBody: "do nothing"
            case .returnEmptyArray, .returnEmptyDictionary, .returnEmptyData: "return an empty collection"
            case .emptyView: "render nothing"
            case .throwError: "throw"
            case .otherCase(let label): "do what `\(label)` does"
            default: mutation.summary
            }
        }
        let assertion = survived.allSatisfy { $0 == .emptyBody } ? "its side effects" : "the result"
        return "In \(place), `\(method)` can \(behaviours.joined(separator: " or ")) without any test failing. "
            + "Add a test of this case that asserts \(assertion)."
    }

    // MARK: - Text

    static func text(_ report: AnalysisReport) -> String {
        var out = "Test effectiveness of \(report.projectPath)\n"
        if !report.coverageAvailable {
            out += "(coverage unavailable: uncovered methods, including ones in inactive `#if` blocks, are reported as pseudo-tested)\n"
        }
        if !report.referencesAvailable {
            out += "(no index store: the referenced column is unknown)\n"
        }
        for classification in sectionOrder {
            let methods = report.methods(classification)
            guard !methods.isEmpty else { continue }
            out += "\n\(title(classification)) (\(methods.count))\n  \(explanation(classification))\n"
            let detailed = classification == .pseudoTested || classification == .partiallyTested
            if !detailed { out += "\n" }
            for result in methods {
                let suffix = detailed ? "" : referenceSuffix(result).map { "  (\($0))" } ?? ""
                out += "\(detailed ? "\n" : "")  \(location(result.method))  \(signature(result.method))\(suffix)\n"
                switch classification {
                case .pseudoTested, .partiallyTested:
                    if let note = referenceNote(result) { out += "    \(note)\n" }
                    if let note = executionNote(result, in: report) { out += "    \(note)\n" }
                    if !result.survivingMutants.isEmpty {
                        out += "    survived: \(result.survivingMutants.map(\.mutant.mutation.summary).joined(separator: ", "))\n"
                    }
                    let detected = result.mutants.filter(\.isDetected)
                    if !detected.isEmpty {
                        out += "    detected: \(detected.map(\.mutant.mutation.summary).joined(separator: ", "))\n"
                    }
                    for mutant in result.survivingMutants {
                        out += "    → \(advice(for: mutant.mutant.mutation, method: result.method.name))\n"
                    }
                    for unverified in result.unverifiedCases {
                        out += "    → \(advice(for: unverified, method: result.method.name))\n"
                    }
                case .notCovered, .tested:
                    break
                }
            }
        }
        if let tests = report.testsFailingAlone, !tests.isEmpty {
            out += "\n\(testsFailingAloneTitle) (\(tests.count))\n  \(testsFailingAloneExplanation)\n\n"
            for test in tests {
                out += "  \(test.test)  (\(test.timedOut ? "timed out; " : "")log: \(test.log))\n"
            }
        }
        if !report.skipped.isEmpty {
            out += "\nNot analyzed (\(report.skipped.count))\n"
            for skipped in report.skipped {
                out += "  \(location(skipped.method))  \(skipped.method.name) — \(skipped.reason)\n"
            }
            if let hint = defaultValueHint(report.skipped, analyzed: report.methods.map(\.method)) { out += "  → \(hint)\n" }
        }
        if report.methods.isEmpty && report.skipped.isEmpty {
            out += "\nNo methods found.\n"
        }
        return out
    }

    // MARK: - Markdown

    static func markdown(_ report: AnalysisReport) -> String {
        var out = "# Test effectiveness\n\n"
        let counts = sectionOrder.map { "\(title($0)): \(report.methods($0).count)" }
        out += counts.joined(separator: " · ") + " · Not analyzed: \(report.skipped.count)\n"
        if !report.coverageAvailable {
            out += "\n> Coverage was unavailable, so uncovered methods (including ones in inactive `#if` blocks) appear as pseudo-tested.\n"
        }
        if !report.referencesAvailable {
            out += "\n> No index store was available, so the referenced column is unknown.\n"
        }
        for classification in sectionOrder {
            let methods = report.methods(classification)
            guard !methods.isEmpty else { continue }
            out += "\n## \(title(classification))\n\n\(explanation(classification))\n\n"
            switch classification {
            case .pseudoTested, .partiallyTested:
                for result in methods {
                    out += "- **`\(result.method.name)`** — `\(location(result.method))`\n"
                    if let note = referenceNote(result) { out += "  - \(note)\n" }
                    if let note = executionNote(result, in: report) { out += "  - \(note)\n" }
                    for mutant in result.survivingMutants {
                        out += "  - \(mutant.mutant.mutation.summary) survived. \(advice(for: mutant.mutant.mutation, method: result.method.name))\n"
                    }
                    for unverified in result.unverifiedCases {
                        out += "  - \(advice(for: unverified, method: result.method.name))\n"
                    }
                }
            case .notCovered, .tested:
                for result in methods {
                    let suffix = referenceSuffix(result).map { " — \($0)" } ?? ""
                    out += "- `\(result.method.name)` — `\(location(result.method))`\(suffix)\n"
                }
            }
        }
        if let tests = report.testsFailingAlone, !tests.isEmpty {
            out += "\n## \(testsFailingAloneTitle)\n\n\(testsFailingAloneExplanation)\n\n"
            for test in tests {
                out += "- `\(test.test)`\(test.timedOut ? " (timed out)" : "") — log: `\(test.log)`\n"
            }
        }
        if !report.skipped.isEmpty {
            out += "\n<details><summary>Not analyzed (\(report.skipped.count))</summary>\n\n"
            for skipped in report.skipped {
                out += "- `\(skipped.method.name)` — \(skipped.reason) (`\(location(skipped.method))`)\n"
            }
            if let hint = defaultValueHint(report.skipped, analyzed: report.methods.map(\.method)) { out += "\n\(hint)\n" }
            out += "\n</details>\n"
        }
        return out
    }

    // MARK: - Helpers

    static let testsFailingAloneTitle = "Tests that fail alone"

    static let testsFailingAloneExplanation =
        "These test scopes pass in the whole suite but fail when run on their own, without mutations: "
        + "they depend on tests that run before them, or share state with them. "
        + "Make each test set up what it needs. They were not used to select tests for mutants."

    /// For executed methods whose mutants survived: is any test about this method at all?
    static func referenceNote(_ result: MethodResult) -> String? {
        guard result.referenced == .notReferenced else { return nil }
        return "referenced: false (no test calls it directly; it only runs inside other code). "
            + "Write a test whose subject is `\(result.method.name)`."
    }

    /// The combinations of the referenced column worth pointing out in the short lists.
    static func referenceSuffix(_ result: MethodResult) -> String? {
        switch (result.classification, result.referenced) {
        case (.notCovered, .referenced):
            "referenced by a test but never executed: check for skipped tests, injected mocks or dispatch to another type"
        case (.tested, .notReferenced):
            "tested only indirectly: no test calls it directly"
        default:
            nil
        }
    }

    /// Shown when coverage was collected but has no data for this method, so surviving mutants do
    /// not tell whether the method ran. When coverage is unavailable altogether, the report header
    /// says so once instead.
    static func executionNote(_ result: MethodResult, in report: AnalysisReport) -> String? {
        guard report.coverageAvailable, result.executed == .unknown else { return nil }
        return "executed: unknown (no coverage data for this method; it may not be run by any test at all)"
    }

    /// How many types `defaultValueHint` names.
    static let hintedTypes = 5

    /// What to do about the methods that are not analyzed for their return type: the user can
    /// name its simplest value. The types that most methods return come first.
    ///
    /// A method around a closure that is a method of its own (`--closure`) is not counted: the
    /// user had its logic analyzed as the closure, and a value for the type that holds the
    /// closure would say nothing about it.
    ///
    /// - Parameter analyzed: the methods that are analyzed; the closures are among them and
    ///   among `skipped`.
    public static func defaultValueHint(_ skipped: [SkippedMethod], analyzed: [MethodInfo] = []) -> String? {
        let closures = (analyzed + skipped.map(\.method)).filter { $0.kind == .closure }
        var counts: [String: Int] = [:]
        for skip in skipped {
            let method = skip.method
            guard let type = DefaultValues.typeToName(in: skip.reason) else { continue }
            let makesAClosure = method.kind != .closure && closures.contains { closure in
                closure.file == method.file && method.declarationStart <= closure.declarationStart
                    && closure.declarationEnd <= method.declarationEnd
            }
            if !makesAClosure { counts[type, default: 0] += 1 }
        }
        guard !counts.isEmpty else { return nil }
        let types = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
        var names = types.prefix(hintedTypes).map { "`\($0.key)` (\($0.value) \($0.value == 1 ? "method" : "methods"))" }
        let more = types.count - names.count
        if more > 0 { names.append("\(more) more \(more == 1 ? "type" : "types")") }
        let list = names.count > 1 ? names.dropLast().joined(separator: ", ") + " and " + names.last! : names[0]
        return "To analyze the methods that return a type without a simplest value, "
            + "give the type one with `--default-value TYPE=EXPRESSION`: \(list)."
    }

    static func location(_ method: MethodInfo) -> String {
        "\(method.file):\(method.declarationStart.line)"
    }

    static func signature(_ method: MethodInfo) -> String {
        guard let returnType = method.returnType else { return method.name }
        return method.kind == .getter ? "\(method.name): \(returnType)" : "\(method.name) -> \(returnType)"
    }
}
