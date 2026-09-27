import SwiftUI
import WebKit
import UIKit
import PhotosUI
import AVFoundation
import Vision
import CoreImage
import Translation
import NaturalLanguage
import QuickLook

enum ToolSheet: String, Identifiable {
    case reader, media, images, qr, translate, site, console, autofill, refresh, blocking, fonts, matrix
    var id: String { rawValue }
}

enum ByteFormat {
    static func bytes(_ value: Int64) -> String {
        guard value > 0 else { return "大小未知" }
        let units = ["B", "KB", "MB", "GB"]
        var amount = Double(value), index = 0
        while amount >= 1024, index < units.count - 1 { amount /= 1024; index += 1 }
        return String(format: index == 0 ? "%.0f %@" : "%.1f %@", amount, units[index])
    }
    static func speed(_ value: Double) -> String { value <= 0 ? "" : bytes(Int64(value)) + "/s" }
    static func remaining(received: Int64, total: Int64, speed: Double) -> String {
        guard total > received, speed > 1 else { return "" }
        let seconds = Double(total - received) / speed
        if seconds < 90 { return "\(Int(seconds)) 秒" }
        return "\(Int(seconds / 60)) 分钟"
    }
}

private struct ReaderBlock: Identifiable {
    var id: Int
    var tag: String
    var text: String
    var href: String
    var src: String
}

struct ReaderSheet: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var blocks: [ReaderBlock] = []
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    Text(title.isEmpty ? tab.pageTitle : title).font(face(model.profile.settings.reader.fontSize + 8)).fontWeight(.bold)
                    if !author.isEmpty { Text(author).font(.subheadline).foregroundStyle(.secondary) }
                    if blocks.isEmpty { Text("没有识别到正文。").foregroundStyle(.secondary) }
                    ForEach(blocks) { block in
                        if block.tag == "img", let url = URL(string: block.src) {
                            AsyncImage(url: url) { image in image.resizable().scaledToFit() } placeholder: { Color.secondary.opacity(0.15).frame(height: 120) }
                                .frame(maxHeight: 360)
                        } else if !block.href.isEmpty, let url = URL(string: block.href) {
                            Link(block.text, destination: url).font(face(model.profile.settings.reader.fontSize))
                        } else {
                            Text(block.text)
                                .font(face(block.tag.hasPrefix("h") ? model.profile.settings.reader.fontSize + 4 : model.profile.settings.reader.fontSize))
                                .fontWeight(block.tag.hasPrefix("h") ? .semibold : .regular)
                                .lineSpacing(model.profile.settings.reader.fontSize * (model.profile.settings.reader.lineHeight - 1))
                        }
                    }
                }.padding(22).frame(maxWidth: 720, alignment: .leading).foregroundStyle(foreground)
            }
            .background(theme.ignoresSafeArea())
            .navigationTitle("阅读模式")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) { Menu("版式") { controls } }
            }
        }.task { await load() }
    }
    @ViewBuilder private var controls: some View {
        Stepper("字号 \(Int(model.profile.settings.reader.fontSize))", value: reader(\.fontSize), in: 14...32, step: 1)
        Picker("字体", selection: readerString(\.font)) {
            Text("系统").tag("system"); Text("衬线").tag("serif"); Text("等宽").tag("mono")
            ForEach(model.profile.settings.importedFonts) { font in Text(font.family).tag(font.family) }
        }
        Stepper("行距 \(String(format: "%.1f", model.profile.settings.reader.lineHeight))", value: reader(\.lineHeight), in: 1.2...2.2, step: 0.1)
        Picker("主题", selection: readerString(\.theme)) { Text("羊皮纸").tag("sepia"); Text("白").tag("light"); Text("黑").tag("dark") }
    }
    private var theme: Color {
        switch model.profile.settings.reader.theme {
        case "dark": return Color(white: 0.12)
        case "light": return .white
        default: return Color(red: 0.96, green: 0.93, blue: 0.86)
        }
    }
    private var foreground: Color { model.profile.settings.reader.theme == "dark" ? Color(white: 0.92) : Color(white: 0.12) }
    private func face(_ size: Double) -> Font {
        switch model.profile.settings.reader.font {
        case "serif": return .system(size: size, design: .serif)
        case "mono": return .system(size: size, design: .monospaced)
        case "", "system": return .system(size: size)
        default: return .custom(model.profile.settings.reader.font, size: size)
        }
    }
    private func reader(_ key: WritableKeyPath<ReaderSettings, Double>) -> Binding<Double> {
        Binding(get: { model.profile.settings.reader[keyPath: key] }, set: { value in
            model.updateProfile(model.profile.id) { $0.settings.reader[keyPath: key] = value }
        })
    }
    private func readerString(_ key: WritableKeyPath<ReaderSettings, String>) -> Binding<String> {
        Binding(get: { model.profile.settings.reader[keyPath: key] }, set: { value in
            model.updateProfile(model.profile.id) { $0.settings.reader[keyPath: key] = value }
        })
    }
    private func load() async {
        guard let value = await PageTools.call("RikuganPageTools.extractArticle()", in: tab.webView) as? [String: Any] else { return }
        title = value["title"] as? String ?? ""
        author = value["author"] as? String ?? ""
        let rows = value["blocks"] as? [[String: Any]] ?? []
        blocks = rows.enumerated().compactMap { index, item in
            let text = item["text"] as? String ?? ""
            let src = item["src"] as? String ?? ""
            guard !text.isEmpty || !src.isEmpty else { return nil }
            return ReaderBlock(id: index, tag: item["tag"] as? String ?? "p", text: text, href: item["href"] as? String ?? "", src: src)
        }
    }
}

