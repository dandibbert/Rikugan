import SwiftUI

/// Omnibox editing overlay (spec §5): URL / search input with history, bookmark, search-history
/// and search-engine suggestions plus keyword shortcuts.
struct OmniboxOverlay: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var manager: TabManager
    @EnvironmentObject private var profile: ProfileContext
    @Binding var editing: Bool
    @State private var text = ""
    @State private var suggestions: [String] = []
    @State private var suggestTask: Task<Void, Never>?
    @FocusState private var focused: Bool

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                HStack {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("搜索或输入网址", text: $text)
                        .focused($focused)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.webSearch)
                        .submitLabel(.go)
                        .onSubmit { submit(text) }
                        .accessibilityIdentifier("omniboxField")
                    if !text.isEmpty {
                        Button { text = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    }
                }
                .padding(.horizontal, 12)
                .frame(height: 40)
                .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                Button("取消") { editing = false }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(.bar)
            List {
                if case .url(let url) = Omnibox.classify(text, shortcuts: services.prefs.shortcuts), !text.isEmpty {
                    row(symbol: "globe", title: url.absoluteString, subtitle: "打开网址") { submit(text) }
                } else if !text.isEmpty {
                    row(symbol: "magnifyingglass", title: text, subtitle: "使用 \(services.prefs.searchEngine.name) 搜索") { submit(text) }
                }
                if !bookmarkMatches.isEmpty {
                    Section("书签") {
                        ForEach(bookmarkMatches) { node in
                            row(symbol: "book", title: node.title, subtitle: node.url ?? "") { open(node.url) }
                        }
                    }
                }
                if !historyMatches.isEmpty {
                    Section("历史记录") {
                        ForEach(historyMatches) { entry in
                            row(symbol: "clock", title: entry.title, subtitle: entry.url) { open(entry.url) }
                        }
                    }
                }
                if !suggestions.isEmpty {
                    Section("\(services.prefs.searchEngine.name) 建议") {
                        ForEach(suggestions, id: \.self) { s in
                            row(symbol: "magnifyingglass", title: s, subtitle: nil) { submit(s) }
                        }
                    }
                }
                if text.isEmpty && !profile.history.searchHistory.isEmpty && !(manager.activeTab?.isPrivate ?? false) {
                    Section("最近搜索") {
                        ForEach(profile.history.searchHistory.prefix(8), id: \.self) { s in
                            row(symbol: "clock.arrow.circlepath", title: s, subtitle: nil) { submit(s) }
                        }
                    }
                }
                if text.isEmpty, let url = manager.activeTab?.url {
                    Section("当前页面") {
                        row(symbol: "doc.on.doc", title: "拷贝链接", subtitle: url.absoluteString) {
                            UIPasteboard.general.url = url
                            editing = false
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .scrollDismissesKeyboard(.immediately)
        }
        .background(Color(.systemGroupedBackground))
        .onAppear {
            text = manager.activeTab?.isHome == false ? (manager.activeTab?.url?.absoluteString ?? "") : ""
            focused = true
        }
        .onChange(of: text) { _, value in fetchSuggestions(value) }
    }

    private var bookmarkMatches: [BookmarkNode] { profile.bookmarks.search(text, limit: 4) }
    private var historyMatches: [HistoryEntry] { profile.history.search(text, limit: 5) }

    @ViewBuilder
    private func row(symbol: String, title: String, subtitle: String?, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: symbol).foregroundStyle(.secondary).frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).lineLimit(1).foregroundStyle(.primary)
                    if let subtitle, !subtitle.isEmpty { Text(subtitle).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
            }
        }
    }

    private func submit(_ input: String) {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        editing = false
        let tab = manager.activeTab ?? manager.newTab()
        tab.loadInput(trimmed)
    }

    private func open(_ raw: String?) {
        guard let raw, let url = URL(string: raw) else { return }
        editing = false
        (manager.activeTab ?? manager.newTab()).load(url)
    }

    private func fetchSuggestions(_ value: String) {
        suggestTask?.cancel()
        let prefs = services.prefs
        guard prefs.searchSuggestions, !(manager.activeTab?.isPrivate ?? false), value.count >= 2,
              case .search = Omnibox.classify(value, shortcuts: prefs.shortcuts),
              let url = prefs.searchEngine.suggestURL(for: value) else { suggestions = []; return }
        suggestTask = Task {
            try? await Task.sleep(nanoseconds: 180_000_000)
            guard !Task.isCancelled, let (data, _) = try? await URLSession.shared.data(from: url) else { return }
            let list = SearchEngine.parseSuggestions(data)
            if !Task.isCancelled { suggestions = Array(list.prefix(6)) }
        }
    }
}
