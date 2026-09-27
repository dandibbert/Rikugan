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
