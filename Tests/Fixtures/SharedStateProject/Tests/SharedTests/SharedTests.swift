import Shared
import Testing

/// Reads `Phrase.separator`. In a process that has run it before, the separator is no longer
/// computed, so a mutant of `makeSeparator()` goes unnoticed there.
@Test func joinsWordsWithTheSeparator() {
    #expect(Phrase.join(["a", "b"]) == "a, b")
}

/// Passes once in a process: the second time, the list has two guests.
@Test func invitedGuestIsOnTheList() {
    Guests.invite("ann")
    #expect(Guests.isInvited("ann"))
    #expect(Guests.count == 1)
}
