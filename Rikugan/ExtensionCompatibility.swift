import Foundation

enum ExtensionCompatibility {
    static let notice = "普通签名兼容后台：把 MV3 的 Service Worker 入口作为非持久后台页面运行，保留原生 browser/chrome 通信与存储。不是完整 Service Worker；依赖 importScripts、Worker 生命周期、clients 或 fetch 拦截的扩展可能不兼容。原安装包保持不变。"

    /// Changes the background host, not the browser.* implementation or permissions.
    static func documentManifest(_ data: Data) throws -> Data? {
        guard var manifest = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              (manifest["manifest_version"] as? Int) == 3,
              var background = manifest["background"] as? [String: Any],
              let worker = background["service_worker"] as? String else { return nil }
        guard safeRelativePath(worker), !worker.hasSuffix("/") else {
            throw RikuganError.message("扩展后台入口路径不安全。")
        }
        background.removeValue(forKey: "service_worker")
        background.removeValue(forKey: "page")
        background["scripts"] = [worker]
        background["persistent"] = false
        background["preferred_environment"] = ["document"]
        manifest["background"] = background
        return try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
    }

    static func safeRelativePath(_ name: String) -> Bool {
        let parts = name.split(separator: "/", omittingEmptySubsequences: false)
        return !name.isEmpty && !name.hasPrefix("/") && !name.contains("\\") && !name.contains("\0") && !name.contains(":")
            && !parts.contains("..") && !parts.contains(".")
            && !parts.dropLast().contains("")
    }

    static func prepare(source: URL, directory: Bool, destination: URL) throws -> (url: URL, mode: String?) {
        let manifest: Data?
        let archive: Data?
        if directory {
            archive = nil
            manifest = try Data(contentsOf: source.appendingPathComponent("manifest.json"))
        } else {
            let data = try Data(contentsOf: source)
            try ArchiveValidator.validate(data)
            archive = data
            manifest = ZipArchive.extract(data: data, path: "manifest.json")
        }
        guard let manifest else { throw RikuganError.message("无法读取安装包根目录中的 manifest.json。") }
        // Managed, developer-authorized builds may explicitly opt in to native workers.
        let nativeWorkerBuild = Bundle.main.object(forInfoDictionaryKey: "RikuganNativeServiceWorkers") as? Bool == true
        guard !nativeWorkerBuild, let adapted = try documentManifest(manifest) else {
            try FileManager.default.copyItem(at: source, to: destination)
            return (destination, nil)
        }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = destination.appendingPathComponent(directory ? "original" : "original.zip")
        let runtime = destination.appendingPathComponent("runtime", isDirectory: true)
        try FileManager.default.copyItem(at: source, to: original)
        if directory { try FileManager.default.copyItem(at: source, to: runtime) }
        else if let archive { try ZipArchive.unpack(archive, to: runtime) }
        try adapted.write(to: runtime.appendingPathComponent("manifest.json"), options: .atomic)
        return (runtime, "document")
    }
}
