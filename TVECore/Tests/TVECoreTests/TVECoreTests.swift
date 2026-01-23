import XCTest
@testable import TVECore

final class TVECoreTests: XCTestCase {

    func testVersion() {
        XCTAssertEqual(TVECore.version, "0.1.0")
    }
}
