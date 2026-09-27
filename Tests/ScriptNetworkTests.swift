import XCTest
@testable import Rikugan

final class ScriptNetworkTests: XCTestCase {
    let origin = URL(string: "http://127.0.0.1:8765/")!
    func testRequestBuilderBinaryHeadersAndOriginPolicy() throws {
        let body = Data([0, 1, 255])
        let value = try ScriptRequest.build(["url": "/__echo", "method": "POST", "dataBase64": body.base64EncodedString(), "timeout": 1000], origin: origin)
        XCTAssertEqual(value.request.httpBody, body)
        XCTAssertEqual(value.timeout, 1)
        XCTAssertThrowsError(try ScriptRequest.build(["url": "file:///tmp/private"], origin: origin))
        XCTAssertThrowsError(try ScriptRequest.build(["url": "/", "headers": ["X-Test": "ok\r\nInjected: yes"]], origin: origin))
        XCTAssertThrowsError(try ScriptRequest.build(["url": "/", "headers": ["Host": "evil.test"]], origin: origin))
        XCTAssertThrowsError(try ScriptRequest.build(["url": "/", "timeout": -1], origin: origin))
        XCTAssertTrue(URLRules.connectionAllowed(origin, origin: origin, rules: ["self"]))
        XCTAssertFalse(URLRules.connectionAllowed(URL(string: "http://127.0.0.1:9999/")!, origin: origin, rules: ["self"]))
        XCTAssertFalse(URLRules.connectionAllowed(URL(string: "https://127.0.0.1:8765/")!, origin: origin, rules: ["self"]))
    }
    @MainActor func testNativeProgressAndPostBody() async throws {
        let built = try ScriptRequest.build(["url": "/__echo", "method": "POST", "dataBase64": Data([0, 1, 255]).base64EncodedString()], origin: origin)
        var states: [Int] = []
        let result: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            ScriptNetwork.fetch(built.request, permits: { _ in true }, progress: { states.append($0["readyState"] as? Int ?? 0) }) { continuation.resume(with: $0) }
        }
        let text = try XCTUnwrap(result["responseText"] as? String)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
        XCTAssertEqual(object["body"] as? String, Data([0, 1, 255]).base64EncodedString())
        XCTAssertEqual(object["cookie"] as? String, "")
        XCTAssertTrue(states.contains(2)); XCTAssertTrue(states.contains(3))
    }
    @MainActor func testNativeCancellationTimeoutAndRedirectPolicy() async throws {
        let url = URL(string: "__slow", relativeTo: origin)!
        var worker: ScriptNetwork?
        let cancelled: Result<[String: Any], Error> = await withCheckedContinuation { continuation in
            worker = ScriptNetwork.fetch(URLRequest(url: url), permits: { _ in true }, progress: { value in
                if value["readyState"] as? Int == 3 { worker?.cancel() }
            }) { continuation.resume(returning: $0) }
        }
        if case .failure(let error) = cancelled { XCTAssertEqual((error as NSError).code, NSURLErrorCancelled) }
        else { XCTFail("Native request was not cancelled") }
        let timeout: Result<[String: Any], Error> = await withCheckedContinuation { continuation in
            ScriptNetwork.fetch(URLRequest(url: url), permits: { _ in true }, timeout: 0.1) { continuation.resume(returning: $0) }
        }
        if case .failure(let error) = timeout { XCTAssertEqual((error as NSError).code, NSURLErrorTimedOut) }
        else { XCTFail("Native request did not time out") }
        let redirect: Result<[String: Any], Error> = await withCheckedContinuation { continuation in
            ScriptNetwork.fetch(URLRequest(url: URL(string: "__redirect", relativeTo: origin)!), permits: { URLRules.connectionAllowed($0, origin: self.origin, rules: ["self"]) }) { continuation.resume(returning: $0) }
        }
        if case .success = redirect { XCTFail("Unauthorized redirect was followed") }
    }
}
