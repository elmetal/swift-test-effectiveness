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
            "Some extreme mutants survived: tests check these methods only for part of their behaviour."
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
        case .emptyView:
            "`\(method)` can render nothing without any test failing. Add a UI, snapshot or view-inspection test."
        case .throwError:
            "`\(method)` can always throw without any test failing. Assert that it succeeds for valid input."
        }
    }

    // MARK: - Text

    static func text(_ report: AnalysisReport) -> String {
        var out = "Extreme mutation analysis of \(report.projectPath)\n"
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
                    out += "    survived: \(result.survivingMutants.map(\.mutant.mutation.summary).joined(separator: ", "))\n"
                    let detected = result.mutants.filter(\.isDetected)
                    if !detected.isEmpty {
                        out += "    detected: \(detected.map(\.mutant.mutation.summary).joined(separator: ", "))\n"
                    }
                    for mutant in result.survivingMutants {
                        out += "    → \(advice(for: mutant.mutant.mutation, method: result.method.name))\n"
                    }
                case .notCovered, .tested:
                    break
                }
            }
        }
        if !report.skipped.isEmpty {
            out += "\nNot analyzed (\(report.skipped.count))\n"
            for skipped in report.skipped {
                out += "  \(location(skipped.method))  \(skipped.method.name) — \(skipped.reason)\n"
            }
        }
        if report.methods.isEmpty && report.skipped.isEmpty {
            out += "\nNo methods found.\n"
        }
        return out
    }

    // MARK: - Markdown

    static func markdown(_ report: AnalysisReport) -> String {
        var out = "# Extreme mutation analysis\n\n"
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
                }
            case .notCovered, .tested:
                for result in methods {
                    let suffix = referenceSuffix(result).map { " — \($0)" } ?? ""
                    out += "- `\(result.method.name)` — `\(location(result.method))`\(suffix)\n"
                }
            }
        }
        if !report.skipped.isEmpty {
            out += "\n<details><summary>Not analyzed (\(report.skipped.count))</summary>\n\n"
            for skipped in report.skipped {
                out += "- `\(skipped.method.name)` — \(skipped.reason) (`\(location(skipped.method))`)\n"
            }
            out += "\n</details>\n"
        }
        return out
    }

    // MARK: - Helpers

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

    static func location(_ method: MethodInfo) -> String {
        "\(method.file):\(method.declarationStart.line)"
    }

    static func signature(_ method: MethodInfo) -> String {
        guard let returnType = method.returnType else { return method.name }
        return method.kind == .getter ? "\(method.name): \(returnType)" : "\(method.name) -> \(returnType)"
    }
}