struct MediaSheet: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var model: AppModel
    @State private var items: [[String: Any]] = []
    @State private var variants: [PlaylistVariant] = []
    var body: some View {
        NavigationStack {
            List {
                if items.isEmpty { ContentUnavailableView("没有嗅探到媒体", systemImage: "play.rectangle", description: Text("来源包括页面元素、performance 和已发生的 fetch/XHR。不处理 FairPlay、Widevine 或 DRM。")) }
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(alignment: .leading, spacing: 6) {
                        Text(item["kind"] as? String ?? "file").font(.caption).foregroundStyle(.secondary)
                        Text(item["url"] as? String ?? "").font(.footnote).lineLimit(2)
                        let width = (item["width"] as? NSNumber)?.intValue ?? 0
                        let height = (item["height"] as? NSNumber)?.intValue ?? 0
                        if width > 0 { Text("\(width)×\(height)").font(.caption2).foregroundStyle(.secondary) }
                        if let size = item["size"] as? NSNumber, size.int64Value > 0 { Text(ByteFormat.bytes(size.int64Value)).font(.caption2).foregroundStyle(.secondary) }
                        else if let size = item["size"] as? Int, size > 0 { Text(ByteFormat.bytes(Int64(size))).font(.caption2).foregroundStyle(.secondary) }
                        Button("下载") { Task { await download(item["url"] as? String) } }.font(.subheadline)
                    }
                }
                if !variants.isEmpty {
                    Section("播放列表") {
                        ForEach(Array(variants.enumerated()), id: \.offset) { _, variant in
                            VStack(alignment: .leading, spacing: 4) {
                                Text(variant.kind.uppercased() + (variant.width > 0 ? " \(variant.width)×\(variant.height)" : "")).font(.caption)
                                Text(variant.url).font(.footnote).lineLimit(2)
                                if variant.bandwidth > 0 { Text("\(variant.bandwidth / 1000) kbps").font(.caption2).foregroundStyle(.secondary) }
                                Button("下载这个地址") { Task { await download(variant.url) } }.font(.subheadline)
                            }
                        }
                    }
                }
            }.navigationTitle("媒体")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("刷新") { Task { await load() } } } }
        }.task { await load() }
    }
    private func load() async {
        items = await PageTools.call("RikuganPageTools.collectMedia()", in: tab.webView) as? [[String: Any]] ?? []
        var found: [PlaylistVariant] = []
        for item in items {
            let kind = item["kind"] as? String ?? ""
            guard kind == "hls" || kind == "dash", let raw = item["url"] as? String, let url = URL(string: raw) else { continue }
            guard let text = await playlistText(url) else { continue }
            if kind == "hls" { found.append(contentsOf: PlaylistText.parseM3U8(text, base: url)) }
            else { found.append(contentsOf: PlaylistText.parseMPD(text, base: url)) }
        }
        variants = found
        await enrichSizes()
    }
    private func enrichSizes() async {
        var next = items
        for index in next.indices {
            let existing = (next[index]["size"] as? NSNumber)?.int64Value ?? Int64(next[index]["size"] as? Int ?? 0)
            if existing > 0 { continue }
            guard let raw = next[index]["url"] as? String, let url = URL(string: raw) else { continue }
            if let length = await contentLength(url) { next[index]["size"] = length }
        }
        items = next
    }
    private func contentLength(_ url: URL) async -> Int64? {
        guard ["http", "https"].contains(url.scheme ?? "") else { return nil }
        var head = URLRequest(url: url)
        head.httpMethod = "HEAD"
        head.timeoutInterval = 8
        if let header = await cookieHeader(for: url) { head.setValue(header, forHTTPHeaderField: "Cookie") }
        if let page = tab.webView.url { head.setValue(page.absoluteString, forHTTPHeaderField: "Referer") }
        if let (_, response) = try? await URLSession.shared.data(for: head), let http = response as? HTTPURLResponse, http.expectedContentLength > 0 {
            return http.expectedContentLength
        }
        var ranged = head
        ranged.httpMethod = "GET"
        ranged.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let (_, response) = try? await URLSession.shared.data(for: ranged), let http = response as? HTTPURLResponse else { return nil }
        if let range = http.value(forHTTPHeaderField: "Content-Range"), let total = range.split(separator: "/").last, let value = Int64(total), value > 0 { return value }
        return http.expectedContentLength > 0 ? http.expectedContentLength : nil
    }
    private func playlistText(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        if let header = await cookieHeader(for: url) { request.setValue(header, forHTTPHeaderField: "Cookie") }
        if let page = tab.webView.url { request.setValue(page.absoluteString, forHTTPHeaderField: "Referer") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) else { return nil }
        return text
    }
    private func download(_ raw: String?) async {
        guard let raw, let url = URL(string: raw) else { return }
        let cookies = await currentCookies()
        model.downloadCenter.start(url: url, cookies: cookies, referer: tab.webView.url?.absoluteString)
    }
    private func cookieHeader(for url: URL) async -> String? { CookieHeader.value(cookies: await currentCookies(), url: url) }
    private func currentCookies() async -> [HTTPCookie] {
        guard let store = tab.isPrivate ? tab.session?.privateStore : tab.session?.dataStore else { return [] }
        return await withCheckedContinuation { continuation in store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) } }
    }
}

struct ImageSheet: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var model: AppModel
    @State private var urls: [String] = []
    @State private var selected = Set<String>()
    @State private var viewing: String?
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(urls, id: \.self) { url in
                        AsyncImage(url: URL(string: url)) { image in image.resizable().scaledToFill() } placeholder: { Color.secondary.opacity(0.15) }
                            .frame(height: 110).clipped().overlay(alignment: .topTrailing) { if selected.contains(url) { Image(systemName: "checkmark.circle.fill").padding(6) } }
                            .onTapGesture { if selected.contains(url) { selected.remove(url) } else { selected.insert(url) } }
                            .contextMenu {
                                Button("复制链接") { UIPasteboard.general.string = url }
                                Button("打开原图") { viewing = url }
                                Button("保存") { Task { await save([url]) } }
                                if let link = URL(string: url) { ShareLink(item: link) { Text("分享") } }
                            }
                    }
                }.padding(8)
            }.navigationTitle("图片 \(selected.count)/\(urls.count)")
                .fullScreenCover(isPresented: Binding(get: { viewing != nil }, set: { if !$0 { viewing = nil } })) {
                    if let viewing { OriginalImageViewer(urlString: viewing, tab: tab) { self.viewing = nil } }
                }
                .toolbar {
                    ToolbarItem(placement: .topBarLeading) { Button(selected.count == urls.count ? "取消" : "全选") { selected = selected.count == urls.count ? [] : Set(urls) } }
                    ToolbarItem(placement: .topBarTrailing) { Button("保存所选") { Task { await save(Array(selected)) } }.disabled(selected.isEmpty) }
                }
        }.task {
            let media = await PageTools.call("RikuganPageTools.collectMedia()", in: tab.webView) as? [[String: Any]] ?? []
            urls = media.compactMap { ($0["kind"] as? String) == "image" ? $0["url"] as? String : nil }
        }
    }
    private func save(_ links: [String]) async {
        var images: [UIImage] = []
        for link in links {
            guard let url = URL(string: link), let (data, _) = try? await URLSession.shared.data(from: url), let image = UIImage(data: data) else { continue }
            images.append(image)
        }
        let saver = PhotoSaver()
        for image in images { await saver.write(image) }
        model.message = images.isEmpty ? "没有保存任何图片。" : "已保存 \(images.count) 张图片。"
    }
}

