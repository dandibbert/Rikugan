import SwiftUI
import UIKit

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
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in onPaste(strings) }
                }
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
                PasteButton(payloadType: String.self) { strings in
                    Task { @MainActor in onPaste(strings) }
                }
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
