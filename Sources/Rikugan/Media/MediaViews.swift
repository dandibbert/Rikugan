import SwiftUI
import Photos
import AVKit

/// Media sniffer (spec §26): DOM + network + navigation responses, including M3U8.
struct MediaSnifferView: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss
    @State private var domItems: [MediaItem] = []
    @State private var sizes: [URL: Int64] = [:]
    @State private var loading = true
    @State private var player: URL?

    private var all: [MediaItem] {
        var seen = Set<URL>()
        return (domItems + tab.sniffedMedia).filter { seen.insert($0.url).inserted }
    }

    var body: some View {
        NavigationStack {
            List {
                if loading { HStack { ProgressView(); Text("正在扫描页面…").foregroundStyle(.secondary) } }
                if !loading && all.isEmpty {
                    Text("没有检测到视频或音频。播放一次视频后再次打开此页面通常可以检测到流地址。").foregroundStyle(.secondary)
                }
                ForEach(all) { item in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Image(systemName: icon(item.kind)).foregroundStyle(.tint)
                            Text(item.fileName).font(.subheadline.weight(.medium)).lineLimit(1)
                        }
                        Text(details(item)).font(.subheadline).foregroundStyle(.secondary)
                        Text(item.url.absoluteString).font(.footnote).foregroundStyle(.tertiary).lineLimit(2)
                        HStack(spacing: 16) {
                            Button("下载") { downloads.downloadInteractively(url: item.url, suggestedName: nil, from: tab) }
                            Button("播放") { player = item.url }
                            Button("拷贝链接") { UIPasteboard.general.url = item.url; ToastCenter.shared.show("已拷贝", symbol: "doc.on.doc") }
                            Button { Presenter.share([item.url]) } label: { Image(systemName: "square.and.arrow.up") }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Button { PageActions.videoAction(tab, "pip") } label: { Label("画中画", systemImage: "pip.enter") }
                    Button { PageActions.videoAction(tab, "fullscreen") } label: { Label("全屏播放", systemImage: "arrow.up.left.and.arrow.down.right") }
                } footer: {
                    Text("FairPlay / Widevine 等 DRM 保护的媒体不在支持范围内；加密的 HLS 无法下载。")
                }
            }
            .navigationTitle("媒体资源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { Button { Task { await scan() } } label: { Image(systemName: "arrow.clockwise") } }
            }
            .task { await scan() }
            .sheet(item: Binding(get: { player.map { IdentifiedURL(url: $0) } }, set: { player = $0?.url })) { item in
                VideoPlayer(player: AVPlayer(url: item.url)).ignoresSafeArea()
            }
        }
    }

    private func scan() async {
        loading = true
        defer { loading = false }
        guard let list = await tab.webView?.rkTools("scanMedia") as? [[String: Any]] else { return }
        domItems = list.compactMap { dict in
            guard let raw = dict["url"] as? String, let url = URL(string: raw), !raw.hasPrefix("blob:") else { return nil }
            return MediaItem(url: url, kind: dict["kind"] as? String ?? "video", source: dict["source"] as? String ?? "dom",
                             width: dict["width"] as? Int ?? 0, height: dict["height"] as? Int ?? 0, duration: dict["duration"] as? Double ?? 0,
                             size: Int64(dict["size"] as? Int ?? 0))
        }
        for item in all where item.size <= 0 && item.kind != "hls" && sizes[item.url] == nil {
            var request = URLRequest(url: item.url, timeoutInterval: 8)
            request.httpMethod = "HEAD"
            if let (_, response) = try? await URLSession.shared.data(for: request), response.expectedContentLength > 0 {
                sizes[item.url] = response.expectedContentLength
            }
        }
    }

    private func icon(_ kind: String) -> String {
        switch kind { case "audio": return "waveform"; case "hls", "dash": return "dot.radiowaves.left.and.right"; default: return "film" }
    }

    private func details(_ item: MediaItem) -> String {
        var parts: [String] = []
        parts.append(item.kind == "hls" ? "HLS 流（M3U8）" : item.kind == "dash" ? "DASH（MPD，仅可复制链接）" : item.kind == "audio" ? "音频" : "视频")
        if item.width > 0 { parts.append("\(item.width)×\(item.height)") }
        if item.duration > 0 { parts.append(Duration.seconds(item.duration).formatted(.time(pattern: .minuteSecond))) }
        let size = item.size > 0 ? item.size : (sizes[item.url] ?? 0)
        if size > 0 { parts.append(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)) }
        parts.append("来源：\(item.source)")
        return parts.joined(separator: " · ")
    }
}

struct IdentifiedURL: Identifiable { let url: URL; var id: String { url.absoluteString } }

/// Images mode (spec §27): preview, original, save, share, copy URL, batch select / save.
struct ImageGalleryView: View {
    @ObservedObject var tab: BrowserTab
    @Environment(\.dismiss) private var dismiss
    @State private var images: [PageImage] = []
    @State private var selecting = false
    @State private var selection = Set<String>()
    @State private var preview: PageImage?
    @State private var saving = false

    struct PageImage: Identifiable, Hashable { let url: URL; let width: Int; let height: Int; var id: String { url.absoluteString } }

    private let columns = [GridItem(.adaptive(minimum: 100), spacing: 4)]

