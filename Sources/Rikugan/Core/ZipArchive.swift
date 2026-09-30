import Foundation
#if canImport(Security)
import Security
#endif
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
            // Validate the archive path itself (not a filesystem-normalised URL: on iOS devices the
            // temporary directory lives under /private/var, and URL standardisation strips
            // "/private" only from paths that already exist, which made every new file look
            // "outside" the destination).
            guard let safe = ZipArchive.safeRelativePath(relative) else {
                throw RikuganError("ZIP 路径越界：\(entry.path)")
            }
            let destination = directory.appendingPathComponent(safe)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try extract(entry).write(to: destination)
        }
    }

    /// A relative path that stays inside the extraction directory, or nil (absolute paths, `..`
    /// components, drive letters). Backslashes (Windows archivers) are treated as separators.
    public static func safeRelativePath(_ path: String) -> String? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        if normalized.hasPrefix("/") || normalized.range(of: "^[A-Za-z]:", options: .regularExpression) != nil { return nil }
        var parts: [String] = []
        for component in normalized.split(separator: "/", omittingEmptySubsequences: true) {
            if component == "." { continue }
            if component == ".." { return nil }
            parts.append(String(component))
        }
        return parts.isEmpty ? nil : parts.joined(separator: "/")
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
    public enum Algorithm { case rsaSHA256, ecdsaSHA256, rsaSHA1 }
    public struct Proof { public let algorithm: Algorithm; public let publicKey: Data; public let signature: Data }

    public let version: Int
    public let zipData: Data
    public let publicKey: Data?
    /// ID declared by the package (CRX3 signed header, or derived from the CRX2 key). Not proof of
    /// authenticity on its own — see `verifiedID()`.
    public let crxID: String?
    public let proofs: [Proof]
    let signedHeaderData: Data?

    public init(data: Data) throws {
        let b = [UInt8](data)
        func u32(_ i: Int) -> Int { Int(b[i]) | Int(b[i + 1]) << 8 | Int(b[i + 2]) << 16 | Int(b[i + 3]) << 24 }
        guard b.count > 16, b[0] == 0x43, b[1] == 0x72, b[2] == 0x32, b[3] == 0x34 else {
            throw RikuganError("不是 CRX 文件（缺少 Cr24 头）")
        }
        version = u32(4)
        if version == 2 {
            let keyLength = u32(8), sigLength = u32(12)
            let start = 16 + keyLength + sigLength
            guard keyLength > 0, sigLength > 0, start < b.count else { throw RikuganError("CRX2 文件损坏") }
            let key = data.subdata(in: 16..<(16 + keyLength))
            publicKey = key
            zipData = data.subdata(in: start..<b.count)
            crxID = ExtensionID.fromPublicKey(key)
            proofs = [Proof(algorithm: .rsaSHA1, publicKey: key, signature: data.subdata(in: (16 + keyLength)..<start))]
            signedHeaderData = nil
        } else if version == 3 {
            let headerLength = u32(8)
            let start = 12 + headerLength
            guard start < b.count else { throw RikuganError("CRX3 文件损坏") }
            let header = Array(b[12..<start])
            zipData = data.subdata(in: start..<b.count)
            var id: String?
            var signed: Data?
            var found: [Proof] = []
            // CrxFileHeader: 2 = sha256_with_rsa, 3 = sha256_with_ecdsa (AsymmetricKeyProof
            // {1: public_key, 2: signature}), 10000 = signed_header_data (SignedData {1: crx_id}).
            for field in Protobuf.fields(header) {
                if field.number == 10000, let raw = field.bytes {
                    signed = Data(raw)
                    for inner in Protobuf.fields(raw) where inner.number == 1 {
                        if let rawID = inner.bytes, rawID.count == 16 { id = ExtensionID.fromRawID(Data(rawID)) }
                    }
                }
                if field.number == 2 || field.number == 3, let proof = field.bytes {
                    var key: Data?, signature: Data?
                    for inner in Protobuf.fields(proof) {
                        if inner.number == 1, let raw = inner.bytes { key = Data(raw) }
                        if inner.number == 2, let raw = inner.bytes { signature = Data(raw) }
                    }
                    if let key, let signature {
                        found.append(Proof(algorithm: field.number == 2 ? .rsaSHA256 : .ecdsaSHA256, publicKey: key, signature: signature))
                    }
                }
            }
            proofs = found
            signedHeaderData = signed
            publicKey = found.first { id != nil && ExtensionID.fromPublicKey($0.publicKey) == id }?.publicKey ?? found.first?.publicKey
            crxID = id ?? publicKey.map(ExtensionID.fromPublicKey)
        } else {
            throw RikuganError("不支持的 CRX 版本 \(version)")
        }
    }

    /// The package ID, only if a valid signature over the payload was made by the key that ID is
    /// derived from (what Chrome checks). nil for an unsigned, tampered or foreign-signed package.
    public func verifiedID() -> String? {
        switch version {
        case 2:
            guard let proof = proofs.first else { return nil }
            return CRXSignature.verify(proof, message: zipData) ? ExtensionID.fromPublicKey(proof.publicKey) : nil
        case 3:
            guard let signed = signedHeaderData, let id = crxID else { return nil }
            var message = Data("CRX3 SignedData".utf8)
            message.append(0)
            let n = UInt32(signed.count)
            message.append(contentsOf: [UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF), UInt8((n >> 16) & 0xFF), UInt8((n >> 24) & 0xFF)])
            message.append(signed)
            message.append(zipData)
            let developerProofs = proofs.filter { ExtensionID.fromPublicKey($0.publicKey) == id }
            return developerProofs.contains { CRXSignature.verify($0, message: message) } ? id : nil
        default:
            return nil
        }
    }
}

