import Foundation

/// User-facing error carrying a localized message. Used across the core logic so that
/// failures surface an explanation instead of failing silently.
public struct RikuganError: LocalizedError, Equatable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
    public var description: String { message }
}

/// Compatibility level used in API matrices for extensions and userscripts.
public enum SupportLevel: String, Codable, CaseIterable {
    case supported = "Supported"
    case partial = "Partial"
    case unsupported = "Unsupported"

    public var symbol: String {
        switch self {
        case .supported: return "✅"
        case .partial: return "🟡"
        case .unsupported: return "❌"
        }
    }
}

public extension String {
    /// JSON string literal (with quotes) safe to embed into generated JavaScript.
    var jsLiteral: String {
        let data = (try? JSONSerialization.data(withJSONObject: [self], options: [.fragmentsAllowed])) ?? Data("[\"\"]".utf8)
        var text = String(decoding: data, as: UTF8.self)
        text.removeFirst(); text.removeLast()
        return text.replacingOccurrences(of: "\u{2028}", with: "\\u2028").replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }
}

public enum JSONText {
    /// Serialises a JSON-compatible value to a compact string; falls back to `null`.
    public static func encode(_ value: Any?) -> String {
        guard let value, !(value is NSNull) else { return "null" }
        if JSONSerialization.isValidJSONObject(value),
           let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) {
            return String(decoding: data, as: UTF8.self)
                .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
                .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
        }
        if let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]) {
            return String(decoding: data, as: UTF8.self)
        }
        return "null"
    }

    public static func decode(_ text: String) -> Any? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
    }

    public static func encode<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(value) else { return "null" }
        return String(decoding: data, as: UTF8.self)
    }
}
