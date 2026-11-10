/// Methods whose logic is a switch: a test of one case detects every mutant of the whole body,
/// so only the mutants of each case show which cases the tests verify.

public enum LoadState: Sendable {
    case idle
    case loading
    case loaded(Int)
    case failed(String)
}

public struct Presenter {
    public var badgesEnabled = true

    public init() {}

    /// A switch expression that is returned implicitly.
    /// Tests: `.idle` is asserted, `.loaded` runs without an assertion, the others never run.
    public func title(for state: LoadState) -> String {
        switch state {
        case .idle: "Idle"
        case .loading: "Loading"
        case .loaded(let count): "\(count) items"
        case .failed(let message): "Failed: \(message)"
        }
    }

    /// A switch statement whose cases return literals. Tests assert both cases.
    public func isBusy(_ state: LoadState) -> Bool {
        switch state {
        case .loading:
            return true
        case .idle, .loaded, .failed:
            return false
        }
    }

    /// A switch after other statements, with a case that returns what a mutant returns.
    /// Tests assert every case.
    public func badge(for state: LoadState) -> Int {
        guard badgesEnabled else { return 0 }
        switch state {
        case .loaded(let count): return count
        case .failed: return 1
        default: return 0
        }
    }

    /// A case that never returns, and cases that return what the mutant returns: only
    /// `case .failed` has a mutant. Tests assert it.
    public func retryDelay(for state: LoadState) -> Double? {
        switch state {
        case .failed(let message) where message.isEmpty: nil
        case .failed: 2.5
        case .loading: fatalError("never asked while loading")
        default: nil
        }
    }
}

public enum Action: Sendable {
    case increment
    case decrement
    case reset
    case noop
}

public final class Counter {
    public private(set) var value = 0

    public init() {}

    /// A `Void` method. Tests: `.increment` is asserted, `.decrement` runs without an assertion,
    /// `.reset` never runs, `.noop` does nothing to begin with.
    public func handle(_ action: Action) {
        switch action {
        case .increment:
            value += 1
        case .decrement:
            value -= 1
        case .reset:
            value = 0
        case .noop:
            break
        }
    }
}

/// Return types without a simplest value: the methods have no mutant of their own, and each case
/// does what another case does.

public enum Tint: Sendable, Equatable {
    case gray
    case blue
    case green
    case red
}

public struct Severity: Sendable, Equatable {
    public var level: Int
}

extension LoadState {
    /// A switch expression that returns an enum.
    /// Tests: `.idle` and `.failed` are asserted, `.loading` runs without an assertion, `.loaded`
    /// never runs.
    public var tint: Tint {
        switch self {
        case .idle: .gray
        case .loading: .blue
        case .loaded: .green
        case .failed: .red
        }
    }

    /// Cases that bind variables, cases that return the same, and a `default`. Tests assert
    /// every case.
    public func severity(threshold: Int) -> Severity {
        switch self {
        case .loaded(let count) where count > threshold:
            return Severity(level: 1)
        case .failed(let message):
            let level = message.isEmpty ? 2 : 3
            return Severity(level: level)
        case .idle:
            return Severity(level: 0)
        default:
            return Severity(level: 0)
        }
    }
}
