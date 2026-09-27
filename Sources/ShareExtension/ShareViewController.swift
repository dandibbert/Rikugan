import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Open in Rikugan" / "Search in Rikugan" share extension. Hands the item to the main app through
/// the `rikugan://` URL scheme. A copy is also written to the App Group container (when the build
/// is signed with the `group.com.dandibbert.Rikugan` group) so the app can pick it up if the
/// system refuses to open the host app from the extension.
final class ShareViewController: UIViewController {
    static let appGroup = "group.com.dandibbert.Rikugan"
    private var sharedURL: URL?
    private var sharedText: String?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .clear
        Task { await loadItems(); presentUI() }
    }

    private func loadItems() async {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        for item in items {
            for provider in item.attachments ?? [] {
                if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
                   let url = try? await provider.loadItem(forTypeIdentifier: UTType.url.identifier) as? URL {
                    if url.isFileURL == false { sharedURL = url }
                }
                if sharedText == nil, provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier),
                   let text = try? await provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) as? String {
                    sharedText = text
                }
            }
            if sharedText == nil, let text = item.attributedContentText?.string, !text.isEmpty { sharedText = text }
        }
        if sharedURL == nil, let text = sharedText?.trimmingCharacters(in: .whitespacesAndNewlines),
           let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue),
           let match = detector.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           match.range.length == (text as NSString).length, let url = match.url {
            sharedURL = url
        }
    }

    private func presentUI() {
        let view = ShareSheetView(url: sharedURL, text: sharedText,
                                  open: { [weak self] in self?.handOff(kind: "open") },
                                  search: { [weak self] in self?.handOff(kind: "search") },
                                  cancel: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) })
        let host = UIHostingController(rootView: view)
        host.view.backgroundColor = .clear
        addChild(host)
        host.view.frame = self.view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        self.view.addSubview(host.view)
        host.didMove(toParent: self)
    }

    private func handOff(kind: String) {
        var components = URLComponents()
        components.scheme = "rikugan"
        components.host = kind
        if kind == "open", let url = sharedURL {
            components.queryItems = [URLQueryItem(name: "url", value: url.absoluteString)]
        } else {
            let query = sharedText ?? sharedURL?.absoluteString ?? ""
            components.queryItems = [URLQueryItem(name: "q", value: query)]
        }
        guard let target = components.url else { return }
        if let defaults = UserDefaults(suiteName: Self.appGroup) {
            defaults.set(target.absoluteString, forKey: "pendingShare")
            defaults.set(Date().timeIntervalSince1970, forKey: "pendingShareDate")
        }
        let opened = openHostApp(target)
        if !opened { UIPasteboard.general.string = sharedURL?.absoluteString ?? sharedText }
        extensionContext?.completeRequest(returningItems: nil)
    }

    /// Extensions cannot call UIApplication.open directly; walk the responder chain to the
    /// application object and invoke `openURL:options:completionHandler:` dynamically.
    private func openHostApp(_ url: URL) -> Bool {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if NSStringFromClass(type(of: current)).contains("UIApplication"), current.responds(to: selector) {
                typealias OpenFn = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let implementation = current.method(for: selector)
                let function = unsafeBitCast(implementation, to: OpenFn.self)
                function(current, selector, url as NSURL, NSDictionary(), nil)
                return true
            }
            responder = current.next
        }
        return false
    }
}

struct ShareSheetView: View {
    let url: URL?
    let text: String?
    let open: () -> Void
    let search: () -> Void
    let cancel: () -> Void

    var body: some View {
        VStack {
            Spacer()
            VStack(spacing: 14) {
                HStack {
                    Image(systemName: "eye.circle.fill").font(.title).foregroundStyle(.tint)
                    Text("Rikugan").font(.headline)
                    Spacer()
                    Button("取消", action: cancel)
                }
                Text(url?.absoluteString ?? text ?? "没有可分享的内容")
                    .font(.footnote).foregroundStyle(.secondary).lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if url != nil {
                    Button(action: open) { Label("在 Rikugan 中打开", systemImage: "safari").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
                if text != nil || url != nil {
                    Button(action: search) { Label("在 Rikugan 中搜索", systemImage: "magnifyingglass").frame(maxWidth: .infinity) }
                        .buttonStyle(.bordered).controlSize(.large)
                }
            }
            .padding(20)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .padding()
        }
    }
}
