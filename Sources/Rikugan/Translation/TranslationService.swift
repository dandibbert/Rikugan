import Foundation
import NaturalLanguage

/// Replaceable translation provider layer (spec §25).
protocol TranslationProvider {
    var id: String { get }
    var name: String { get }
    func translate(_ texts: [String], from source: String?, to target: String) async throws -> [String]
}

struct TranslationLanguage: Identifiable, Hashable {
    let code: String
    let name: String
    var id: String { code }

    static let common: [TranslationLanguage] = [
        .init(code: "zh-CN", name: "简体中文"), .init(code: "zh-TW", name: "繁體中文"), .init(code: "en", name: "English"),
        .init(code: "ja", name: "日本語"), .init(code: "ko", name: "한국어"), .init(code: "fr", name: "Français"),
        .init(code: "de", name: "Deutsch"), .init(code: "es", name: "Español"), .init(code: "pt", name: "Português"),
        .init(code: "it", name: "Italiano"), .init(code: "ru", name: "Русский"), .init(code: "ar", name: "العربية"),
        .init(code: "hi", name: "हिन्दी"), .init(code: "th", name: "ไทย"), .init(code: "vi", name: "Tiếng Việt"),
        .init(code: "id", name: "Bahasa Indonesia"), .init(code: "ms", name: "Bahasa Melayu"), .init(code: "tr", name: "Türkçe"),
        .init(code: "nl", name: "Nederlands"), .init(code: "pl", name: "Polski"), .init(code: "sv", name: "Svenska"),
        .init(code: "uk", name: "Українська"), .init(code: "cs", name: "Čeština"), .init(code: "el", name: "Ελληνικά"),
        .init(code: "he", name: "עברית"), .init(code: "fa", name: "فارسی"), .init(code: "da", name: "Dansk"),
        .init(code: "fi", name: "Suomi"), .init(code: "no", name: "Norsk"), .init(code: "hu", name: "Magyar"),
        .init(code: "ro", name: "Română"), .init(code: "bg", name: "Български"), .init(code: "bn", name: "বাংলা"),
        .init(code: "ta", name: "தமிழ்"), .init(code: "ur", name: "اردو"), .init(code: "fil", name: "Filipino"),
    ]

    static func name(for code: String) -> String {
        common.first { $0.code.lowercased() == code.lowercased() || $0.code.split(separator: "-").first.map(String.init) == code.lowercased() }?.name
            ?? Locale.current.localizedString(forLanguageCode: code) ?? code
    }
}

struct GoogleFreeProvider: TranslationProvider {
    let id = "google"
    let name = "Google 翻译"

    func translate(_ texts: [String], from source: String?, to target: String) async throws -> [String] {
        var components = URLComponents(string: "https://translate.googleapis.com/translate_a/t")!
        components.queryItems = [.init(name: "client", value: "gtx"), .init(name: "sl", value: source ?? "auto"),
                                 .init(name: "tl", value: target), .init(name: "dt", value: "t"), .init(name: "format", value: "text")]
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded;charset=UTF-8", forHTTPHeaderField: "Content-Type")
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: "&+=?#")
        request.httpBody = Data(texts.map { "q=" + ($0.addingPercentEncoding(withAllowedCharacters: allowed) ?? "") }.joined(separator: "&").utf8)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw RikuganError("Google 翻译返回 HTTP \(http.statusCode)") }
        let json = try JSONSerialization.jsonObject(with: data)
        func text(_ item: Any) -> String? {
            if let s = item as? String { return s }
            if let a = item as? [Any] { return a.first.flatMap(text) }
            return nil
        }
        if texts.count == 1, let single = text(json) { return [single] }
        guard let array = json as? [Any] else { throw RikuganError("无法解析翻译结果") }
        let results = array.compactMap(text)
        guard results.count == texts.count else { throw RikuganError("翻译结果数量不匹配") }
        return results
    }
}

