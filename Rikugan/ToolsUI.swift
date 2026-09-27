import SwiftUI
import WebKit
import UIKit
import PhotosUI
import Photos
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

struct ReaderSheet: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var author = ""
    @State private var text = ""
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(title.isEmpty ? tab.pageTitle : title).font(.system(size: model.profile.settings.reader.fontSize + 6, weight: .bold))
                    if !author.isEmpty { Text(author).font(.subheadline).foregroundStyle(.secondary) }
                    Text(text.isEmpty ? "没有识别到正文。" : text).font(.system(size: model.profile.settings.reader.fontSize)).lineSpacing(model.profile.settings.reader.fontSize * (model.profile.settings.reader.lineHeight - 1))
                }.padding(22).frame(maxWidth: 720, alignment: .leading)
            }
            .background(theme.ignoresSafeArea())
            .navigationTitle("阅读模式")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("完成") { dismiss() } } }
        }.task { await load() }
    }
    private var theme: Color {
        switch model.profile.settings.reader.theme {
        case "dark": return Color(white: 0.12)
        case "light": return .white
        default: return Color(red: 0.96, green: 0.93, blue: 0.86)
        }
    }
    private func load() async {
        guard let value = await PageTools.call("RikuganPageTools.extractArticle()", in: tab.webView) as? [String: Any] else { return }
        title = value["title"] as? String ?? ""
        author = value["author"] as? String ?? ""
        text = value["text"] as? String ?? ""
    }
}

struct MediaSheet: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var model: AppModel
    @State private var items: [[String: Any]] = []
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
                        Button("下载") { if let raw = item["url"] as? String, let url = URL(string: raw) { model.downloadCenter.start(url: url, from: tab) } }.font(.subheadline)
                    }
                }
            }.navigationTitle("媒体")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("刷新") { Task { await load() } } } }
        }.task { await load() }
    }
    private func load() async {
        items = await PageTools.call("RikuganPageTools.collectMedia()", in: tab.webView) as? [[String: Any]] ?? []
    }
}

struct ImageSheet: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var model: AppModel
    @State private var urls: [String] = []
    @State private var selected = Set<String>()
    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 110), spacing: 8)], spacing: 8) {
                    ForEach(urls, id: \.self) { url in
                        WebsiteImageThumbnail(tab: tab, rawURL: url)
                            .frame(height: 110).clipped().overlay(alignment: .topTrailing) { if selected.contains(url) { Image(systemName: "checkmark.circle.fill").padding(6) } }
                            .onTapGesture { if selected.contains(url) { selected.remove(url) } else { selected.insert(url) } }
                            .contextMenu {
                                Button("复制链接") { UIPasteboard.general.string = url }
                                Button("保存") { Task { await save([url]) } }
                                if let link = URL(string: url) { ShareLink(item: link) { Text("分享") } }
                            }
                    }
                }.padding(8)
            }.navigationTitle("图片 \(selected.count)/\(urls.count)")
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
        guard let webView = tab.existingWebView else { model.message = "页面已经被系统回收，请重新打开后保存图片。"; return }
        let userAgent = await PageTools.call("navigator.userAgent", in: webView) as? String
        var images: [UIImage] = [], fetchFailures = 0
        for link in links {
            guard let url = URL(string: link) else { fetchFailures += 1; continue }
            do {
                let (data, _) = try await WebsiteResourceFetcher.data(from: url, store: webView.configuration.websiteDataStore,
                    referer: webView.url, userAgent: userAgent)
                guard let image = UIImage(data: data) else { fetchFailures += 1; continue }
                images.append(image)
            } catch { fetchFailures += 1 }
        }
        guard !images.isEmpty else { model.message = "没有取得可保存的图片。失败 \(fetchFailures) 张。"; return }
        let authorization = await PhotoSaver.authorization()
        guard authorization == .authorized || authorization == .limited else {
            model.message = "没有照片添加权限。可在系统设置中允许 Rikugan 添加照片。"; return
        }
        var saved = 0, photoFailures = 0
        for image in images {
            do { try await PhotoSaver.write(image); saved += 1 }
            catch { photoFailures += 1 }
        }
        let failed = fetchFailures + photoFailures
        model.message = saved == 0 ? "没有保存任何图片。失败 \(failed) 张。" : "已保存 \(saved) 张" + (failed > 0 ? "，失败 \(failed) 张。" : "图片。")
    }
}

