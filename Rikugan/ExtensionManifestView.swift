import SwiftUI

struct ExtensionManifestView: View {
    let record: ExtensionRecord
    @ObservedObject var session: BrowserSession
    @State private var original = false
    var body: some View {
        VStack {
            if record.backgroundMode == "document" {
                Picker("清单", selection: $original) {
                    Text("实际运行清单").tag(false)
                    Text("原始清单").tag(true)
                }.pickerStyle(.segmented).padding()
            }
            ScrollView([.horizontal, .vertical]) {
                Text(manifestText).font(.system(.caption, design: .monospaced)).textSelection(.enabled).padding()
            }
        }.navigationTitle("manifest.json")
    }
    private var manifestText: String {
        do {
            guard let model = session.model else { return "身份已关闭。" }
            var url = model.directory(session.profileID).appendingPathComponent(record.relativePath)
            if original && record.backgroundMode == "document" {
                let root = url.deletingLastPathComponent()
                let archive = root.appendingPathComponent("original.zip")
                url = FileManager.default.fileExists(atPath: archive.path) ? archive : root.appendingPathComponent("original")
            }
            let directory = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
            let data: Data
            if directory { data = try Data(contentsOf: url.appendingPathComponent("manifest.json")) }
            else {
                guard let extracted = ZipArchive.extract(data: try Data(contentsOf: url), path: "manifest.json") else { return "安装包缺少 manifest.json。" }
                data = extracted
            }
            let json = try JSONSerialization.jsonObject(with: data)
            return String(decoding: try JSONSerialization.data(withJSONObject: json, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self)
        } catch { return "读取清单失败：\(error.localizedDescription)" }
    }
}
