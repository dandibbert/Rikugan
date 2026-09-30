import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Open in Rikugan" / "Search in Rikugan" share extension.
///
/// Each share gets an ID and is appended to a FIFO inbox in the App Group container (when the build
/// is signed with `group.com.dandibbert.Rikugan`; `containerURL` tells whether it really is). The
/// extension then tries to open the app with `rikugan://…&shareID=<id>`; the app processes each ID
/// once, whichever of the URL and the inbox reaches it first. Opening the host app from an
/// extension is not an API Apple offers to share extensions, so the result is shown to the user:
/// when it fails the item waits in the inbox (or, without the App Group, is copied).
final class ShareViewController: UIViewController {
    static let appGroup = "group.com.dandibbert.Rikugan"
    static let inboxKey = "pendingShares"
    private var sharedURL: URL?
    private var sharedText: String?
    private var host: UIHostingController<ShareSheetView>?
    private let status = ShareStatus()

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
        let view = ShareSheetView(url: sharedURL, text: sharedText, status: status,
                                  open: { [weak self] in self?.handOff(kind: "open") },
                                  search: { [weak self] in self?.handOff(kind: "search") },
                                  cancel: { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) })
        let host = UIHostingController(rootView: view)
        self.host = host
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
        let shareID = UUID().uuidString
        components.queryItems = (components.queryItems ?? []) + [URLQueryItem(name: "shareID", value: shareID)]
        guard let target = components.url else { return }
        let queued = enqueue(id: shareID, url: target)
        openHostApp(target) { [weak self] opened in
            guard let self else { return }
            if opened { self.extensionContext?.completeRequest(returningItems: nil); return }
            if queued {
                self.status.message = "无法直接打开 Rikugan。内容已保存，下次打开 Rikugan 时会自动打开。"
            } else {
                UIPasteboard.general.string = self.sharedURL?.absoluteString ?? self.sharedText
                self.status.message = "无法直接打开 Rikugan，也无法保存（未配置 App Group）。内容已拷贝到剪贴板，请打开 Rikugan 后粘贴。"
            }
        }
    }

    /// Appends to the App Group inbox. False when the group container is not available (unsigned
    /// or signed without the App Group), in which case nothing is written.
    private func enqueue(id: String, url: URL) -> Bool {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) != nil,
              let defaults = UserDefaults(suiteName: Self.appGroup) else { return false }
        var inbox = defaults.array(forKey: Self.inboxKey) as? [[String: Any]] ?? []
        inbox.append(["id": id, "url": url.absoluteString, "date": Date().timeIntervalSince1970])
        defaults.set(inbox, forKey: Self.inboxKey)
        return true
    }

    /// Extensions cannot call UIApplication.open directly; walk the responder chain to the
    /// application object and invoke `openURL:options:completionHandler:` dynamically, reporting
    /// the system's answer (false when no application object is reachable).
    private func openHostApp(_ url: URL, completion: @escaping (Bool) -> Void) {
        let selector = NSSelectorFromString("openURL:options:completionHandler:")
        var responder: UIResponder? = self
        while let current = responder {
            if NSStringFromClass(type(of: current)).contains("UIApplication"), current.responds(to: selector) {
                typealias OpenFn = @convention(c) (AnyObject, Selector, NSURL, NSDictionary, (@convention(block) (Bool) -> Void)?) -> Void
                let implementation = current.method(for: selector)
                let function = unsafeBitCast(implementation, to: OpenFn.self)
                let done: @convention(block) (Bool) -> Void = { success in DispatchQueue.main.async { completion(success) } }
                function(current, selector, url as NSURL, NSDictionary(), done)
                return
            }
            responder = current.next
        }
        completion(false)
    }
}

final class ShareStatus: ObservableObject {
    @Published var message: String?
}

struct ShareSheetView: View {
    let url: URL?
    let text: String?
    @ObservedObject var status: ShareStatus
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
                if let message = status.message {
                    Label(message, systemImage: "exclamationmark.triangle").font(.footnote)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button(action: cancel) { Text("好").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                } else if url != nil {
                    Button(action: open) { Label("在 Rikugan 中打开", systemImage: "safari").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
                if status.message == nil, text != nil || url != nil {
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