struct OriginalImageViewer: View {
    let urlString: String
    @ObservedObject var tab: BrowserTab
    var back: () -> Void
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        NavigationStack {
            ZStack {
                Color.black.ignoresSafeArea()
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else if failed {
                    Text("原图没有加载。").foregroundStyle(.white)
                } else {
                    ProgressView().tint(.white)
                }
            }
            .navigationTitle("原图")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("返回") { back() } } }
        }
        .task { await load() }
    }
    private func load() async {
        guard let url = URL(string: urlString) else { failed = true; return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        if let store = tab.isPrivate ? tab.session?.privateStore : tab.session?.dataStore {
            let cookies: [HTTPCookie] = await withCheckedContinuation { continuation in
                store.httpCookieStore.getAllCookies { continuation.resume(returning: $0) }
            }
            if let header = CookieHeader.value(cookies: cookies, url: url) { request.setValue(header, forHTTPHeaderField: "Cookie") }
        }
        if let page = tab.webView.url { request.setValue(page.absoluteString, forHTTPHeaderField: "Referer") }
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              let picture = UIImage(data: data) else { failed = true; return }
        image = picture
    }
}

final class PhotoSaver: NSObject {
    private var continuation: CheckedContinuation<Void, Never>?
    func write(_ image: UIImage) async {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            UIImageWriteToSavedPhotosAlbum(image, self, #selector(image(_:didFinishSavingWithError:contextInfo:)), nil)
        }
    }
    @objc func image(_ image: UIImage, didFinishSavingWithError error: Error?, contextInfo: UnsafeMutableRawPointer?) {
        continuation?.resume(); continuation = nil
    }
}

struct QRSheet: View {
    let address: String
    var open: (String) -> Void
    var search: (String) -> Void
    @State private var scanned = ""
    @State private var camera = false
    @State private var photo: PhotosPickerItem?
    var body: some View {
        NavigationStack {
            VStack(spacing: 18) {
                if let image = QRCode.image(address) { Image(uiImage: image).interpolation(.none).resizable().frame(width: 220, height: 220) }
                Text(address).font(.footnote).lineLimit(3).multilineTextAlignment(.center)
                Button("用相机扫描") { camera = true }
                PhotosPicker("从照片识别", selection: $photo, matching: .images)
                if !scanned.isEmpty {
                    Text(scanned).font(.headline).textSelection(.enabled)
                    HStack {
                        Button("打开") { open(scanned) }
                        Button("搜索") { search(scanned) }
                        Button("复制") { UIPasteboard.general.string = scanned }
                    }.buttonStyle(.bordered)
                }
            }.padding().navigationTitle("二维码")
        }
        .sheet(isPresented: $camera) { CameraScanner { scanned = $0; camera = false } }
        .onChange(of: photo) { _, item in
            Task {
                guard let data = try? await item?.loadTransferable(type: Data.self), let image = UIImage(data: data) else { return }
                scanned = QRCode.read(image) ?? "没有识别到二维码。"
            }
        }
    }
}

enum QRCode {
    static func image(_ text: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = CIContext().createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
    static func read(_ image: UIImage) -> String? {
        guard let cg = image.cgImage else { return nil }
        let request = VNDetectBarcodesRequest()
        request.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: cg).perform([request])
        return request.results?.first?.payloadStringValue
    }
}

struct CameraScanner: UIViewControllerRepresentable {
    var onCode: (String) -> Void
    func makeUIViewController(context: Context) -> ScannerController { let controller = ScannerController(); controller.onCode = onCode; return controller }
    func updateUIViewController(_ controller: ScannerController, context: Context) {}
}

final class ScannerController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    var onCode: (String) -> Void = { _ in }
    private let session = AVCaptureSession()
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: start()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { allowed in DispatchQueue.main.async { allowed ? self.start() : self.fail() } }
        default: fail()
        }
    }
    private func start() {
        guard let device = AVCaptureDevice.default(for: .video), let input = try? AVCaptureDeviceInput(device: device), session.canAddInput(input) else { fail(); return }
        session.addInput(input)
        let output = AVCaptureMetadataOutput()
        guard session.canAddOutput(output) else { fail(); return }
        session.addOutput(output)
        output.setMetadataObjectsDelegate(self, queue: .main)
        output.metadataObjectTypes = [.qr]
        let preview = AVCaptureVideoPreviewLayer(session: session)
        preview.frame = view.bounds
        preview.videoGravity = .resizeAspectFill
        view.layer.addSublayer(preview)
        session.startRunning()
    }
    private func fail() {
        let label = UILabel(); label.text = "相机不可用。"; label.textColor = .white; label.sizeToFit()
        label.center = view.center; view.addSubview(label)
    }
    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput objects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let code = objects.compactMap({ $0 as? AVMetadataMachineReadableCodeObject }).first?.stringValue else { return }
        session.stopRunning(); onCode(code)
    }
}

@available(iOS 18.0, *)
enum PageTranslation {
    static func configuration(target: String, backend: String) -> TranslationSession.Configuration? {
        guard backend.isEmpty || backend == "apple" else { return nil }
        return TranslationSession.Configuration(target: Locale.Language(identifier: target))
    }
}

