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

/// Paste-and-go inside a search field (start page, address-bar overlay), like Safari: a small
/// theme-coloured "Paste" capsule at the trailing edge, shown only while the field is empty and
/// the pasteboard holds a link or text. One tap opens the link (or searches the text).
struct PasteAndGoInline: View {
    @StateObject private var probe = PasteboardProbe()
    var compact = false
    let onPaste: ([String]) -> Void

    var body: some View {
        if probe.kind != .none {
            PasteAndGoButton(onPaste: onPaste)
                .labelStyle(.titleAndIcon)
                .buttonBorderShape(.capsule)
                .controlSize(compact ? .mini : .small)
                .tint(Theme.color)
                .fixedSize()
                .transition(.opacity.combined(with: .scale(scale: 0.9)))
                .accessibilityLabel(probe.kind == .link ? "打开拷贝的链接" : "搜索拷贝的文字")
                .accessibilityIdentifier("pasteAndGo")
        }
    }
}