struct WebsiteImageThumbnail: View {
    @ObservedObject var tab: BrowserTab
    let rawURL: String
    @State private var image: UIImage?
    @State private var failed = false
    var body: some View {
        Group {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else if failed { Image(systemName: "photo.badge.exclamationmark").frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
            else { ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity).background(.quaternary) }
        }.task(id: rawURL) { await load() }
    }
    private func load() async {
        guard let url = URL(string: rawURL), let webView = tab.existingWebView else { failed = true; return }
        let userAgent = await PageTools.call("navigator.userAgent", in: webView) as? String
        do {
            let (data, _) = try await WebsiteResourceFetcher.data(from: url, store: webView.configuration.websiteDataStore,
                referer: webView.url, userAgent: userAgent, limit: 8 * 1024 * 1024)
            guard let decoded = UIImage(data: data) else { failed = true; return }
            image = decoded
        } catch { failed = true }
    }
}

enum PhotoSaver {
    static func authorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { continuation.resume(returning: $0) }
        }
    }
    static func write(_ image: UIImage) async throws {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges({ PHAssetChangeRequest.creationRequestForAsset(from: image) }) { success, error in
                if success { continuation.resume() }
                else { continuation.resume(throwing: error ?? RikuganError.message("系统没有保存这张图片。")) }
            }
        }
    }
}

