import Foundation

/// GM_xmlhttpRequest networking. Same-origin Cookie headers are attached by the caller.
/// Redirects that leave that host drop the Cookie header. `cancel()` aborts the URLSession task.
final class ScriptExchange: NSObject, URLSessionDataDelegate {
    private var session: URLSession?
    private var task: URLSessionDataTask?
    private var response: HTTPURLResponse?
    private var bytes = Data()
    private let limit: Int
    private let sameOriginHost: String?
    private let permits: (URL) -> Bool
    private var completion: ((Result<[String: Any], Error>) -> Void)?
    private var failure: Error?
    private var aborted = false
    var onEvent: (([String: Any]) -> Void)?

    private init(limit: Int, sameOriginHost: String?, permits: @escaping (URL) -> Bool, completion: @escaping (Result<[String: Any], Error>) -> Void) {
        self.limit = limit
        self.sameOriginHost = sameOriginHost
        self.permits = permits
        self.completion = completion
    }

    /// readyState 1 is opened, 2 is headers, 3 is a received chunk. State 4 is the completion result.
    static func transferEvent(readyState: Int, loaded: Int, total: Int, status: Int, statusText: String, headers: String, finalUrl: String, responseText: String, chunk: Data) -> [String: Any] {
        [
            "readyState": readyState,
            "loaded": loaded,
            "total": max(total, 0),
            "status": status,
            "statusText": statusText,
            "responseHeaders": headers,
            "finalUrl": finalUrl,
            "responseText": responseText,
            "chunkText": String(data: chunk, encoding: .utf8) ?? "",
            "chunkBase64": chunk.isEmpty ? "" : chunk.base64EncodedString()
        ]
    }

    @discardableResult
    static func start(_ request: URLRequest, limit: Int = 8 * 1024 * 1024, sameOriginHost: String? = nil,
                      onEvent: (([String: Any]) -> Void)? = nil,
                      permits: @escaping (URL) -> Bool,
                      completion: @escaping (Result<[String: Any], Error>) -> Void) -> ScriptExchange? {
        guard let url = request.url, permits(url) else {
            completion(.failure(RikuganError.message("请求不在 @connect 授权范围内。")))
            return nil
        }
        let worker = ScriptExchange(limit: limit, sameOriginHost: sameOriginHost, permits: permits, completion: completion)
        worker.onEvent = onEvent
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 30
        configuration.timeoutIntervalForResource = 60
        let session = URLSession(configuration: configuration, delegate: worker, delegateQueue: nil)
        worker.session = session
        let task = session.dataTask(with: request)
        worker.task = task
        worker.emit(readyState: 1, chunk: Data())
        task.resume()
        return worker
    }

    func cancel() {
        aborted = true
        failure = RikuganError.message("已取消")
        task?.cancel()
    }

    static func fetch(_ request: URLRequest, limit: Int = 8 * 1024 * 1024,
                      permits: @escaping (URL) -> Bool,
                      completion: @escaping (Result<[String: Any], Error>) -> Void) {
        _ = start(request, limit: limit, permits: permits, completion: completion)
    }

    static func downloadText(_ url: URL) async throws -> String {
        let result: [String: Any] = try await withCheckedThrowingContinuation { continuation in
            fetch(URLRequest(url: url), limit: 8_000_000, permits: { $0.scheme == "https" && $0.user == nil && $0.password == nil }) {
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
            fetch(URLRequest(url: url), limit: limit, permits: { ["https", "http"].contains($0.scheme) && $0.user == nil && $0.password == nil }) {
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
            completionHandler(nil)
            task.cancel()
            return
        }
        var next = request
        if let sameOriginHost, let host = request.url?.host?.lowercased(), host != sameOriginHost {
            next.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(next)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse else {
            failure = RikuganError.message("响应格式不支持或超过大小限制。")
            completionHandler(.cancel)
            return
        }
        if response.expectedContentLength > Int64(limit) {
            failure = RikuganError.message("响应格式不支持或超过大小限制。")
            completionHandler(.cancel)
            return
        }
        self.response = http
        emit(readyState: 2, chunk: Data())
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard bytes.count + data.count <= limit else {
            failure = RikuganError.message("响应超过大小限制。")
            dataTask.cancel()
            return
        }
        bytes.append(data)
        emit(readyState: 3, chunk: data)
    }

    private func emit(readyState: Int, chunk: Data) {
        let http = response
        let total = Int(http?.expectedContentLength ?? -1)
        let payload = Self.transferEvent(
            readyState: readyState,
            loaded: bytes.count,
            total: total,
            status: http?.statusCode ?? 0,
            statusText: http.map { HTTPURLResponse.localizedString(forStatusCode: $0.statusCode) } ?? "",
            headers: http.map { $0.allHeaderFields.map { "\($0.key): \($0.value)" }.joined(separator: "\r\n") } ?? "",
            finalUrl: http?.url?.absoluteString ?? "",
            responseText: String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .isoLatin1) ?? "",
            chunk: chunk
        )
        let report = onEvent
        guard report != nil else { return }
        DispatchQueue.main.async { report?(payload) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let result: Result<[String: Any], Error>
        if aborted { result = .failure(RikuganError.message("已取消")) }
        else if let error = failure ?? error { result = .failure(error) }
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
        let done = completion
        completion = nil
        session.finishTasksAndInvalidate()
        self.session = nil
        DispatchQueue.main.async { done?(result) }
    }
}

enum ScriptRequestBody {
    static let limit = 8 * 1024 * 1024

    static func bytes(text: String?, base64: String?) -> Result<Data?, Error> {
        if let base64 {
            guard base64.utf8.count <= (limit / 3) * 4 + 8 else { return .failure(RikuganError.message("请求体超过大小限制。")) }
            guard let data = Data(base64Encoded: base64) else { return .failure(RikuganError.message("请求体无法解码。")) }
            guard data.count <= limit else { return .failure(RikuganError.message("请求体超过大小限制。")) }
            return .success(data)
        }
        return .success(text?.data(using: .utf8))
    }
}

enum ScriptVault {
    static func persists(isPrivate: Bool) -> Bool { !isPrivate }
    static func commit(isPrivate: Bool, scriptID: UUID, stored: [String: Any], json: String, memory: inout [UUID: [String: Any]]) -> String? {
        if persists(isPrivate: isPrivate) { return json }
        memory[scriptID] = stored
        return nil
    }
}

enum ScriptRequestCookies {
    static func shouldAttach(page: URL, request: URL, permitted: Bool) -> Bool {
        guard permitted, let pageHost = page.host?.lowercased(), let host = request.host?.lowercased() else { return false }
        return page.scheme?.lowercased() == request.scheme?.lowercased() && pageHost == host
    }
}

typealias ScriptNetwork = ScriptExchange