@available(iOS 18.0, *)
struct TranslateSheet: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var model: AppModel
    @State private var configuration: TranslationSession.Configuration?
    @State private var rows: [(id: String, text: String)] = []
    @State private var status = "正在提取页面文字"
    @State private var original = false
    @State private var translating = false
    @State private var applied = Set<String>()
    var body: some View {
        NavigationStack {
            Form {
                Text(status).font(.footnote)
                Picker("翻译后端", selection: Binding(get: { model.profile.settings.translationBackend }, set: { value in
                    model.updateProfile(model.profile.id) { $0.settings.translationBackend = value }
                    Task { await rearm() }
                })) { Text("Apple 设备端").tag("apple") }
                Picker("目标语言", selection: Binding(get: { model.profile.settings.translateTarget }, set: { value in
                    model.updateProfile(model.profile.id) { $0.settings.translateTarget = value }
                })) {
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Button(original ? "显示译文" : "显示原文") { Task { await toggle() } }.disabled(rows.isEmpty)
                Text("翻译使用设置里的 translationBackend。目前只有 Apple 设备端 TranslationSession 可以在没有密钥时运行。语言列表是可以交给系统的目标语言；没下载的语言包由系统报错。").font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("翻译网页")
                .translationTask(configuration) { session in await translate(session) }
                .onChange(of: tab.liveTexts) { _, items in Task { await translateIncoming(items) } }
                .onDisappear { Task { _ = await PageTools.call("RikuganPageTools.stopWatch()", in: tab.webView) } }
        }.task { await collect() }
    }
    static let languages = [
        ("zh-Hans", "简体中文"), ("zh-Hant", "繁体中文"), ("en", "英语"), ("en-GB", "英语（英国）"),
        ("ja", "日语"), ("ko", "韩语"), ("fr", "法语"), ("de", "德语"), ("es", "西班牙语"),
        ("pt-BR", "葡萄牙语（巴西）"), ("pt-PT", "葡萄牙语（葡萄牙）"), ("ru", "俄语"), ("ar", "阿拉伯语"),
        ("it", "意大利语"), ("vi", "越南语"), ("th", "泰语"), ("id", "印尼语"), ("nl", "荷兰语"),
        ("pl", "波兰语"), ("tr", "土耳其语"), ("uk", "乌克兰语"), ("hi", "印地语"), ("cs", "捷克语"),
        ("da", "丹麦语"), ("fi", "芬兰语"), ("el", "希腊语"), ("he", "希伯来语"), ("hu", "匈牙利语"),
        ("ms", "马来语"), ("nb", "挪威语"), ("ro", "罗马尼亚语"), ("sk", "斯洛伐克语"), ("sv", "瑞典语"),
        ("ca", "加泰罗尼亚语"), ("hr", "克罗地亚语"), ("bg", "保加利亚语"),
        ("bn", "孟加拉语"), ("ta", "泰米尔语"), ("te", "泰卢固语"), ("mr", "马拉地语"), ("ur", "乌尔都语"),
        ("fa", "波斯语"), ("fil", "菲律宾语"), ("sw", "斯瓦希里语"), ("sr", "塞尔维亚语"), ("sl", "斯洛文尼亚语"),
        ("et", "爱沙尼亚语"), ("lv", "拉脱维亚语"), ("lt", "立陶宛语"), ("kk", "哈萨克语"), ("mn", "蒙古语")
    ]
    private func collect() async {
        let value = await PageTools.call("RikuganPageTools.collectTexts(0)", in: tab.webView) as? [[String: Any]] ?? []
        rows = value.compactMap { item in
            guard let id = item["id"] as? String, let text = item["text"] as? String else { return nil }
            return (id, text)
        }
        let sample = rows.prefix(8).map(\.text).joined(separator: " ")
        let recognizer = NLLanguageRecognizer(); recognizer.processString(sample)
        status = "检测语言：\(recognizer.dominantLanguage?.rawValue ?? "未知") · \(rows.count) 段"
        await rearm()
    }
    private func rearm() async {
        let backend = model.profile.settings.translationBackend
        guard let next = PageTranslation.configuration(target: model.profile.settings.translateTarget, backend: backend) else {
            configuration = nil
            status = "翻译后端「\(backend)」没有可用实现，没有开始翻译。"
            return
        }
        configuration = next
    }
    private func translate(_ session: TranslationSession) async {
        guard !translating else { return }
        translating = true
        defer { translating = false }
        let cap = rows.filter { !applied.contains($0.id) }
        guard !cap.isEmpty else {
            status = "已翻译 \(applied.count) 段。这个页面打开时会继续补译。"
            _ = await PageTools.call("RikuganPageTools.watchNewText(0)", in: tab.webView)
            return
        }
        var index = 0
        var done = applied.count
        while index < cap.count {
            let batch = Array(cap[index..<min(index + 40, cap.count)])
            let requests = batch.map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
            do {
                let responses = try await session.translations(from: requests)
                try await apply(responses.map { ["id": $0.clientIdentifier ?? "", "text": $0.targetText] })
                batch.forEach { applied.insert($0.id) }
                done = applied.count
                status = "已翻译 \(done) 段"
            } catch {
                status = "翻译停在 \(done) 段：\(error.localizedDescription)"
                return
            }
            index += batch.count
        }
        if rows.contains(where: { !applied.contains($0.id) }) {
            await rearm()
            return
        }
        status = "已翻译 \(done) 段。这个页面打开时会继续补译。"
        _ = await PageTools.call("RikuganPageTools.watchNewText(0)", in: tab.webView)
    }
    private func translateIncoming(_ items: [[String: String]]) async {
        let fresh = items.compactMap { item -> (id: String, text: String)? in
            guard let id = item["id"], let text = item["text"], !applied.contains(id) else { return nil }
            return (id, text)
        }
        guard !fresh.isEmpty else { return }
        rows.append(contentsOf: fresh)
        status = "页面有新文字，正在补译 \(fresh.count) 段"
        guard !translating else { return }
        await rearm()
    }
    private func apply(_ pairs: [[String: String]]) async throws {
        guard let data = try? JSONSerialization.data(withJSONObject: pairs), let json = String(data: data, encoding: .utf8) else { return }
        _ = await PageTools.call("RikuganPageTools.applyTexts(\(json))", in: tab.webView)
    }
    private func toggle() async {
        original.toggle()
        let call = original ? "RikuganPageTools.restoreTexts()" : "RikuganPageTools.applyTexts([])"
        if original { _ = await PageTools.call(call, in: tab.webView) }
        else { await rearm() }
    }
}

struct SiteSettingsSheet: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var model: AppModel
    var host: String { tab.webView.url?.host ?? URL(string: tab.address)?.host ?? "" }
    var body: some View {
        NavigationStack {
            Form {
                if host.isEmpty { Text("打开网页后才能保存站点设置。") }
                else {
                    override("桌面版", key: \.desktopMode)
                    Picker("暗黑模式", selection: optional(\.darkMode)) {
                        Text("跟随全局").tag(String?.none); Text("关闭").tag(String?("off")); Text("自动").tag(String?("auto")); Text("始终").tag(String?("on"))
                    }
                    toggle("内容拦截", key: \.contentBlocking)
                    Picker("外部 App", selection: optional(\.externalNavigation)) { Text("跟随全局").tag(Optional<String>.none); Text("询问").tag(Optional("ask")); Text("允许").tag(Optional("allow")); Text("禁止").tag(Optional("block")) }
                    toggle("用户脚本", key: \.userScriptsEnabled)
                    toggle("JavaScript", key: \.javascriptEnabled, reload: true)
                    Picker("弹窗", selection: optional(\.popups)) { Text("允许").tag(Optional("allow")); Text("询问").tag(Optional("ask")); Text("禁止").tag(Optional("block")) }
                    Picker("网页字体", selection: optional(\.fontFamily)) {
                        Text("跟随身份").tag(String?.none)
                        Text("不覆盖，用网页自己的字体").tag(String?(""))
                        ForEach(FontLibrary.families().prefix(80), id: \.self) { Text($0).tag(String?($0)) }
                    }
                    Section("网页权限") {
                        ForEach(["camera", "microphone", "location", "clipboard", "notification"], id: \.self) { kind in
                            Picker(kind, selection: permission(kind)) { Text("询问").tag("ask"); Text("允许").tag("allow"); Text("禁止").tag("block") }
                        }
                    }
                }
            }.navigationTitle(host.isEmpty ? "站点设置" : host)
        }
    }
    private func snapshot() -> SiteSettings { model.profile.site(for: host) ?? SiteSettings(host: host) }
    private func save(_ site: SiteSettings, reload: Bool = false) {
        model.updateProfile(model.profile.id) { profile in
            if let index = profile.siteSettings.firstIndex(where: { $0.host == host }) { profile.siteSettings[index] = site }
            else { profile.siteSettings.append(site) }
        }
        tab.applyDecorations(); tab.syncContentRules(); tab.session?.refreshScripts()
        if reload, !tab.isHome { tab.webView.reload() }
    }
    private func optional(_ key: WritableKeyPath<SiteSettings, String?>) -> Binding<String?> {
        Binding(get: { snapshot()[keyPath: key] }, set: { value in var site = snapshot(); site[keyPath: key] = value; save(site) })
    }
    private func toggle(_ title: String, key: WritableKeyPath<SiteSettings, Bool?>, reload: Bool = false) -> some View {
        Picker(title, selection: Binding(get: { snapshot()[keyPath: key] }, set: { value in var site = snapshot(); site[keyPath: key] = value; save(site, reload: reload) })) {
            Text("跟随").tag(Optional<Bool>.none); Text("开").tag(Optional(true)); Text("关").tag(Optional(false))
        }
    }
    private func override(_ title: String, key: WritableKeyPath<SiteSettings, Bool?>) -> some View { toggle(title, key: key, reload: true) }
    private func permission(_ kind: String) -> Binding<String> {
        Binding(get: { model.profile.permission(host: host, kind: kind) }, set: { value in
            model.updateProfile(model.profile.id) { profile in
                profile.webPermissions.removeAll { $0.host == host && $0.kind == kind }
                if value != "ask" { profile.webPermissions.append(WebPermission(host: host, kind: kind, decision: value)) }
            }
        })
    }
}

