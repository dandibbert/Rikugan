import Foundation
import WebKit

/// User-initiated resource fetches that need the current WKWebsiteDataStore's
/// login cookies (for example saving an image visible only after login).
/// Redirects rebuild the Cookie header for the destination so credentials are
/// never forwarded blindly to another host.
final class WebsiteResourceFetcher: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let cookies: [HTTPCookie]
    private let limit: Int
    private let referer: URL?
    private let userAgent: String?
    private var bytes = Data()
    private var response: HTTPURLResponse?
    private var failure: Error?
    private var completion: ((Result<(Data, HTTPURLResponse), Error>) -> Void)?
    private var session: URLSession?
    private var redirects = 0

    private init(cookies: [HTTPCookie], limit: Int, referer: URL?, userAgent: String?, completion: @escaping (Result<(Data, HTTPURLResponse), Error>) -> Void) {
        self.cookies = cookies; self.limit = limit; self.referer = referer; self.userAgent = userAgent; self.completion = completion
    }

    @MainActor static func data(from url: URL, store: WKWebsiteDataStore, referer: URL?, userAgent: String?, limit: Int = 25 * 1024 * 1024) async throws -> (Data, HTTPURLResponse) {
        guard valid(url), (1...50 * 1024 * 1024).contains(limit) else { throw RikuganError.message("图片地址或大小限制无效。") }
        let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
            store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
        }
        return try await withCheckedThrowingContinuation { continuation in
            let worker = WebsiteResourceFetcher(cookies: cookies, limit: limit, referer: referer, userAgent: userAgent) {
                continuation.resume(with: $0)
            }
            let configuration = URLSessionConfiguration.ephemeral
            configuration.httpCookieStorage = nil; configuration.httpShouldSetCookies = false; configuration.urlCache = nil
            configuration.timeoutIntervalForRequest = 30; configuration.timeoutIntervalForResource = 60
            worker.session = URLSession(configuration: configuration, delegate: worker, delegateQueue: .main)
            worker.session?.dataTask(with: worker.request(url)).resume()
        }
    }

    static func cookieHeader(for url: URL, cookies: [HTTPCookie], now: Date = Date()) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let path = url.path.isEmpty ? "/" : url.path
        let matches = cookies.filter { cookie in
            if let expires = cookie.expiresDate, expires <= now { return false }
            if cookie.isSecure && url.scheme?.lowercased() != "https" { return false }
            let domain = cookie.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            let domainOK = host == domain || (cookie.domain.hasPrefix(".") && host.hasSuffix("." + domain))
            let cookiePath = cookie.path.isEmpty ? "/" : cookie.path
            let pathOK: Bool
            if path == cookiePath { pathOK = true }
            else if cookiePath.hasSuffix("/") { pathOK = path.hasPrefix(cookiePath) }
            else { pathOK = path.hasPrefix(cookiePath + "/") }
            return domainOK && pathOK
        }
        guard !matches.isEmpty else { return nil }
        return HTTPCookie.requestHeaderFields(with: matches)["Cookie"]
    }

    private static func valid(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil && url.user == nil && url.password == nil
    }
    private func request(_ url: URL, method: String = "GET") -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = method
        request.setValue("image/avif,image/webp,image/*,*/*;q=0.8", forHTTPHeaderField: "Accept")
        if let value = Self.cookieHeader(for: url, cookies: cookies) { request.setValue(value, forHTTPHeaderField: "Cookie") }
        if let userAgent, !userAgent.isEmpty { request.setValue(String(userAgent.prefix(1024)), forHTTPHeaderField: "User-Agent") }
        if let referer, Self.valid(referer), var components = URLComponents(url: referer, resolvingAgainstBaseURL: false) {
            components.path = "/"; components.query = nil; components.fragment = nil
            if let value = components.url?.absoluteString { request.setValue(value, forHTTPHeaderField: "Referer") }
        }
        return request
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects += 1
        guard redirects <= 10, let url = request.url, Self.valid(url) else {
            failure = RikuganError.message("图片重定向过多或目标不是安全的 HTTP(S) 地址。")
            completionHandler(nil); task.cancel(); return
        }
        completionHandler(self.request(url, method: request.httpMethod ?? "GET"))
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              response.expectedContentLength <= Int64(limit) else {
            failure = RikuganError.message("图片服务器返回失败状态或文件超过大小限制。")
            completionHandler(.cancel); return
        }
        self.response = http; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= limit else {
            failure = RikuganError.message("图片超过 \(limit / 1024 / 1024) MB 限制。")
            dataTask.cancel(); return
        }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<(Data, HTTPURLResponse), Error>
        if let error = failure ?? error { result = .failure(error) }
        else if let response { result = .success((bytes, response)) }
        else { result = .failure(RikuganError.message("图片服务器没有返回响应。")) }
        let done = completion; completion = nil
        session.finishTasksAndInvalidate(); self.session = nil
        done?(result)
    }
}
