/// Global state shared by the tests, so that one test can depend on another having run.
public enum Registry {
    nonisolated(unsafe) private static var names: [String] = []

    public static func register(_ name: String) {
        names.append(name)
    }

    public static func isRegistered(_ name: String) -> Bool {
        names.contains(name)
    }

    /// Called by `LookupTests` only, and never checked: pseudo-tested in the whole suite. Selected
    /// alone, `LookupTests` fails anyway, which would make its mutants look detected.
    public static func summary() -> String {
        names.joined(separator: ", ")
    }
}

public struct Doubler {
    public init() {}

    public func double(_ value: Int) -> Int {
        value * 2
    }
}
