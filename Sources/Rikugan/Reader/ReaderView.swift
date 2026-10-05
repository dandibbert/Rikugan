import SwiftUI
import WebKit

/// Reader mode (spec §24): article extraction and a clean re-rendering with font / size /
/// line-height / background / theme settings.
struct ReaderView: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var fonts: FontManager
    @Environment(\.dismiss) private var dismiss
    @State private var article: [String: Any]?
    @State private var failed = false
    @StateObject private var holder = ReaderWebViewHolder()

    private let themes: [(id: String, name: String)] = [("auto", "自动"), ("light", "浅色"), ("sepia", "米色"), ("gray", "灰色"), ("dark", "深色")]

    var body: some View {
        NavigationStack {
            Group {
                if failed {
                    VStack(spacing: 12) {
                        Image(icon: "doc.plaintext").font(.largeTitle).foregroundStyle(.secondary)
                        Text("此页面无法使用阅读模式").foregroundStyle(.secondary)
                    }
                } else if article == nil {
                    ProgressView()
                } else {
                    PlainWebView(webView: holder.webView)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("阅读模式")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Section("字号") {
                            Button { services.prefs.readerFontSize = max(12, services.prefs.readerFontSize - 1); render() } label: { Label("缩小", icon: "textformat.size.smaller") }
                            Button { services.prefs.readerFontSize = min(34, services.prefs.readerFontSize + 1); render() } label: { Label("放大", icon: "textformat.size.larger") }
                        }
                        Picker("行距", selection: Binding(get: { services.prefs.readerLineHeight }, set: { services.prefs.readerLineHeight = $0; render() })) {
                            Text("紧凑").tag(1.4); Text("标准").tag(1.7); Text("宽松").tag(2.0)
                        }
                        Picker("字体", selection: Binding(get: { services.prefs.readerFontFamily }, set: { services.prefs.readerFontFamily = $0; render() })) {
                            Text("系统").tag("-apple-system")
                            Text("衬线（宋体）").tag("Songti SC, Georgia, serif")
                            Text("New York").tag("ui-serif")
                            Text("圆体").tag("ui-rounded")
                            ForEach(fonts.imported) { Text($0.family).tag($0.family) }
                            if services.prefs.webFontEnabled && !services.prefs.webFontFamily.isEmpty { Text(services.prefs.webFontFamily).tag(services.prefs.webFontFamily) }
                        }
                        Picker("背景", selection: Binding(get: { services.prefs.readerTheme }, set: { services.prefs.readerTheme = $0; render() })) {
                            ForEach(Array(themes.enumerated()), id: \.offset) { _, theme in Text(theme.name).tag(theme.id) }
                        }
                    } label: { Image(icon: "textformat.size") }
                }
            }
        }
        .task { await load() }
    }

    private func load() async {
        guard let webView = tab.webView, let result = await webView.rkTools("extractReader") as? [String: Any],
              (result["length"] as? Int ?? 0) > 200 else { failed = true; return }
        article = result
        render()
    }

    private func render() {
        guard let article else { return }
        let prefs = services.prefs
        let (bg, fg) = colors(prefs.readerTheme)
        let fontFace = fonts.importedFont(family: prefs.readerFontFamily).flatMap { font -> String? in
            guard let data = try? Data(contentsOf: font.fileURL) else { return nil }
            return "@font-face { font-family: '\(font.family)'; src: url(data:font/\(font.fileURL.pathExtension);base64,\(data.base64EncodedString())); }"
        } ?? ""
        let title = escape(article["title"] as? String ?? "")
        let meta = [article["byline"] as? String, article["siteName"] as? String].compactMap { $0 }.filter { !$0.isEmpty }.map(escape).joined(separator: " · ")
        let html = """
        <!doctype html><html lang="\(escape(article["lang"] as? String ?? ""))"><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <style>
        \(fontFace)
        :root { color-scheme: \(prefs.readerTheme == "dark" ? "dark" : "light dark"); }
        body { margin: 0; padding: 24px 20px 80px; background: \(bg); color: \(fg); font-family: \(prefs.readerFontFamily.contains(",") || prefs.readerFontFamily.hasPrefix("-") || prefs.readerFontFamily.hasPrefix("ui-") ? prefs.readerFontFamily : "'\(prefs.readerFontFamily)'"), -apple-system, sans-serif;
               font-size: \(prefs.readerFontSize)px; line-height: \(prefs.readerLineHeight); -webkit-text-size-adjust: 100%; }
        \(prefs.readerTheme == "auto" ? "@media (prefers-color-scheme: dark) { body { background: #1c1c1e; color: #e5e5e7; } a { color: #64a8ff; } }" : "")
        article { max-width: 720px; margin: 0 auto; }
        h1 { font-size: 1.6em; line-height: 1.25; margin: 0 0 .4em; }
        .meta { opacity: .6; font-size: .8em; margin-bottom: 2em; }
        img, video, figure { max-width: 100%; height: auto; border-radius: 6px; }
        figure { margin: 1.2em 0; } figcaption { font-size: .8em; opacity: .7; }
        pre, code { font-family: ui-monospace, Menlo, monospace; font-size: .85em; white-space: pre-wrap; word-break: break-word; }
        pre { background: rgba(127,127,127,.12); padding: 12px; border-radius: 8px; }
        blockquote { margin: 1em 0; padding-left: 1em; border-left: 3px solid rgba(127,127,127,.4); opacity: .85; }
        a { color: #0a66d6; } table { border-collapse: collapse; max-width: 100%; display: block; overflow-x: auto; } td, th { border: 1px solid rgba(127,127,127,.3); padding: 4px 8px; }
        </style></head><body><article><h1>\(title)</h1><div class="meta">\(meta)</div>\(article["html"] as? String ?? "")</article></body></html>
        """
        holder.webView.loadHTMLString(html, baseURL: URL(string: article["url"] as? String ?? ""))
    }

    private func colors(_ theme: String) -> (String, String) {
        switch theme {
        case "sepia": return ("#f4ecd8", "#5b4636")
        case "gray": return ("#4a4a4d", "#e8e8ea")
        case "dark": return ("#1c1c1e", "#e5e5e7")
        default: return ("#ffffff", "#1d1d1f")
        }
    }

    private func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }
}

@MainActor final class ReaderWebViewHolder: NSObject, ObservableObject, WKNavigationDelegate {
    let webView: WKWebView

    override init() {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        webView = RikuganWebView(frame: .zero, configuration: configuration, purpose: "reader")
        super.init()
        webView.navigationDelegate = self
        webView.isOpaque = false
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if navigationAction.navigationType == .linkActivated, let url = navigationAction.request.url {
            TabRegistry.shared.focusedWindow?.activeTab?.load(url)
            decisionHandler(.cancel)
        } else {
            decisionHandler(.allow)
        }
    }
}
