import Foundation

/// How this copy of the app was signed, read from the app itself: the entitlements embedded in
/// the executable's code signature and the bundled provisioning profile. Re-signing tools differ
/// in what they write (bundle ID, application-identifier, App Groups), and system services that
/// identify the app by its application-identifier (document picker grants, alternate icons,
/// App Groups) fail when it does not name this bundle. Shown on the Diagnostics page only; not
/// part of the exported report.
@MainActor struct SigningInfo {
    var bundleID: String
    var shareExtensionBundleID: String?
    /// Entitlements in the executable's signature (what the system enforces).
    var signedEntitlements: [String: Any]?
    var profileName: String?
    var profileTeam: String?
    var profileExpires: Date?
    var profileKind: String
    var profileAppID: String?

    var applicationIdentifier: String? { signedEntitlements?["application-identifier"] as? String }
    var teamID: String? { signedEntitlements?["com.apple.developer.team-identifier"] as? String }
    var appGroups: [String] { signedEntitlements?["com.apple.security.application-groups"] as? [String] ?? [] }
    var getTaskAllow: Bool { signedEntitlements?["get-task-allow"] as? Bool ?? false }

    /// Problems that explain features failing after re-signing.
    var problems: [String] {
        var list: [String] = []
        if signedEntitlements == nil {
            list.append("读不到签名中的 entitlements（未签名或签名格式无法解析）")
        } else if let appID = applicationIdentifier {
            if appID.contains("*") {
                list.append("application-identifier 是通配符（\(appID)），没有替换成本 App 的包名：文件选择器授权、更换图标等依赖 App 身份的系统功能会失败")
            } else if !appID.hasSuffix("." + bundleID) {
                list.append("application-identifier（\(appID)）与包名（\(bundleID)）不一致")
            }
        } else {
            list.append("签名中没有 application-identifier")
        }
        if let ext = shareExtensionBundleID, !ext.hasPrefix(bundleID + ".") {
            list.append("分享扩展包名（\(ext)）不是以主 App 包名开头")
        }
        if !appGroups.contains(AppServices.appGroup) {
            list.append("签名中没有 App Group \(AppServices.appGroup)（分享扩展只能退回到剪贴板交接）")
        }
        return list
    }

    static func read() -> SigningInfo {
        let bundle = Bundle.main
        var info = SigningInfo(bundleID: bundle.bundleIdentifier ?? "?", profileKind: "无描述文件")
        if let plugIns = bundle.builtInPlugInsURL,
           let appex = try? FileManager.default.contentsOfDirectory(at: plugIns, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "appex" }) {
            info.shareExtensionBundleID = Bundle(url: appex)?.bundleIdentifier
        }
        if let executable = bundle.executableURL, let data = try? Data(contentsOf: executable, options: .mappedIfSafe) {
            info.signedEntitlements = entitlements(inMachO: data)
        }
        if let url = bundle.url(forResource: "embedded", withExtension: "mobileprovision"),
           let data = try? Data(contentsOf: url), let profile = plist(embeddedIn: data) {
            info.profileName = profile["Name"] as? String
            info.profileTeam = (profile["TeamName"] as? String).map { name in
                ((profile["TeamIdentifier"] as? [String])?.first).map { "\(name)（\($0)）" } ?? name
            }
            info.profileExpires = profile["ExpirationDate"] as? Date
            info.profileAppID = (profile["Entitlements"] as? [String: Any])?["application-identifier"] as? String
            let devices = (profile["ProvisionedDevices"] as? [Any])?.count
            if profile["ProvisionsAllDevices"] as? Bool == true {
                info.profileKind = "企业（所有设备）"
            } else if let devices {
                let development = (profile["Entitlements"] as? [String: Any])?["get-task-allow"] as? Bool == true
                info.profileKind = (development ? "开发" : "Ad Hoc") + "（\(devices) 台设备）"
            } else {
                info.profileKind = "其他"
            }
        }
        return info
    }

    // MARK: Parsing

    /// The XML plist inside a CMS-signed .mobileprovision.
    private static func plist(embeddedIn data: Data) -> [String: Any]? {
        guard let start = data.range(of: Data("<?xml".utf8)), let end = data.range(of: Data("</plist>".utf8), in: start.lowerBound..<data.endIndex) else { return nil }
        let slice = data.subdata(in: start.lowerBound..<end.upperBound)
        return try? PropertyListSerialization.propertyList(from: slice, format: nil) as? [String: Any]
    }

    /// Entitlements blob (magic 0xfade7171) of the code signature (LC_CODE_SIGNATURE) of a thin or
    /// fat 64-bit Mach-O.
    private static func entitlements(inMachO data: Data) -> [String: Any]? {
        func u32(_ offset: Int, bigEndian: Bool) -> UInt32? {
            guard offset >= 0, offset + 4 <= data.count else { return nil }
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self) }
            return bigEndian ? UInt32(bigEndian: value) : UInt32(littleEndian: value)
        }
        guard let magic = u32(0, bigEndian: true) else { return nil }
        var sliceOffset = 0
        if magic == 0xCAFE_BABE || magic == 0xCAFE_BABF {
            // Fat: first arm64 slice (CPU_TYPE_ARM64 = 0x0100000C), else the first slice.
            let count = Int(u32(4, bigEndian: true) ?? 0)
            let entrySize = magic == 0xCAFE_BABF ? 32 : 20
            var chosen: Int?
            for index in 0..<count {
                let entry = 8 + index * entrySize
                let cpu = u32(entry, bigEndian: true)
                let offset = magic == 0xCAFE_BABF ? Int((UInt64(u32(entry + 8, bigEndian: true) ?? 0) << 32) | UInt64(u32(entry + 12, bigEndian: true) ?? 0))
                                                  : Int(u32(entry + 8, bigEndian: true) ?? 0)
                if chosen == nil || cpu == 0x0100_000C { chosen = offset }
                if cpu == 0x0100_000C { break }
            }
            guard let chosen else { return nil }
            sliceOffset = chosen
        }
        guard u32(sliceOffset, bigEndian: false) == 0xFEED_FACF, let commands = u32(sliceOffset + 16, bigEndian: false) else { return nil }
        var cursor = sliceOffset + 32
        for _ in 0..<commands {
            guard let cmd = u32(cursor, bigEndian: false), let size = u32(cursor + 4, bigEndian: false), size > 0 else { return nil }
            if cmd == 0x1D, let dataOffset = u32(cursor + 8, bigEndian: false) {
                let blob = sliceOffset + Int(dataOffset)
                guard u32(blob, bigEndian: true) == 0xFADE_0CC0, let count = u32(blob + 8, bigEndian: true) else { return nil }
                for index in 0..<Int(count) {
                    guard let offset = u32(blob + 12 + index * 8 + 4, bigEndian: true) else { continue }
                    let entry = blob + Int(offset)
                    guard u32(entry, bigEndian: true) == 0xFADE_7171, let length = u32(entry + 4, bigEndian: true),
                          entry + Int(length) <= data.count, length > 8 else { continue }
                    let xml = data.subdata(in: (entry + 8)..<(entry + Int(length)))
                    return try? PropertyListSerialization.propertyList(from: xml, format: nil) as? [String: Any]
                }
                return nil
            }
            cursor += Int(size)
        }
        return nil
    }
}
