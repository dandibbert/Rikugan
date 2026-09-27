import Foundation

enum ScriptUpdateResolver {
    /// An update endpoint often contains metadata only. It must never replace the
    /// installed program. The caller always previews the returned full source.
    static func source(for installed: UserScript, checkVersion: Bool = true,
                       fetch: (URL) async throws -> String = { try await ScriptNetwork.downloadText($0) }) async throws -> String? {
        let address = checkVersion && !installed.updateURL.isEmpty ? installed.updateURL :
            (installed.downloadURL.isEmpty ? installed.updateURL : installed.downloadURL)
        let metadataURL = try secureURL(address)
        let first = try await fetch(metadataURL)
        let metadata = try UserScript.parse(first)
        if checkVersion && !VersionComparator.isNewer(metadata.version, than: installed.version) { return nil }
        let downloadAddress = metadata.downloadURL.isEmpty ? installed.downloadURL : metadata.downloadURL
        let source: String
        if !downloadAddress.isEmpty, try secureURL(downloadAddress) != metadataURL {
            source = try await fetch(secureURL(downloadAddress))
        } else { source = first }
        guard let end = source.range(of: "// ==/UserScript=="),
              !source[end.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw RikuganError.message("更新服务器只返回了元数据，没有脚本正文。原脚本未修改，请检查 @downloadURL。")
        }
        let script = try UserScript.parse(source)
        if VersionComparator.isNewer(metadata.version, than: script.version) {
            throw RikuganError.message("下载的脚本正文比更新元数据版本旧，原脚本未修改。")
        }
        if checkVersion && !VersionComparator.isNewer(script.version, than: installed.version) { return nil }
        return source
    }

    private static func secureURL(_ raw: String) throws -> URL {
        guard let url = URL(string: raw), url.scheme?.lowercased() == "https", url.host != nil,
              url.user == nil, url.password == nil else { throw RikuganError.message("这个脚本没有有效的 HTTPS 更新/下载地址。") }
        return url
    }
}
