/// Logic that is written as closures: the methods that make them only return them, so only the
/// closures themselves show what the tests verify.

/// What a handler asks to happen next.
public enum Command: Equatable, Sendable {
    case none
    case save
    case reload
}

/// Changes a state for an event, and says what happens next.
public struct Handler<State, Event> {
    public let handle: (inout State, Event) -> Command

    public init(_ handle: @escaping (inout State, Event) -> Command) {
        self.handle = handle
    }
}

public enum Event: Sendable {
    case received
    case opened
    case muted
    case refreshed
    case ignored
}

public struct Inbox {
    public struct State: Equatable, Sendable {
        public var unread = 0
        public var isMuted = false

        public init() {}
    }

    public init() {}

    /// A closure that ends with a switch statement.
    /// Tests: `.received` and `.refreshed` are asserted, `.opened` runs without an assertion,
    /// `.muted` never runs. `.ignored` returns what the mutant returns.
    public var handler: Handler<State, Event> {
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
            case .refreshed:
                return .reload
            case .ignored:
                return .none
            }
        }
    }
}

public struct Archive {
    public init() {}

    /// A closure whose body is a switch expression, returned implicitly.
    /// Tests: `.received` is asserted, `.opened` runs without an assertion.
    public func handler() -> Handler<Int, Event> {
        Handler<Int, Event> { _, event in
            switch event {
            case .received: .save
            case .opened: .reload
            default: .none
            }
        }
    }

    /// A closure of one expression. Tests assert it.
    public var refreshing: Handler<Int, Event> {
        .init { count, _ in count > 0 ? .reload : .none }
    }
}

public final class Feed {
    private var listeners: [(String) -> Void] = []

    public init() {}

    public func subscribe(_ listener: @escaping (String) -> Void) {
        listeners.append(listener)
    }

    public func post(_ line: String) {
        for listener in listeners { listener(line) }
    }
}

public final class Recorder {
    public private(set) var lines: [String] = []
    public private(set) var count = 0

    public init() {}

    /// Two closures that return nothing. Tests assert `lines`, and never read `count`.
    public func record(_ feed: Feed) {
        feed.subscribe { line in
            self.lines.append(line)
        }
        feed.subscribe { _ in self.count += 1 }
    }
}

public struct Rule {
    public let check: (Int) -> Bool

    public init(_ check: @escaping (Int) -> Bool) {
        self.check = check
    }
}

public enum Rules {
    /// A closure without a signature. Tests assert both results.
    public static var positive: Rule { Rule { $0 > 0 } }

    /// A closure in a closure, each a method of its own. Tests assert both results.
    public static func all(_ rules: [Rule]) -> Rule {
        Rule { value in
            rules.allSatisfy { $0.check(value) }
        }
    }
}

public struct Job {
    public let run: () async throws -> Int

    public init(_ run: @escaping () async throws -> Int) {
        self.run = run
    }
}

extension Archive {
    /// A closure that is `async` and throws. Tests assert the count.
    public func count(of items: [Int]) -> Job {
        Job {
            try await Task.sleep(nanoseconds: 1)
            return items.count
        }
    }
}

extension Archive {
    /// A closure that only returns the value its mutant returns. A test runs it without an
    /// assertion, and there is nothing it could assert.
    public var idle: Handler<Int, Event> {
        Handler { _, _ in .none }
    }
}

extension Recorder {
    /// Forgets the lines, which a test asserts. Its closure ignores what is posted, and `reset()`
    /// has an empty body: a test runs both, and there is nothing in them it could detect.
    public func mute(_ feed: Feed) {
        lines.removeAll()
        feed.subscribe { _ in }
    }

    public func reset() {}
}

public struct Outbox {
    public struct State: Equatable, Sendable {
        public var sent = 0
        public var failed = 0

        public init() {}
    }

    public init() {}

    /// Each case changes the state and then says what happens next.
    /// Tests: `.received` asserts the state and the command, `.opened` the state only, and
    /// `.refreshed` runs without an assertion.
    public var handler: Handler<State, Event> {
        Handler { state, event in
            switch event {
            case .received:
                state.sent += 1
                return .save
            case .opened:
                state.failed += 1
                return .reload
            case .refreshed:
                state.sent = 0
                return .save
            default:
                return .none
            }
        }
    }

    /// Changes the state and says whether it did. Tests assert the state, never the result.
    public func send(_ count: Int, in state: inout State) -> Bool {
        guard count > 0 else { return false }
        state.sent += count
        return true
    }
}
