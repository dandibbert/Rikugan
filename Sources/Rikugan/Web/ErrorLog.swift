import Foundation

/// In-memory ring buffer of runtime errors shown on the Diagnostics page and included in the
/// diagnostics export. Contains no page content, URLs are reduced to their host.
@MainActor final class ErrorLog: ObservableObject {
    struct Entry: Identifiable, Codable {
        var id = UUID()
        let date: Date
        let source: String
        let message: String
    }

    static let shared = ErrorLog()
    @Published private(set) var entries: [Entry] = []

    func record(_ message: String, source: String) {
        entries.append(Entry(date: Date(), source: source, message: Self.scrub(String(message.prefix(500)))))
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }

    func clear() { entries.removeAll() }

    /// Reduces http(s)/ws(s) URLs to scheme + host (credentials in the authority dropped) so paths,
    /// query strings and user:password never reach the log.
    nonisolated static func scrub(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"((?:https?|wss?)://)(?:[^/\s"'?#@]*@)?([^/\s"'?#]+)[^\s"']*"#, options: [.caseInsensitive]) else { return text }
        return regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "$1$2/…")
    }
}

/// Diagnostics export helpers. Error messages are free text written by extensions, scripts and
/// web pages; a regex cannot prove such text is free of secrets. The export therefore contains
/// only a `signature` (error type and source location) by default; the (redacted) text is an
/// explicit opt-in the user can preview.
enum Redactor {
    /// "TypeError @ popup.js:12", "Unsupported API: chrome.identity.getAuthToken", …
    static func signature(_ message: String) -> String {
        let text = message.trimmingCharacters(in: .whitespacesAndNewlines)
        var head = ""
        if let match = text.range(of: #"^(\[[a-z]+\] )?(Unhandled rejection: )?[A-Za-z_$][A-Za-z0-9_$]*(Error|Exception)\b"#, options: .regularExpression) {
            head = String(text[match])
        } else if let match = text.range(of: #"^(\[[a-z]+\] )?(Unsupported API: [A-Za-z0-9_.]+|Missing @grant [A-Za-z0-9_.]+)"#, options: .regularExpression) {
            head = String(text[match])
        } else {
            head = "message"
        }
        if let location = text.range(of: #" @ [A-Za-z0-9_./-]+:[0-9]+$"#, options: .regularExpression) {
            head += String(text[location])
        }
        return head + " (\(text.count) chars)"
    }

    /// Best-effort redaction for the opt-in text: any URL → scheme + host, file / data / blob URLs
    /// dropped, key=value secrets, e-mail addresses, long tokens and digit runs removed.
    static func redact(_ message: String) -> String {
        var text = ErrorLog.scrub(message)
        let rules: [(String, String)] = [
            (#"(?i)\b(file|data|blob|content|javascript):[^\s"']*"#, "$1:…"),
            (#"(?i)\b([a-z][a-z0-9+.-]*://)(?:[^/\s"'?#@]*@)?([^/\s"'?#]+)[^\s"']*"#, "$1$2/…"),
            (#"(?i)\b(password|passwd|pwd|token|secret|api[_-]?key|key|auth|authorization|session|sid|cookie|code|bearer)\s*[:=]\s*[^\s,;&"']+"#, "$1=‹redacted›"),
            (#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#, "‹email›"),
            (#"[A-Za-z0-9_\-+/=]{24,}"#, "‹token›"),
            (#"\d{6,}"#, "‹number›"),
        ]
        for (pattern, template) in rules {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: template)
        }
        return text
    }
}

/// Privileged calls that were rejected (wrong content world, missing @grant, foreign extension
/// identity, port not owned by the caller …). Evidence for the adversarial self-tests and the
/// Diagnostics export; contains no page content.
@MainActor final class SecurityLog: ObservableObject {
    struct Entry: Identifiable, Codable {
        var id = UUID()
        let date: Date
        let message: String
    }

    static let shared = SecurityLog()
    @Published private(set) var entries: [Entry] = []
    private(set) var totalRejected = 0

    func record(_ message: String) {
        totalRejected += 1
        entries.append(Entry(date: Date(), message: ErrorLog.scrub(String(message.prefix(300)))))
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }

    func clear() { entries.removeAll(); totalRejected = 0 }
}