struct ConsoleSheet: View {
    @ObservedObject var tab: BrowserTab
    @State private var source = "document.title"
    @State private var result = "实验功能：在页面主世界执行公开的 evaluateJavaScript。页面 error 和 console.error 会列在下面。完整检查请用 Safari Develop，本 App 已按设置打开 isInspectable。这不是完整的 Web Inspector。"
    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $source).font(.system(.footnote, design: .monospaced)).frame(minHeight: 120)
                Button("运行") { run() }.buttonStyle(.borderedProminent)
                if !tab.consoleLines.isEmpty {
                    Text(tab.consoleLines.suffix(30).joined(separator: "\n")).font(.system(.caption2, design: .monospaced)).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled)
                }
                ScrollView { Text(result).font(.footnote).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            }.padding().navigationTitle("实验控制台")
        }
    }
    private func run() {
        tab.webView.evaluateJavaScript(source) { value, error in
            if let error { result = error.localizedDescription }
            else if let data = try? JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.prettyPrinted]), let text = String(data: data, encoding: .utf8) { result = text }
            else { result = String(describing: value ?? "undefined") }
        }
    }
}

struct AutofillSheet: View {
    @EnvironmentObject var model: AppModel
    var tab: BrowserTab?
    @State private var items: [AutofillItem] = []
    @State private var editing = false
    @State private var draft = AutofillItem(kind: "password", title: "", host: "", username: "", secret: "")
    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("密码、身份和支付备注只放在钥匙串（WhenUnlockedThisDeviceOnly），不写 UserDefaults。填充必须由你点按，不会自动提交。").font(.footnote).foregroundStyle(.secondary)
                    Button("同步到 iCloud 私有数据库") {
                        Task { model.message = await AutofillVault.pushToCloud(profile: model.profile.id, items: items) }
                    }
                    Button("从 iCloud 合并") { Task { await pullCloud() } }
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title.isEmpty ? item.kind : item.title).font(.headline)
                        Text(item.host).font(.caption).foregroundStyle(.secondary)
                        if item.kind == "payment", !item.paymentLast4.isEmpty { Text("•••• \(item.paymentLast4)").font(.caption).foregroundStyle(.secondary) }
                        if !item.address.isEmpty { Text(item.address).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                        if tab != nil { Button("填入当前网页") { Task { await fill(item) } }.font(.subheadline) }
                    }
                }.onDelete { index in items.remove(atOffsets: index); try? AutofillVault.save(profile: model.profile.id, items: items) }
            }.navigationTitle("自动填充")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("添加", systemImage: "plus") { editing = true } } }
                .onAppear { items = AutofillVault.load(profile: model.profile.id); Task { await pullCloud() } }
                .sheet(isPresented: $editing) { AutofillEditor(draft: $draft) { items.append(draft); try? AutofillVault.save(profile: model.profile.id, items: items); draft = AutofillItem(kind: "password", title: "", host: "", username: "", secret: "") } }
        }
    }
    private func fill(_ item: AutofillItem) async {
        guard let tab else { return }
        let payload = AutofillVault.fillPayload(item)
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        _ = await PageTools.call("RikuganPageTools.fill(\(json))", in: tab.webView)
    }
    private func pullCloud() async {
        guard let remote = await AutofillVault.pullFromCloud(profile: model.profile.id) else { return }
        let merged = AutofillVault.merge(local: items, remote: remote)
        items = merged
        try? AutofillVault.save(profile: model.profile.id, items: merged)
    }
}

