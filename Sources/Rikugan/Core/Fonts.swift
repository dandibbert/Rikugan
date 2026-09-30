import Foundation

/// Resolved font override for one host (spec follow-up §9).
public struct FontPlan: Equatable, Codable {
    public var body: String?
    public var heading: String?
    public var mono: String?
    public var isEmpty: Bool { body == nil && heading == nil && mono == nil }

    public init(body: String? = nil, heading: String? = nil, mono: String? = nil) {
        self.body = body; self.heading = heading; self.mono = mono
    }

    /// Global rules + per-site override. A per-site `webFont == false` disables everything; per-site
    /// families replace the global ones individually.
    public static func resolve(prefs: Preferences, site: SiteSettings, host: String) -> FontPlan? {
        if site.webFont == false { return nil }
        if prefs.webFontExcludedHosts.contains(where: { DomainTools.host(host, isWithin: $0) }) && site.webFont != true { return nil }
        let globalOn = prefs.webFontEnabled || site.webFont == true
        func pick(_ siteValue: String?, _ global: String) -> String? {
            if let siteValue, !siteValue.isEmpty { return siteValue }
            return globalOn && !global.isEmpty ? global : nil
        }
        let plan = FontPlan(body: pick(site.fontBody, prefs.webFontFamily), heading: pick(site.fontHeading, prefs.webFontHeading),
                            mono: pick(site.fontMono, prefs.webFontMono))
        return plan.isEmpty ? nil : plan
    }

    /// Heuristic used by the page tagger to recognise icon / symbol fonts (never overridden).
    public static let iconFontPattern = "icon|icomoon|awesome|fontello|glyph|symbol|material|octicon|dashicons|feather|remix|ionic|typicons|entypo|linearicons|themify|bootstrap-icons|codicon|iconfont|^fa$|^fa[srbld]?-|webfont-ico|lucide|tabler|phosphor"
}

/// TrueType / OpenType collection (.ttc) splitter: WebKit's font loader handles single-face
/// sfnt data, so every face of an imported collection is rebuilt as a standalone font.
public enum FontCollection {
    public static func isCollection(_ data: Data) -> Bool { data.prefix(4) == Data("ttcf".utf8) }

    public static func split(_ data: Data) throws -> [Data] {
        let b = [UInt8](data)
        func u16(_ i: Int) -> Int { Int(b[i]) << 8 | Int(b[i + 1]) }
        func u32(_ i: Int) -> Int { u16(i) << 16 | u16(i + 2) }
        guard b.count >= 12, isCollection(data) else { throw RikuganError("不是 TTC 字体集合") }
        let count = u32(8)
        guard count > 0, count < 256, 12 + count * 4 <= b.count else { throw RikuganError("TTC 字体集合头部损坏") }
        var fonts: [Data] = []
        for index in 0..<count {
            let offset = u32(12 + index * 4)
            guard offset + 12 <= b.count else { throw RikuganError("TTC 字体偏移越界") }
            let numTables = u16(offset + 4)
            guard numTables > 0, numTables < 200, offset + 12 + numTables * 16 <= b.count else { throw RikuganError("TTC 字体表目录损坏") }
            var header = [UInt8](b[offset..<(offset + 12)])
            var records: [UInt8] = []
            var body: [UInt8] = []
            var position = 12 + numTables * 16
            for t in 0..<numTables {
                let r = offset + 12 + t * 16
                let tableOffset = u32(r + 8), length = u32(r + 12)
                guard tableOffset + length <= b.count else { throw RikuganError("TTC 字体表越界") }
                var record = [UInt8](b[r..<(r + 8)])
                record += [UInt8((position >> 24) & 0xFF), UInt8((position >> 16) & 0xFF), UInt8((position >> 8) & 0xFF), UInt8(position & 0xFF)]
                record += [UInt8](b[(r + 12)..<(r + 16)])
                records += record
                body += b[tableOffset..<(tableOffset + length)]
                let pad = (4 - length % 4) % 4
                body += [UInt8](repeating: 0, count: pad)
                position += length + pad
            }
            header[4] = UInt8((numTables >> 8) & 0xFF)
            header[5] = UInt8(numTables & 0xFF)
            fonts.append(Data(header + records + body))
        }
        return fonts
    }
}
