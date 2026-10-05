import SwiftUI

/// Minimal start page (spec §44): search, favorites, frequently visited, optional wallpaper.
/// No news feed, recommendations or ads.
struct HomeView: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var profile: ProfileContext
    @State private var query = ""
    @FocusState private var focused: Bool

    private let columns = [GridItem(.adaptive(minimum: 72, maximum: 96), spacing: 16)]

    private var wallpaper: UIImage? {
        services.prefs.wallpaperFileName.flatMap { UIImage(contentsOfFile: AppPaths.wallpapers.appendingPathComponent($0).path) }
    }

    var body: some View {
        ZStack {
            if let wallpaper {
                GeometryReader { geo in
                    Image(uiImage: wallpaper).resizable().scaledToFill().frame(width: geo.size.width, height: geo.size.height).clipped()
                        .overlay(services.prefs.immersiveWallpaper ? Color.clear : Color.black.opacity(0.25))
                }
                .ignoresSafeArea()
            } else {
                Color(.systemGroupedBackground).ignoresSafeArea()
            }
            if services.prefs.homepageMode == .blank {
                Color.clear
            } else {
                ScrollView {
                    VStack(spacing: 26) {
                        Image(icon: tab.isPrivate ? "hand.raised.circle.fill" : "eye.circle.fill")
                            .font(.system(size: 54)).foregroundStyle(tab.isPrivate ? AnyShapeStyle(Color.purple) : AnyShapeStyle(.tint))
                            .padding(.top, 40)
                        if tab.isPrivate {
                            Text("无痕浏览").font(.title2.bold())
                            Text("关闭无痕标签页后，Rikugan 不会保留浏览记录、Cookie、缓存和搜索记录。")
                                .font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 30)
                        }
                        HStack {
                            Image(icon: "magnifyingglass").foregroundStyle(.secondary)
                            TextField("搜索或输入网址", text: $query)
                                .focused($focused)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                                .keyboardType(.webSearch)
                                .submitLabel(.go)
                                .onSubmit { tab.loadInput(query); query = "" }
                                .accessibilityIdentifier("homeSearchField")
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 46)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .frame(maxWidth: 600)
                        .padding(.horizontal)
                        if !profile.bookmarks.favorites.isEmpty {
                            section("个人收藏") {
                                ForEach(profile.bookmarks.favorites) { node in
                                    SiteTile(title: node.title, urlString: node.url ?? "") { open(node.url) }
                                        .contextMenu { Button("删除", role: .destructive) { profile.bookmarks.delete(node) } }
                                }
                            }
                        }
                        if services.prefs.showFrequentlyVisited && !tab.isPrivate {
                            let frequent = profile.history.frequentlyVisited(limit: 8)
                            if !frequent.isEmpty {
                                section("经常访问") {
                                    ForEach(frequent) { entry in
                                        SiteTile(title: entry.title, urlString: entry.url) { open(entry.url) }
                                    }
                                }
                            }
                        }
                    }
                    .padding(.bottom, 40)
                    .frame(maxWidth: .infinity)
                }
                .scrollDismissesKeyboard(.immediately)
            }
        }
    }

    @ViewBuilder
    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline).padding(.horizontal, 4)
            LazyVGrid(columns: columns, spacing: 16, content: content)
        }
        .padding(16)
        .background(services.prefs.immersiveWallpaper && wallpaper != nil ? AnyShapeStyle(.ultraThinMaterial) : AnyShapeStyle(Color(.secondarySystemGroupedBackground)),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .frame(maxWidth: 640)
        .padding(.horizontal)
    }

    private func open(_ raw: String?) {
        guard let raw, let url = URL(string: raw) else { return }
        tab.load(url)
    }
}

struct SiteTile: View {
    let title: String
    let urlString: String
    let action: () -> Void
    @State private var icon: UIImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                ZStack {
                    RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Color(.tertiarySystemBackground))
                    if let icon {
                        Image(uiImage: icon).resizable().scaledToFit().padding(12)
                    } else {
                        Text(String((URL(string: urlString)?.host?.replacingOccurrences(of: "www.", with: "") ?? title).prefix(1)).uppercased())
                            .font(.title2.bold()).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 60, height: 60)
                Text(title).font(.caption2).lineLimit(2).multilineTextAlignment(.center).foregroundStyle(.primary)
            }
        }
        .buttonStyle(.plain)
        .task {
            guard let url = URL(string: urlString), let host = url.host else { return }
            if let cached = FaviconCache.shared.image(for: host) { icon = cached; return }
            if let apple = URL(string: "https://\(host)/apple-touch-icon.png"), let image = await FaviconCache.shared.fetch(apple, host: host) { icon = image; return }
            if let ico = URL(string: "https://\(host)/favicon.ico") { icon = await FaviconCache.shared.fetch(ico, host: host) }
        }
    }
}
