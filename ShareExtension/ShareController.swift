import UIKit
import UniformTypeIdentifiers

@objc(ShareViewController)
public final class ShareViewController: UIViewController {
    private var items: [SharedItem] = []
    private let detail = UILabel()
    private var openButton = UIButton(type: .system)
    private var searchButton = UIButton(type: .system)
    private var loading: Task<Void, Never>?
    private var sending = false
    public override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        let title = UILabel(); title.text = "Rikugan"; title.font = .preferredFont(forTextStyle: .title2)
        detail.text = "正在读取分享内容…"; detail.numberOfLines = 0; detail.font = .preferredFont(forTextStyle: .subheadline)
        openButton = button("用 Rikugan 打开 / 安装脚本", action: #selector(openInApp))
        searchButton = button("在 Rikugan 中搜索", action: #selector(searchInApp))
        openButton.isEnabled = false; searchButton.isEnabled = false
        let stack = UIStackView(arrangedSubviews: [title, detail, openButton, searchButton, button("取消", action: #selector(cancel))])
        stack.axis = .vertical; stack.spacing = 16; stack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -24),
            stack.centerYAnchor.constraint(equalTo: view.centerYAnchor)
        ])
        let providers = (extensionContext?.inputItems as? [NSExtensionItem])?.flatMap { $0.attachments ?? [] } ?? []
        loading = Task { @MainActor [weak self] in
            do {
                let items = try await ShareInputReader.read(providers)
                guard !Task.isCancelled, let self else { return }
                self.items = items
                let scripts = items.filter { $0.kind == .script }.count
                self.detail.text = "\(items.count) 项内容" + (scripts > 0 ? "，其中 \(scripts) 个用户脚本。打开主 App 后逐个确认源码与权限，不会自动执行。" : "，按分享顺序打开。")
                self.openButton.isEnabled = true; self.searchButton.isEnabled = scripts == 0
            } catch { self?.detail.text = error.localizedDescription }
        }
    }
    private func button(_ title: String, action: Selector) -> UIButton {
        let button = UIButton(type: .system); button.setTitle(title, for: .normal)
        button.titleLabel?.font = .preferredFont(forTextStyle: .headline)
        button.addTarget(self, action: action, for: .touchUpInside); return button
    }
    @objc private func openInApp() { finish(items) }
    @objc private func searchInApp() {
        finish(items.map { var item = $0; item.kind = .search; return item })
    }
    @objc private func cancel() { loading?.cancel(); extensionContext?.cancelRequest(withError: CocoaError(.userCancelled)) }
    private func finish(_ values: [SharedItem]) {
        guard !sending, !values.isEmpty else { return }
        sending = true; openButton.isEnabled = false; searchButton.isEnabled = false
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.dandibbert.Rikugan") else {
            completeNotice("当前签名没有可用的 App Group，内容未发送。可复制内容后在主 App 中粘贴导入。", copy: values.map(\.value).joined(separator: "\n\n")); return
        }
        do { try ShareInbox(container: container).enqueue(SharedBatch(items: values)) }
        catch {
            completeNotice("未加入分享队列：\(error.localizedDescription)", copy: values.map(\.value).joined(separator: "\n\n")); return
        }
        extensionContext?.open(URL(string: "rikugan://pending")!) { [weak self] opened in
            DispatchQueue.main.async {
                guard let self else { return }
                if opened { self.extensionContext?.completeRequest(returningItems: nil) }
                else { self.completeNotice("已安全保存 \(values.count) 项内容，请打开 Rikugan 接收。脚本仍需在主 App 确认安装。", copy: nil) }
            }
        }
    }
    private func completeNotice(_ text: String, copy: String?) {
        let alert = UIAlertController(title: "Rikugan", message: text, preferredStyle: .alert)
        if let copy { alert.addAction(UIAlertAction(title: "复制并完成", style: .default) { _ in UIPasteboard.general.string = copy; self.extensionContext?.completeRequest(returningItems: nil) }) }
        alert.addAction(UIAlertAction(title: "完成", style: .cancel) { _ in self.extensionContext?.completeRequest(returningItems: nil) })
        present(alert, animated: true)
    }
}
