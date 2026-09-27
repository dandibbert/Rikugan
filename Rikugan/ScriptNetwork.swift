import Foundation

/// Ephemeral, cookie-free networking. Redirects are subject to the same @connect policy.
final class ScriptNetwork: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var response: HTTPURLResponse?
    private var bytes = Data()
    private let limit: Int
    private let permits: (URL) -> Bool
    private var completion: ((Result<[String: Any], Error>) -> Void)?
    private var failure: Error?

    private init(limit: Int, permits: @escaping (URL) -> Bool, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        self.limit = limit; self.permits = permits; self.completion = completion
    }
    static func fetch(_ request: URLRequest, limit: Int = 8 * 1024 * 1024,
                      permits: @escaping (URL) -> Bool,
                      completion: @escaping (Result<[String: Any], Error>) -> Void) {
        guard let url = request.url, permits(url) else { completion(.failure(RikuganError.message("请求不在 @connect 授权范围内。"))); return }
        let worker = ScriptNetwork(limit: limit, permits: permits, completion: completion)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        worker.session = URLSession(configuration: configuration, delegate: worker, delegateQueue: nil)
        worker.session?.dataTask(with: request).resume()
    }
    static func downloadText(_ url: URL) async throws -> String {
        let result: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            fetch(URLRequest(url: url), limit: 2_000_000, permits: { $0.scheme == "https" && $0.user == nil && $0.password == nil }) {
                continuation.resume(with: $0)
            }
        }
        guard let code = result["status"] as? Int, (200..<300).contains(code), let text = result["responseText"] as? String else {
            throw RikuganError.message("下载失败：服务器未返回有效文本（HTTP \(result["status"] ?? "?")）。")
        }
        return text
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, permits(url) else {
            failure = RikuganError.message("重定向目标未获 @connect 授权。")
            completionHandler(nil); task.cancel(); return
        }
        completionHandler(request)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, response.expectedContentLength <= Int64(limit) else {
            failure = RikuganError.message("响应格式不支持或超过大小限制。")
            completionHandler(.cancel); return
        }
        self.response = http; completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= limit else {
            failure = RikuganError.message("响应超过大小限制。")
            dataTask.cancel(); return
        }
        bytes.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<[String: Any], Error>
        if let error = failure ?? error { result = .failure(error) }
        else if let response {
            result = .success([
                "status": response.statusCode,
                "statusText": HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
                "responseText": String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? "",
                "responseBase64": bytes.base64EncodedString(),
                "responseHeaders": response.allHeaderFields.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n"),
                "finalUrl": response.url?.absoluteString ?? "",
                "readyState": 4
            ])
        } else { result = .failure(RikuganError.message("服务器未返回响应。")) }
        let done = completion; completion = nil
        session.finishTasksAndInvalidate(); self.session = nil
        DispatchQueue.main.async { done?(result) }
    }
}

