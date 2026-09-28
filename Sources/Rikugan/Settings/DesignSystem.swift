import SwiftUI

// Shared building blocks so settings and sheets look like one app (iOS Settings style):
// - the settings root has an icon per row; sub-pages use plain text rows;
// - values sit on the right in secondary colour;
// - secondary actions on a value (copy, open) live in a menu on that row, not in inline buttons.

/// A row showing a link or long value; tapping offers Copy / Open.
struct LinkRow: View {
    let title: String
    let value: String
    var open: ((URL) -> Void)?

    private var url: URL? {
        guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    /// Shown without the scheme; the full value is copied.
    private var display: String {
        guard let url else { return value }
        return (url.host ?? "") + url.path + (url.query.map { "?" + $0 } ?? "")
    }

    var body: some View {
        Menu {
            Button { UIPasteboard.general.string = value; ToastCenter.shared.show("已拷贝", symbol: "doc.on.doc") } label: {
                Label("拷贝", systemImage: "doc.on.doc")
            }
            if let url, let open { Button { open(url) } label: { Label("在新标签页打开", systemImage: "safari") } }
            if let url { ShareLink(item: url) { Label("分享", systemImage: "square.and.arrow.up") } }
        } label: {
            HStack(spacing: 12) {
                Text(title).foregroundStyle(.primary)
                Spacer(minLength: 8)
                Text(display).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            .contentShape(Rectangle())
        }
        .accessibilityHint("轻点以拷贝或打开")
    }
}


/// Icon + title + subtitle at the top of a detail page (extensions, userscripts, install sheets).
struct ItemHeader<Icon: View>: View {
    let title: String
    var subtitle: String = ""
    @ViewBuilder let icon: () -> Icon

    var body: some View {
        HStack(spacing: 14) {
            icon()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline).lineLimit(2)
                if !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(3) }
            }
        }
        .padding(.vertical, 2)
    }
}
