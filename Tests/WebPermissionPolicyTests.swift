import XCTest
@testable import Rikugan

final class WebPermissionPolicyTests: XCTestCase {
    func testCombinedPermissionNeverBypassesDenyOrAsk() {
        XCTAssertEqual(WebPermissionPolicy.aggregate(["allow", "allow"]), "allow")
        XCTAssertEqual(WebPermissionPolicy.aggregate(["allow", "ask"]), "ask")
        XCTAssertEqual(WebPermissionPolicy.aggregate(["ask", "ask"]), "ask")
        XCTAssertEqual(WebPermissionPolicy.aggregate(["allow", "block"]), "block")
        XCTAssertEqual(WebPermissionPolicy.aggregate(["block", "ask"]), "block")
        XCTAssertEqual(WebPermissionPolicy.aggregate([]), "ask")
    }
}
