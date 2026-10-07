import SwiftUI
import UIKit

/// "Save as" step before a user-initiated download: file name, destination, size and source.
@MainActor enum DownloadPrompt {
    struct Decision { let fileName: String; let destination: DownloadLocation.Destination }

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
            if let sheet = controller.sheetPresentationController {
                sheet.detents = [.custom(identifier: .init("download")) { _ in 370 }]
                sheet.prefersGrabberVisible = true
                sheet.preferredCornerRadius = 28
            }
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
    @State private var destination = DownloadLocation.destination
    @State private var alwaysAsk = true
    @State private var pickingFolder = false
    @FocusState private var editingName: Bool
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
        VStack(spacing: 18) {
            HStack {
                Text("下载文件").font(.headline)
                Spacer()
                Button { close(nil) } label: {
                    Image(icon: "xmark").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        .frame(width: 30, height: 30).background(Color(.tertiarySystemFill), in: Circle())
                }
                .accessibilityLabel("取消")
            }
            HStack(spacing: 14) {
                Image(icon: DownloadRow.symbol(forFileName: name))
                    .font(.system(size: 26)).foregroundStyle(.tint)
                    .frame(width: 58, height: 58)
                    .background(Theme.color.opacity(0.14), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                VStack(alignment: .leading, spacing: 6) {
                    TextField("文件名", text: $name)
                        .font(.body.weight(.medium))
                        .focused($editingName)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .submitLabel(.done)
                        .padding(.horizontal, 10).frame(height: 36)
                        .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityIdentifier("download-name")
                    if !subtitle.isEmpty {
                        Text(subtitle).font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
            Menu {
                Picker("保存到", selection: $destination) {
                    Label("Rikugan 下载", icon: "arrow.down.circle").tag(DownloadLocation.Destination.rikugan)
                    if let folder = DownloadLocation.customFolderName {
                        Label(folder, icon: "folder").tag(DownloadLocation.Destination.custom)
                    }
                }
                Button { pickingFolder = true } label: { Label(DownloadLocation.customFolder == nil ? "选择文件夹…" : "更换文件夹…", icon: "folder") }
            } label: {
                HStack(spacing: 10) {
                    Image(icon: destination == .custom ? "folder" : "arrow.down.circle").foregroundStyle(.tint)
                    Text("保存到").foregroundStyle(.secondary)
                    Spacer()
                    Text(DownloadLocation.displayName(destination)).foregroundStyle(.primary).lineLimit(1)
                    Image(icon: "chevron.down").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
                .font(.subheadline)
                .padding(.horizontal, 14).frame(height: 46)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
            .accessibilityIdentifier("download-destination")
            Button { close(.init(fileName: cleaned, destination: destination)) } label: {
                Text("下载").font(.body.weight(.semibold)).frame(maxWidth: .infinity).frame(height: 32)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.roundedRectangle(radius: 14))
            .controlSize(.large)
            .disabled(cleaned.isEmpty)
            .accessibilityIdentifier("download-confirm")
            Toggle("每次下载前询问", isOn: $alwaysAsk).font(.footnote).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color(.systemBackground))
        .downloadFolderPicker(isPresented: $pickingFolder) { destination = .custom }
    }

    private var subtitle: String {
        var parts: [String] = []
        if size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        if let host = source?.host { parts.append(host) }
        return parts.isEmpty ? (mime ?? "") : parts.joined(separator: " · ")
    }

    private var cleaned: String { name.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "/", with: "_") }

    private func close(_ decision: DownloadPrompt.Decision?) {
        if let decision {
            DownloadLocation.destination = decision.destination
            if !alwaysAsk { AppServices.shared.prefs.downloadConfirm = false }
        }
        finish(decision)
        dismiss()
    }
}
