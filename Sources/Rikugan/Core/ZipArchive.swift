import Foundation
#if canImport(Compression)
import Compression
#endif

/// Minimal, defensive ZIP reader (store + deflate). Used for extension packages, CRX payloads
/// and imported archives. Rejects path traversal, symlinks, encryption and ZIP64.
public struct ZipArchive {
    public struct Entry {
        public let path: String
        public let method: UInt16
        public let compressedSize: Int
        public let uncompressedSize: Int
        public let localHeaderOffset: Int
        public let isDirectory: Bool
        public let crc32: UInt32
    }

    public let data: Data
    public let entries: [Entry]

    public static let maxTotalUncompressed = 256 * 1024 * 1024
    public static let maxEntries = 20_000

    public init(data: Data) throws {
        self.data = data
        let bytes = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(bytes[i]) | Int(bytes[i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        guard bytes.count >= 22 else { throw RikuganError("ZIP 文件太小或已损坏") }
        var eocd: Int?
        let lowest = max(0, bytes.count - 65_557)
        var i = bytes.count - 22
        while i >= lowest {
            if u32(i) == 0x0605_4B50 { eocd = i; break }
            i -= 1
        }
        guard let end = eocd else { throw RikuganError("找不到 ZIP 目录，文件可能不是 ZIP") }
        let count = u16(end + 10)
        let cdSize = u32(end + 12)
        let cdOffset = u32(end + 16)
        guard count != 0xFFFF, cdOffset != 0xFFFF_FFFF else { throw RikuganError("暂不支持 ZIP64 格式") }
        guard count <= ZipArchive.maxEntries, cdOffset + cdSize <= end else { throw RikuganError("ZIP 目录无效") }
        var entries: [Entry] = []
        var p = cdOffset
        var total = 0
        for _ in 0..<count {
            guard p + 46 <= bytes.count, u32(p) == 0x0201_4B50 else { throw RikuganError("ZIP 目录项损坏") }
            let flags = u16(p + 8)
            let method = UInt16(u16(p + 10))
            let crc = UInt32(u32(p + 16))
            let compressed = u32(p + 20)
            let uncompressed = u32(p + 24)
            let nameLength = u16(p + 28), extraLength = u16(p + 30), commentLength = u16(p + 32)
            let externalAttributes = u32(p + 38)
            let localOffset = u32(p + 42)
            guard p + 46 + nameLength <= bytes.count else { throw RikuganError("ZIP 文件名损坏") }
            let nameBytes = bytes[(p + 46)..<(p + 46 + nameLength)]
            let name = String(bytes: nameBytes, encoding: .utf8) ?? String(bytes: nameBytes, encoding: .isoLatin1) ?? ""
            p += 46 + nameLength + extraLength + commentLength
            guard flags & 1 == 0 else { throw RikuganError("不支持加密的 ZIP") }
            guard compressed != 0xFFFF_FFFF, uncompressed != 0xFFFF_FFFF else { throw RikuganError("暂不支持 ZIP64 格式") }
            let unixMode = externalAttributes >> 16
            if unixMode & 0xF000 == 0xA000 { throw RikuganError("ZIP 中包含符号链接，已拒绝：\(name)") }
            let normalized = name.replacingOccurrences(of: "\\", with: "/")
            guard !normalized.isEmpty, !normalized.hasPrefix("/"), !normalized.contains("\0"),
                  !normalized.split(separator: "/").contains("..") else {
                throw RikuganError("ZIP 中包含危险路径，已拒绝：\(name)")
            }
            total += uncompressed
            guard total <= ZipArchive.maxTotalUncompressed else { throw RikuganError("解压后超过 256 MB，已拒绝") }
            entries.append(Entry(path: normalized, method: method, compressedSize: compressed, uncompressedSize: uncompressed,
                                 localHeaderOffset: localOffset, isDirectory: normalized.hasSuffix("/"), crc32: crc))
        }
        self.entries = entries
    }

    public func entry(_ path: String) -> Entry? { entries.first { $0.path == path } }

    public func extract(_ entry: Entry) throws -> Data {
        let bytes = data
        let base = bytes.startIndex
        func u16(_ i: Int) -> Int { Int(bytes[base + i]) | Int(bytes[base + i + 1]) << 8 }
        func u32(_ i: Int) -> Int { u16(i) | u16(i + 2) << 16 }
        let h = entry.localHeaderOffset
        guard h + 30 <= bytes.count, u32(h) == 0x0403_4B50 else { throw RikuganError("ZIP 本地文件头损坏：\(entry.path)") }
        let start = h + 30 + u16(h + 26) + u16(h + 28)
        guard start + entry.compressedSize <= bytes.count else { throw RikuganError("ZIP 数据越界：\(entry.path)") }
        let payload = bytes.subdata(in: (base + start)..<(base + start + entry.compressedSize))
        switch entry.method {
        case 0: return payload
        case 8: return try ZipArchive.inflate(payload, expectedSize: entry.uncompressedSize)
        default: throw RikuganError("不支持的 ZIP 压缩方法 \(entry.method)：\(entry.path)")
        }
    }

    /// Raw DEFLATE decompression.
    public static func inflate(_ data: Data, expectedSize: Int) throws -> Data {
        if expectedSize == 0 { return Data() }
        #if canImport(Compression)
        var output = Data(count: expectedSize)
        let written = output.withUnsafeMutableBytes { (dst: UnsafeMutableRawBufferPointer) -> Int in
            data.withUnsafeBytes { (src: UnsafeRawBufferPointer) -> Int in
                guard let d = dst.bindMemory(to: UInt8.self).baseAddress,
                      let s = src.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(d, expectedSize, s, data.count, nil, COMPRESSION_ZLIB)
            }
        }
        guard written == expectedSize else { throw RikuganError("ZIP 解压失败（数据损坏）") }
        return output
        #else
        throw RikuganError("当前平台不支持 DEFLATE")
        #endif
    }

    /// Extracts every entry beneath `root` (a path prefix inside the archive) into `directory`.
    public func extractAll(to directory: URL, stripPrefix root: String = "") throws {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        for entry in entries where !entry.isDirectory {
            guard entry.path.hasPrefix(root) else { continue }
            let relative = String(entry.path.dropFirst(root.count))
            if relative.isEmpty || relative.hasPrefix("__MACOSX/") || relative.hasSuffix(".DS_Store") { continue }
            let destination = directory.appendingPathComponent(relative)
            guard destination.standardizedFileURL.path.hasPrefix(directory.standardizedFileURL.path) else {
                throw RikuganError("ZIP 路径越界：\(entry.path)")
            }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try extract(entry).write(to: destination)
        }
    }

    /// Locates the folder inside the archive that contains `fileName` at its root
    /// (handles archives wrapped in one extra directory).
    public func rootPrefix(containing fileName: String) -> String? {
        if entry(fileName) != nil { return "" }
        let candidates = entries.filter { $0.path.hasSuffix("/" + fileName) && !$0.path.hasPrefix("__MACOSX/") }
            .map { String($0.path.dropLast(fileName.count)) }
            .sorted { $0.count < $1.count }
        return candidates.first
    }
}

/// Chrome CRX (v2 / v3) container.
public struct CRXPackage {
    public let zipData: Data
    public let publicKey: Data?
    public let crxID: String?

    public init(data: Data) throws {
        let b = [UInt8](data)
        func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        guard b.count > 16, b[0] == 0x43, b[1] == 0x72, b[2] == 0x32, b[3] == 0x34 else {
            throw RikuganError("不是 CRX 文件（缺少 Cr24 头）")
        }
        let version = u32(4)
        if version == 2 {
            let keyLength = u32(8), sigLength = u32(12)
            let start = 16 + keyLength + sigLength
            guard start < b.count else { throw RikuganError("CRX2 文件损坏") }
            publicKey = data.subdata(in: 16..<(16 + keyLength))
            zipData = data.subdata(in: start..<b.count)
            crxID = publicKey.map(ExtensionID.fromPublicKey)
        } else if version == 3 {
            let headerLength = u32(8)
            let start = 12 + headerLength
            guard start < b.count else { throw RikuganError("CRX3 文件损坏") }
            let header = Array(b[12..<start])
            zipData = data.subdata(in: start..<b.count)
            var key: Data?
            var id: String?
            // CrxFileHeader: 2 = sha256_with_rsa (AsymmetricKeyProof), 10000 = signed_header_data
            for field in Protobuf.fields(header) {
                if field.number == 10000, let signed = field.bytes {
                    for inner in Protobuf.fields(signed) where inner.number == 1 {
                        if let raw = inner.bytes, raw.count == 16 { id = ExtensionID.fromRawID(Data(raw)) }
                    }
                }
                if field.number == 2, key == nil, let proof = field.bytes {
                    for inner in Protobuf.fields(proof) where inner.number == 1 {
                        if let raw = inner.bytes { key = Data(raw) }
                    }
                }
            }
            publicKey = key
            crxID = id ?? key.map(ExtensionID.fromPublicKey)
        } else {
            throw RikuganError("不支持的 CRX 版本 \(version)")
        }
    }
}

enum Protobuf {
    struct Field { let number: Int; let bytes: [UInt8]? }

    static func fields(_ data: [UInt8]) -> [Field] {
        var result: [Field] = []
        var i = 0
        func varint() -> Int? {
            var value = 0, shift = 0
            while i < data.count {
                let byte = Int(data[i]); i += 1
                value |= (byte & 0x7F) << shift
                if byte & 0x80 == 0 { return value }
                shift += 7
                if shift > 56 { return nil }
            }
            return nil
        }
        while i < data.count {
            guard let key = varint() else { break }
            let number = key >> 3, wire = key & 7
            switch wire {
            case 0: guard varint() != nil else { return result }; result.append(Field(number: number, bytes: nil))
            case 1: i += 8
            case 2:
                guard let length = varint(), length >= 0, i + length <= data.count else { return result }
                result.append(Field(number: number, bytes: Array(data[i..<(i + length)])))
                i += length
            case 5: i += 4
            default: return result
            }
        }
        return result
    }
}
