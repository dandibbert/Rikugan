import SwiftUI
import WebKit

struct ExtensionActionStrip: View {
    @ObservedObject var session: BrowserSession
    @ObservedObject var tab: BrowserTab
    private var records: [ExtensionRecord] {
        session.profile.extensions.filter { $0.enabled && session.contexts[$0.id]?.action(for: tab) != nil }
    }
    var body: some View {
        if !tab.isPrivate && !records.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(records) { record in
                        if let action = session.contexts[record.id]?.action(for: tab) {
                            Button { session.performExtension(record.id, targetTab: tab) } label: {
                                HStack(spacing: 6) {
                                    if let icon = action.icon(for: CGSize(width: 22, height: 22)) {
                                        Image(uiImage: icon).resizable().scaledToFit().frame(width: 22, height: 22)
                                    } else { Image(systemName: "puzzlepiece.extension").frame(width: 22, height: 22) }
                                    Text(action.label.isEmpty ? record.name : action.label).font(.caption).lineLimit(1)
                                    if !action.badgeText.isEmpty {
                                        Text(String(action.badgeText.prefix(5))).font(.caption2.bold())
                                            .padding(.horizontal, 5).padding(.vertical, 2).background(.quaternary, in: Capsule())
                                    }
                                }.padding(.horizontal, 9).frame(height: 32).background(.quaternary, in: Capsule())
                            }.buttonStyle(.plain).disabled(!action.isEnabled)
                                .accessibilityIdentifier("extension.toolbar." + record.name)
                        }
                    }
                }
            }.frame(height: 34)
        }
    }
}
