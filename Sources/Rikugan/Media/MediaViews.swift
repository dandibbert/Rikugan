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
                            Image(icon: icon(item.kind)).foregroundStyle(.tint)
                            Text(item.fileName).font(.subheadline.weight(.medium)).lineLimit(1)
                        }
                        Text(details(item)).font(.subheadline).foregroundStyle(.secondary)
                        Text(item.url.absoluteString).font(.footnote).foregroundStyle(.tertiary).lineLimit(2)
                        HStack(spacing: 16) {
                            Button("下载") { downloads.downloadInteractively(url: item.url, suggestedName: nil, from: tab) }
                            Button("播放") { player = item.url }
                            Button("拷贝链接") { UIPasteboard.general.url = item.url; ToastCenter.shared.show("已拷贝", symbol: "doc.on.doc") }
                            Button { Presenter.share([item.url]) } label: { Image(icon: "square.and.arrow.up") }
                        }
                        .buttonStyle(.borderless)
                        .font(.caption)
                    }
                    .padding(.vertical, 4)
                }
                Section {
                    Button { PageActions.videoAction(tab, "pip") } label: { Label("画中画", icon: "pip.enter") }
                    Button { PageActions.videoAction(tab, "fullscreen") } label: { Label("全屏播放", icon: "arrow.up.left.and.arrow.down.right") }
                } footer: {
                    Text("FairPlay / Widevine 等 DRM 保护的媒体不在支持范围内；加密的 HLS 无法下载。")
                }
            }
            .navigationTitle("媒体资源")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarLeading) { Button { Task { await scan() } } label: { Image(icon: "arrow.clockwise") } }
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
            if let length = await DownloadManager.pageResourceLength(item.url, tab: tab) { sizes[item.url] = length }
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
                            PageImageView(url: image.url, tab: tab) { img in img.resizable().scaledToFill() } placeholder: { _ in Color(.secondarySystemBackground) }
                            .frame(minWidth: 0, maxWidth: .infinity).frame(height: 110).clipped()
                            .contentShape(Rectangle())
                            .onTapGesture {
                                if selecting { toggle(image) } else { preview = image }
                            }
                            if selecting {
                                Image(icon: selection.contains(image.id) ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(.white, Theme.color).font(.title3).padding(5)
                            }
                        }
                        .contextMenu {
                            Button { Task { await save([image]) } } label: { Label("存储到相册", icon: "square.and.arrow.down") }
                            Button { UIPasteboard.general.url = image.url } label: { Label("拷贝图片地址", icon: "link") }
                            Button { Presenter.share([image.url]) } label: { Label("分享", icon: "square.and.arrow.up") }
                            Button { tab.manager?.newTab(url: image.url, isPrivate: tab.isPrivate); dismiss() } label: { Label("在新标签页打开原图", icon: "arrow.up.right.square") }
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
            .sheet(item: $preview) { image in ImagePreview(image: image, tab: tab) { preview = nil; tab.manager?.newTab(url: image.url, isPrivate: tab.isPrivate); dismiss() } }
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
        let saved = await Self.saveToPhotos(list.map(\.url), tab: tab)
        if saved >= 0 {
            let failed = list.count - saved
            ToastCenter.shared.show(failed > 0 ? "已存储 \(saved) 张，\(failed) 张无法获取" : "已存储 \(saved) 张图片",
                                    symbol: failed > 0 ? "exclamationmark.triangle" : "photo")
        }
        selecting = false
        selection.removeAll()
    }

    /// Returns the number saved, or -1 without photo-library permission (a toast explains it).
    /// Images are fetched with the page's context (see `DownloadManager.pageResource`).
    static func saveToPhotos(_ urls: [URL], tab: BrowserTab?) async -> Int {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { ToastCenter.shared.show("没有相册写入权限", symbol: "exclamationmark.triangle"); return -1 }
        var saved = 0
        for url in urls {
            guard let data = try? await DownloadManager.pageResource(url, tab: tab) else { continue }
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
    var tab: BrowserTab?
    var openInTab: (() -> Void)?
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1

    @ViewBuilder private var actions: some View {
        Button { Task { if await ImageGalleryView.saveToPhotos([image.url], tab: tab) > 0 { ToastCenter.shared.show("已存储到相册", symbol: "photo") } } } label: {
            Label("存储到相册", icon: "square.and.arrow.down")
        }
        Button { Task { await copyImage() } } label: { Label("拷贝图片", icon: "doc.on.doc") }
        Button { UIPasteboard.general.url = image.url; ToastCenter.shared.show("已拷贝图片地址", symbol: "link") } label: { Label("拷贝图片地址", icon: "link") }
        Button { Presenter.share([image.url]) } label: { Label("分享", icon: "square.and.arrow.up") }
        if let openInTab { Button { openInTab() } label: { Label("在新标签页打开原图", icon: "arrow.up.right.square") } }
    }

    var body: some View {
        NavigationStack {
            PageImageView(url: image.url, tab: tab) { img in
                    img.resizable().scaledToFit()
                        .scaleEffect(scale)
                        .gesture(MagnificationGesture()
                            .onChanged { scale = max(1, baseScale * $0) }
                            .onEnded { _ in baseScale = scale })
                        .onTapGesture(count: 2) { withAnimation { scale = scale > 1 ? 1 : 2.5; baseScale = scale } }
                        .contextMenu { actions }
            } placeholder: { failed in
                if failed { Label("图片无法加载", icon: "exclamationmark.triangle").foregroundStyle(.white) }
                else { ProgressView().tint(.white) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Color.black)
            .navigationTitle(image.width > 0 ? "\(image.width)×\(image.height)" : image.url.lastPathComponent)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Menu { actions } label: { Image(icon: "ellipsis.circle") }.accessibilityIdentifier("imagePreviewActions")
                }
            }
        }
    }

    private func copyImage() async {
        guard let data = try? await DownloadManager.pageResource(image.url, tab: tab), let uiImage = UIImage(data: data) else {
            ToastCenter.shared.show("无法拷贝图片", symbol: "exclamationmark.triangle"); return
        }
        UIPasteboard.general.image = uiImage
        ToastCenter.shared.show("已拷贝图片", symbol: "doc.on.doc")
    }
}

/// Loads an image with the page's context (cookies / Referer / blob: inside the page) instead of
/// AsyncImage's shared session, which has neither and would store responses globally.
struct PageImageView<Content: View, Placeholder: View>: View {
    let url: URL
    let tab: BrowserTab?
    @ViewBuilder var content: (Image) -> Content
    @ViewBuilder var placeholder: (_ failed: Bool) -> Placeholder
    @State private var image: UIImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image { content(Image(uiImage: image)) } else { placeholder(failed) }
        }
        .task(id: url) {
            image = nil
            failed = false
            if let data = try? await DownloadManager.pageResource(url, tab: tab), let decoded = UIImage(data: data) { image = decoded }
            else if !Task.isCancelled { failed = true }
        }
    }
}
