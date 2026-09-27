import Foundation
import Combine
import WebKit

struct DownloadLive: Equatable {
    var received: Int64 = 0
    var total: Int64 = 0
    var speed: Double = 0
    var updated = Date()
}

enum DownloadPolicy {
    static func safeName(_ raw: String, maxBytes: Int = 180) -> String {
        let name = (raw.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
            .components(separatedBy: .controlCharacters).joined()
        return name.isEmpty || name == "." || name == ".." ? "download" : String(decoding: name.utf8.prefix(maxBytes), as: UTF8.self)
    }
    static func recoveredState(_ state: String, hasResumeData: Bool) -> String {
        ["running", "pausing", "paused"].contains(state) ? (hasResumeData ? "paused" : "failed") : state
    }
    static func restartURL(_ record: DownloadRecord) -> URL? {
        guard !record.source.isEmpty, let url = URL(string: record.source),
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

/// A single WKDownload path for navigation and media downloads. It preserves the
/// initiating profile's cookies, owns its delegates independently of tab lifetime,
/// and ignores late callbacks from cancelled/replaced native downloads.
@MainActor final class DownloadCenter: NSObject, ObservableObject, WKDownloadDelegate {
    weak var model: AppModel?
    @Published var live: [UUID: DownloadLive] = [:]
    private var downloads: [UUID: WKDownload] = [:]
    private var identifiers: [ObjectIdentifier: UUID] = [:]
    private var views: [UUID: WKWebView] = [:]
    private var owners: [UUID: UUID] = [:]
    private var originTabs: [UUID: UUID] = [:]
    private var privateDownloads = Set<UUID>()
    private var observations: [UUID: [NSKeyValueObservation]] = [:]
    private var samples: [UUID: (bytes: Int64, time: Date)] = [:]
    private var resumeData: [UUID: Data] = [:]
    private var diagnostics: [String] = []

    private func note(_ phase: String, id: UUID) {
        let value = live[id]
        let line = "\(id.uuidString.prefix(8)) \(phase) state=\(record(id)?.state ?? "missing") bytes=\(value?.received ?? 0)/\(value?.total ?? 0)"
        diagnostics.append(line); diagnostics = Array(diagnostics.suffix(60))
        NSLog("Rikugan download %@", line)
    }
    var diagnosticSummary: String { diagnostics.joined(separator: "\n") }

    func activate(_ model: AppModel) {
        self.model = model
        for profile in model.state.profiles {
            for record in profile.downloads { owners[record.id] = profile.id }
            model.updateProfile(profile.id) { value in
                for i in value.downloads.indices {
                    let record = value.downloads[i]
                    let hasData = self.savedResumeData(record.id) != nil
                    value.downloads[i].state = DownloadPolicy.recoveredState(record.state, hasResumeData: hasData)
                    value.downloads[i].resumable = hasData
                }
            }
        }
    }

    func directory(profile: UUID) -> URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true).appendingPathComponent(profile.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func fileURL(_ record: DownloadRecord, profile: UUID) -> URL {
        directory(profile: profile).appendingPathComponent(DownloadPolicy.safeName(record.fileName, maxBytes: 240))
    }

    func hasActiveDownload(tabID: UUID) -> Bool {
        originTabs.contains { $0.value == tabID && downloads[$0.key] != nil }
    }

    func start(url: URL, suggested name: String? = nil) {
        guard let tab = model?.session?.activeTab, let profile = tab.session?.profileID,
              ["http", "https", "blob", "data"].contains(url.scheme?.lowercased() ?? "") else {
            model?.message = "只能下载当前浏览环境中的 HTTP(S)、blob 或 data 资源。"; return
        }
        let view = tab.webView
        view.startDownload(using: URLRequest(url: url)) { [weak self] download in
            self?.adopt(download, view: view, profile: profile, tabID: tab.id, isPrivate: tab.isPrivate, suggested: name)
        }
    }
    func adopt(_ download: WKDownload, from tab: BrowserTab) {
        guard let profile = tab.session?.profileID, let view = tab.existingWebView else { download.cancel(nil); return }
        adopt(download, view: view, profile: profile, tabID: tab.id, isPrivate: tab.isPrivate)
    }
    private func adopt(_ download: WKDownload, view: WKWebView, profile: UUID, tabID: UUID, isPrivate: Bool, suggested: String? = nil) {
        guard let model, model.state.profiles.contains(where: { $0.id == profile }) else { download.cancel(nil); return }
        if isPrivate {
            guard model.session?.profileID == profile,
                  model.session?.tabs.contains(where: { $0.id == tabID && $0.isPrivate }) == true else {
                download.cancel(nil); return
            }
        }
        let id = UUID(), name = DownloadPolicy.safeName(suggested ?? download.originalRequest?.url?.lastPathComponent ?? "download")
        owners[id] = profile; originTabs[id] = tabID; views[id] = view
        if isPrivate { privateDownloads.insert(id) }
        // Explicitly saved files may persist, but private URLs and resume tokens do not.
        let record = DownloadRecord(id: id, name: name, fileName: String(id.uuidString.prefix(8)) + "-" + name,
                                    state: "running", resumable: true, source: isPrivate ? "" : (download.originalRequest?.url?.absoluteString ?? ""))
        model.updateProfile(profile) { $0.downloads.insert(record, at: 0) }
        attach(download, id: id)
    }
    private func attach(_ download: WKDownload, id: UUID) {
        downloads[id] = download; identifiers[ObjectIdentifier(download)] = id; download.delegate = self
        observations[id] = [
            download.progress.observe(\.completedUnitCount, options: [.new]) { [weak self, weak download] _, _ in
                Task { @MainActor in if let download { self?.progress(download, id: id) } }
            },
            download.progress.observe(\.totalUnitCount, options: [.new]) { [weak self, weak download] _, _ in
                Task { @MainActor in if let download { self?.progress(download, id: id) } }
            }
        ]
        progress(download, id: id)
        note("attached", id: id)
    }

    func pause(_ id: UUID) {
        guard let download = downloads[id], record(id)?.state == "running" else { return }
        persistProgress(id); update(id) { $0.state = "pausing"; $0.resumable = false }
        download.cancel { [weak self] data in
            guard let self, self.record(id)?.state == "pausing" else { return }
            self.detach(id, releaseView: data == nil)
            self.storeResumeData(data, id: id)
            self.update(id) { $0.state = data == nil ? "failed" : "paused"; $0.resumable = data != nil }
            self.note("pause-callback", id: id)
            if data == nil { self.model?.message = "服务器未提供续传数据，下载已停止；可重新下载。" }
        }
    }
    func resume(_ id: UUID) {
        guard let record = record(id), ["paused", "failed"].contains(record.state),
              let owner = owners[id], let data = savedResumeData(id) else { return }
        let view: WKWebView
        if let retained = views[id] { view = retained }
        else {
            let configuration = WKWebViewConfiguration()
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: owner)
            view = WKWebView(frame: .zero, configuration: configuration); views[id] = view
        }
        update(id) { $0.state = "running"; $0.resumable = true }
        note("resume-request", id: id)
        view.resumeDownload(fromResumeData: data) { [weak self] download in
            guard let self, self.record(id)?.state == "running" else { download.cancel(nil); return }
            self.attach(download, id: id)
        }
    }
    func restart(_ id: UUID) {
        guard let record = record(id), let owner = owners[id], let url = DownloadPolicy.restartURL(record), let model else { return }
        guard model.state.activeProfileID == owner else { model.message = "请先切回这个下载所属的身份。"; return }
        let view: WKWebView
        let tabID: UUID
        if let tab = model.session?.activeTab, tab.session?.profileID == owner, !tab.isPrivate {
            view = tab.webView; tabID = tab.id
        } else {
            let configuration = WKWebViewConfiguration(); configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: owner)
            view = WKWebView(frame: .zero, configuration: configuration); tabID = UUID()
        }
        let name = record.name
        view.startDownload(using: URLRequest(url: url)) { [weak self, weak view] download in
            guard let self, let view else { download.cancel(nil); return }
            self.delete(id)
            self.adopt(download, view: view, profile: owner, tabID: tabID, isPrivate: false, suggested: name)
        }
    }
    func cancel(_ id: UUID) {
        let download = downloads[id]
        persistProgress(id)
        update(id) { $0.state = "cancelled"; $0.resumable = false }
        detach(id, releaseView: true); storeResumeData(nil, id: id)
        download?.cancel(nil)
        removePartialFile(id)
    }
    func delete(_ id: UUID) {
        guard let model, let owner = owners[id] else { return }
        cancel(id)
        model.updateProfile(owner) { $0.downloads.removeAll { $0.id == id } }
        owners[id] = nil; originTabs[id] = nil; privateDownloads.remove(id)
    }
    func removeProfile(_ profile: UUID) {
        for id in owners.filter({ $0.value == profile }).map(\.key) { delete(id) }
    }
    func endPrivateSession(_ profile: UUID) {
        // A paused download retains its web view and ephemeral cookie store. Do
        // not let that hidden reference keep a closed private session alive.
        for id in privateDownloads.filter({ owners[$0] == profile }) { cancel(id) }
    }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        guard let id = identifiers[ObjectIdentifier(download)], let owner = owners[id], record(id) != nil else { completionHandler(nil); return }
        if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            fail(id, message: "下载失败：HTTP \(http.statusCode)", resume: nil); completionHandler(nil); return
        }
        let name = DownloadPolicy.safeName(suggestedFilename)
        let file = String(id.uuidString.prefix(8)) + "-" + name
        update(id) { $0.name = name; $0.fileName = file; $0.total = max(0, response.expectedContentLength) }
        completionHandler(directory(profile: owner).appendingPathComponent(file))
        note("destination", id: id)
    }
    func downloadDidFinish(_ download: WKDownload) {
        guard let id = identifiers[ObjectIdentifier(download)], let record = record(id), let owner = owners[id] else { return }
        note("finish-callback", id: id)
        let file = fileURL(record, profile: owner)
        guard let size = try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize else {
            fail(id, message: "下载完成回调没有对应的文件，未标记为成功。", resume: nil); return
        }
        update(id) { $0.state = "finished"; $0.resumable = false; $0.received = Int64(size); $0.total = Int64(size) }
        detach(id, releaseView: true); storeResumeData(nil, id: id)
        model?.message = "下载完成：\(record.name)"
    }
    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        guard let id = identifiers[ObjectIdentifier(download)], record(id)?.state != "pausing" else { return }
        fail(id, message: "下载失败：\(error.localizedDescription)", resume: resumeData)
    }
    private func fail(_ id: UUID, message: String, resume: Data?) {
        note("failed: " + message, id: id)
        persistProgress(id); storeResumeData(resume, id: id)
        update(id) { $0.state = "failed"; $0.resumable = resume != nil }
        detach(id, releaseView: resume == nil)
        if resume == nil { removePartialFile(id) }
        model?.message = message
    }
    private func progress(_ download: WKDownload, id: UUID) {
        guard downloads[id] === download else { return }
        let bytes = max(0, download.progress.completedUnitCount), now = Date()
        var speed = live[id]?.speed ?? 0
        if let sample = samples[id], now.timeIntervalSince(sample.time) >= 0.4 {
            speed = max(0, Double(bytes - sample.bytes) / now.timeIntervalSince(sample.time))
            samples[id] = (bytes, now)
        } else if samples[id] == nil { samples[id] = (bytes, now) }
        live[id] = DownloadLive(received: bytes, total: max(0, download.progress.totalUnitCount), speed: speed, updated: now)
        if (bytes / 1_048_576) != ((record(id)?.received ?? 0) / 1_048_576) {
            note("progress", id: id)
            persistProgress(id)
        }
    }
    private func persistProgress(_ id: UUID) {
        if let value = live[id] { update(id) { $0.received = value.received; $0.total = value.total } }
    }
    private func detach(_ id: UUID, releaseView: Bool) {
        if let download = downloads.removeValue(forKey: id) {
            identifiers[ObjectIdentifier(download)] = nil; download.delegate = nil
        }
        observations[id] = nil; live[id] = nil; samples[id] = nil
        if releaseView { views[id] = nil; originTabs[id] = nil; privateDownloads.remove(id) }
    }
    private func record(_ id: UUID) -> DownloadRecord? {
        guard let owner = owners[id] else { return nil }
        return model?.state.profiles.first(where: { $0.id == owner })?.downloads.first(where: { $0.id == id })
    }
    private func update(_ id: UUID, _ mutate: (inout DownloadRecord) -> Void) {
        guard let owner = owners[id] else { return }
        model?.updateProfile(owner) { profile in
            if let i = profile.downloads.firstIndex(where: { $0.id == id }) { mutate(&profile.downloads[i]) }
        }
    }
    private func resumeURL(_ id: UUID) -> URL? {
        guard let owner = owners[id], let model else { return nil }
        return model.directory(owner).appendingPathComponent("DownloadResume", isDirectory: true).appendingPathComponent(id.uuidString)
    }
    private func savedResumeData(_ id: UUID) -> Data? {
        if let data = resumeData[id] { return data }
        guard let url = resumeURL(id), let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size <= 8_000_000 else { return nil }
        return try? Data(contentsOf: url)
    }
    private func storeResumeData(_ data: Data?, id: UUID) {
        resumeData[id] = data
        guard let url = resumeURL(id) else { return }
        guard let data, !privateDownloads.contains(id) else { try? FileManager.default.removeItem(at: url); return }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        } catch { model?.message = "续传数据只能保留到本次退出：\(error.localizedDescription)" }
    }
    private func removePartialFile(_ id: UUID) {
        if let record = record(id), let owner = owners[id] { try? FileManager.default.removeItem(at: fileURL(record, profile: owner)) }
    }
}
