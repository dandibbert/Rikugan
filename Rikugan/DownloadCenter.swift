import Foundation
import WebKit

struct DownloadLive: Equatable {
    var received: Int64 = 0
    var total: Int64 = 0
    var speed: Double = 0
    var updated = Date()
}

@MainActor final class DownloadCenter: NSObject, URLSessionDownloadDelegate {
    weak var model: AppModel?
    @Published var live: [UUID: DownloadLive] = [:]
    private var session: URLSession!
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var samples: [UUID: (bytes: Int64, time: Date)] = [:]
    private var resumeData: [UUID: Data] = [:]
    private var owners: [UUID: UUID] = [:]
    private var webDownloads: [UUID: WKDownload] = [:]
    private var webResume: [UUID: Data] = [:]
    private var webTabs: [UUID: UUID] = [:]
    private var webFiles: [UUID: URL] = [:]
    private var pollTask: Task<Void, Never>?

    func activate(_ model: AppModel) {
        self.model = model
        guard session == nil else { return }
        let configuration = URLSessionConfiguration.default
        configuration.waitsForConnectivity = true
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }

    func directory(profile: UUID) -> URL {
        let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent(profile.uuidString, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
    func fileURL(_ record: DownloadRecord, profile: UUID) -> URL { directory(profile: profile).appendingPathComponent(record.fileName) }

    func start(url: URL, suggested name: String? = nil, cookies: [HTTPCookie] = [], referer: String? = nil) {
        guard let model else { return }
        let profile = model.profile.id
        let id = UUID()
        owners[id] = profile
        let fileName = safeName(name ?? url.lastPathComponent)
        let record = DownloadRecord(id: id, name: fileName, fileName: fileName, state: "running", source: url.absoluteString, resumable: true)
        model.updateProfile(profile) { $0.downloads.insert(record, at: 0) }
        var request = URLRequest(url: url)
        request.setValue("Rikugan", forHTTPHeaderField: "User-Agent")
        if let header = CookieHeader.value(cookies: cookies, url: url) { request.setValue(header, forHTTPHeaderField: "Cookie") }
        if let referer { request.setValue(referer, forHTTPHeaderField: "Referer") }
        let task = session.downloadTask(with: request)
        task.taskDescription = id.uuidString
        tasks[id] = task
        live[id] = DownloadLive()
        task.resume()
    }
    func pause(_ id: UUID) {
        if let task = tasks[id] {
            task.cancel(byProducingResumeData: { [weak self] data in
                Task { @MainActor in
                    guard let self else { return }
                    if let data { self.resumeData[id] = data }
                    self.tasks[id] = nil
                    self.live[id] = nil
                    self.update(id, state: "paused", resumable: data != nil)
                }
            })
            return
        }
        guard let download = webDownloads[id] else { return }
        download.cancel { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                self.webDownloads[id] = nil
                if let data { self.webResume[id] = data }
                self.live[id] = nil
                self.update(id, state: "paused", resumable: data != nil)
            }
        }
    }
    func resume(_ id: UUID) {
        if webResume[id] != nil { resumeWebKit(id); return }
        guard let model, let data = resumeData[id], let owner = owners[id] ?? Optional(model.profile.id),
              let record = model.state.profiles.first(where: { $0.id == owner })?.downloads.first(where: { $0.id == id }) else { return }
        owners[id] = owner
        let task = session.downloadTask(withResumeData: data)
        task.taskDescription = id.uuidString
        tasks[id] = task
        live[id] = DownloadLive(received: record.received, total: record.total)
        update(id, state: "running")
        task.resume()
    }
    func cancel(_ id: UUID) {
        tasks[id]?.cancel()
        webDownloads[id]?.cancel { _ in }
        tasks[id] = nil
        webDownloads[id] = nil
        webFiles[id] = nil
        resumeData[id] = nil
        webResume[id] = nil
        live[id] = nil
        update(id, state: "cancelled")
    }
    func delete(_ id: UUID) {
        guard let model else { return }
        let owner = owners[id] ?? model.profile.id
        cancel(id)
        if let record = model.state.profiles.first(where: { $0.id == owner })?.downloads.first(where: { $0.id == id }) {
            try? FileManager.default.removeItem(at: fileURL(record, profile: owner))
        }
        model.updateProfile(owner) { $0.downloads.removeAll { $0.id == id } }
        owners[id] = nil
    }
    func noteWebKit(name: String, fileName: String, state: String, total: Int64 = 0) -> UUID {
        let id = UUID()
        guard let model else { return id }
        owners[id] = model.profile.id
        var record = DownloadRecord(id: id, name: name, fileName: fileName, state: state, resumable: true)
        record.total = max(0, total)
        model.updateProfile(model.profile.id) { $0.downloads.insert(record, at: 0) }
        return id
    }
    func attachWebKit(_ id: UUID, download: WKDownload, tab: UUID, file: URL) {
        webDownloads[id] = download
        webTabs[id] = tab
        webFiles[id] = file
        owners[id] = model?.profile.id
        ensureWebPoll()
    }
    func finishWebKit(_ id: UUID, fileName: String) {
        webDownloads[id] = nil
        webResume[id] = nil
        webFiles[id] = nil
        update(id, state: "finished", fileName: fileName)
    }
    func failWebKit(_ id: UUID, resume: Data?, message: String) {
        if let resume { webResume[id] = resume }
        webDownloads[id] = nil
        webFiles[id] = nil
        if model?.state.profiles.flatMap(\.downloads).first(where: { $0.id == id })?.state == "paused" {
            update(id, resumable: resume != nil || webResume[id] != nil)
            return
        }
        live[id] = nil
        update(id, state: resume == nil ? "failed" : "paused", resumable: resume != nil)
        model?.message = message
    }
    /// Public WKDownloadDelegate has no byte-progress method. WebKit writes the destination
    /// file as bytes arrive, so speed and ETA come from that file's size.
    private func ensureWebPoll() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor in
            while !webFiles.isEmpty {
                try? await Task.sleep(nanoseconds: 400_000_000)
                for (id, url) in webFiles {
                    let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value ?? 0
                    let total = model.flatMap { model in model.state.profiles.flatMap(\.downloads).first { $0.id == id }?.total } ?? 0
                    progress(id, written: size, expected: max(total, 0))
                    if size > 0 { update(id, received: size) }
                }
            }
            pollTask = nil
        }
    }
    private func resumeWebKit(_ id: UUID) {
        guard let data = webResume[id], let model else { return }
        guard let tabID = webTabs[id], let tab = model.session?.tabs.first(where: { $0.id == tabID }) else {
            model.message = "原来的标签页已关闭，无法继续这个网页下载。"
            return
        }
        tab.webView.resumeDownload(fromResumeData: data) { [weak self] download in
            Task { @MainActor in
                guard let self else { return }
                download.delegate = tab
                self.webDownloads[id] = download
                self.webResume[id] = nil
                self.update(id, state: "running", resumable: true)
            }
        }
    }

    private func update(_ id: UUID, state: String? = nil, fileName: String? = nil, resumable: Bool? = nil, received: Int64? = nil, total: Int64? = nil) {
        guard let model, let owner = owners[id] ?? Optional(model.profile.id) else { return }
        owners[id] = owner
        model.updateProfile(owner) { profile in
            guard let index = profile.downloads.firstIndex(where: { $0.id == id }) else { return }
            if let state { profile.downloads[index].state = state }
            if let fileName { profile.downloads[index].fileName = fileName; profile.downloads[index].name = fileName }
            if let resumable { profile.downloads[index].resumable = resumable }
            if let received { profile.downloads[index].received = received }
            if let total { profile.downloads[index].total = total }
        }
    }
    private func safeName(_ raw: String) -> String {
        let name = (raw as NSString).lastPathComponent
        return name.isEmpty || name == "." || name == ".." ? "download" : name
    }
    private func identifier(_ task: URLSessionTask) -> UUID? { task.taskDescription.flatMap(UUID.init(uuidString:)) }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:))
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.copyItem(at: location, to: temp)
        let suggested = downloadTask.response?.suggestedFilename
        Task { @MainActor in self.complete(id, temp: temp, suggested: suggested) }
    }
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let id = downloadTask.taskDescription.flatMap(UUID.init(uuidString:))
        Task { @MainActor in self.progress(id, written: totalBytesWritten, expected: totalBytesExpectedToWrite) }
    }
    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let id = task.taskDescription.flatMap(UUID.init(uuidString:))
        let resume = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data
        Task { @MainActor in
            guard let id, self.tasks[id] != nil || error != nil else { return }
            if let resume { self.resumeData[id] = resume }
            if error != nil, self.model?.profile.downloads.first(where: { $0.id == id })?.state == "running" {
                self.tasks[id] = nil
                self.live[id] = nil
                self.update(id, state: "failed", resumable: resume != nil)
            }
        }
    }

    private func progress(_ id: UUID?, written: Int64, expected: Int64) {
        guard let id else { return }
        let now = Date()
        var speed = live[id]?.speed ?? 0
        if let sample = samples[id] {
            let delta = now.timeIntervalSince(sample.time)
            if delta > 0.4 { speed = Double(written - sample.bytes) / delta; samples[id] = (written, now) }
        } else { samples[id] = (written, now) }
        live[id] = DownloadLive(received: written, total: max(0, expected), speed: speed, updated: now)
    }
    private func complete(_ id: UUID?, temp: URL, suggested: String?) {
        guard let id, let model else { try? FileManager.default.removeItem(at: temp); return }
        let profile = owners[id] ?? model.profile.id
        let current = model.state.profiles.first { $0.id == profile }?.downloads.first { $0.id == id }
        let received = live[id]?.received ?? current?.received ?? 0
        let total = live[id]?.total ?? current?.total ?? 0
        var fileName = safeName(suggested ?? current?.fileName ?? "download")
        var destination = directory(profile: profile).appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: destination.path) {
            fileName = String(id.uuidString.prefix(8)) + "-" + fileName
            destination = directory(profile: profile).appendingPathComponent(fileName)
        }
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
            tasks[id] = nil
            live[id] = nil
            resumeData[id] = nil
            update(id, state: "finished", fileName: fileName, received: received, total: total > 0 ? total : received)
            model.message = "下载完成：\(fileName)"
        } catch {
            try? FileManager.default.removeItem(at: temp)
            update(id, state: "failed")
            model.message = error.localizedDescription
        }
    }
}

enum CookieHeader {
    static func value(cookies: [HTTPCookie], url: URL) -> String? {
        guard let host = url.host?.lowercased() else { return nil }
        let matched = cookies.filter { cookie in
            let domain = cookie.domain.lowercased().hasPrefix(".") ? String(cookie.domain.lowercased().dropFirst()) : cookie.domain.lowercased()
            let hostOK = host == domain || host.hasSuffix("." + domain)
            let pathOK = url.path.hasPrefix(cookie.path)
            return hostOK && pathOK
        }
        let header = matched.map { "\($0.name)=\($0.value)" }.joined(separator: "; ")
        return header.isEmpty ? nil : header
    }
}