struct AutofillEditor: View {
    @Binding var draft: AutofillItem
    var save: () -> Void
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $draft.kind) { Text("密码").tag("password"); Text("身份").tag("identity"); Text("支付备注").tag("payment") }
                TextField("标题", text: $draft.title); TextField("网站", text: $draft.host).textInputAutocapitalization(.never)
                TextField("用户名", text: $draft.username).textInputAutocapitalization(.never)
                SecureField("密码或卡号", text: $draft.secret)
                TextField("姓名", text: $draft.name); TextField("邮箱", text: $draft.email); TextField("电话", text: $draft.phone)
                TextField("地址", text: $draft.address)
                TextField("支付标签", text: $draft.paymentLabel); TextField("末四位", text: $draft.paymentLast4)
            }.navigationTitle("钥匙串条目")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { save(); dismiss() } }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

struct ContentBlockingView: View {
    @EnvironmentObject var model: AppModel
    @State private var rule = ""
    @State private var subName = "AdGuard"
    @State private var subURL = ""
    var body: some View {
        Form {
            Toggle("内容拦截", isOn: setting(\.contentBlocking))
            Toggle("内置常见广告域名", isOn: setting(\.builtInRules))
            Section("自定义规则") {
                ForEach(model.profile.settings.customRules) { rule in
                    Text(rule.text).font(.system(.footnote, design: .monospaced))
                }.onDelete { index in
                    model.updateProfile(model.profile.id) { $0.settings.customRules.remove(atOffsets: index) }
                    rebuild()
                }
                TextField("example.com##.ad 或 ||ads.example^", text: $rule).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("添加规则") {
                    let text = rule.trimmingCharacters(in: .whitespaces)
                    guard !text.isEmpty else { return }
                    model.updateProfile(model.profile.id) { $0.settings.customRules.append(CustomBlockRule(text: text)) }
                    rule = ""; rebuild()
                }
            }
            Section("AdGuard 订阅") {
                ForEach(model.profile.settings.subscriptions) { sub in
                    VStack(alignment: .leading) {
                        Text(sub.name)
                        Text(sub.url).font(.caption2).foregroundStyle(.secondary)
                        Text(sub.body.isEmpty ? "尚未下载" : "\(sub.body.split(separator: "\n").count) 行").font(.caption)
                        Button("重新下载") { Task { await refreshSubscription(sub) } }.font(.caption)
                    }
                }.onDelete { index in model.updateProfile(model.profile.id) { $0.settings.subscriptions.remove(atOffsets: index) }; rebuild() }
                TextField("名称", text: $subName)
                TextField("https://…/filters.txt", text: $subURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("添加并下载") { Task { await addSubscription() } }
                Button("订阅 EasyList") {
                    subName = "EasyList"
                    subURL = "https://easylist.to/easylist/easylist.txt"
                    Task { await addSubscription() }
                }
            }
            Text("内置规则、自定义规则和第三方列表都会编译并安装到网页。订阅按原文件下载，单次上限 8 MB，不把 EasyList 打进安装包。网络规则和元素隐藏进 WKContentRuleList。#%# 和 ##+js 里的 abort-on-property-read、abort-on-property-write、json-prune、set-constant、prevent-fetch、prevent-xhr 会在页面开始时执行。带 noopjs、empty、1x1 的规则网络动作是拦截，不是重定向，也不会返回空的 2xx。页面会另外定义空值：__rgRedirect.noopjs 是空函数，__rgRedirect.empty 是空字符串，__rgRedirect.pixel 是 1×1 透明图的 data URL，并对该域名 prevent-fetch。removeparam 会在主框架跳转前去掉对应查询参数。csp 会插入 meta 策略。replace 会改主框架 HTML，以及之后 fetch/XHR 读到的文本；图片、音视频和二进制响应跳过。").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("内容拦截")
    }
    private func setting(_ key: WritableKeyPath<BrowserSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.profile.settings[keyPath: key] }, set: { value in model.updateProfile(model.profile.id) { $0.settings[keyPath: key] = value }; rebuild() })
    }
    private func refreshSubscription(_ sub: FilterSubscription) async {
        guard let url = URL(string: sub.url), url.scheme == "https" else { model.message = "订阅只接受 HTTPS。"; return }
        do {
            let text = try await ScriptNetwork.downloadText(url)
            model.updateProfile(model.profile.id) { profile in
                if let index = profile.settings.subscriptions.firstIndex(where: { $0.id == sub.id }) {
                    profile.settings.subscriptions[index].body = text
                    profile.settings.subscriptions[index].updatedAt = Date()
                }
            }
            rebuild()
        } catch { model.message = error.localizedDescription }
    }
    private func addSubscription() async {
        guard let url = URL(string: subURL), url.scheme == "https" else { model.message = "订阅只接受 HTTPS。"; return }
        do {
            let text = try await ScriptNetwork.downloadText(url)
            model.updateProfile(model.profile.id) { $0.settings.subscriptions.append(FilterSubscription(name: subName.isEmpty ? "订阅" : subName, url: subURL, body: text, updatedAt: Date())) }
            subURL = ""; rebuild()
        } catch { model.message = error.localizedDescription }
    }
    private func rebuild() { if let session = model.session { Task { await BlockListCoordinator.rebuild(session, announce: true) } } }
}

