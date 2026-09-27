import XCTest
@testable import Rikugan

final class DeviceDiagnosticsTests: XCTestCase {
    func testDiagnosticReportSchemaDoesNotContainBrowsingPayloadFields() throws {
        let report = DiagnosticReport(appVersion: "0.4.0", build: "1", osVersion: "test", environment: "simulator", checks: [
            DiagnosticCheck(id: "one", title: "Check", level: .pass, detail: "sanitized")
        ])
        let data = try JSONEncoder().encode(report)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["history"]); XCTAssertNil(object["cookies"]); XCTAssertNil(object["urls"])
        let text = String(decoding: data, as: UTF8.self).lowercased()
        XCTAssertFalse(text.contains("password")); XCTAssertFalse(text.contains("https://"))
    }
}
