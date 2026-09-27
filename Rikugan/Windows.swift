import SwiftUI
import WebKit

@MainActor final class WindowRegistry: ObservableObject {
    @Published var sessions: [UUID: WindowSession] = [:]
    @discardableResult func open(store: WKWebsiteDataStore, extensions: WKWebExtensionController?, url: URL?) -> UUID {
        let session = WindowSession(store: store, extensions: extensions)
        session.addTab(url: url, select: true)
        sessions[session.id] = session
        return session.id
    }
}

@MainActor final class WindowTab: ObservableObject, Identifiable {
    let id = UUID()
    let webView: WKWebView
    @Published var title = "新标签"
    @Published var address = ""
    @Published var canGoBack = false
    @Published var canGoForward = false
    @Published var loading = false

    init(webView: WKWebView, url: URL?) {
        self.webView = webView
        address = url?.absoluteString ?? ""
        if let url { webView.load(URLRequest(url: url)) }
    }

    func sync() {
        address = webView.url?.absoluteString ?? address
        if let pageTitle = webView.title, !pageTitle.isEmpty { title = pageTitle }
        canGoBack = webView.canGoBack
        canGoForward = webView.canGoForward
        loading = webView.isLoading
    }
}

@MainActor final class WindowSession: NSObject, ObservableObject, WKNavigationDelegate {
    let id = UUID()
    let store: WKWebsiteDataStore
    let extensions: WKWebExtensionController?
    @Published var tabs: [WindowTab] = []
    @Published var selectedID: UUID?

    init(store: WKWebsiteDataStore, extensions: WKWebExtensionController?) {
        self.store = store
        self.extensions = extensions
    }

    var active: WindowTab? { tabs.first { $0.id == selectedID } ?? tabs.first }

    @discardableResult func addTab(url: URL?, select: Bool) -> WindowTab {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = store
        if let extensions { configuration.webExtensionController = extensions }
        configuration.allowsInlineMediaPlayback = true
        let webView = WKWebView(frame: .zero, configuration: configuration)
        let tab = WindowTab(webView: webView, url: url)
        webView.navigationDelegate = self
        webView.allowsBackForwardNavigationGestures = true
        tabs.append(tab)
        if select || selectedID == nil { selectedID = tab.id }
        return tab
    }

    func select(_ id: UUID) { selectedID = id }

    func close(_ id: UUID) {
        tabs.removeAll { $0.id == id }
        if selectedID == id { selectedID = tabs.last?.id }
    }

    func load(_ text: String) {
        guard let tab = active else { return }
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: value), let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else { return }
        tab.address = url.absoluteString
        tab.webView.load(URLRequest(url: url))
    }

    private func tab(for webView: WKWebView) -> WindowTab? { tabs.first { $0.webView === webView } }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        tab(for: webView)?.loading = true
        objectWillChange.send()
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { tab(for: webView)?.sync(); objectWillChange.send() }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { tab(for: webView)?.sync(); objectWillChange.send() }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { tab(for: webView)?.sync(); objectWillChange.send() }
}

struct AuxiliaryBrowserView: View {
    @EnvironmentObject var model: AppModel
    var windowID: UUID?
    var body: some View {
        if let windowID, let session = model.windows.sessions[windowID] {
            WindowBrowserView(session: session)
        } else {
            ContentUnavailableView("这个窗口没有自己的页面", systemImage: "macwindow", description: Text("新窗口有自己的标签、地址栏和前进后退，不会把当前标签的网页视图挪走。"))
        }
    }
}

struct WindowBrowserView: View {
    @ObservedObject var session: WindowSession
    @State private var input = ""
    var body: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(session.tabs) { tab in
                        WindowTabChip(tab: tab, selected: tab.id == session.active?.id) { session.select(tab.id) } close: { session.close(tab.id) }
                    }
                    Button { session.addTab(url: nil, select: true); input = "" } label: { Image(systemName: "plus") }
                        .accessibilityLabel("这个窗口的新标签")
                }.padding(.horizontal, 10).padding(.vertical, 8)
            }
            HStack {
                Button { session.active?.webView.goBack() } label: { Image(systemName: "chevron.left") }
                    .disabled(session.active?.canGoBack != true).accessibilityLabel("后退")
                Button { session.active?.webView.goForward() } label: { Image(systemName: "chevron.right") }
                    .disabled(session.active?.canGoForward != true).accessibilityLabel("前进")
                TextField("这个窗口的网址", text: $input)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .onSubmit { session.load(input) }
                Button(session.active?.loading == true ? "停止" : "刷新") {
                    if session.active?.loading == true { session.active?.webView.stopLoading() } else { session.active?.webView.reload() }
                }
                Button("打开") { session.load(input) }
            }.padding(10)
            if let tab = session.active {
                WebSurface(webView: tab.webView)
            } else {
                ContentUnavailableView("没有标签", systemImage: "plus", description: Text("点加号打开这个窗口里的新标签。"))
            }
        }
        .onAppear { input = session.active?.address ?? "" }
        .onChange(of: session.selectedID) { _, _ in input = session.active?.address ?? "" }
        .onChange(of: session.active?.address ?? "") { _, value in if !value.isEmpty { input = value } }
        .navigationTitle(session.active?.title ?? "新窗口")
    }
}

private struct WindowTabChip: View {
    @ObservedObject var tab: WindowTab
    var selected: Bool
    var select: () -> Void
    var close: () -> Void
    var body: some View {
        HStack(spacing: 4) {
            Button(tab.title) { select() }.font(.subheadline.weight(selected ? .bold : .regular)).lineLimit(1)
            Button(action: close) { Image(systemName: "xmark").font(.caption2) }.accessibilityLabel("关闭标签")
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(selected ? Color.accentColor.opacity(0.15) : Color.clear, in: Capsule())
    }
}
