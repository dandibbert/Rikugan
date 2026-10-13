import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// "Open the copied link" on the start page and in the address-bar overlay.
///
/// Uses the system PasteButton: reading the pasteboard through it needs no "Allow Paste" prompt.
/// Before that, the pasteboard is only *inspected* (pattern detection, which reads no content and
/// shows no prompt) to decide whether to offer a link or a search.
@MainActor final class PasteboardProbe: ObservableObject {
    enum Kind { case none, link, text }
    @Published private(set) var kind: Kind = .none
    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        for name in [UIPasteboard.changedNotification, UIApplication.didBecomeActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func refresh() {
        let board = UIPasteboard.general
        guard board.hasURLs || board.hasStrings else { kind = .none; return }
        if board.hasURLs { kind = .link; return }
        board.detectPatterns(for: [.probableWebURL]) { [weak self] result in
            let isLink = (try? result.get())?.contains(.probableWebURL) ?? false
            Task { @MainActor in self?.kind = isLink ? .link : .text }
        }
    }
}

/// Takes what was pasted: a URL is opened, other text is searched.
@MainActor enum PasteAndGo {
    static func open(_ strings: [String], in tab: BrowserTab?, manager: TabManager) {
        guard let text = strings.first?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return }
        let target = tab ?? manager.newTab()
        target.loadInput(text)
    }
}

/// The system paste button (no "Allow Paste" prompt). Links copied from Safari and many apps are
/// on the pasteboard only as a URL, not as text: a String-only paste button received nothing for
/// them, so the button accepts URLs as well as text.
struct PasteAndGoButton: View {
    let onPaste: ([String]) -> Void

    var body: some View {
        PasteButton(supportedContentTypes: [.url, .plainText, .text]) { providers in
            Task { @MainActor in
                var strings: [String] = []
                for provider in providers {
                    if let text = await Self.load(provider) { strings.append(text) }
                }
                if strings.isEmpty {
                    ToastCenter.shared.show("剪贴板里没有可打开的链接或文字", symbol: "exclamationmark.triangle")
                } else {
                    onPaste(strings)
                }
            }
        }
    }

    private static func load(_ provider: NSItemProvider) async -> String? {
        if provider.canLoadObject(ofClass: URL.self),
           let url = await withCheckedContinuation({ (c: CheckedContinuation<URL?, Never>) in
               _ = provider.loadObject(ofClass: URL.self) { url, _ in c.resume(returning: url) }
           }) {
            return url.absoluteString
        }
        if provider.canLoadObject(ofClass: NSString.self),
           let text = await withCheckedContinuation({ (c: CheckedContinuation<String?, Never>) in
               _ = provider.loadObject(ofClass: NSString.self) { value, _ in c.resume(returning: value as? String) }
           }) {
            return text
        }
        return nil
    }
}

/// Row for the address-bar overlay's suggestion list.
struct PasteAndGoRow: View {
    @StateObject private var probe = PasteboardProbe()
    let onPaste: ([String]) -> Void

    var body: some View {
        if probe.kind != .none {
            HStack(spacing: 12) {
                Image(icon: probe.kind == .link ? "link" : "magnifyingglass").foregroundStyle(.secondary).frame(width: 22)
                Text(probe.kind == .link ? "打开拷贝的链接" : "搜索拷贝的文字").foregroundStyle(.primary)
                Spacer()
                PasteAndGoButton(onPaste: onPaste)
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
            .accessibilityIdentifier("pasteAndGo")
        }
    }
}

/// Compact version for the start page, under the search field.
struct PasteAndGoChip: View {
    @StateObject private var probe = PasteboardProbe()
    let onPaste: ([String]) -> Void

    var body: some View {
        if probe.kind != .none {
            HStack(spacing: 10) {
                Image(icon: probe.kind == .link ? "link" : "magnifyingglass").foregroundStyle(.tint)
                Text(probe.kind == .link ? "打开拷贝的链接" : "搜索拷贝的文字").font(.subheadline)
                Spacer(minLength: 8)
                PasteAndGoButton(onPaste: onPaste)
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .controlSize(.small)
            }
            .padding(.leading, 14).padding(.trailing, 8)
            .frame(height: 44)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .frame(maxWidth: 600)
            .padding(.horizontal)
            .accessibilityIdentifier("pasteAndGoChip")
        }
    }
}
