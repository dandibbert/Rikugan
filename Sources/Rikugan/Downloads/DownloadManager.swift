import Foundation
import WebKit
import UIKit
import QuickLook

/// One download (spec §29). Backed by WKDownload, URLSessionDownloadTask or the HLS downloader.
@MainActor final class DownloadItem: ObservableObject, Identifiable {
    enum State: Equatable { case downloading, paused, completed, failed(String), cancelled }

    let id: UUID
    let numericID: Int
    @Published var fileName: String
    @Published var sourceURL: URL?
    @Published var state: State = .downloading
    @Published var received: Int64 = 0
    @Published var total: Int64 = 0
    @Published var speed: Double = 0
    @Published var fileURL: URL?
    var mime: String = ""
    let startDate: Date
    var headers: [String: String] = [:]
    weak var webView: WKWebView?
    var wkDownload: WKDownload?
    var task: URLSessionDownloadTask?
    var resumeData: Data?
    var hlsTask: Task<Void, Never>?
    /// Chosen in the download prompt: open the Files exporter once finished.
    var exportToFiles = false
    /// Started from a private tab: never written to the download history file and never reported
    /// to extensions.
    var isPrivate = false
    /// The name came from the user / script (prompt, GM_download name, chrome.downloads filename)
    /// and wins over the server's suggested file name.
    var userNamedFile = false
    private var progressObservation: NSKeyValueObservation?
    private var lastSample: (date: Date, bytes: Int64) = (Date(), 0)

    init(id: UUID = UUID(), numericID: Int, fileName: String, sourceURL: URL?, startDate: Date = Date()) {
        self.id = id
        self.numericID = numericID
        self.fileName = fileName
        self.sourceURL = sourceURL
        self.startDate = startDate
    }

    var fraction: Double { total > 0 ? min(1, Double(received) / Double(total)) : 0 }
    var remaining: TimeInterval? { speed > 0 && total > 0 ? Double(total - received) / speed : nil }

    func update(received: Int64, total: Int64) {
        self.received = received
        if total > 0 { self.total = total }
        let now = Date()
        let dt = now.timeIntervalSince(lastSample.date)
        if dt >= 0.7 {
            speed = max(0, Double(received - lastSample.bytes) / dt)
            lastSample = (now, received)
        }
    }

    func observe(_ progress: Progress) {
        progressObservation = progress.observe(\.completedUnitCount, options: [.new]) { [weak self] progress, _ in
            let completed = progress.completedUnitCount, total = progress.totalUnitCount
            Task { @MainActor in self?.update(received: completed, total: total) }
        }
    }

    var chromeState: String {
        switch state {
        case .completed: return "complete"
        case .downloading, .paused: return "in_progress"
        default: return "interrupted"
        }
    }

    var chromeJSON: [String: Any] {
        var errorValue: Any = NSNull()
        if case .failed(let message) = state { errorValue = message }
        return ["id": numericID, "url": sourceURL?.absoluteString ?? "", "finalUrl": sourceURL?.absoluteString ?? "",
         "filename": fileURL?.path ?? fileName, "state": chromeState, "paused": state == .paused, "bytesReceived": received,
         "totalBytes": total, "fileSize": total, "mime": mime, "danger": "safe", "exists": fileURL.map { FileManager.default.fileExists(atPath: $0.path) } ?? false,
         "startTime": ISO8601DateFormatter().string(from: startDate), "canResume": resumeData != nil, "incognito": isPrivate,
         "error": errorValue]
    }
}

