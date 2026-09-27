import Foundation
import WebKit
import Combine

/// An installed userscript. Source, metadata, dependencies and per-script storage are separate.
struct InstalledUserScript: Codable, Identifiable, Hashable {
    var id: UUID
    var source: String
    var metadata: UserScriptMetadata
    var enabled: Bool
    var installedAt: Date
    var updatedAt: Date
    var sourceURL: String?
    /// Downloaded @require code keyed by URL.
    var requireCode: [String: String] = [:]
    /// Downloaded @resource payloads (base64) keyed by resource name.
    var resourceData: [String: StoredResource] = [:]
    var lastUpdateCheck: Date?
    var position: Int = 0

    struct StoredResource: Codable, Hashable {
        var mime: String
        var base64: String
    }

    var name: String { metadata.name }
    var updateURL: URL? { (metadata.updateURL ?? metadata.downloadURL ?? sourceURL).flatMap(URL.init(string:)) }
    var downloadURL: URL? { (metadata.downloadURL ?? sourceURL).flatMap(URL.init(string:)) }
}

struct BuiltUserScript {
    let source: String
    let time: WKUserScriptInjectionTime
    let mainFrameOnly: Bool
}

/// Persistence + source generation for userscripts (spec §9 ScriptStore / ScriptInjector / ResourceManager).
@MainActor final class UserScriptStore: ObservableObject {
    @Published private(set) var scripts: [InstalledUserScript] = []
    let directory: URL
    private let indexFile: JSONFile<[InstalledUserScript]>
    private var values: [UUID: [String: String]] = [:]
    private var tokens: [UUID: String] = [:]
    private(set) lazy var gm = GMBridge(store: self)
    /// Scripts whose main-frame injection ran per tab (for the manager / menu).
    private var sourceCache: [String: String] = [:]

    init(directory: URL) {
        self.directory = directory
        indexFile = JSONFile(directory.appendingPathComponent("scripts.json"))
        scripts = (indexFile.load() ?? []).sorted { $0.position < $1.position }
    }

    func script(_ id: UUID) -> InstalledUserScript? { scripts.first { $0.id == id } }

    /// Random per-launch token authenticating GM bridge calls from the page world.
    func token(for id: UUID) -> String {
        if let token = tokens[id] { return token }
        let token = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        tokens[id] = token
        return token
    }

    // MARK: Values (independent storage namespace per script – never page localStorage)

    private func valuesFile(_ id: UUID) -> URL { directory.appendingPathComponent("values-\(id.uuidString).json") }

    func values(for id: UUID) -> [String: String] {
        if let cached = values[id] { return cached }
        let loaded = JSONFile<[String: String]>(valuesFile(id)).load() ?? [:]
        values[id] = loaded
        return loaded
    }

    func setValue(_ value: String?, key: String, for id: UUID) {
        var current = values(for: id)
        current[key] = value
        values[id] = current
        JSONFile<[String: String]>(valuesFile(id)).save(current)
        // Injected sources embed a value snapshot; rebuild them on the next navigation.
        for tab in TabRegistry.shared.allTabs { tab.invalidateInjection() }
    }

    func replaceValues(_ newValues: [String: String], for id: UUID) {
        values[id] = newValues
        JSONFile<[String: String]>(valuesFile(id)).save(newValues)
    }

    // MARK: CRUD

    @discardableResult
    func install(source: String, sourceURL: String?, requires: [String: String], resources: [String: InstalledUserScript.StoredResource],
                 enabled: Bool = true) throws -> InstalledUserScript {
        let parsed = MetadataParser.parse(source)
        if let error = parsed.firstError { throw RikuganError(error) }
        let now = Date()
        if let index = existingIndex(for: parsed.metadata) {
            scripts[index].source = source
            scripts[index].metadata = parsed.metadata
            scripts[index].updatedAt = now
            scripts[index].requireCode = requires
            scripts[index].resourceData = resources
            if let sourceURL { scripts[index].sourceURL = sourceURL }
            save()
            return scripts[index]
        }
        let script = InstalledUserScript(id: UUID(), source: source, metadata: parsed.metadata, enabled: enabled, installedAt: now,
                                         updatedAt: now, sourceURL: sourceURL, requireCode: requires, resourceData: resources,
                                         position: (scripts.map(\.position).max() ?? 0) + 1)
        scripts.append(script)
        save()
        return script
    }

