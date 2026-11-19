import Testing
@testable import Closures

@Test func receivedCountsUnread() {
    var state = Inbox.State()
    _ = Inbox().handler.handle(&state, .received)
    #expect(state.unread == 1)
}

@Test func openedDoesNotCrash() {
    var state = Inbox.State()
    _ = Inbox().handler.handle(&state, .opened)
}

@Test func refreshedReloads() {
    var state = Inbox.State()
    #expect(Inbox().handler.handle(&state, .refreshed) == .reload)
}

@Test func archiveSavesWhatItReceives() {
    var count = 0
    #expect(Archive().handler().handle(&count, .received) == .save)
}

@Test func archiveOpensWithoutCrashing() {
    var count = 0
    _ = Archive().handler().handle(&count, .opened)
}

@Test func refreshingReloadsWhatHasItems() {
    var count = 2
    #expect(Archive().refreshing.handle(&count, .received) == .reload)
}

@Test func recorderKeepsLines() {
    let feed = Feed()
    let recorder = Recorder()
    recorder.record(feed)
    feed.post("a")
    #expect(recorder.lines == ["a"])
}

@Test func positiveRule() {
    #expect(Rules.positive.check(1))
    #expect(!Rules.positive.check(0))
}

@Test func allRules() {
    let even = Rule { $0 % 2 == 0 }
    #expect(Rules.all([Rules.positive, even]).check(2))
    #expect(!Rules.all([Rules.positive, even]).check(3))
}

@Test func countsItems() async throws {
    #expect(try await Archive().count(of: [1, 2, 3]).run() == 3)
}

@Test func idleRuns() {
    var count = 0
    _ = Archive().idle.handle(&count, .received)
}

@Test func muteForgetsLines() {
    let feed = Feed()
    let recorder = Recorder()
    recorder.record(feed)
    feed.post("a")
    recorder.mute(feed)
    #expect(recorder.lines.isEmpty)
    feed.post("b")
    recorder.reset()
}
