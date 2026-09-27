import Foundation

enum ScriptRequest {
    static func build(_ args: [String: Any], origin: URL) throws -> (request: URLRequest, timeout: TimeInterval) {
        guard let raw = args["url"] as? String, raw.utf8.count <= 16000,
              let url = URL(string: raw, relativeTo: origin)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.user == nil, url.password == nil else {
            throw RikuganError.message("GM XHR 只允许没有嵌入凭证的 HTTP(S) 地址。")
        }
        let method = (args["method"] as? String ?? "GET").uppercased()
        guard method.range(of: #"^[A-Z]{1,24}$"#, options: .regularExpression) != nil,
              !["CONNECT", "TRACE", "TRACK"].contains(method) else { throw RikuganError.message("不支持的 HTTP 方法。") }
        let milliseconds = (args["timeout"] as? NSNumber)?.doubleValue ?? 0
        guard milliseconds.isFinite, (0...120000).contains(milliseconds) else { throw RikuganError.message("timeout 必须为 0–120000 毫秒。") }
        let timeout = milliseconds == 0 ? 60 : max(0.01, milliseconds / 1000)
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        request.httpMethod = method
        if let encoded = args["dataBase64"] as? String {
            guard encoded.utf8.count <= 2_800_000, let data = Data(base64Encoded: encoded), data.count <= 2_000_000 else { throw RikuganError.message("请求正文无效或超过 2 MB。") }
            request.httpBody = data
        } else if let text = args["data"] as? String {
            guard text.utf8.count <= 2_000_000 else { throw RikuganError.message("请求正文超过 2 MB。") }
            request.httpBody = Data(text.utf8)
        }
        let headers = args["headers"] as? [String: String] ?? [:]
        guard headers.count <= 64 else { throw RikuganError.message("请求头超过限制。") }
        for (key, value) in headers {
            guard key.range(of: #"^[A-Za-z0-9!#$%&'*+.^_`|~-]+$"#, options: .regularExpression) != nil,
                  value.utf8.count <= 8192, !value.contains("\r"), !value.contains("\n"),
                  !["host", "content-length", "connection", "transfer-encoding"].contains(key.lowercased()) else {
                throw RikuganError.message("不支持或不安全的请求头：\(key)")
            }
            request.setValue(value, forHTTPHeaderField: key)
        }
        return (request, timeout)
    }
}
