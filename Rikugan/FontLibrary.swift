import CoreText
import UIKit

enum FontLibrary {
    static func rejectUnsupported(_ data: Data, ext: String) throws {
        let kind = ext.lowercased()
        if kind == "woff" || kind == "woff2" {
            throw RikuganError.message("不能注册 woff / woff2。Core Text 只接受 ttf、otf 或 ttc，页面不会假装已经用上这个字体。")
        }
        if data.count >= 4 {
            let magic = String(data: data.prefix(4), encoding: .ascii) ?? ""
            if magic == "wOFF" || magic == "wOF2" {
                throw RikuganError.message("文件内容是 woff / woff2。Core Text 不能注册，请换 ttf、otf 或 ttc。")
            }
        }
        guard ["ttf", "otf", "ttc", ""].contains(kind) else {
            throw RikuganError.message("只接受 ttf、otf 或 ttc。")
        }
    }
    static func register(_ url: URL) throws -> String {
        var error: Unmanaged<CFError>?
        guard CTFontManagerRegisterFontsForURL(url as CFURL, .process, &error) else {
            throw (error?.takeRetainedValue()).map { $0 as Error } ?? RikuganError.message("系统没有接受这个字体文件。")
        }
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(url as CFURL) as? [CTFontDescriptor],
              let first = descriptors.first,
              let name = CTFontDescriptorCopyAttribute(first, kCTFontFamilyNameAttribute) as? String else {
            throw RikuganError.message("字体已注册，但读不到字体家族名称。")
        }
        return name
    }
    static func families() -> [String] {
        UIFont.familyNames.sorted()
    }
    static func faceCSS(file: URL, family: String) -> String {
        guard let data = try? Data(contentsOf: file), data.count <= 2_500_000 else { return "" }
        let ext = file.pathExtension.lowercased()
        let mime = ext == "otf" ? "font/otf" : ext == "ttc" ? "font/collection" : "font/ttf"
        let format = ext == "otf" ? "opentype" : "truetype"
        return "@font-face{font-family:\(json(family));src:url(data:\(mime);base64,\(data.base64EncodedString())) format('\(format)');}"
    }
    private static func json(_ value: String) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: [value])) ?? Data("[]".utf8)
        let text = String(data: data, encoding: .utf8) ?? "[\"\"]"
        return String(text.dropFirst().dropLast())
    }
}
