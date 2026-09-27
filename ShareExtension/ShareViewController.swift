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
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let payload = ["action": action, "url": pageURL?.absoluteString ?? "", "text": value]
        var queued = false
        if let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.dandibbert.Rikugan") {
            let file = container.appendingPathComponent("share-inbox.json")
            do {
                try JSONSerialization.data(withJSONObject: payload).write(to: file, options: .atomic)
                queued = true
            } catch { queued = false }
        }
        var parts = URLComponents()
        parts.scheme = "rikugan"
        parts.host = queued ? "pending" : action
        if !queued { parts.queryItems = [URLQueryItem(name: "action", value: action), URLQueryItem(name: "text", value: value)] }
        guard let url = parts.url else { extensionContext?.completeRequest(returningItems: nil); return }
        let saved = queued
        extensionContext?.open(url) { opened in
            DispatchQueue.main.async {
                if opened { self.extensionContext?.completeRequest(returningItems: nil); return }
                let message = saved
                    ? "已保存到待打开列表，请手动打开 Rikugan 接收。iOS 不允许此分享面板直接启动主 App。"
                    : "当前签名没有可用的 App Group，且 iOS 未允许直接启动主 App。可复制内容后打开 Rikugan。"
                let alert = UIAlertController(title: saved ? "内容已保存" : "未发送到 Rikugan", message: message, preferredStyle: .alert)
                alert.addAction(UIAlertAction(title: saved ? "完成" : "复制并完成", style: .default) { _ in
                    if !saved { UIPasteboard.general.string = value }
                    self.extensionContext?.completeRequest(returningItems: nil)
                })
                self.present(alert, animated: true)
            }
        }
    }
}
