import Testing
@testable import TestEffectivenessCore

struct AridDetectionTests {
    private func skipped(_ source: String, options: DiscoveryOptions = .init()) -> [String: Bool] {
        let methods = MethodDiscovery.discover(source: source, relativePath: "Sources/A/File.swift", options: options)
        return Dictionary(uniqueKeysWithValues: methods.map { method in
            if case .skip(let reason) = method.decision { return (method.info.name, reason == AridDetector.skipReason) }
            return (method.info.name, false)
        })
    }

    @Test func loggingOnlyBodiesAreSkipped() {
        let result = skipped("""
        import os
        struct S {
            static let logger = Logger(subsystem: "a", category: "b")
            let logger = Logger()
            func printOnly() { print("x") }
            func several(_ v: Int) { debugPrint(v); NSLog("%d", v); os_log("x") }
            func instanceLogger() { logger.info("x \\(1)") }
            func selfLogger() { self.logger.debug("x") }
            func staticLogger() { Self.logger.error("x") }
            func namespace() { Log.network.notice("x") }
            func inline() { Logger(subsystem: "a", category: "b").fault("x") }
            func asserting(_ v: Int) { assert(v > 0); assertionFailure() }
        }
        """)
        #expect(result.filter { !$0.value }.isEmpty, "\(result)")
    }

    @Test func controlFlowAroundLoggingIsArid() {
        let result = skipped("""
        struct S {
            var verbose = false
            func guarded() {
                guard verbose else { return }
                print("x")
            }
            func conditional() {
                if verbose { print("a") } else if !verbose { print("b") } else { print("c") }
            }
            func withoutElse() {
                if verbose { print("a") }
            }
            func debugOnly() {
                #if DEBUG
                print("x")
                #endif
            }
            func deferred() { defer { print("done") }; print("start") }
            func awaited() async { await logger.info("x") }
        }
        """)
        #expect(result.filter { !$0.value }.isEmpty, "\(result)")
    }

    @Test func bodiesWithOtherEffectsAreAnalysed() {
        let result = skipped("""
        struct S {
            func empty() {}
            func mixed() { print("x"); count += 1 }
            func otherCall() { save() }
            func callInCondition() { if cache.remove("k") != nil { print("removed") } }
            func callInGuard() { guard flush() else { return }; print("x") }
            func effectInElseIf() { if verbose { print("a") } else if quiet { reset() } }
            func effectInElse() { if verbose { print("a") } else { reset() } }
            func notALogger() { formatter.info("x") }
            func notALoggingMethod() { logger.flush() }
            func debugBranchWithEffect() {
                #if DEBUG
                print("x")
                #else
                reset()
                #endif
            }
            func returnsValue() -> Int { print("x"); return 1 }
        }
        """)
        #expect(result.filter { $0.value }.isEmpty, "\(result)")
        #expect(result.count == 11)
    }

    @Test func throwingLoggingMethodGetsNoThrowMutant() {
        let methods = MethodDiscovery.discover(
            source: "func f() throws { print(1) }", relativePath: "Sources/A/File.swift",
            options: DiscoveryOptions(includeThrowMutants: true)
        )
        #expect(methods.first?.mutations == [])
    }

    @Test func additionalCallsAreArid() {
        let source = """
        struct S {
            func tracked() { track("tap") }
            func viaShared() { Analytics.shared.track("tap"); self.track("x") }
            func otherShared() { Other.shared.track("tap") }
        }
        """
        #expect(skipped(source).values.allSatisfy { !$0 })
        let options = DiscoveryOptions(arid: AridDetector(additionalCalls: ["track", "Analytics.shared.track"]))
        #expect(skipped(source, options: options) == [
            "S.tracked()": true, "S.viaShared()": true, "S.otherShared()": false,
        ])
    }

    @Test func detectionCanBeDisabled() {
        let methods = MethodDiscovery.discover(
            source: "func f() { print(1) }", relativePath: "Sources/A/File.swift",
            options: DiscoveryOptions(arid: nil)
        )
        #expect(methods.first?.mutations == [.emptyBody])
    }
}
