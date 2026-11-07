import Testing
@testable import TestEffectivenessCore

struct ClassifierTests {
    private func results(_ outcomes: [MutantOutcome]) -> [MutantResult] {
        outcomes.enumerated().map { MutantResult(mutant: Mutant(id: $0.offset, mutation: .emptyBody), outcome: $0.element) }
    }

    @Test func allSurvivedIsPseudoTested() {
        #expect(Classifier.classify(results([.survived, .survived])) == .pseudoTested)
    }

    @Test func someSurvivedIsPartiallyTested() {
        #expect(Classifier.classify(results([.survived, .killed])) == .partiallyTested)
    }

    @Test func noneSurvivedIsTested() {
        #expect(Classifier.classify(results([.killed, .timedOut])) == .tested)
    }

    @Test func notRunIsNotCovered() {
        #expect(Classifier.classify(results([.notRun, .notRun])) == .notCovered)
        #expect(Classifier.classify([]) == .notCovered)
    }
}