    /// Same name + namespace replaces the existing script (Tampermonkey semantics).
    func existingIndex(for metadata: UserScriptMetadata) -> Int? {
        scripts.firstIndex { $0.metadata.name == metadata.name && $0.metadata.namespace == metadata.namespace }
    }

    func updateSource(_ id: UUID, source: String) throws {
        let parsed = MetadataParser.parse(source)
        if let error = parsed.firstError { throw RikuganError(error) }
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].source = source
        scripts[index].metadata = parsed.metadata
        scripts[index].updatedAt = Date()
        save()
    }

    func setEnabled(_ id: UUID, _ enabled: Bool) {
        guard let index = scripts.firstIndex(where: { $0.id == id }) else { return }
        scripts[index].enabled = enabled
        save()
    }

    func update(_ script: InstalledUserScript) {
        guard let index = scripts.firstIndex(where: { $0.id == script.id }) else { return }
        scripts[index] = script
        save()
    }

    func delete(_ id: UUID) {
        scripts.removeAll { $0.id == id }
        values.removeValue(forKey: id)
        try? FileManager.default.removeItem(at: valuesFile(id))
        save()
    }

    func move(from source: IndexSet, to destination: Int) {
        scripts.move(fromOffsets: source, toOffset: destination)
        for i in scripts.indices { scripts[i].position = i }
        save()
    }

    private func save() {
        sourceCache.removeAll()
        indexFile.save(scripts)
        WebViewFactory.invalidateAllTabs()
    }

    // MARK: Injection source generation

    /// WKUserScripts for one script: an unwrapped-guard main-frame variant when the URL matches,
    /// plus a sub-frame variant (unless @noframes) that checks the URL in JS.
    func userScripts(for script: InstalledUserScript, mainFrameURL: URL, isPrivate: Bool) -> [BuiltUserScript] {
        var result: [BuiltUserScript] = []
        let meta = script.metadata
        let time: WKUserScriptInjectionTime = (meta.runAt == .documentStart || meta.runAt == .documentBody) ? .atDocumentStart : .atDocumentEnd
        if meta.matches(mainFrameURL) {
            result.append(BuiltUserScript(source: build(script, frameMode: "main", isPrivate: isPrivate), time: time, mainFrameOnly: true))
        }
        if !meta.noframes {
            result.append(BuiltUserScript(source: build(script, frameMode: "sub", isPrivate: isPrivate), time: time, mainFrameOnly: false))
        }
        return result
    }

    func build(_ script: InstalledUserScript, frameMode: String, isPrivate: Bool) -> String {
        let cacheKey = "\(script.id)-\(frameMode)-\(isPrivate)-\(script.updatedAt.timeIntervalSince1970)"
        let meta = script.metadata
        let rx: ([URLRule]) -> [[String]] = { rules in rules.map { [$0.regex, $0.caseInsensitive ? "i" : ""] } }
        var resources: [String: Any] = [:]
        for (name, res) in script.resourceData { resources[name] = ["mime": res.mime, "data": res.base64] }
        let metaDict: [String: Any] = [
            "name": meta.name, "namespace": meta.namespace, "version": meta.version, "description": meta.description,
            "author": meta.author, "matches": meta.matches, "includes": meta.includes, "excludes": meta.excludes,
            "resources": meta.resources.map { ["name": $0.name, "url": $0.url] }, "icon": meta.icon ?? "",
            "downloadURL": meta.downloadURL ?? "", "updateURL": meta.updateURL ?? "", "homepage": meta.homepage ?? "",
            "connects": meta.connects, "requires": meta.requires, "noframes": meta.noframes,
        ]
        let config: [String: Any] = [
            "id": script.id.uuidString, "token": token(for: script.id), "handler": Worlds.messageHandlerName,
            "name": meta.name, "grants": meta.grants, "values": values(for: script.id), "resources": resources,
            "runAt": meta.runAt.rawValue, "frameMode": frameMode,
            "include": rx(meta.includeRules()), "exclude": rx(meta.excludeRules()),
            "meta": metaDict, "metaStr": metadataBlock(script.source), "appVersion": AppServices.shared.appVersion,
            "world": meta.runsInPageWorld ? "page" : "content", "incognito": isPrivate,
        ]
        let prefix: String
        if let cached = sourceCache[cacheKey] { prefix = cached } else {
            let requires = meta.requires.compactMap { script.requireCode[$0] }.joined(separator: "\n;\n")
            prefix = requires
            sourceCache[cacheKey] = prefix
        }
        let body = prefix + (prefix.isEmpty ? "" : "\n;\n") + script.source + "\n//# sourceURL=userscript-\(meta.name.replacingOccurrences(of: " ", with: "_")).user.js"
        var runtime = JSResource.load("UserscriptRuntime")
        runtime = runtime.replacingOccurrences(of: "/*__RK_CONFIG__*/null", with: JSONText.encode(config))
        guard let range = runtime.range(of: "/*__RK_BODY__*/") else { return runtime }
        runtime.replaceSubrange(range, with: body)
        return runtime
    }

    func metadataBlock(_ source: String) -> String {
        guard let start = source.range(of: "==UserScript=="), let end = source.range(of: "==/UserScript==") , start.upperBound <= end.lowerBound else { return "" }
        return "// ==UserScript==" + source[start.upperBound..<end.lowerBound] + "==/UserScript=="
    }

    // MARK: Export / import

    var exported: [ExportedUserscript] {
        scripts.map { ExportedUserscript(source: $0.source, enabled: $0.enabled, values: values(for: $0.id)) }
    }

    func importScripts(_ list: [ExportedUserscript]) async {
        for item in list {
            do {
                let deps = try await UserscriptDependencies.fetch(for: MetadataParser.parse(item.source).metadata)
                let script = try install(source: item.source, sourceURL: nil, requires: deps.requires, resources: deps.resources, enabled: item.enabled)
                replaceValues(item.values, for: script.id)
            } catch {
                ToastCenter.shared.show("导入脚本失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle")
            }
        }
    }

    /// Bundled demo / self-test script installer.
    func installBundled(named name: String) throws -> InstalledUserScript {
        guard let url = Bundle.main.url(forResource: name, withExtension: "user.js", subdirectory: "SelfTest") ??
                Bundle.main.url(forResource: name, withExtension: "js", subdirectory: "SelfTest"),
              let source = try? String(contentsOf: url, encoding: .utf8) else { throw RikuganError("找不到内置脚本 \(name)") }
        return try install(source: source, sourceURL: nil, requires: [:], resources: [:])
    }
}

/// Downloads @require and @resource (ResourceManager).
enum UserscriptDependencies {
    struct Result { var requires: [String: String] = [:]; var resources: [String: InstalledUserScript.StoredResource] = [:] }

    static func fetch(for meta: UserScriptMetadata) async throws -> Result {
        var result = Result()
        guard meta.requires.count <= 30, meta.resources.count <= 30 else { throw RikuganError("@require / @resource 数量过多") }
        for url in meta.requires {
            guard let target = URL(string: url) else { continue }
            let (data, response) = try await URLSession.shared.data(from: target)
            guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
                throw RikuganError("下载 @require 失败：\(url)")
            }
            result.requires[url] = String(decoding: data, as: UTF8.self)
        }
        for resource in meta.resources {
            guard let target = URL(string: resource.url) else { continue }
            let (data, response) = try await URLSession.shared.data(from: target)
            guard data.count < 20_000_000 else { throw RikuganError("@resource 过大：\(resource.name)") }
            let mime = (response as? HTTPURLResponse)?.mimeType ?? MIME.type(forExtension: target.pathExtension)
            result.resources[resource.name] = .init(mime: mime, base64: data.base64EncodedString())
        }
        return result
    }
}