struct QRSheet: View {
    let address: String
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
                if !scanned.isEmpty { Text(scanned).font(.headline).textSelection(.enabled) }
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

struct TranslateSheet: View {
    @ObservedObject var tab: BrowserTab
    @EnvironmentObject var model: AppModel
    @State private var configuration: TranslationSession.Configuration?
    @State private var rows: [(id: String, text: String)] = []
    @State private var status = "正在提取页面文字"
    @State private var original = false
    @State private var translatedPairs: [[String: String]] = []
    var body: some View {
        NavigationStack {
            Form {
                Text(status).font(.footnote)
                Picker("目标语言", selection: Binding(get: { model.profile.settings.translateTarget }, set: { value in
                    model.updateProfile(model.profile.id) { $0.settings.translateTarget = value }
                    translatedPairs = []; original = false
                    configuration = TranslationSession.Configuration(target: Locale.Language(identifier: value))
                })) {
                    ForEach(Self.languages, id: \.0) { Text($0.1).tag($0.0) }
                }
                Button(original ? "显示译文" : "显示原文") { Task { await toggle() } }.disabled(rows.isEmpty)
                Text("翻译层目前是 Apple 设备端 Translation。换 provider 时实现 Translation 调用点即可，页面替换逻辑不用重写。未下载的语言包会由系统提示，不会假装已经译完。").font(.footnote).foregroundStyle(.secondary)
            }.navigationTitle("翻译网页")
                .translationTask(configuration) { session in await translate(session) }
        }.task { await collect() }
    }
    static let languages = [("zh-Hans", "简体中文"), ("zh-Hant", "繁体中文"), ("en", "英语"), ("ja", "日语"), ("ko", "韩语"), ("fr", "法语"), ("de", "德语"), ("es", "西班牙语"), ("pt", "葡萄牙语"), ("ru", "俄语"), ("ar", "阿拉伯语"), ("it", "意大利语"), ("vi", "越南语"), ("th", "泰语"), ("id", "印尼语"), ("nl", "荷兰语"), ("pl", "波兰语"), ("tr", "土耳其语"), ("uk", "乌克兰语"), ("hi", "印地语")]
    private func collect() async {
        let value = await PageTools.call("RikuganPageTools.collectTexts(80)", in: tab.webView) as? [[String: Any]] ?? []
        rows = value.compactMap { item in
            guard let id = item["id"] as? String, let text = item["text"] as? String else { return nil }
            return (id, text)
        }
        let sample = rows.prefix(6).map(\.text).joined(separator: " ")
        let recognizer = NLLanguageRecognizer(); recognizer.processString(sample)
        status = "检测语言：\(recognizer.dominantLanguage?.rawValue ?? "未知") · \(rows.count) 段"
        configuration = TranslationSession.Configuration(target: Locale.Language(identifier: model.profile.settings.translateTarget))
    }
    private func translate(_ session: TranslationSession) async {
        let requests = rows.prefix(80).map { TranslationSession.Request(sourceText: $0.text, clientIdentifier: $0.id) }
        do {
            let responses = try await session.translations(from: Array(requests))
            let pairs: [[String: String]] = responses.map { ["id": $0.clientIdentifier ?? "", "text": $0.targetText] }
            translatedPairs = pairs
            guard let data = try? JSONSerialization.data(withJSONObject: pairs), let json = String(data: data, encoding: .utf8) else { return }
            _ = await PageTools.call("RikuganPageTools.applyTexts(\(json))", in: tab.webView)
            status = "已替换 \(responses.count) 段文字，版面结构保持为原来的文本节点。"
        } catch { status = "翻译没有完成：\(error.localizedDescription)" }
    }
    private func toggle() async {
        original.toggle()
        if original { _ = await PageTools.call("RikuganPageTools.restoreTexts()", in: tab.webView) }
        else if !translatedPairs.isEmpty,
                let data = try? JSONSerialization.data(withJSONObject: translatedPairs),
                let json = String(data: data, encoding: .utf8) {
            _ = await PageTools.call("RikuganPageTools.applyTexts(\(json))", in: tab.webView)
        } else {
            configuration = TranslationSession.Configuration(target: Locale.Language(identifier: model.profile.settings.translateTarget))
        }
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
                    override("桌面版", key: \.desktopMode, reload: true)
                    Picker("暗黑模式", selection: optional(\.darkMode)) {
                        Text("跟随全局").tag(String?.none); Text("关闭").tag(String?("off")); Text("自动").tag(String?("auto")); Text("始终").tag(String?("on"))
                    }
                    toggle("内容拦截", key: \.contentBlocking)
                    Picker("网页字体", selection: optional(\.webFontFamily)) {
                        Text("跟随全局").tag(Optional<String>.none)
                        Text("不覆盖").tag(Optional(""))
                        ForEach(FontLibrary.families(), id: \.self) { Text($0).tag(Optional($0)) }
                    }
                    Picker("外部 App", selection: optional(\.externalNavigation)) { Text("跟随全局").tag(Optional<String>.none); Text("询问").tag(Optional("ask")); Text("允许").tag(Optional("allow")); Text("禁止").tag(Optional("block")) }
                    toggle("用户脚本", key: \.userScriptsEnabled, reload: true)
                    toggle("JavaScript", key: \.javascriptEnabled, reload: true)
                    Picker("弹窗", selection: optional(\.popups)) { Text("跟随").tag(String?.none); Text("允许").tag(Optional("allow")); Text("询问").tag(Optional("ask")); Text("禁止").tag(Optional("block")) }
                    Section("网页权限") {
                        ForEach(["camera", "microphone", "location", "clipboard"], id: \.self) { kind in
                            Picker(kind, selection: permission(kind)) { Text("询问").tag("ask"); Text("允许").tag("allow"); Text("禁止").tag("block") }
                        }
                    }
                }
            }.navigationTitle(host.isEmpty ? "站点设置" : host)
        }
    }
    private func snapshot() -> SiteSettings { model.profile.site(for: host) ?? SiteSettings(host: host) }
    private func save(_ site: SiteSettings, reload: Bool = false) {
        var normalized = site; normalized.host = host.lowercased()
        model.updateProfile(model.profile.id) { profile in
            if let index = profile.siteSettings.firstIndex(where: { $0.host.lowercased() == normalized.host }) { profile.siteSettings[index] = normalized }
            else { profile.siteSettings.append(normalized) }
        }
        tab.applyDecorations(); tab.syncContentRules(); tab.session?.refreshScripts()
        if reload { tab.webView.reload() }
    }
    private func optional(_ key: WritableKeyPath<SiteSettings, String?>) -> Binding<String?> {
        Binding(get: { snapshot()[keyPath: key] }, set: { value in var site = snapshot(); site[keyPath: key] = value; save(site) })
    }
    private func toggle(_ title: String, key: WritableKeyPath<SiteSettings, Bool?>, reload: Bool = false) -> some View {
        Picker(title, selection: Binding(get: { snapshot()[keyPath: key] }, set: { value in var site = snapshot(); site[keyPath: key] = value; save(site, reload: reload) })) {
            Text("跟随").tag(Optional<Bool>.none); Text("开").tag(Optional(true)); Text("关").tag(Optional(false))
        }
    }
    private func override(_ title: String, key: WritableKeyPath<SiteSettings, Bool?>, reload: Bool = false) -> some View { toggle(title, key: key, reload: reload) }
    private func permission(_ kind: String) -> Binding<String> {
        Binding(get: { model.profile.permission(host: host, kind: kind) }, set: { value in
            model.updateProfile(model.profile.id) { profile in
                let normalizedHost = host.lowercased()
                profile.webPermissions.removeAll { $0.host.lowercased() == normalizedHost && $0.kind == kind }
                if value != "ask" { profile.webPermissions.append(WebPermission(host: normalizedHost, kind: kind, decision: value)) }
            }
        })
    }
}

