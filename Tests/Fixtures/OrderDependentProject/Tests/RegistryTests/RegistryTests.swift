import Registry
import XCTest

/// Runs first (XCTest runs test classes in name order).
final class AARegistrationTests: XCTestCase {
    func testRegister() {
        Registry.register("a")
        XCTAssertTrue(Registry.isRegistered("a"))
    }
}

/// Passes only after `AARegistrationTests` has registered "a": fails when run on its own.
final class LookupTests: XCTestCase {
    func testLookup() {
        XCTAssertTrue(Registry.isRegistered("a"))
        _ = Registry.summary()
    }
}

final class DoublerTests: XCTestCase {
    func testDouble() {
        XCTAssertEqual(Doubler().double(3), 6)
    }
}
