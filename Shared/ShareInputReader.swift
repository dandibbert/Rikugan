import Foundation
import UniformTypeIdentifiers

enum ShareInputReader {
    static func read(_ providers: [NSItemProvider]) async throws -> [SharedItem] {
        guard (1...16).contains(providers.count) else { throw ShareInboxError.invalid("一次分享需要包含 1–16 项内容。") }
        var items: [SharedItem] = []
        for provider in providers {
            let item = try await read(provider)
            try item.validate()
            items.append(item)
        }
        guard items.reduce(0, { $0 + $1.value.utf8.count }) <= 8_000_000 else { throw ShareInboxError.invalid("本次分享超过 8 MB。") }
        return items
    }
    static func text(_ value: String, name: String = "") throws -> SharedItem {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let kind: SharedItem.Kind = trimmed.contains("// ==UserScript==") ? .script :
            (["http", "https"].contains(URL(string: trimmed)?.scheme?.lowercased() ?? "") && !trimmed.contains(where: \.isWhitespace) ? .open : .search)
        let item = SharedItem(kind: kind, value: kind == .script ? value : trimmed, name: String(name.prefix(120)))
        try item.validate(); return item
    }
    private static func scriptFile(_ url: URL, name: String) throws -> SharedItem {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let info = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard info.isRegularFile == true, info.isSymbolicLink != true, (info.fileSize ?? Int.max) <= 2_000_000 else {
            throw ShareInboxError.invalid("分享的脚本必须是最多 2 MB 的普通文本文件。")
        }
        let item = SharedItem(kind: .script, value: try String(contentsOf: url, encoding: .utf8), name: String(name.prefix(120)))
        try item.validate(); return item
    }
    private static func read(_ provider: NSItemProvider) async throws -> SharedItem {
        let name = provider.suggestedName ?? ""
        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, error in
                    do {
                        if let error { throw error }
                        guard let url = item as? URL, url.isFileURL else { throw ShareInboxError.invalid("没有读取到分享文件。") }
                        continuation.resume(returning: try scriptFile(url, name: name.isEmpty ? url.lastPathComponent : name))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        let scriptType = provider.registeredTypeIdentifiers.first {
            UTType($0)?.conforms(to: .javaScript) == true ||
                (name.lowercased().hasSuffix(".user.js") && UTType($0)?.conforms(to: .data) == true)
        }
        if let scriptType {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadFileRepresentation(forTypeIdentifier: scriptType) { url, error in
                    // NSItemProvider removes temporary files after this callback.
                    // Read bytes INSIDE it, never pass the temporary URL onward.
                    if let url {
                        do { continuation.resume(returning: try scriptFile(url, name: name)) }
                        catch { continuation.resume(throwing: error) }
                    } else {
                        // Some providers export data but cannot vend a temporary
                        // file. Keep the same UTF-8, metadata and size checks.
                        provider.loadDataRepresentation(forTypeIdentifier: scriptType) { data, dataError in
                            do {
                                guard let data, data.count <= 2_000_000, let value = String(data: data, encoding: .utf8) else {
                                    throw dataError ?? error ?? ShareInboxError.invalid("分享没有提供有效脚本正文。")
                                }
                                let item = SharedItem(kind: .script, value: value, name: String(name.prefix(120)))
                                try item.validate(); continuation.resume(returning: item)
                            } catch { continuation.resume(throwing: error) }
                        }
                    }
                }
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadItem(forTypeIdentifier: UTType.url.identifier, options: nil) { item, error in
                    do {
                        if let error { throw error }
                        guard let url = item as? URL else { throw ShareInboxError.invalid("没有读取到分享网址。") }
                        if url.isFileURL { continuation.resume(returning: try scriptFile(url, name: name)); return }
                        continuation.resume(returning: try text(url.absoluteString, name: name))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        if provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
            return try await withCheckedThrowingContinuation { continuation in
                provider.loadDataRepresentation(forTypeIdentifier: UTType.plainText.identifier) { data, error in
                    do {
                        if let error { throw error }
                        guard let data, data.count <= 2_000_000, let value = String(data: data, encoding: .utf8) else { throw ShareInboxError.invalid("分享文本不是 UTF-8 或超过 2 MB。") }
                        continuation.resume(returning: try text(value, name: name))
                    } catch { continuation.resume(throwing: error) }
                }
            }
        }
        throw ShareInboxError.invalid("仅支持网页链接、文本和 .user.js 脚本文件。")
    }
}