/// Microsoft Translator via the Edge browser token (no key required).
actor MicrosoftEdgeProvider: TranslationProvider {
    nonisolated let id = "microsoft"
    nonisolated let name = "Microsoft 翻译"
    private var token: (value: String, expires: Date)?

    private func authToken() async throws -> String {
        if let token, token.expires > Date() { return token.value }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://edge.microsoft.com/translate/auth")!)
        let value = String(decoding: data, as: UTF8.self)
        guard value.count > 20 else { throw RikuganError("无法获取 Microsoft 翻译令牌") }
        token = (value, Date().addingTimeInterval(8 * 60))
        return value
    }

    static func code(_ code: String) -> String {
        switch code.lowercased() {
        case "zh-cn", "zh-hans", "zh": return "zh-Hans"
        case "zh-tw", "zh-hant", "zh-hk": return "zh-Hant"
        case "no": return "nb"
        default: return code
        }
    }

    func translate(_ texts: [String], from source: String?, to target: String) async throws -> [String] {
        let token = try await authToken()
        var components = URLComponents(string: "https://api-edge.cognitive.microsofttranslator.com/translate")!
        components.queryItems = [.init(name: "api-version", value: "3.0"), .init(name: "to", value: Self.code(target))]
        if let source, source != "auto" { components.queryItems?.append(.init(name: "from", value: Self.code(source))) }
        var request = URLRequest(url: components.url!, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: texts.map { ["Text": $0] })
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 { throw RikuganError("Microsoft 翻译返回 HTTP \(http.statusCode)") }
        guard let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { throw RikuganError("无法解析翻译结果") }
        return array.map { (($0["translations"] as? [[String: Any]])?.first?["text"] as? String) ?? "" }
    }
}

/// Self-hosted / third-party LibreTranslate-compatible server.
struct LibreTranslateProvider: TranslationProvider {
    let id = "libre"
    let name = "LibreTranslate（自定义服务器）"
    let server: String
    let apiKey: String

    func translate(_ texts: [String], from source: String?, to target: String) async throws -> [String] {
        guard let url = URL(string: server.hasSuffix("/translate") ? server : server.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/translate") else {
            throw RikuganError("翻译服务器地址无效")
        }
        var request = URLRequest(url: url, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = ["q": texts, "source": source ?? "auto", "target": target.split(separator: "-").first.map(String.init) ?? target, "format": "text"]
        if !apiKey.isEmpty { body["api_key"] = apiKey }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        if let list = json?["translatedText"] as? [String] { return list }
        if let single = json?["translatedText"] as? String { return [single] }
        throw RikuganError((json?["error"] as? String) ?? "翻译服务器返回错误")
    }
}

/// DeepL API (user supplied key).
struct DeepLProvider: TranslationProvider {
    let id = "deepl"
    let name = "DeepL（API Key）"
    let apiKey: String

    func translate(_ texts: [String], from source: String?, to target: String) async throws -> [String] {
        guard !apiKey.isEmpty else { throw RikuganError("请先在设置中填写 DeepL API Key") }
        let host = apiKey.hasSuffix(":fx") ? "https://api-free.deepl.com/v2/translate" : "https://api.deepl.com/v2/translate"
        var request = URLRequest(url: URL(string: host)!, timeoutInterval: 60)
        request.httpMethod = "POST"
        request.setValue("DeepL-Auth-Key \(apiKey)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let deeplTarget = target.lowercased().hasPrefix("zh") ? "ZH" : target.uppercased()
        request.httpBody = try JSONSerialization.data(withJSONObject: ["text": texts, "target_lang": deeplTarget])
        let (data, _) = try await URLSession.shared.data(for: request)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let list = json?["translations"] as? [[String: Any]] else { throw RikuganError((json?["message"] as? String) ?? "DeepL 返回错误") }
        return list.map { $0["text"] as? String ?? "" }
    }
}

@MainActor final class TranslationService {
    private let microsoft = MicrosoftEdgeProvider()

    static let providerOptions: [(id: String, name: String)] = [
        ("microsoft", "Microsoft 翻译"), ("google", "Google 翻译"), ("libre", "LibreTranslate（自定义服务器）"), ("deepl", "DeepL（API Key）"),
    ]

    var provider: TranslationProvider {
        let prefs = AppServices.shared.prefs
        switch prefs.translationProvider {
        case "microsoft": return microsoft
        case "libre": return LibreTranslateProvider(server: prefs.translationServerURL, apiKey: prefs.translationAPIKey)
        case "deepl": return DeepLProvider(apiKey: prefs.translationAPIKey)
        default: return GoogleFreeProvider()
        }
    }