struct ConsoleSheet: View {
    @ObservedObject var tab: BrowserTab
    @State private var source = "document.title"
    @State private var result = "实验功能：在页面主世界执行公开的 evaluateJavaScript。完整检查请用 Safari Develop，本 App 已按设置打开 isInspectable。"
    var body: some View {
        NavigationStack {
            VStack {
                TextEditor(text: $source).font(.system(.footnote, design: .monospaced)).frame(minHeight: 120)
                Button("运行") { run() }.buttonStyle(.borderedProminent)
                ScrollView { Text(result).font(.footnote).frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled) }
            }.padding().navigationTitle("实验控制台")
        }
    }
    private func run() {
        tab.webView.evaluateJavaScript(source) { value, error in
            if let error { result = error.localizedDescription }
            else if let data = try? JSONSerialization.data(withJSONObject: value ?? NSNull(), options: [.prettyPrinted, .fragmentsAllowed]), let text = String(data: data, encoding: .utf8) { result = text }
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
                }
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.title.isEmpty ? item.kind : item.title).font(.headline)
                        Text(item.host).font(.caption).foregroundStyle(.secondary)
                        if let tab {
                            let allowed = AutofillPolicy.canFill(item, pageURL: tab.existingWebView?.url ?? URL(string: tab.address))
                            Button("填入当前网页") { Task { await fill(item) } }.font(.subheadline).disabled(!allowed)
                            if !allowed { Text("网站不匹配；编辑条目的网站或使用对应站点的条目。").font(.caption2).foregroundStyle(.orange) }
                        }
                    }.contextMenu { Button("编辑") { draft = item; editing = true } }
                }.onDelete(perform: deleteItems)
            }.navigationTitle("自动填充")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("添加", systemImage: "plus") { editing = true } } }
                .onAppear {
                    do { items = try AutofillVault.loadChecked(profile: model.profile.id) }
                    catch { model.message = error.localizedDescription }
                }
                .sheet(isPresented: $editing) { AutofillEditor(draft: $draft) { saveDraft() } }
        }
    }
    private func fill(_ item: AutofillItem) async {
        guard let tab else { return }
        guard AutofillPolicy.canFill(item, pageURL: tab.existingWebView?.url ?? URL(string: tab.address)) else {
            model.message = "这个自动填充条目不属于当前网站。"; return
        }
        let payload: [String: String] = [
            "username": item.username,
            "password": item.kind == "password" ? item.secret : "",
            "name": item.name,
            "email": item.email,
            "phone": item.phone,
            "address": item.address,
            "cardNumber": item.kind == "payment" ? item.secret : "",
            "cardName": item.kind == "payment" ? item.name : ""
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: payload), let json = String(data: data, encoding: .utf8) else { return }
        _ = await PageTools.call("RikuganPageTools.fill(\(json))", in: tab.webView)
    }
    private func saveDraft() -> Bool {
        do {
            let clean = try draft.validated()
            var next = items
            if let index = next.firstIndex(where: { $0.id == clean.id }) { next[index] = clean } else { next.append(clean) }
            try AutofillVault.save(profile: model.profile.id, items: next)
            items = next
            draft = AutofillItem(kind: "password", title: "", host: "", username: "", secret: "")
            return true
        } catch { model.message = error.localizedDescription; return false }
    }
    private func deleteItems(_ offsets: IndexSet) {
        var next = items; next.remove(atOffsets: offsets)
        do { try AutofillVault.save(profile: model.profile.id, items: next); items = next }
        catch { model.message = error.localizedDescription }
    }
}

