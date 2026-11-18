/// State that outlives a test. A process that runs the tests of one mutant after the other keeps
/// it from one mutant to the next.
public enum Phrase {
    /// Computed when it is first read; a process that has read it keeps the value.
    static let separator: String = makeSeparator()

    public static func join(_ words: [String]) -> String {
        words.joined(separator: separator)
    }

    static func makeSeparator() -> String {
        ", "
    }
}

/// A list that is never cleared.
public enum Guests {
    nonisolated(unsafe) static var names: [String] = []

    public static func invite(_ name: String) {
        names.append(name)
    }

    public static func isInvited(_ name: String) -> Bool {
        names.contains(name)
    }

    public static var count: Int {
        names.count
    }
}
