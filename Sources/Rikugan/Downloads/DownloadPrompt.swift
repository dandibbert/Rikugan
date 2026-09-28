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
            if let sheet = controller.sheetPresentationController { sheet.detents = [.medium(), .large()]; sheet.prefersGrabberVisible = true }
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
    @State private var dontAsk = false
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
                Section("文件名") {
                    TextField("文件名", text: $name)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .accessibilityIdentifier("download-name")
                }
                Section {
                    Picker("保存到", selection: $toFiles) {
                        Text("Rikugan 下载文件夹").tag(false)
                        Text("完成后选择位置（“文件”）").tag(true)
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                } header: { Text("保存到") } footer: {
                    Text(toFiles ? "下载完成后会打开“文件”让你选择保存位置；下载管理中仍保留一份。" : "位于“文件” → 我的 iPhone → Rikugan → Downloads。")
                }
                Section {
                    if size > 0 { LabeledContent("大小", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
                    if let mime, !mime.isEmpty { LabeledContent("类型", value: mime) }
                    if let host = source?.host { LabeledContent("来源", value: host) }
                }
                Section {
                    Toggle("以后不再询问，直接下载", isOn: $dontAsk)
                } footer: { Text("可在 设置 → 媒体与下载 中重新打开。") }
            }
            .navigationTitle("下载文件")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { close(nil) } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("下载") { close(.init(fileName: cleaned, exportToFiles: toFiles)) }
                        .disabled(cleaned.isEmpty)
                        .accessibilityIdentifier("download-confirm")
                }
            }
        }
    }

    private var cleaned: String { name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "_") }

    private func close(_ decision: DownloadPrompt.Decision?) {
        if decision != nil && dontAsk { AppServices.shared.prefs.downloadConfirm = false }
        finish(decision)
        dismiss()
    }
}