struct AutofillEditor: View {
    @Binding var draft: AutofillItem
    var save: () -> Bool
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        NavigationStack {
            Form {
                Picker("类型", selection: $draft.kind) { Text("密码").tag("password"); Text("身份").tag("identity"); Text("支付备注").tag("payment") }
                TextField("标题", text: $draft.title); TextField("网站", text: $draft.host).textInputAutocapitalization(.never)
                if draft.kind == "password" {
                    TextField("用户名", text: $draft.username).textInputAutocapitalization(.never)
                    SecureField("密码", text: $draft.secret)
                } else if draft.kind == "identity" {
                    TextField("姓名", text: $draft.name); TextField("邮箱", text: $draft.email).textInputAutocapitalization(.never)
                    TextField("电话", text: $draft.phone).keyboardType(.phonePad); TextField("地址", text: $draft.address)
                } else {
                    TextField("持卡人姓名", text: $draft.name)
                    SecureField("卡号", text: $draft.secret).keyboardType(.numberPad)
                    TextField("支付标签", text: $draft.paymentLabel); TextField("末四位（可留空自动生成）", text: $draft.paymentLast4).keyboardType(.numberPad)
                }
            }.navigationTitle("钥匙串条目")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("保存") { if save() { dismiss() } } }; ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
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
                    VStack(alignment: .leading) { Text(sub.name); Text(sub.url).font(.caption2).foregroundStyle(.secondary); Text(sub.body.isEmpty ? "尚未下载" : "\(sub.body.split(separator: "\n").count) 行").font(.caption) }
                }.onDelete { index in model.updateProfile(model.profile.id) { $0.settings.subscriptions.remove(atOffsets: index) }; rebuild() }
                TextField("名称", text: $subName)
                TextField("https://…/filters.txt", text: $subURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("添加并下载") { Task { await addSubscription() } }
            }
            if let error = model.session?.contentRuleError { Text(error).font(.footnote).foregroundStyle(.red) }
            Text("网络和元素隐藏规则编译为 WKContentRuleList。只解析兼容子集；不支持的语法不会扩大成无条件拦截，最多约 1500 条网络规则。").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("内容拦截")
    }
    private func setting(_ key: WritableKeyPath<BrowserSettings, Bool>) -> Binding<Bool> {
        Binding(get: { model.profile.settings[keyPath: key] }, set: { value in model.updateProfile(model.profile.id) { $0.settings[keyPath: key] = value }; rebuild() })
    }
    private func addSubscription() async {
        guard let url = URL(string: subURL), url.scheme == "https" else { model.message = "订阅只接受 HTTPS。"; return }
        do {
            let text = try await ScriptNetwork.downloadText(url)
            let body = String(text.prefix(1_500_000))
            model.updateProfile(model.profile.id) { $0.settings.subscriptions.append(FilterSubscription(name: subName.isEmpty ? "订阅" : subName, url: subURL, body: body, updatedAt: Date())) }
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
            Picker("网页字体", selection: Binding(get: { model.profile.settings.webFontFamily }, set: { value in
                model.updateProfile(model.profile.id) { $0.settings.webFontFamily = value }
                model.session?.tabs.forEach { $0.applyDecorations() }
            })) {
                Text("不覆盖").tag("")
                ForEach(FontLibrary.families(), id: \.self) { Text($0).tag($0) }
            }
            Button("安装字体文件") { importing = true }
            Text("列表包含系统字体，以及通过描述文件安装后能被 UIFont 看到的字体。可导入 ttf/otf/ttc；仅替换文本，保留图标、符号和代码字体。动态内容会继续应用；站点设置可以单独覆盖或关闭。").font(.footnote).foregroundStyle(.secondary)
        }.navigationTitle("网页字体")
            .fileImporter(isPresented: $importing, allowedContentTypes: [.font, .data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first { do { try model.importFont(url) } catch { model.message = error.localizedDescription } }
            }
    }
}