/// Signature checks with the Security framework. Keys are X.509 SubjectPublicKeyInfo (DER).
enum CRXSignature {
    static func verify(_ proof: CRXPackage.Proof, message: Data) -> Bool {
        #if canImport(Security)
        guard let parsed = subjectPublicKey(proof.publicKey) else { return false }
        let (algorithmOID, keyBits) = parsed
        let isEC = algorithmOID == ecPublicKeyOID
        let attributes: [String: Any] = [
            kSecAttrKeyType as String: isEC ? kSecAttrKeyTypeECSECPrimeRandom : kSecAttrKeyTypeRSA,
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        guard let key = SecKeyCreateWithData(keyBits as CFData, attributes as CFDictionary, nil) else { return false }
        let algorithm: SecKeyAlgorithm
        switch proof.algorithm {
        case .rsaSHA256: algorithm = .rsaSignatureMessagePKCS1v15SHA256
        case .rsaSHA1: algorithm = .rsaSignatureMessagePKCS1v15SHA1
        case .ecdsaSHA256: algorithm = .ecdsaSignatureMessageX962SHA256
        }
        guard (proof.algorithm == .ecdsaSHA256) == isEC, SecKeyIsAlgorithmSupported(key, .verify, algorithm) else { return false }
        return SecKeyVerifySignature(key, algorithm, message as CFData, proof.signature as CFData, nil)
        #else
        return false
        #endif
    }

    static let ecPublicKeyOID: [UInt8] = [0x2A, 0x86, 0x48, 0xCE, 0x3D, 0x02, 0x01] // 1.2.840.10045.2.1

    /// SubjectPublicKeyInfo ::= SEQUENCE { algorithm SEQUENCE { OID, params }, subjectPublicKey BIT STRING }
    /// Returns the algorithm OID and the key bits (PKCS#1 RSAPublicKey or an X9.63 EC point).
    static func subjectPublicKey(_ der: Data) -> ([UInt8], Data)? {
        let bytes = [UInt8](der)
        var index = 0
        func readTLV() -> (tag: UInt8, range: Range<Int>)? {
            guard index + 2 <= bytes.count else { return nil }
            let tag = bytes[index]; index += 1
            var length = Int(bytes[index]); index += 1
            if length & 0x80 != 0 {
                let count = length & 0x7F
                guard count > 0, count <= 4, index + count <= bytes.count else { return nil }
                length = 0
                for _ in 0..<count { length = length << 8 | Int(bytes[index]); index += 1 }
            }
            guard index + length <= bytes.count else { return nil }
            defer { index += length }
            return (tag, index..<(index + length))
        }
        guard let outer = readTLV(), outer.tag == 0x30 else { return nil }
        index = outer.range.lowerBound
        guard let algorithm = readTLV(), algorithm.tag == 0x30 else { return nil }
        let afterAlgorithm = index
        index = algorithm.range.lowerBound
        guard let oid = readTLV(), oid.tag == 0x06 else { return nil }
        let oidBytes = Array(bytes[oid.range])
        index = afterAlgorithm
        guard let bitString = readTLV(), bitString.tag == 0x03, bitString.range.count > 1, bytes[bitString.range.lowerBound] == 0 else { return nil }
        return (oidBytes, Data(bytes[(bitString.range.lowerBound + 1)..<bitString.range.upperBound]))
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
