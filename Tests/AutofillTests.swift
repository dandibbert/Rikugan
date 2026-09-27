import XCTest
@testable import Rikugan

final class AutofillTests: XCTestCase {
    func testHostPolicyAndPaymentNormalization() throws {
        var item = AutofillItem(kind: "payment", title: "Card", host: "HTTPS://Example.COM/login", username: "", secret: "4111 1111 1111 1234")
        item = try item.validated()
        XCTAssertEqual(item.host, "example.com")
        XCTAssertEqual(item.paymentLast4, "1234")
        XCTAssertTrue(AutofillPolicy.canFill(item, pageURL: URL(string: "https://shop.example.com/checkout")))
        XCTAssertFalse(AutofillPolicy.canFill(item, pageURL: URL(string: "https://example.com.evil.test/")))
        item.host = ""
        XCTAssertTrue(AutofillPolicy.canFill(item, pageURL: URL(string: "https://any.test/")))
    }
    func testInvalidAutofillItemsFailClosed() {
        XCTAssertThrowsError(try AutofillItem(kind: "unknown", title: "", host: "", username: "", secret: "").validated())
        XCTAssertThrowsError(try AutofillItem(kind: "password", title: String(repeating: "x", count: 17000), host: "", username: "", secret: "").validated())
    }
    func testRootAndSubdomainNormalizationDoesNotAcceptSiblingSuffixes() throws {
        let item = try AutofillItem(kind: "identity", title: "Me", host: ".Example.com.", username: "", secret: "").validated()
        XCTAssertEqual(item.host, "example.com")
        XCTAssertTrue(AutofillPolicy.canFill(item, pageURL: URL(string: "https://a.example.com/")))
        XCTAssertFalse(AutofillPolicy.canFill(item, pageURL: URL(string: "https://badexample.com/")))
    }
}