struct FontSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var importing = false
    var body: some View {
        Form {
            Picker("正文", selection: Binding(get: { model.profile.settings.webFontFamily }, set: { value in
                model.updateProfile(model.profile.id) { $0.settings.webFontFamily = value }
                model.session?.tabs.forEach { if $0.webViewIfLive() != nil { $0.applyDecorations() } }
            })) {
                Text("不覆盖").tag("")
                ForEach(FontLibrary.families(), id: \.self) { Text($0).tag($0) }
            }
            Picker("标题", selection: Binding(get: { model.profile.settings.headingFontFamily }, set: { value in
                model.updateProfile(model.profile.id) { $0.settings.headingFontFamily = value }
                model.session?.tabs.forEach { if $0.webViewIfLive() != nil { $0.applyDecorations() } }
            })) {
                Text("跟随正文").tag("")
                ForEach(FontLibrary.families(), id: \.self) { Text($0).tag($0) }
            }
            Picker("等宽", selection: Binding(get: { model.profile.settings.monospaceFontFamily }, set: { value in
                model.updateProfile(model.profile.id) { $0.settings.monospaceFontFamily = value }
                model.session?.tabs.forEach { if $0.webViewIfLive() != nil { $0.applyDecorations() } }
            })) {
                Text("跟随正文").tag("")
                ForEach(FontLibrary.families(), id: \.self) { Text($0).tag($0) }
            }
            Button("安装字体文件") { importing = true }
            Text("列表包含系统字体，以及通过描述文件安装后能被 UIFont 看到的字体。导入的 ttf、otf、ttc 会注册到本进程，并用 data URL 注入网页。woff / woff2 Core Text 不能注册，导入会被拒绝。正文、标题和等宽分开设置，不使用全页 * 选择器。Material Icons、Font Awesome 和 iconfont 会写回原来的字体家族。站点可以选择不覆盖。").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("网页字体")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.font, .data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { do { try model.importFont(url) } catch { model.message = error.localizedDescription } }
            }
    }
}

struct CapabilityView: View {
    var body: some View {
        List {
            ForEach(ChromeAPIMatrix.entries, id: \.api) { entry in
                Section {
                    Text(entry.note).font(.footnote).foregroundStyle(.secondary)
                    ForEach(ChromeAPIMatrix.methods.filter { $0.api == entry.api }, id: \.name) { method in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack { Text(method.name).font(.subheadline); Spacer(); Text(method.level).font(.caption.weight(.semibold)).foregroundStyle(method.level == "Unsupported" ? .red : method.level == "Partial" ? .orange : .green) }
                            Text(method.note).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    HStack { Text(entry.api); Spacer(); Text(entry.level).foregroundStyle(entry.level == "Unsupported" ? .red : entry.level == "Partial" ? .orange : .green) }
                }
            }
        }.navigationTitle("扩展 API")
    }
}

struct DiagnosticsView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var session: BrowserSession
    var body: some View {
        List {
            LabeledContent("App version", value: appVersion)
            LabeledContent("Git commit", value: Bundle.main.infoDictionary?["RikuganGitCommit"] as? String ?? "local")
            LabeledContent("Build date", value: Bundle.main.infoDictionary?["RikuganBuildDate"] as? String ?? "local")
            LabeledContent("Device / OS", value: "\(UIDevice.current.model) · \(UIDevice.current.systemName) \(UIDevice.current.systemVersion)")
            LabeledContent("Profile", value: model.profile.name)
            LabeledContent("Tabs", value: "\(session.tabs.count)")
            LabeledContent("Live WebView", value: "\(session.tabs.filter { $0.webViewIfLive() != nil }.count)")
            LabeledContent("Suspended", value: "\(session.tabs.filter { $0.phase == .suspended }.count)")
            LabeledContent("Terminated", value: "\(session.tabs.filter { $0.phase == .terminated }.count)")
            LabeledContent("Userscripts", value: model.profile.scripts.filter(\.enabled).map(\.name).joined(separator: ", ").ifEmpty("none"))
            LabeledContent("Extensions", value: model.profile.extensions.map(\.name).joined(separator: ", ").ifEmpty("none"))
            LabeledContent("Background", value: session.extensionPhase.rawValue)
            if !session.extensionPhaseError.isEmpty { Text(session.extensionPhaseError).font(.caption).foregroundStyle(.red) }
            LabeledContent("DNR redirect", value: "Unsupported")
            LabeledContent("DNR modifyHeaders", value: "Unsupported")
            LabeledContent("App Group", value: FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupID.suite) == nil ? "unavailable" : AppGroupID.suite)
            LabeledContent("Share Extension", value: sharePresent ? "embedded" : "not in bundle")
            LabeledContent("Web Inspector", value: model.profile.settings.inspectable ? "enabled" : "off")
            Section("Last runtime errors") {
                if model.runtimeLog.isEmpty { Text("none").foregroundStyle(.secondary) }
                ForEach(Array(model.runtimeLog.enumerated()), id: \.offset) { _, line in Text(line).font(.caption) }
            }
            Button("Export Diagnostics") { export() }
            Text("诊断文件不含历史、Cookie、密码或页面正文。PlayCover 上的结果不能写成 iPhone 通过。").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("诊断")
    }
    private var appVersion: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.2.0"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }
    private var sharePresent: Bool {
        let plugins = Bundle.main.builtInPlugInsURL
        guard let plugins, let items = try? FileManager.default.contentsOfDirectory(at: plugins, includingPropertiesForKeys: nil) else { return false }
        return items.contains { $0.lastPathComponent.contains("Share") }
    }
    private func export() {
        let payload: [String: Any] = [
            "appVersion": appVersion,
            "commit": Bundle.main.infoDictionary?["RikuganGitCommit"] as? String ?? "local",
            "buildDate": Bundle.main.infoDictionary?["RikuganBuildDate"] as? String ?? "local",
            "os": UIDevice.current.systemVersion,
            "profile": model.profile.name,
            "tabs": session.tabs.count,
            "liveWebViews": session.tabs.filter { $0.webViewIfLive() != nil }.count,
            "suspended": session.tabs.filter { $0.phase == .suspended }.count,
            "terminated": session.tabs.filter { $0.phase == .terminated }.count,
            "userscripts": model.profile.scripts.map(\.name),
            "extensions": model.profile.extensions.map { ["name": $0.name, "version": $0.version] },
            "background": session.extensionPhase.rawValue,
            "backgroundError": session.extensionPhaseError,
            "appGroup": FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: AppGroupID.suite) != nil,
            "shareExtension": sharePresent,
            "webInspector": model.profile.settings.inspectable,
            "runtimeLog": model.runtimeLog,
            "api": ChromeAPIMatrix.entries.map { ["api": $0.api, "level": $0.level] }
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("Rikugan-diagnostics.json")
        try? data.write(to: url, options: .atomic)
        BrowserPresentation.share([url])
    }
}

