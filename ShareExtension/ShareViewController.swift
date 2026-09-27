import UIKit
import UniformTypeIdentifiers

/// Share extension. The App Group id must match the main app. Unsigned builds do not
/// activate the group until the IPA is re-signed with a profile that contains it.
@objc(ShareViewController)
public final class ShareViewController: UIViewController {
    private var pageURL: URL?
    private var text = ""
    private var ready = false
    private var openButton: UIButton?
    private var searchButton: UIButton?
    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel()
        title.text = "Rikugan"
        title.font = .preferredFont(forTextStyle: .title2)
        let open = button("用 Rikugan 打开", action: #selector(openInApp))
        let search = button("在 Rikugan 中搜索", action: #selector(searchInApp))
        open.isEnabled = false
        search.isEnabled = false
        openButton = open
        searchButton = search
        let cancel = button("取消", action: #selector(cancel))
        let stack = UIStackView(arrangedSubviews: [title, open, search, cancel])
        stack.axis = .vertical
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        loadInput()
    }
    private func button(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system)
        button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.addTarget(self, action: action, for: .touchUpInside)
        return button
    }
    private func loadInput() {
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        let group = DispatchGroup()
        for provider in providers {
            if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.url.identifier) { item, _ in
                    let url = item as? URL ?? (item as? NSURL).map { $0 as URL }
                    DispatchQueue.main.async {
                        if let url { self.pageURL = url }
                        group.leave()
                    }
                }
            } else if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                group.enter()
                provider.loadItem(forTypeIdentifier: UTType.plainText.identifier) { item, _ in
                    let value = item as? String
                    DispatchQueue.main.async {
                        if let value { self.text = value }
                        group.leave()
                    }
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            self?.ready = true
            self?.openButton?.isEnabled = true
            self?.searchButton?.isEnabled = true
        }
    }
    @objc private func openInApp() {
        guard ready else { return }
        finish(action: "open", value: pageURL?.absoluteString ?? text)
    }
    @objc private func searchInApp() {
        guard ready else { return }
        finish(action: "search", value: text.isEmpty ? (pageURL?.absoluteString ?? "") : text)
    }
    @objc private func cancel() { extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)) }
    private func finish(action: String, value: String) {
        let payload = ["action": action, "url": pageURL?.absoluteString ?? "", "text": value]
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.dandibbert.Rikugan") {
            let file = container.appendingPathComponent("share-inbox.json")
            try? JSONSerialization.data(withJSONObject: payload).write(to: file)
        }
        var parts = URLComponents()
        parts.scheme = "rikugan"
        parts.host = value.count > 1500 ? "pending" : action
        if value.count <= 1500 { parts.queryItems = [URLQueryItem(name: "action", value: action), URLQueryItem(name: "text", value: value)] }
        guard let url = parts.url else { extensionContext?.completeRequest(returningItems: nil); return }
        extensionContext?.open(url) { _ in self.extensionContext?.completeRequest(returningItems: nil) }
    }
}