@MainActor final class DownloadManager: NSObject, ObservableObject {
    @Published private(set) var items: [DownloadItem] = []
    private var nextID = 1
    /// No shared cookie jar or cache: the cookies of the requesting profile / private session are
    /// attached per request (only those that apply to the URL), and nothing is stored globally.
    private lazy var session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        return URLSession(configuration: configuration, delegate: self, delegateQueue: .main)
    }()
    private var taskItems: [Int: DownloadItem] = [:]
    private var wkItems: [ObjectIdentifier: DownloadItem] = [:]
    private let recordsFile = JSONFile<[Record]>(AppPaths.support.appendingPathComponent("downloads.json"))

    struct Record: Codable {
        var id: UUID
        var fileName: String
        var url: String?
        var date: Date
        var size: Int64
    }

    var activeCount: Int { items.filter { $0.state == .downloading }.count }

    func restore() {
        for record in recordsFile.load() ?? [] {
            let file = AppPaths.downloads.appendingPathComponent(record.fileName)
            guard FileManager.default.fileExists(atPath: file.path) else { continue }
            let item = DownloadItem(id: record.id, numericID: allocateID(), fileName: record.fileName, sourceURL: record.url.flatMap(URL.init(string:)), startDate: record.date)
            item.fileURL = file
            item.total = record.size
            item.received = record.size
            item.state = .completed
            items.append(item)
        }
    }

    private func persist() {
        let records = items.filter { $0.state == .completed && !$0.isPrivate }.map {
            Record(id: $0.id, fileName: $0.fileURL?.lastPathComponent ?? $0.fileName, url: $0.sourceURL?.absoluteString, date: $0.startDate, size: $0.total)
        }
        recordsFile.save(records)
    }

    private func allocateID() -> Int { defer { nextID += 1 }; return nextID }

    // MARK: WKDownload

    func attach(_ download: WKDownload, sourceTab: BrowserTab?, suggestedResponse: URLResponse? = nil) {
        let item = DownloadItem(numericID: allocateID(), fileName: suggestedResponse?.suggestedFilename ?? download.originalRequest?.url?.lastPathComponent ?? "download",
                                sourceURL: download.originalRequest?.url)
        item.isPrivate = sourceTab?.isPrivate ?? (TabRegistry.shared.tab(for: download.webView)?.isPrivate ?? false)
        item.webView = download.webView
        item.wkDownload = download
        item.mime = suggestedResponse?.mimeType ?? ""
        wkItems[ObjectIdentifier(download)] = item
        download.delegate = self
        item.observe(download.progress)
        items.insert(item, at: 0)
        // Announced once the destination is decided (after the optional prompt).
    }

    // MARK: Direct downloads (links, media sniffer, extensions, GM_download)

    /// User-initiated download (link / media panel): asks for name and destination first when the
    /// prompt is enabled. Programmatic callers (GM_download, chrome.downloads, tests) use `download`.
    func downloadInteractively(url: URL, suggestedName: String?, from tab: BrowserTab?) {
        guard DownloadPrompt.enabled, url.scheme != "blob" else { download(url: url, suggestedName: suggestedName, from: tab); return }
        let isHLS = url.pathExtension.lowercased() == "m3u8"
        let name = suggestedName ?? (isHLS ? url.deletingPathExtension().lastPathComponent + ".ts"
                                          : (url.lastPathComponent.isEmpty ? (url.host ?? "download") : url.lastPathComponent))
        Task {
            guard let decision = await DownloadPrompt.ask(fileName: name, size: 0, source: url, mime: nil) else { return }
            let item = download(url: url, suggestedName: decision.fileName, from: tab)
            item?.exportToFiles = decision.exportToFiles
        }
    }

    @discardableResult
    func download(url: URL, suggestedName: String?, from tab: BrowserTab?, headers: [String: String] = [:]) -> DownloadItem? {
        if url.pathExtension.lowercased() == "m3u8" { return downloadHLS(url: url, suggestedName: suggestedName, from: tab) }
        if url.scheme == "blob" || url.scheme == "data" {
            if url.scheme == "data", let item = saveDataURL(url, name: suggestedName) { return item }
            ToastCenter.shared.show("无法直接下载 blob 资源", symbol: "exclamationmark.triangle")
            return nil
        }
        let item = DownloadItem(numericID: allocateID(), fileName: suggestedName ?? (url.lastPathComponent.isEmpty ? (url.host ?? "download") : url.lastPathComponent),
                                sourceURL: url)
        item.headers = headers
        item.isPrivate = tab?.isPrivate ?? false
        item.userNamedFile = suggestedName != nil
        items.insert(item, at: 0)
        Task {
            var request = URLRequest(url: url)
            for (k, v) in headers { request.setValue(v, forHTTPHeaderField: k) }
            if let tab {
                request.setValue(tab.webView?.url?.absoluteString, forHTTPHeaderField: "Referer")
                // Only cookies the browser itself would send to this URL (domain / host-only, path,
                // Secure, expiry).
                if let header = await Self.cookieHeader(for: url, tab: tab) { request.setValue(header, forHTTPHeaderField: "Cookie") }
            }
            let task = session.downloadTask(with: request)
            item.task = task
            taskItems[task.taskIdentifier] = item
            task.resume()
        }
        announce(item)
        return item
    }

    private func saveDataURL(_ url: URL, name: String?) -> DownloadItem? {
        let text = url.absoluteString
        guard let comma = text.firstIndex(of: ",") else { return nil }
        let header = text[text.index(text.startIndex, offsetBy: 5)..<comma]
        let payload = String(text[text.index(after: comma)...])
        let data = header.hasSuffix(";base64") ? Data(base64Encoded: payload) : payload.removingPercentEncoding.map { Data($0.utf8) }
        guard let data else { return nil }
        let mime = header.split(separator: ";").first.map(String.init) ?? "application/octet-stream"
        let ext = UTTypeHelper.fileExtension(forMIME: mime)
        let file = AppPaths.uniqueFile(in: AppPaths.downloads, name: name ?? "file.\(ext)")
        guard (try? data.write(to: file)) != nil else { return nil }
        let item = DownloadItem(numericID: allocateID(), fileName: file.lastPathComponent, sourceURL: nil)
        item.fileURL = file
        item.total = Int64(data.count)
        item.received = item.total
        item.state = .completed
        items.insert(item, at: 0)
        persist()
        return item
    }

    /// Fetches a resource the page shows (images for the gallery / save / copy) with the page's
    /// context: blob: and data: URLs are read inside the page, http(s) with the tab's cookies for
    /// that URL and the page as Referer, through a session that stores nothing.
    static func pageResource(_ url: URL, tab: BrowserTab?) async throws -> Data {
        let scheme = url.scheme?.lowercased() ?? ""
        if scheme == "blob" || scheme == "data" {
            guard let webView = tab?.webView, let base64 = await webView.rkTools("readResource", [url.absoluteString]) as? String,
                  let data = Data(base64Encoded: base64) else { throw RikuganError("无法从页面读取该资源") }
            return data
        }
        guard scheme == "http" || scheme == "https" else { throw RikuganError("不支持的地址") }
        var request = URLRequest(url: url, timeoutInterval: 30)
        if let tab {
            if let referer = tab.webView?.url?.absoluteString { request.setValue(referer, forHTTPHeaderField: "Referer") }
            if let cookie = await cookieHeader(for: url, tab: tab) { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            if let agent = tab.webView?.customUserAgent, !agent.isEmpty { request.setValue(agent, forHTTPHeaderField: "User-Agent") }
        }
        let (data, response) = try await resourceSession.data(for: request, delegate: CookieRedirectGuard())
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw RikuganError("HTTP \(http.statusCode)") }
        return data
    }

    /// Content length from a HEAD request made with the page's context (nil if unknown).
    static func pageResourceLength(_ url: URL, tab: BrowserTab?) async -> Int64? {
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.httpMethod = "HEAD"
        if let tab {
            if let referer = tab.webView?.url?.absoluteString { request.setValue(referer, forHTTPHeaderField: "Referer") }
            if let cookie = await cookieHeader(for: url, tab: tab) { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
        }
        guard let (_, response) = try? await resourceSession.data(for: request, delegate: CookieRedirectGuard()),
              response.expectedContentLength > 0 else { return nil }
        return response.expectedContentLength
    }

    private static let resourceSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCache = nil
        return URLSession(configuration: configuration)
    }()

    static func cookieHeader(for url: URL, tab: BrowserTab) async -> String? {
        let store = tab.isPrivate ? tab.profile.privateDataStore() : tab.profile.dataStore
        let cookies = await store.httpCookieStore.allCookies().filter { CookieScope.cookie($0, appliesTo: url) }
        return cookies.isEmpty ? nil : HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    /// Items extensions may see (private downloads are not reported, like other private browsing).
    var extensionVisibleItems: [DownloadItem] { items.filter { !$0.isPrivate } }

    private func announce(_ item: DownloadItem) {
        if !item.isPrivate { AppServices.shared.profile.extensions.downloadCreated(item) }
        ToastCenter.shared.show("开始下载：\(item.fileName)", symbol: "arrow.down.circle", actionTitle: "查看") {
            NotificationCenter.default.post(name: .rikuganShowDownloads, object: nil)
        }
    }

    // MARK: Controls

    func pause(_ item: DownloadItem) {
        guard item.state == .downloading else { return }
        if let download = item.wkDownload {
            download.cancel { data in Task { @MainActor in item.resumeData = data; item.state = data == nil ? .failed("服务器不支持暂停") : .paused } }
        } else if let task = item.task {
            task.cancel(byProducingResumeData: { data in Task { @MainActor in item.resumeData = data; item.state = data == nil ? .failed("服务器不支持断点续传") : .paused } })
        } else if item.hlsTask != nil {
            ToastCenter.shared.show("HLS 下载不支持暂停", symbol: "info.circle")
        }
    }

    func resume(_ item: DownloadItem) {
        guard item.state == .paused || { if case .failed = item.state { return true }; return false }() else { return }
        if let data = item.resumeData, let webView = item.webView, item.wkDownload != nil {
            webView.resumeDownload(fromResumeData: data) { [weak self] download in
                guard let self else { return }
                item.wkDownload = download
                self.wkItems[ObjectIdentifier(download)] = item
                download.delegate = self
                item.observe(download.progress)
                item.state = .downloading
            }
        } else if let data = item.resumeData {
            let task = session.downloadTask(withResumeData: data)
            item.task = task
            taskItems[task.taskIdentifier] = item
            item.state = .downloading
            task.resume()
        } else if let url = item.sourceURL {
            remove(item, deleteFile: false)
            download(url: url, suggestedName: item.fileName, from: nil, headers: item.headers)
        }
    }

    func cancel(_ item: DownloadItem) {
        item.wkDownload?.cancel(nil)
        item.task?.cancel()
        item.hlsTask?.cancel()
        item.state = .cancelled
    }

    func remove(_ item: DownloadItem, deleteFile: Bool) {
        cancel(item)
        if deleteFile, let file = item.fileURL { try? FileManager.default.removeItem(at: file) }
        items.removeAll { $0.id == item.id }
        persist()
        if !item.isPrivate { AppServices.shared.profile.extensions.downloadErased(item.numericID) }
    }

    func clearFinished() {
        items.removeAll { $0.state != .downloading && $0.state != .paused }
        persist()
    }

    func open(_ item: DownloadItem) {
        guard let file = item.fileURL else { return }
        let controller = QLPreviewController()
        let source = PreviewSource(url: file)
        controller.dataSource = source
        objc_setAssociatedObject(controller, &PreviewSource.key, source, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        Presenter.present(controller)
    }

    func share(_ item: DownloadItem) {
        guard let file = item.fileURL else { return }
        Presenter.share([file])
    }

    func saveToFiles(_ item: DownloadItem) {
        guard let file = item.fileURL else { return }
        let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
        Presenter.present(picker)
    }

    fileprivate func finish(_ item: DownloadItem, file: URL) {
        // Completed means the file is really there.
        guard FileManager.default.fileExists(atPath: file.path) else {
            item.state = .failed("文件未能保存")
            ToastCenter.shared.show("下载失败：文件未能保存（\(item.fileName)）", symbol: "exclamationmark.triangle")
            return
        }
        item.fileURL = file
        item.fileName = file.lastPathComponent
        let size = (try? FileManager.default.attributesOfItem(atPath: file.path)[.size] as? Int64) ?? item.received
        item.total = size
        item.received = item.total
        item.state = .completed
        item.speed = 0
        persist()
        if item.exportToFiles { item.exportToFiles = false; saveToFiles(item) }
        if !item.isPrivate {
            AppServices.shared.profile.extensions.dispatchAll("downloads.onChanged", permission: "downloads") { _ in
                [["id": item.numericID, "state": ["previous": "in_progress", "current": "complete"]]]
            }
        }
        ToastCenter.shared.show("下载完成：\(item.fileName)", symbol: "checkmark.circle", actionTitle: "打开") { [weak self] in self?.open(item) }
    }

    // MARK: HLS

    private func downloadHLS(url: URL, suggestedName: String?, from tab: BrowserTab?) -> DownloadItem {
        let base = suggestedName ?? ((url.deletingPathExtension().lastPathComponent.isEmpty ? "video" : url.deletingPathExtension().lastPathComponent) + ".ts")
        let item = DownloadItem(numericID: allocateID(), fileName: base, sourceURL: url)
        item.isPrivate = tab?.isPrivate ?? false
        item.userNamedFile = suggestedName != nil
        items.insert(item, at: 0)
        announce(item)
        let referer = tab?.webView?.url?.absoluteString
        item.hlsTask = Task { [weak self] in
            do {
                // Playlist and segments are requested with the page's cookies for each URL.
                let cookies: (URL) async -> String? = { target in
                    guard let tab else { return nil }
                    return await DownloadManager.cookieHeader(for: target, tab: tab)
                }
                let file = try await HLSDownloader.download(url: url, name: base, referer: referer, cookies: cookies) { done, total in
                    Task { @MainActor in item.update(received: Int64(done), total: Int64(total)) }
                }
                self?.finish(item, file: file)
            } catch is CancellationError {
                item.state = .cancelled
            } catch {
                item.state = .failed(error.localizedDescription)
            }
        }
        return item
    }
}

extension Notification.Name {
    static let rikuganShowDownloads = Notification.Name("rikugan.showDownloads")
}

extension DownloadManager: WKDownloadDelegate {
    nonisolated func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                              completionHandler: @escaping (URL?) -> Void) {
        MainActor.assumeIsolated {
            let item = wkItems[ObjectIdentifier(download)]
            let place: (String, Bool) -> Void = { name, exportToFiles in
                let file = AppPaths.uniqueFile(in: AppPaths.downloads, name: name)
                if let item {
                    item.fileName = file.lastPathComponent
                    item.mime = response.mimeType ?? item.mime
                    if response.expectedContentLength > 0 { item.total = response.expectedContentLength }
                    item.fileURL = file
                    item.exportToFiles = exportToFiles
                    self.announce(item)
                }
                completionHandler(file)
            }
            guard DownloadPrompt.enabled else { place(suggestedFilename, false); return }
            Task { @MainActor in
                // WebKit waits for the destination: the download does not start before the user confirms.
                if let decision = await DownloadPrompt.ask(fileName: suggestedFilename, size: response.expectedContentLength,
                                                           source: download.originalRequest?.url ?? response.url, mime: response.mimeType) {
                    place(decision.fileName, decision.exportToFiles)
                } else {
                    completionHandler(nil)
                    if let item {
                        self.wkItems.removeValue(forKey: ObjectIdentifier(download))
                        self.items.removeAll { $0.id == item.id }
                    }
                }
            }
        }
    }

    nonisolated func downloadDidFinish(_ download: WKDownload) {
        MainActor.assumeIsolated {
            guard let item = wkItems.removeValue(forKey: ObjectIdentifier(download)), let file = item.fileURL else { return }
            finish(item, file: file)
        }
    }

    nonisolated func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        MainActor.assumeIsolated {
            guard let item = wkItems[ObjectIdentifier(download)] else { return }
            item.resumeData = resumeData
            if item.state != .paused && item.state != .cancelled { item.state = .failed(error.localizedDescription) }
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    /// The Cookie header was chosen for the original URL: drop it when a redirect leaves that host.
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                                newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if request.url?.host?.lowercased() != task.originalRequest?.url?.host?.lowercased() || request.url?.scheme?.lowercased() != "https" {
            next.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(next)
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                                totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        MainActor.assumeIsolated {
            taskItems[downloadTask.taskIdentifier]?.update(received: totalBytesWritten, total: totalBytesExpectedToWrite)
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file must be moved synchronously.
        let suggested = downloadTask.response?.suggestedFilename
        let mime = downloadTask.response?.mimeType
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var moveError: Error?
        do { try FileManager.default.moveItem(at: location, to: temp) } catch { moveError = error }
        MainActor.assumeIsolated {
            guard let item = taskItems.removeValue(forKey: downloadTask.taskIdentifier) else { try? FileManager.default.removeItem(at: temp); return }
            if let moveError {
                item.state = .failed("无法保存临时文件：\(moveError.localizedDescription)")
                return
            }
            if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                item.state = .failed("HTTP \(http.statusCode)")
                try? FileManager.default.removeItem(at: temp)
                return
            }
            var name = item.fileName
            if !item.userNamedFile, let suggested, !suggested.isEmpty, suggested != "Unknown" { name = suggested }
            if (name as NSString).pathExtension.isEmpty, let mime { name += "." + UTTypeHelper.fileExtension(forMIME: mime) }
            let file = AppPaths.uniqueFile(in: AppPaths.downloads, name: name)
            do {
                try FileManager.default.moveItem(at: temp, to: file)
            } catch {
                try? FileManager.default.removeItem(at: temp)
                item.state = .failed("无法保存文件：\(error.localizedDescription)")
                ToastCenter.shared.show("下载失败：无法保存 \(name)", symbol: "exclamationmark.triangle")
                return
            }
            item.mime = mime ?? ""
            finish(item, file: file)
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let resume = (error as NSError).userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        MainActor.assumeIsolated {
            guard let item = taskItems.removeValue(forKey: task.taskIdentifier) else { return }
            if item.resumeData == nil { item.resumeData = resume }
            if item.state == .downloading { item.state = .failed(error.localizedDescription) }
        }
    }
}

/// Drops the Cookie header chosen for the original URL when a redirect leaves that host or HTTPS.
final class CookieRedirectGuard: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        var next = request
        if request.url?.host?.lowercased() != task.originalRequest?.url?.host?.lowercased() || request.url?.scheme?.lowercased() != "https" {
            next.setValue(nil, forHTTPHeaderField: "Cookie")
        }
        completionHandler(next)
    }
}