private extension String {
    func ifEmpty(_ fallback: String) -> String { isEmpty ? fallback : self }
}

struct DownloadList: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var center: DownloadCenter
    @State private var exportURL: URL?
    var body: some View {
        Group { downloadRows }
        .sheet(isPresented: Binding(get: { exportURL != nil }, set: { if !$0 { exportURL = nil } })) {
            if let exportURL { DocumentExport(url: exportURL) }
        }
    }
    @ViewBuilder private var downloadRows: some View {
        let records = model.profile.downloads
        if records.isEmpty { Text("还没有下载文件").foregroundStyle(.secondary) }
        ForEach(records) { record in
            let live = center.live[record.id]
            VStack(alignment: .leading, spacing: 6) {
                Text(record.name).font(.subheadline)
                if record.state == "running" || record.state == "paused" {
                    let received = live?.received ?? record.received
                    let total = live?.total ?? record.total
                    ProgressView(value: total > 0 ? Double(received) / Double(total) : nil)
                    Text([record.state == "paused" ? "已暂停" : "下载中", total > 0 ? "\(Int(Double(received) / Double(total) * 100))%" : nil, ByteFormat.speed(live?.speed ?? 0), ByteFormat.remaining(received: received, total: total, speed: live?.speed ?? 0)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if record.resumable && record.state == "running" { Button("暂停") { center.pause(record.id) } }
                        if record.state == "paused" { Button("继续") { center.resume(record.id) } }
                        Button("取消") { center.cancel(record.id) }
                    }.font(.caption)
                } else {
                    Text(record.state == "finished" ? "已完成 · \(ByteFormat.bytes(record.total))" : record.state).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if record.state == "finished" {
                            let file = center.fileURL(record, profile: model.profile.id)
                            ShareLink(item: file) { Image(systemName: "square.and.arrow.up") }
                            Button("保存到文件") { exportURL = file }
                            NavigationLink("打开") { QuickLookView(url: file) }
                        }
                        Button("删除", role: .destructive) { center.delete(record.id) }
                    }.font(.caption)
                }
            }
        }
    }
}

struct DocumentExport: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        UIDocumentPickerViewController(forExporting: [url], asCopy: true)
    }
    func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {}
}

struct QuickLookView: UIViewControllerRepresentable {
    let url: URL
    func makeCoordinator() -> Coordinator { Coordinator(url: url) }
    func makeUIViewController(context: Context) -> QLPreviewController {
        let controller = QLPreviewController(); controller.dataSource = context.coordinator; return controller
    }
    func updateUIViewController(_ controller: QLPreviewController, context: Context) {}
    final class Coordinator: NSObject, QLPreviewControllerDataSource {
        let url: URL
        init(url: URL) { self.url = url }
        func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
        func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
    }
}

struct SourceEditor: UIViewRepresentable {
    @Binding var text: String
    var query: String
    var tick: Int
    func makeCoordinator() -> Coordinator { Coordinator(text: $text) }
    func makeUIView(context: Context) -> UIView {
        let container = UIView()
        let gutter = UITextView(); gutter.isEditable = false; gutter.isSelectable = false; gutter.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        gutter.textColor = .secondaryLabel; gutter.backgroundColor = .clear; gutter.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 0)
        let code = UITextView(); code.font = gutter.font; code.autocorrectionType = .no; code.autocapitalizationType = .none
        code.smartDashesType = .no; code.smartQuotesType = .no; code.delegate = context.coordinator
        code.accessibilityIdentifier = "script.source"; code.text = text; code.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 8, right: 8)
        gutter.translatesAutoresizingMaskIntoConstraints = false; code.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(gutter); container.addSubview(code)
        NSLayoutConstraint.activate([
            gutter.leadingAnchor.constraint(equalTo: container.leadingAnchor), gutter.topAnchor.constraint(equalTo: container.topAnchor), gutter.bottomAnchor.constraint(equalTo: container.bottomAnchor), gutter.widthAnchor.constraint(equalToConstant: 44),
            code.leadingAnchor.constraint(equalTo: gutter.trailingAnchor), code.trailingAnchor.constraint(equalTo: container.trailingAnchor), code.topAnchor.constraint(equalTo: container.topAnchor), code.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
        context.coordinator.code = code; context.coordinator.gutter = gutter; context.coordinator.refresh()
        return container
    }
    func updateUIView(_ view: UIView, context: Context) {
        if context.coordinator.code?.text != text { context.coordinator.code?.text = text; context.coordinator.refresh() }
        if context.coordinator.tick != tick { context.coordinator.tick = tick; context.coordinator.jump(query) }
    }
    final class Coordinator: NSObject, UITextViewDelegate {
        @Binding var text: String
        weak var code: UITextView?
        weak var gutter: UITextView?
        var tick = -1
        var cursor = 0
        init(text: Binding<String>) { _text = text }
        func textViewDidChange(_ textView: UITextView) { text = textView.text; refresh() }
        func scrollViewDidScroll(_ scrollView: UIScrollView) { gutter?.contentOffset.y = scrollView.contentOffset.y }
        func refresh() {
            let count = max(1, text.components(separatedBy: "\n").count)
            gutter?.text = (1...count).map { String($0) }.joined(separator: "\n")
        }
        func jump(_ query: String) {
            guard let code, !query.isEmpty else { return }
            let ns = text as NSString
            let range = ns.range(of: query, options: [], range: NSRange(location: cursor, length: max(0, ns.length - cursor)))
            let found = range.location == NSNotFound ? ns.range(of: query) : range
            guard found.location != NSNotFound else { return }
            code.selectedRange = found
            code.scrollRangeToVisible(found)
            cursor = found.location + found.length
        }
    }
}
