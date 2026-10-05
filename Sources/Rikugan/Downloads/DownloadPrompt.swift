import SwiftUI
import UIKit

/// "Save as" step before a user-initiated download: file name, destination, size and source.
@MainActor enum DownloadPrompt {
    struct Decision { let fileName: String; let exportToFiles: Bool }

    /// Whether a prompt should be shown (setting on, and no self-test is driving downloads).
    static var enabled: Bool { AppServices.shared.prefs.downloadConfirm && !SelfTestRunner.shared.running && !SelfTestRunner.autoRun }

    /// nil = cancelled by the user.
    static func ask(fileName: String, size: Int64, source: URL?, mime: String?) async -> Decision? {
        await withCheckedContinuation { continuation in
            var finished = false
            let finish: (Decision?) -> Void = { decision in
                guard !finished else { return }
                finished = true
                continuation.resume(returning: decision)
            }
            let view = DownloadConfirmView(initialName: fileName, size: size, source: source, mime: mime, finish: finish)
            let controller = UIHostingController(rootView: view)
            controller.modalPresentationStyle = .pageSheet
            if let sheet = controller.sheetPresentationController { sheet.detents = [.medium()]; sheet.prefersGrabberVisible = false }
            controller.presentationController?.delegate = DismissWatcher.shared
            DismissWatcher.shared.onDismiss[ObjectIdentifier(controller)] = { finish(nil) }
            Presenter.present(controller)
        }
    }

    /// Swipe-to-dismiss counts as cancel.
    final class DismissWatcher: NSObject, UIAdaptivePresentationControllerDelegate {
        static let shared = DismissWatcher()
        var onDismiss: [ObjectIdentifier: () -> Void] = [:]
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            let key = ObjectIdentifier(presentationController.presentedViewController)
            onDismiss.removeValue(forKey: key)?()
        }
    }
}

struct DownloadConfirmView: View {
    let initialName: String
    let size: Int64
    let source: URL?
    let mime: String?
    let finish: (DownloadPrompt.Decision?) -> Void
    @State private var name = ""
    @State private var toFiles = false
    @State private var alwaysAsk = true
    @Environment(\.dismiss) private var dismiss

    init(initialName: String, size: Int64, source: URL?, mime: String?, finish: @escaping (DownloadPrompt.Decision?) -> Void) {
        self.initialName = initialName
        self.size = size
        self.source = source
        self.mime = mime
        self.finish = finish
        _name = State(initialValue: initialName)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 12) {
                        Image(icon: DownloadRow.symbol(forFileName: name))
                            .font(.title2).foregroundStyle(.tint)
                            .frame(width: 44, height: 44)
                            .background(Theme.color.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        VStack(alignment: .leading, spacing: 2) {
                            TextField("文件名", text: $name)
                                .font(.headline)
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                                .accessibilityIdentifier("download-name")
                            Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
                        }
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Picker("保存位置", selection: $toFiles) {
                        Text("Rikugan 下载").tag(false)
                        Text("下载后选择…").tag(true)
                    }
                    Toggle("下载前总是询问", isOn: $alwaysAsk)
                } footer: {
                    Text(toFiles ? "下载完成后打开“文件”选择保存位置，下载列表中也保留一份。" : "“文件” › 我的 iPhone › Rikugan › Downloads")
                }
            }
            .navigationTitle("下载")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { close(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下载") { close(.init(fileName: cleaned, exportToFiles: toFiles)) }
                        .fontWeight(.semibold)
                        .disabled(cleaned.isEmpty)
                        .accessibilityIdentifier("download-confirm")
                }
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let host = source?.host { parts.append(host) }
        return parts.isEmpty ? (mime ?? "") : parts.joined(separator: " · ")
    }

    private var cleaned: String { name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "_") }

    private func close(_ decision: DownloadPrompt.Decision?) {
        if decision != nil && !alwaysAsk { AppServices.shared.prefs.downloadConfirm = false }
        finish(decision)
        dismiss()
    }
}
