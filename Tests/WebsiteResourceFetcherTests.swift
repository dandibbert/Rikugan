import XCTest
import WebKit
import UIKit
@testable import Rikugan

final class WebsiteResourceFetcherTests: XCTestCase {
    func testCookieHeaderRespectsDomainPathSecureAndExpiry() throws {
        let url = URL(string: "https://sub.example.com/account/image.png")!
        let valid = try XCTUnwrap(HTTPCookie(properties: [.domain: ".example.com", .path: "/account", .name: "auth", .value: "yes", .secure: "TRUE"]))
        let wrongPath = try XCTUnwrap(HTTPCookie(properties: [.domain: ".example.com", .path: "/other", .name: "other", .value: "no"]))
        let sibling = try XCTUnwrap(HTTPCookie(properties: [.domain: "badexample.com", .path: "/", .name: "bad", .value: "no"]))
        let header = WebsiteResourceFetcher.cookieHeader(for: url, cookies: [valid, wrongPath, sibling])
        XCTAssertEqual(header, "auth=yes")
        XCTAssertNil(WebsiteResourceFetcher.cookieHeader(for: URL(string: "http://sub.example.com/account/image.png")!, cookies: [valid]))
    }

    @MainActor func testAuthenticatedWebsiteStoreImageFetch() async throws {
        let id = UUID(), store = WKWebsiteDataStore(forIdentifier: id)
        defer { WKWebsiteDataStore.remove(forIdentifier: id) { _ in } }
        let cookie = try XCTUnwrap(HTTPCookie(properties: [.domain: "127.0.0.1", .path: "/", .name: "download-auth", .value: "yes"]))
        await withCheckedContinuation { continuation in store.httpCookieStore.setCookie(cookie) { continuation.resume() } }
        let (data, response) = try await WebsiteResourceFetcher.data(from: URL(string: "http://127.0.0.1:8765/__private-image.png")!, store: store,
            referer: URL(string: "http://127.0.0.1:8765/private"), userAgent: "RikuganTest")
        XCTAssertEqual(response.statusCode, 200)
        XCTAssertNotNil(UIImage(data: data))
    }
}
