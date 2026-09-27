import SwiftUI
import WebKit

@MainActor final class WindowRegistry: ObservableObject {
    @Published var pages: [UUID: AuxiliaryPage] = [:]
    @discardableResult func open(store: WKWebsiteDataStore, extensions: WKWebExtensionController?, url: URL?) -> UUID {
        let id = UUID()
        pages[id] = AuxiliaryPage(id: id, store: store, extensions: extensions, url: url)
        return id
    }
}

@MainActor final class AuxiliaryPage: NSObject, ObservableObject, WKNavigationDelegate {
    let id: UUID
    let webView: WKWebView
    @Published var address: String
    @Published var title = "新窗口"

    init(id: UUID, store: WKWebsiteDataStore, extensions: WKWebExtensionController?, url: URL?) {
        self.id = id
        address = url?.absoluteString ?? ""
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        if let extensions { configuration.webExtensionController = extensions }
        configuration.allowsInlineMediaPlayback = true
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        if let url { webView.load(URLRequest(url: url)) }
    }

    func load(_ text: String) {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        address = url.absoluteString
        webView.load(URLRequest(url: url))
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        address = webView.url?.absoluteString ?? address
        if let title = webView.title, !title.isEmpty { self.title = title }
    }
}

struct AuxiliaryBrowserView: View {
    @EnvironmentObject var model: AppModel
    var windowID: UUID?
    var body: some View {
        if let windowID, let page = model.windows.pages[windowID] {
            AuxiliaryPageView(page: page)
        } else {
            ContentUnavailableView("这个窗口没有自己的页面", systemImage: "macwindow", description: Text("新窗口使用单独的 WKWebView 打开网址，不会把当前标签的网页视图挪走。"))
        }
    }
}

struct AuxiliaryPageView: View {
    @ObservedObject var page: AuxiliaryPage
    @State private var input = ""
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button { page.webView.goBack() } label: { Image(systemName: "chevron.left") }.disabled(!page.webView.canGoBack)
                TextField("这个窗口的网址", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { page.load(input) }
                Button("打开") { page.load(input) }
            }.padding(10)
            WebSurface(webView: page.webView)
        }
        .onAppear { if input.isEmpty { input = page.address } }
        .onChange(of: page.address) { _, value in input = value }
        .navigationTitle(page.title)
    }
}
