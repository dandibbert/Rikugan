import Foundation
import Combine

struct DownloadLive: Equatable {
    var received: Int64 = 0
    var total: Int64 = 0
    var speed: Double = 0
    var updated = Date()
}

@MainActor final class DownloadCenter: NSObject, ObservableObject, URLSessionDownloadDelegate {
    weak var model: AppModel?
    @Published var live: [UUID: DownloadLive] = [:]
    private var session: URLSession!
    private var tasks: [UUID: URLSessionDownloadTask] = [:]
    private var samples: [UUID: (bytes: Int64, time: Date)] = [:]
    private var resumeData: [UUID: Data] = [:]
    private var owners: [UUID: UUID] = [:]

    func activate(_ model: AppModel) {
        self.model = model
        guard session == nil else { return }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCache = nil
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

    func start(url: URL, suggested name: String? = nil) {
        guard let model else { return }
        let profile = model.profile.id
        let id = UUID()
        owners[id] = profile
        let fileName = safeName(name ?? url.lastPathComponent)
        let record = DownloadRecord(id: id, name: fileName, fileName: fileName, state: "running", resumable: true, source: url.absoluteString)
        model.updateProfile(profile) { $0.downloads.insert(record, at: 0) }
        var request = URLRequest(url: url)
        request.setValue("Rikugan", forHTTPHeaderField: "User-Agent")
        let task = session.downloadTask(with: request)
        task.taskDescription = id.uuidString
        tasks[id] = task
        live[id] = DownloadLive()
        task.resume()
    }
    func pause(_ id: UUID) {
        guard let task = tasks[id] else { return }
        task.cancel(byProducingResumeData: { [weak self] data in
            Task { @MainActor in
                guard let self else { return }
                if let data { self.resumeData[id] = data }
                self.tasks[id] = nil
                self.live[id] = nil
                self.update(id, state: "paused", resumable: data != nil)
            }
        })
    }
    func resume(_ id: UUID) {
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
        tasks[id] = nil
        resumeData[id] = nil
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
    func noteWebKit(name: String, fileName: String, state: String) -> UUID {
        let id = UUID()
        guard let model else { return id }
        owners[id] = model.profile.id
        let record = DownloadRecord(id: id, name: name, fileName: fileName, state: state, resumable: false)
        model.updateProfile(model.profile.id) { $0.downloads.insert(record, at: 0) }
        return id
    }
    func finishWebKit(_ id: UUID, fileName: String) { update(id, state: "finished", fileName: fileName) }

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
