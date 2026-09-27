import SwiftUI
import WebKit

/// Hosts the active tab's long-lived WKWebView. Switching tabs swaps the subview; web views are
/// never recreated, so page state is preserved (spec §3.1).
struct WebViewContainer: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> ContainerView {
        let view = ContainerView()
        view.show(webView)
        return view
    }

    func updateUIView(_ uiView: ContainerView, context: Context) {
        uiView.show(webView)
    }

    final class ContainerView: UIView {
        private weak var current: WKWebView?

        func show(_ webView: WKWebView) {
            guard current !== webView else { return }
            current?.removeFromSuperview()
            webView.removeFromSuperview()
            webView.translatesAutoresizingMaskIntoConstraints = false
            addSubview(webView)
            NSLayoutConstraint.activate([
                webView.leadingAnchor.constraint(equalTo: leadingAnchor),
                webView.trailingAnchor.constraint(equalTo: trailingAnchor),
                webView.topAnchor.constraint(equalTo: topAnchor),
                webView.bottomAnchor.constraint(equalTo: bottomAnchor),
            ])
            current = webView
        }
    }
}

/// Generic web view for extension popups / options pages.
struct PlainWebView: UIViewRepresentable {
    let webView: WKWebView
    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}
