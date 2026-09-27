import Foundation

enum ShareInboxError: LocalizedError {
    case invalid(String)
    var errorDescription: String? { if case .invalid(let message) = self { return message }; return nil }
}

struct SharedItem: Codable, Identifiable, Equatable {
    enum Kind: String, Codable { case open, search, script }
    var id = UUID()
    var kind: Kind
    var value: String
    var name = ""

    func validate() throws {
        let limit = kind == .script ? 2_000_000 : 16_000
        guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              value.utf8.count <= limit, name.utf8.count <= 512 else {
            throw ShareInboxError.invalid("分享内容为空或超过大小限制。脚本最多 2 MB，链接/文本最多 16 KB。")
        }
        if kind == .open {
            guard let url = URL(string: value), ["http", "https"].contains(url.scheme?.lowercased() ?? ""),
                  url.host != nil, url.user == nil, url.password == nil else {
                throw ShareInboxError.invalid("分享链接必须是没有嵌入凭证的 HTTP(S) 网页。")
            }
        }
        if kind == .script {
            guard let start = value.range(of: "// ==UserScript=="),
                  value.range(of: "// ==/UserScript==", range: start.upperBound..<value.endIndex) != nil else {
                throw ShareInboxError.invalid("文件缺少完整的 Userscript 元数据头，未导入。")
            }
        }
    }
}

struct SharedBatch: Codable, Identifiable, Equatable {
    var version = 1
    var id = UUID()
    var createdAt = Date()
    var items: [SharedItem]
}

/// Immutable, uniquely named batch files are published atomically. No shared
/// read-modify-write slot: two share extensions cannot overwrite one another.
/// Group -> app transfer is copy, persist, acknowledge (retryable and idempotent).
final class ShareInbox {
    let directory: URL
    private let lock = NSRecursiveLock()
    init(container: URL) { directory = container.appendingPathComponent("ShareInbox", isDirectory: true) }

    func enqueue(_ batch: SharedBatch) throws {
        lock.lock(); defer { lock.unlock() }
        guard batch.version == 1, (1...16).contains(batch.items.count),
              Set(batch.items.map(\.id)).count == batch.items.count, batch.createdAt.timeIntervalSince1970.isFinite else {
            throw ShareInboxError.invalid("分享批次版本或内容无效。一次最多 16 项。")
        }
        try batch.items.forEach { try $0.validate() }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = url(batch.id)
        if FileManager.default.fileExists(atPath: file.path) {
            guard try read(file) == batch else { throw ShareInboxError.invalid("分享标识冲突，未覆盖已有内容。") }
            return
        }
        let existing = try batches()
        let data = try JSONEncoder().encode(batch)
        guard existing.count < 64, data.count <= 8_500_000,
              existing.flatMap(\.items).reduce(data.count, { $0 + $1.value.utf8.count }) <= 32_000_000 else {
            throw ShareInboxError.invalid("分享收件箱已满，请先在 Rikugan 处理待导入内容。")
        }
        try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }

    func batches() throws -> [SharedBatch] {
        lock.lock(); defer { lock.unlock() }
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }
        return try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey])
            .filter { $0.pathExtension == "json" }
            .map { try read($0) }
            .sorted { $0.createdAt == $1.createdAt ? $0.id.uuidString < $1.id.uuidString : $0.createdAt < $1.createdAt }
    }
    func items() throws -> [SharedItem] { try batches().flatMap(\.items) }

    func acknowledge(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        for var batch in try batches() where batch.items.contains(where: { $0.id == id }) {
            batch.items.removeAll { $0.id == id }
            if batch.items.isEmpty { try removeBatch(batch.id) }
            else { try JSONEncoder().encode(batch).write(to: url(batch.id), options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]) }
        }
    }
    func removeBatch(_ id: UUID) throws {
        lock.lock(); defer { lock.unlock() }
        let file = url(id)
        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
    }
    func transfer(to destination: ShareInbox) throws {
        for batch in try batches() {
            try destination.enqueue(batch)
            try removeBatch(batch.id)
        }
    }
    private func url(_ id: UUID) -> URL { directory.appendingPathComponent(id.uuidString.lowercased() + ".json") }
    private func read(_ file: URL) throws -> SharedBatch {
        let attributes = try file.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
        guard attributes.isSymbolicLink != true, attributes.isRegularFile == true,
              (attributes.fileSize ?? Int.max) <= 8_500_000 else { throw ShareInboxError.invalid("分享文件不安全或超过大小限制。") }
        let batch = try JSONDecoder().decode(SharedBatch.self, from: Data(contentsOf: file))
        guard batch.version == 1, file.lastPathComponent == url(batch.id).lastPathComponent,
              (1...16).contains(batch.items.count), Set(batch.items.map(\.id)).count == batch.items.count else {
            throw ShareInboxError.invalid("分享文件损坏，未执行或覆盖任何资料。")
        }
        try batch.items.forEach { try $0.validate() }
        return batch
    }
}