struct CapabilityView: View {
    var body: some View {
        List(ChromeAPIMatrix.entries, id: \.api) { entry in
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(entry.api).font(.headline); Spacer(); Text(entry.level).font(.caption.weight(.semibold)).foregroundStyle(entry.level == "Unsupported" ? .red : entry.level == "Partial" ? .orange : .green) }
                Text(entry.note).font(.footnote).foregroundStyle(.secondary)
            }
        }.navigationTitle("扩展 API")
    }
}

struct DownloadList: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var center: DownloadCenter
    var body: some View {
        let records = model.profile.downloads
        if records.isEmpty { Text("还没有下载文件").foregroundStyle(.secondary) }
        if model.session?.tabs.contains(where: \.isPrivate) == true {
            Text("关闭最后一个无痕标签或切换身份，会取消本次无痕会话中未完成的下载；已保存的文件保留。").font(.caption).foregroundStyle(.secondary)
        }
        ForEach(records) { record in
            let live = center.live[record.id]
            VStack(alignment: .leading, spacing: 6) {
                Text(record.name).font(.subheadline)
                if ["running", "pausing", "paused"].contains(record.state) {
                    let received = live?.received ?? record.received
                    let total = live?.total ?? record.total
                    ProgressView(value: total > 0 ? Double(received) / Double(total) : nil)
                    Text([record.state == "paused" ? "已暂停" : "下载中", total > 0 ? "\(Int(Double(received) / Double(total) * 100))%" : nil, ByteFormat.speed(live?.speed ?? 0), ByteFormat.remaining(received: received, total: total, speed: live?.speed ?? 0)].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if record.resumable && record.state == "running" { Button("暂停") { center.pause(record.id) } }
                        if record.state == "paused" && record.resumable { Button("继续") { center.resume(record.id) } }
                        if record.state == "pausing" { Text("正在暂停…") }
                        Button("取消") { center.cancel(record.id) }
                    }.font(.caption)
                } else {
                    Text(record.state == "finished" ? "已完成 · \(ByteFormat.bytes(record.total))" : record.state).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if record.state == "failed" && record.resumable { Button("重试续传") { center.resume(record.id) } }
                        if ["failed", "cancelled"].contains(record.state), !record.resumable, DownloadPolicy.restartURL(record) != nil {
                            Button("重新下载") { center.restart(record.id) }
                        }
                        if record.state == "finished" {
                            ShareLink(item: center.fileURL(record, profile: model.profile.id)) { Image(systemName: "square.and.arrow.up") }
                            NavigationLink("打开") { QuickLookView(url: center.fileURL(record, profile: model.profile.id)) }
                        }
                        Button("删除", role: .destructive) { center.delete(record.id) }
                    }.font(.caption)
                }
            }
        }
    }
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
