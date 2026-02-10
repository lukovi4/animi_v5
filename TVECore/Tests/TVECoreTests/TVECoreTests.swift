import XCTest
@testable import TVECore
@testable import TVECompilerCore

final class TVECoreTests: XCTestCase {

    func testVersion() {
        XCTAssertEqual(TVECore.version, "0.1.0")
    }
}