    var body: some View {
        NavigationStack {
            ScrollView {
                if images.isEmpty { Text("没有找到图片").foregroundStyle(.secondary).padding(.top, 60) }
                LazyVGrid(columns: columns, spacing: 4) {
                    ForEach(images) { image in
                        ZStack(alignment: .topTrailing) {
                            AsyncImage(url: image.url) { phase in
                                if let img = phase.image { img.resizable().scaledToFill() }
                                else { Color(.secondarySystemBackground) }
                            }
                            .frame(minWidth: 0, maxWidth: .infinity).frame(height: 110).clipped()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selecting { toggle(image) } else { preview = image }
                            }
                            if selecting {
                                Image(systemName: selection.contains(image.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(.white, Color.accentColor).font(.title3).padding(5)
                            }
                        }
                        .contextMenu {
                            Button { Task { await save([image]) } } label: { Label("存储到相册", systemImage: "square.and.arrow.down") }
                            Button { UIPasteboard.general.url = image.url } label: { Label("拷贝图片地址", systemImage: "link") }
                            Button { Presenter.share([image.url]) } label: { Label("分享", systemImage: "square.and.arrow.up") }
                            Button { tab.manager?.newTab(url: image.url, isPrivate: tab.isPrivate); dismiss() } label: { Label("在新标签页打开原图", systemImage: "arrow.up.right.square") }
                        }
                    }
                }
                .padding(4)
            }
            .navigationTitle("图片（\(images.count)）")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) { Button(selecting ? "取消选择" : "选择") { selecting.toggle(); selection.removeAll() } }
                if selecting {
                    ToolbarItemGroup(placement: .bottomBar) {
                        Button(selection.count == images.count ? "取消全选" : "全选") {
                            selection = selection.count == images.count ? [] : Set(images.map(\.id))
                        }
                        Spacer()
                        Button(saving ? "正在存储…" : "存储 \(selection.count) 张") {
                            Task { await save(images.filter { selection.contains($0.id) }) }
                        }
                        .disabled(selection.isEmpty || saving)
                    }
                }
            }
            .task { await scan() }
            .sheet(item: $preview) { image in ImagePreview(image: image) { preview = nil; tab.manager?.newTab(url: image.url, isPrivate: tab.isPrivate); dismiss() } }
        }
    }

    private func toggle(_ image: PageImage) {
        if selection.contains(image.id) { selection.remove(image.id) } else { selection.insert(image.id) }
    }

    private func scan() async {
        guard let list = await tab.webView?.rkTools("scanImages") as? [[String: Any]] else { return }
        images = list.compactMap { dict in
            guard let raw = dict["url"] as? String, let url = URL(string: raw) else { return nil }
            return PageImage(url: url, width: dict["width"] as? Int ?? 0, height: dict["height"] as? Int ?? 0)
        }
    }

    private func save(_ list: [PageImage]) async {
        saving = true
        defer { saving = false }
        let saved = await Self.saveToPhotos(list.map(\.url))
        if saved >= 0 { ToastCenter.shared.show("已存储 \(saved) 张图片", symbol: "photo") }
        selecting = false
        selection.removeAll()
    }

    /// Returns the number saved, or -1 without photo-library permission (a toast explains it).
    static func saveToPhotos(_ urls: [URL]) async -> Int {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { ToastCenter.shared.show("没有相册写入权限", symbol: "exclamationmark.triangle"); return -1 }
        var saved = 0
        for url in urls {
            guard let data = try? await URLSession.shared.data(from: url).0 else { continue }
            let ok: Bool = await withCheckedContinuation { continuation in
                PHPhotoLibrary.shared().performChanges({
                    PHAssetCreationRequest.forAsset().addResource(with: .photo, data: data, options: nil)
                }, completionHandler: { success, _ in continuation.resume(returning: success) })
            }
            if ok { saved += 1 }
        }
        return saved
    }
}

/// Full-size image with the same actions as the thumbnails (long press, or the … button).
struct ImagePreview: View {
    let image: ImageGalleryView.PageImage
    var openInTab: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1

    @ViewBuilder private var actions: some View {
        Button { Task { if await ImageGalleryView.saveToPhotos([image.url]) > 0 { ToastCenter.shared.show("已存储到相册", symbol: "photo") } } } label: {
            Label("存储到相册", systemImage: "square.and.arrow.down")
        }
        Button { Task { await copyImage() } } label: { Label("拷贝图片", systemImage: "doc.on.doc") }
        Button { UIPasteboard.general.url = image.url; ToastCenter.shared.show("已拷贝图片地址", symbol: "link") } label: { Label("拷贝图片地址", systemImage: "link") }
        Button { Presenter.share([image.url]) } label: { Label("分享", systemImage: "square.and.arrow.up") }
        if let openInTab { Button { openInTab() } label: { Label("在新标签页打开原图", systemImage: "arrow.up.right.square") } }
    }

    var body: some View {
        NavigationStack {
            AsyncImage(url: image.url) { phase in
                if let img = phase.image {
                    img.resizable().scaledToFit()
                        .scaleEffect(scale)
                        .gesture(MagnificationGesture()
                            .onChanged { scale = max(1, baseScale * $0) }
                            .onEnded { _ in baseScale = scale })
                        .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5; baseScale = scale } }
                        .contextMenu { actions }
                } else if phase.error != nil {
                    Label("图片无法加载", systemImage: "exclamationmark.triangle").foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle(image.width > 0 ? "\(image.width)×\(image.height)" : image.url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu { actions } label: { Image(systemName: "ellipsis.circle") }.accessibilityIdentifier("imagePreviewActions")
                }
            }
        }
    }

    private func copyImage() async {
        guard let data = try? await URLSession.shared.data(from: image.url).0, let uiImage = UIImage(data: data) else {
            ToastCenter.shared.show("无法拷贝图片", symbol: "exclamationmark.triangle"); return
        }
        UIPasteboard.general.image = uiImage
        ToastCenter.shared.show("已拷贝图片", symbol: "doc.on.doc")
    }
}