/// Minimal HLS (m3u8) downloader: picks the best variant, downloads unencrypted segments and
/// concatenates them. DRM / encrypted streams are out of scope (spec §26).
enum HLSDownloader {
    static func download(url: URL, name: String, referer: String?, cookies: @escaping (URL) async -> String? = { _ in nil },
                         progress: @escaping (Int, Int) -> Void) async throws -> URL {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        let session = URLSession(configuration: configuration)
        defer { session.finishTasksAndInvalidate() }
        func fetch(_ u: URL) async throws -> Data {
            var request = URLRequest(url: u, timeoutInterval: 60)
            if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
            if let cookie = await cookies(u) { request.setValue(cookie, forHTTPHeaderField: "Cookie") }
            let (data, response) = try await session.data(for: request, delegate: CookieRedirectGuard())
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) { throw RikuganError("HTTP \(http.statusCode)：\(u.lastPathComponent)") }
            return data
        }
        var playlistURL = url
        var text = String(decoding: try await fetch(url), as: UTF8.self)
        if M3U8.isMaster(text) {
            guard let best = M3U8.variants(text, base: url).first else { throw RikuganError("播放列表中没有可用的清晰度") }
            playlistURL = best.url
            text = String(decoding: try await fetch(best.url), as: UTF8.self)
        }
        let playlist = M3U8.media(text, base: playlistURL)
        if let method = playlist.encryption { throw RikuganError("该视频流已加密（\(method)），不支持下载") }
        if let feature = playlist.unsupported { throw RikuganError("该视频流使用了 \(feature)，暂不支持下载") }
        guard !playlist.segments.isEmpty else { throw RikuganError("播放列表为空或为直播流") }
        var fileName = name
        if playlist.isFMP4 { fileName = (name as NSString).deletingPathExtension + ".mp4" }
        let file = AppPaths.uniqueFile(in: AppPaths.downloads, name: fileName)
        FileManager.default.createFile(atPath: file.path, contents: nil)
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        if let initSegment = playlist.initSegment { try handle.write(contentsOf: try await fetch(initSegment)) }
        for (index, segment) in playlist.segments.enumerated() {
            try Task.checkCancellation()
            var attempt = 0
            while true {
                do { try handle.write(contentsOf: try await fetch(segment.url)); break }
                catch { attempt += 1; if attempt >= 3 { throw error } }
            }
            progress(index + 1, playlist.segments.count)
        }
        return file
    }
}

enum UTTypeHelper {
    static func fileExtension(forMIME mime: String) -> String {
        let map = ["image/jpeg": "jpg", "image/png": "png", "image/gif": "gif", "image/webp": "webp", "video/mp4": "mp4", "audio/mpeg": "mp3",
                   "application/pdf": "pdf", "application/zip": "zip", "text/plain": "txt", "text/html": "html", "application/json": "json",
                   "video/webm": "webm", "audio/mp4": "m4a", "image/svg+xml": "svg", "application/x-chrome-extension": "crx"]
        return map[mime.lowercased()] ?? "bin"
    }
}

final class PreviewSource: NSObject, QLPreviewControllerDataSource {
    static var key: UInt8 = 0
    let url: URL
    init(url: URL) { self.url = url }
    func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }
    func previewController(_ controller: QLPreviewController, previewItemAt index: Int) -> QLPreviewItem { url as NSURL }
}
