import Testing
@testable import Switches

@Test func idleTitle() {
    #expect(Presenter().title(for: .idle) == "Idle")
}

@Test func loadedTitleDoesNotCrash() {
    _ = Presenter().title(for: .loaded(3))
}

@Test func busy() {
    #expect(Presenter().isBusy(.loading))
    #expect(!Presenter().isBusy(.idle))
}

@Test func badges() {
    #expect(Presenter().badge(for: .loaded(5)) == 5)
    #expect(Presenter().badge(for: .failed("x")) == 1)
    #expect(Presenter().badge(for: .idle) == 0)
}

@Test func retryDelayAfterFailure() {
    #expect(Presenter().retryDelay(for: .failed("timeout")) == 2.5)
}

@Test func increment() {
    let counter = Counter()
    counter.handle(.increment)
    #expect(counter.value == 1)
}

@Test func decrementDoesNotCrash() {
    Counter().handle(.decrement)
}

@Test func tints() {
    #expect(LoadState.idle.tint == .gray)
    #expect(LoadState.failed("x").tint == .red)
}

@Test func loadingTintDoesNotCrash() {
    _ = LoadState.loading.tint
}

@Test func severities() {
    #expect(LoadState.loaded(9).severity(threshold: 5) == Severity(level: 1))
    #expect(LoadState.loaded(1).severity(threshold: 5) == Severity(level: 0))
    #expect(LoadState.failed("").severity(threshold: 5) == Severity(level: 2))
    #expect(LoadState.failed("x").severity(threshold: 5) == Severity(level: 3))
    #expect(LoadState.idle.severity(threshold: 5) == Severity(level: 0))
}
