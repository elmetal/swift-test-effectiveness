import Testing
import XCTest
@testable import Store

struct MockRepository: Repository {
    func fetch(id: Int) -> String? { "mock" }
}

// Swift Testing: the concrete type is named in the same test.
@Test func sqlThroughProtocol() {
    let repo: any Repository = SQLRepository()
    #expect(repo.fetch(id: 1) == "row1")
}

// Mock injection: RemoteRepository and SQLRepository are not the subject here.
@Test func serviceWithMock() {
    let service = UserService(repo: MockRepository())
    #expect(service.name(of: 1) == "mock")
    #expect(service.isReady)
}

@Test func percent() {
    #expect(Format.percent(0.5) == "50%")
}

// XCTest: the subject is created in setUp and used in a test method of the same class.
final class ShapeTests: XCTestCase {
    var shape: Shape!

    override func setUp() {
        shape = Square(side: 2)
    }

    func testArea() {
        XCTAssertEqual(shape.area(), 4)
    }

    func testDefaultCount() {
        let repo: any Repository = SQLRepository()
        XCTAssertEqual(repo.count(), 0)
    }
}