    func detectLanguage(sample: String, declared: String?) -> String? {
        let recognizer = NLLanguageRecognizer()
        recognizer.processString(sample)
        if let language = recognizer.dominantLanguage, language != .undetermined {
            switch language {
            case .simplifiedChinese: return "zh-CN"
            case .traditionalChinese: return "zh-TW"
            default: return language.rawValue
            }
        }
        return declared.flatMap { $0.isEmpty ? nil : String($0.prefix(2)) }
    }

    func translate(_ texts: [String], from source: String?, to target: String) async throws -> [String] {
        do {
            return try await provider.translate(texts, from: source, to: target)
        } catch {
            // Fall back to the other free provider once before failing.
            let fallback: TranslationProvider = provider.id == "google" ? microsoft : GoogleFreeProvider()
            return try await fallback.translate(texts, from: source, to: target)
        }
    }
}

/// Page translation flow (keeps the page structure by translating text nodes in place).
@MainActor enum TranslationCoordinator {
    static func translate(_ tab: BrowserTab, target: String? = nil) {
        guard let webView = tab.webView else { return }
        let services = AppServices.shared
        let targetLanguage = target ?? services.prefs.translationTargetLanguage
        tab.translation = .translating(progress: 0)
        Task {
            let sample = await webView.rkTools("languageSample") as? [String: Any]
            let source = services.translator.detectLanguage(sample: sample?["sample"] as? String ?? "", declared: sample?["lang"] as? String)
            tab.translationSourceLanguage = source
            if let source, source.prefix(2) == targetLanguage.prefix(2), target == nil {
                tab.translation = .failed("页面已经是\(TranslationLanguage.name(for: targetLanguage))")
                return
            }
            guard let raw = await webView.rkTools("startTranslation") as? [[[String: Any]]], !raw.isEmpty else {
                tab.translation = .failed("没有可翻译的文本")
                return
            }
            var done = 0
            var failures = 0
            for batch in raw {
                let ids = batch.compactMap { $0["id"] as? Int }
                let texts = batch.compactMap { $0["text"] as? String }
                guard ids.count == texts.count else { continue }
                do {
                    let translated = try await services.translator.translate(texts, from: source, to: targetLanguage)
                    let payload = zip(ids, translated).map { ["id": $0.0, "text": $0.1] as [String: Any] }
                    _ = await webView.rkTools("applyTranslations", [payload])
                } catch {
                    failures += 1
                    if failures > 3 { tab.translation = .failed(error.localizedDescription); return }
                }
                done += 1
                tab.translation = .translating(progress: Double(done) / Double(raw.count))
            }
            tab.translation = .translated(showingOriginal: false)
        }
    }

    static func translateAdditional(_ batches: [[[String: Any]]], tab: BrowserTab) {
        guard case .translated(false) = tab.translation, let webView = tab.webView else { return }
        let services = AppServices.shared
        Task {
            for batch in batches {
                let ids = batch.compactMap { $0["id"] as? Int }
                let texts = batch.compactMap { $0["text"] as? String }
                guard ids.count == texts.count,
                      let translated = try? await services.translator.translate(texts, from: tab.translationSourceLanguage, to: services.prefs.translationTargetLanguage) else { continue }
                _ = await webView.rkTools("applyTranslations", [zip(ids, translated).map { ["id": $0.0, "text": $0.1] as [String: Any] }])
            }
        }
    }

    static func toggleOriginal(_ tab: BrowserTab) {
        guard case .translated(let showing) = tab.translation, let webView = tab.webView else { return }
        Task {
            _ = await webView.rkTools("showOriginal", [!showing])
            tab.translation = .translated(showingOriginal: !showing)
        }
    }

    static func stop(_ tab: BrowserTab) {
        guard let webView = tab.webView else { return }
        Task {
            _ = await webView.rkTools("stopTranslation")
            tab.translation = .idle
        }
    }

    static func autoTranslateIfNeeded(_ tab: BrowserTab) {
        let languages = AppServices.shared.prefs.autoTranslateLanguages
        guard !languages.isEmpty, tab.translation == .idle, let webView = tab.webView else { return }
        Task {
            let sample = await webView.rkTools("languageSample") as? [String: Any]
            guard let source = AppServices.shared.translator.detectLanguage(sample: sample?["sample"] as? String ?? "", declared: sample?["lang"] as? String),
                  languages.contains(where: { $0.prefix(2) == source.prefix(2) }) else { return }
            translate(tab)
        }
    }
}
