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
    private var task: URLSessionDataTask?
    private var deadline: DispatchWorkItem?
    private var progress: (([String: Any]) -> Void)?
    private var lastProgress = Date.distantPast

    private init(limit: Int, permits: @escaping (URL) -> Bool, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        self.limit = limit; self.permits = permits; self.completion = completion
    }
    @discardableResult static func fetch(_ request: URLRequest, limit: Int = 8 * 1024 * 1024,
                      permits: @escaping (URL) -> Bool,
                      timeout: TimeInterval = 60, progress: (([String: Any]) -> Void)? = nil,
                      completion: @escaping (Result<[String: Any], Error>) -> Void) -> ScriptNetwork? {
        guard let url = request.url, permits(url) else { completion(.failure(RikuganError.message("请求不在 @connect 授权范围内。"))); return nil }
        let worker = ScriptNetwork(limit: limit, permits: permits, completion: completion)
        worker.progress = progress
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        let interval = min(120, max(0.01, timeout))
        configuration.timeoutIntervalForRequest = interval
        configuration.timeoutIntervalForResource = interval
        // All mutable delegate state and deadline delivery share the main queue.
        worker.session = URLSession(configuration: configuration, delegate: worker, delegateQueue: .main)
        worker.task = worker.session?.dataTask(with: request)
        let deadline = DispatchWorkItem { [weak worker] in
            guard let worker, worker.completion != nil else { return }
            worker.failure = URLError(.timedOut); worker.task?.cancel()
        }
        worker.deadline = deadline
        DispatchQueue.main.asyncAfter(deadline: .now() + interval, execute: deadline)
        worker.task?.resume()
        return worker
    }
    func cancel() { task?.cancel() }
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
    static func download(_ url: URL, limit: Int = 1_000_000) async throws -> (Data, String) {
        let result: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            fetch(URLRequest(url: url), limit: limit, permits: { ($0.scheme == "https" || (url.scheme == "http" && $0.scheme == "http")) && $0.user == nil && $0.password == nil }) {
                continuation.resume(with: $0)
            }
        }
        guard let code = result["status"] as? Int, (200..<300).contains(code),
              let encoded = result["responseBase64"] as? String, let data = Data(base64Encoded: encoded) else {
            throw RikuganError.message("资源下载失败（HTTP \(result["status"] ?? "?")）。")
        }
        let headers = (result["responseHeaders"] as? String ?? "").lowercased()
        let mime = headers.split(separator: "\r\n").first { $0.hasPrefix("content-type:") }?.dropFirst(13).split(separator: ";").first.map { String($0).trimmingCharacters(in: .whitespaces) } ?? "application/octet-stream"
        return (data, mime)
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
        self.response = http
        reportProgress(readyState: 2)
        completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= limit else {
            failure = RikuganError.message("响应超过大小限制。")
            dataTask.cancel(); return
        }
        bytes.append(data)
        if Date().timeIntervalSince(lastProgress) >= 0.05 {
            lastProgress = Date(); reportProgress(readyState: 3)
        }
    }
    private func reportProgress(readyState: Int) {
        guard let response else { return }
        progress?(["readyState": readyState, "status": response.statusCode,
            "statusText": HTTPURLResponse.localizedString(forStatusCode: response.statusCode),
            "loaded": bytes.count, "total": max(0, response.expectedContentLength), "lengthComputable": response.expectedContentLength >= 0,
            "responseHeaders": response.allHeaderFields.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n"),
            "finalUrl": response.url?.absoluteString ?? ""])
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        deadline?.cancel(); deadline = nil
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
        progress = nil; self.task = nil
        session.finishTasksAndInvalidate(); self.session = nil
        DispatchQueue.main.async { done?(result) }
    }
}

