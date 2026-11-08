public protocol Repository {
    func fetch(id: Int) -> String?
    func count() -> Int
}

extension Repository {
    /// Default implementation, used by conformers that do not provide their own.
    public func count() -> Int { 0 }
}

/// Tested through the protocol: the test names this type and calls `fetch` on a `Repository`.
public struct SQLRepository: Repository {
    public init() {}
    public func fetch(id: Int) -> String? { id > 0 ? "row\(id)" : nil }
}

/// Never named by a test: only ever reached through `UserService` with a mock injected.
public struct RemoteRepository: Repository {
    public init() {}
    public func fetch(id: Int) -> String? { "remote\(id)" }
    public func count() -> Int { 42 }
}

public struct UserService {
    let repo: any Repository
    public init(repo: any Repository) { self.repo = repo }

    /// Called directly by a test.
    public func name(of id: Int) -> String { repo.fetch(id: id) ?? "unknown" }

    /// Only called from `name(of:)`-like production code paths, never by a test.
    public func normalized(_ name: String) -> String { name.lowercased() }

    /// Read by a test.
    public var isReady: Bool { true }
}

open class Shape {
    public init() {}
    open func area() -> Double { 0 }
}

public final class Square: Shape {
    let side: Double
    public init(side: Double) { self.side = side }
    public override func area() -> Double { side * side }
}

/// Never instantiated by a test.
public final class Circle: Shape {
    public override func area() -> Double { 3 }
}

public enum Format {
    public static func percent(_ value: Double) -> String { "\(Int(clamped(value) * 100))%" }

    /// Executed and verified through `percent(_:)`, but no test calls it directly.
    static func clamped(_ value: Double) -> Double { min(max(value, 0), 1) }
}
