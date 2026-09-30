import Foundation
import WebKit
import UIKit
import AVFoundation
import UIKit.UIGestureRecognizerSubclass

/// chrome.* namespaces backed by Rikugan's own data: identity (web auth flow), history, bookmarks,
/// topSites, sessions, search, tts, management, browsingData and idle, plus tabs.move / discard /
/// highlight. Dispatched from `ChromeAPIBridge.handleCall`; every entry is listed in
/// chrome-api-matrix.json and verified by scripts/test_js.cjs.
extension ChromeAPIBridge {
    /// Wraps a result so "handled, returned nil" differs from "not an API of this file".
    struct Handled { let value: Any? }

    func extraAPI(_ api: String, ext: LoadedExtension, list: [Any], caller: Caller) async throws -> Handled? {
        func arg(_ i: Int) -> Any? { i < list.count ? (list[i] is NSNull ? nil : list[i]) : nil }
        func dict(_ i: Int) -> [String: Any] { arg(i) as? [String: Any] ?? [:] }
        let profile = runtime.profile

        switch api {
        // ---- identity -----------------------------------------------------------------------------
        case "identity.launchWebAuthFlow":
            try requirePermission(ext, "identity")
            let details = dict(0)
            guard let raw = details["url"] as? String, let url = URL(string: raw),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw RikuganError("Authorization page could not be loaded.")
            }
            let result = try await AuthFlowSession.run(
                url: url, extID: ext.id, extName: ext.displayName, dataStore: profile.dataStore,
                interactive: details["interactive"] as? Bool ?? false,
                abortOnLoad: details["abortOnLoadForNonInteractive"] as? Bool ?? true,
                nonInteractiveTimeout: (details["timeoutMsForNonInteractive"] as? Double).map { $0 / 1000 } ?? 1)
            return Handled(value: result.absoluteString)

        // ---- history ------------------------------------------------------------------------------
        case "history.search":
            try requirePermission(ext, "history")
            let q = dict(0)
            let text = (q["text"] as? String ?? "").lowercased()
            let start = Self.date(q["startTime"]) ?? Date().addingTimeInterval(-86_400)
            let end = Self.date(q["endTime"]) ?? .distantFuture
            let max = q["maxResults"] as? Int ?? 100
            var seen = Set<String>()
            var items: [[String: Any]] = []
            for entry in profile.history.entries where entry.visitedAt >= start && entry.visitedAt < end {
                guard seen.insert(entry.url).inserted else { continue }
                if !text.isEmpty, !text.split(separator: " ").allSatisfy({ entry.url.lowercased().contains($0) || entry.title.lowercased().contains($0) }) { continue }
                items.append(historyItem(entry, in: profile.history))
                if max > 0, items.count >= max { break }
            }
            return Handled(value: items)
        case "history.getVisits":
            try requirePermission(ext, "history")
            let url = dict(0)["url"] as? String ?? ""
            return Handled(value: profile.history.entries.filter { $0.url == url }.map { entry -> [String: Any] in
                ["id": Self.stableID(entry.url), "visitId": Self.stableID(entry.id.uuidString), "visitTime": entry.visitedAt.timeIntervalSince1970 * 1000,
                 "referringVisitId": "0", "transition": "link", "isLocal": true]
            })
        case "history.addUrl":
            try requirePermission(ext, "history")
            guard let raw = dict(0)["url"] as? String, let url = URL(string: raw), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                throw RikuganError("Invalid URL.")
            }
            profile.history.record(url: url, title: dict(0)["title"] as? String ?? "")
            return Handled(value: nil)
        case "history.deleteUrl":
            try requirePermission(ext, "history")
            profile.history.delete(url: dict(0)["url"] as? String ?? "")
            return Handled(value: nil)
        case "history.deleteRange":
            try requirePermission(ext, "history")
            guard let start = Self.date(dict(0)["startTime"]), let end = Self.date(dict(0)["endTime"]) else { throw RikuganError("startTime and endTime are required") }
            profile.history.delete(from: start, to: end)
            return Handled(value: nil)
        case "history.deleteAll":
            try requirePermission(ext, "history")
            profile.history.clearAll()
            return Handled(value: nil)

        // ---- bookmarks ----------------------------------------------------------------------------
        case "bookmarks.getTree":
            try requirePermission(ext, "bookmarks")
            return Handled(value: [bookmarkRoot(profile.bookmarks, recursive: true)])
        case "bookmarks.getSubTree":
            try requirePermission(ext, "bookmarks")
            let id = arg(0) as? String ?? ""
            if id == "0" { return Handled(value: [bookmarkRoot(profile.bookmarks, recursive: true)]) }
            let node = try bookmark(id, in: profile.bookmarks)
            return Handled(value: [bookmarkJSON(node, store: profile.bookmarks, recursive: true)])
        case "bookmarks.get":
            try requirePermission(ext, "bookmarks")
            let ids = (arg(0) as? [String]) ?? (arg(0) as? String).map { [$0] } ?? []
            var nodes: [[String: Any]] = []
            for id in ids {
                if id == "0" { nodes.append(bookmarkRoot(profile.bookmarks, recursive: false)); continue }
                let node = try bookmark(id, in: profile.bookmarks)
                nodes.append(bookmarkJSON(node, store: profile.bookmarks, recursive: false))
            }
            return Handled(value: nodes)
        case "bookmarks.getChildren":
            try requirePermission(ext, "bookmarks")
            let parent = try bookmarkParent(arg(0) as? String ?? "", in: profile.bookmarks)
            return Handled(value: profile.bookmarks.children(of: parent).map { bookmarkJSON($0, store: profile.bookmarks, recursive: false) })
        case "bookmarks.getRecent":
            try requirePermission(ext, "bookmarks")
            let count = Swift.max(1, arg(0) as? Int ?? 10)
            let recent = profile.bookmarks.nodes.filter { !$0.isFolder }.sorted { $0.createdAt > $1.createdAt }.prefix(count)
            return Handled(value: recent.map { bookmarkJSON($0, store: profile.bookmarks, recursive: false) })
        case "bookmarks.search":
            try requirePermission(ext, "bookmarks")
            let query = arg(0) as? [String: Any]
            let words = ((arg(0) as? String) ?? query?["query"] as? String ?? "").lowercased().split(separator: " ")
            let url = query?["url"] as? String
            let title = query?["title"] as? String
            let matches = profile.bookmarks.nodes.filter { node in
                if node.isFolder && url != nil { return false }
                if let url, node.url != url { return false }
                if let title, node.title != title { return false }
                let haystack = (node.title + " " + (node.url ?? "")).lowercased()
                return words.allSatisfy { haystack.contains($0) }
            }
            return Handled(value: matches.map { bookmarkJSON($0, store: profile.bookmarks, recursive: false) })
        case "bookmarks.create":
            try requirePermission(ext, "bookmarks")
            let d = dict(0)
            let parent = try bookmarkParent(d["parentId"] as? String ?? "0", in: profile.bookmarks)
            let url = d["url"] as? String
            if let url, URL(string: url)?.scheme == nil { throw RikuganError("Invalid URL.") }
            let node = profile.bookmarks.add(title: d["title"] as? String ?? "", url: url, parent: parent, isFolder: url == nil)
            return Handled(value: bookmarkJSON(node, store: profile.bookmarks, recursive: false))
        case "bookmarks.update":
            try requirePermission(ext, "bookmarks")
            var node = try bookmark(arg(0) as? String ?? "", in: profile.bookmarks, modifying: true)
            let changes = dict(1)
            if let title = changes["title"] as? String { node.title = title }
            if let url = changes["url"] as? String, !node.isFolder {
                guard URL(string: url)?.scheme != nil else { throw RikuganError("Invalid URL.") }
                node.url = url
            }
            profile.bookmarks.update(node)
            return Handled(value: bookmarkJSON(node, store: profile.bookmarks, recursive: false))
        case "bookmarks.move":
            try requirePermission(ext, "bookmarks")
            let node = try bookmark(arg(0) as? String ?? "", in: profile.bookmarks, modifying: true)
            let destination = dict(1)
            let parent = try (destination["parentId"] as? String).map { try bookmarkParent($0, in: profile.bookmarks) } ?? node.parentID
            if parent != node.parentID {
                // A folder cannot move into itself or one of its descendants.
                var cursor = parent
                while let current = cursor {
                    if current == node.id { throw RikuganError("Can't move a folder into its own descendant.") }
                    cursor = profile.bookmarks.nodes.first { $0.id == current }?.parentID
                }
                profile.bookmarks.move(node, to: parent)
            }
            if let index = destination["index"] as? Int, let moved = profile.bookmarks.nodes.first(where: { $0.id == node.id }) {
                let from = profile.bookmarks.index(of: moved)
                let count = profile.bookmarks.children(of: parent).count
                let to = Swift.min(Swift.max(0, index), count)
                if to != from { profile.bookmarks.reorder(parent: parent, from: IndexSet(integer: from), to: to) }
            }
            let result = profile.bookmarks.nodes.first { $0.id == node.id } ?? node
            return Handled(value: bookmarkJSON(result, store: profile.bookmarks, recursive: false))
        case "bookmarks.remove", "bookmarks.removeTree":
            try requirePermission(ext, "bookmarks")
            let node = try bookmark(arg(0) as? String ?? "", in: profile.bookmarks, modifying: true)
            if api == "bookmarks.remove", node.isFolder, !profile.bookmarks.children(of: node.id).isEmpty {
                throw RikuganError("Can't remove non-empty folder (use recursive to remove a folder).")
            }
            profile.bookmarks.delete(node)
            return Handled(value: nil)

        // ---- topSites -----------------------------------------------------------------------------
        case "topSites.get":
            try requirePermission(ext, "topSites")
            return Handled(value: profile.history.frequentlyVisited(limit: 20).map { ["url": $0.url, "title": $0.title] })

        // ---- sessions -----------------------------------------------------------------------------
        case "sessions.getRecentlyClosed":
            try requirePermission(ext, "sessions")
            let max = Swift.min(25, Swift.max(1, dict(0)["maxResults"] as? Int ?? 25))
            let closed = TabRegistry.shared.allWindows.flatMap { window in window.recentlyClosed.map { (window, $0) } }
            return Handled(value: closed.prefix(max).map { pair in sessionJSON(pair.1, window: pair.0, ext: ext) })
        case "sessions.restore":
            try requirePermission(ext, "sessions")
            let wanted = arg(0) as? String
            let closed = TabRegistry.shared.allWindows.flatMap { window in window.recentlyClosed.map { (window, $0) } }
            let match: (TabManager, TabSnapshot)?
            if let wanted { match = closed.first { $0.1.id.uuidString == wanted } } else { match = closed.first }
            guard let match else {
                throw RikuganError(wanted == nil ? "There are no recently closed sessions." : "Invalid session id: \"\(wanted ?? "")\".")
            }
            let window = match.0
            window.reopen(match.1)
            guard let tab = window.activeTab else { return Handled(value: nil) }
            return Handled(value: ["lastModified": Int(Date().timeIntervalSince1970), "tab": tabJSON(tab, for: ext)])

        // ---- search -------------------------------------------------------------------------------
        case "search.query":
            try requirePermission(ext, "search")
            let q = dict(0)
            guard let text = q["text"] as? String, !text.trimmingCharacters(in: .whitespaces).isEmpty else { throw RikuganError("Missing query text.") }
            guard let url = AppServices.shared.prefs.searchEngine.searchURL(for: text) else { throw RikuganError("Search failed.") }
            let disposition = q["disposition"] as? String
            if let tabID = q["tabId"] as? Int {
                guard disposition == nil else { throw RikuganError("Cannot set both 'disposition' and 'tabId'.") }
                try tabFor(tabID, caller: caller).load(url)
            } else if disposition == "NEW_TAB" || disposition == "NEW_WINDOW" {
                guard let manager = TabRegistry.shared.focusedWindow else { throw RikuganError("No window") }
                manager.newTab(url: url, isPrivate: false)
            } else {
                try tabFor(nil, caller: caller).load(url)
            }
            return Handled(value: nil)

        // ---- tts ----------------------------------------------------------------------------------
        case "tts.speak":
            try requirePermission(ext, "tts")
            TTSController.shared.speak(arg(0) as? String ?? "", options: dict(1), callbackID: arg(2) as? String, ext: ext, runtime: runtime)
            return Handled(value: nil)
        case "tts.stop":
            TTSController.shared.stop(); return Handled(value: nil)
        case "tts.pause":
            TTSController.shared.pause(); return Handled(value: nil)
        case "tts.resume":
            TTSController.shared.resume(); return Handled(value: nil)
        case "tts.isSpeaking":
            return Handled(value: TTSController.shared.isSpeaking)
        case "tts.getVoices":
            try requirePermission(ext, "tts")
            return Handled(value: TTSController.voices())

        // ---- management ---------------------------------------------------------------------------
        case "management.getSelf":
            return Handled(value: managementInfo(ext.record))
        case "management.get":
            try requirePermission(ext, "management")
            let id = arg(0) as? String ?? ""
            guard let record = runtime.records.first(where: { $0.id == id }) else { throw RikuganError("Failed to find extension with id \(id).") }
            return Handled(value: managementInfo(record))
        case "management.getAll":
            try requirePermission(ext, "management")
            return Handled(value: runtime.records.map(managementInfo))
        case "management.getPermissionWarningsById":
            try requirePermission(ext, "management")
            let id = arg(0) as? String ?? ""
            guard let record = runtime.records.first(where: { $0.id == id }) else { throw RikuganError("Failed to find extension with id \(id).") }
            return Handled(value: PermissionDescriber.describe(apiPermissions: record.grantedPermissions, hostPatterns: record.grantedHosts).map(\.text))
        case "management.getPermissionWarningsByManifest":
            guard let data = (arg(0) as? String)?.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw RikuganError("Manifest file is invalid") }
            let perms = (json["permissions"] as? [String] ?? []).filter { !$0.contains("://") && $0 != "<all_urls>" }
            let hosts = (json["host_permissions"] as? [String] ?? []) + (json["permissions"] as? [String] ?? []).filter { $0.contains("://") || $0 == "<all_urls>" }
            return Handled(value: PermissionDescriber.describe(apiPermissions: perms, hostPatterns: hosts).map(\.text))
        case "management.setEnabled":
            try requirePermission(ext, "management")
            let id = arg(0) as? String ?? ""
            let enabled = arg(1) as? Bool ?? false
            guard id != ext.id else { throw RikuganError("Cannot change the enabled state of the calling extension.") }
            guard let record = runtime.records.first(where: { $0.id == id }) else { throw RikuganError("Failed to find extension with id \(id).") }
            if enabled, !record.enabled {
                let ok = await Presenter.confirm(title: "启用“\(record.name)”？", message: "“\(ext.displayName)”请求启用这个扩展。", confirm: "启用")
                guard ok else { throw RikuganError("The user did not accept the re-enable dialog.") }
            }
            if record.enabled != enabled { runtime.setEnabled(id, enabled) }
            return Handled(value: nil)
        case "management.uninstall", "management.uninstallSelf":
            let targetID = api == "management.uninstallSelf" ? ext.id : (arg(0) as? String ?? "")
            if api == "management.uninstall" { try requirePermission(ext, "management") }
            guard let record = runtime.records.first(where: { $0.id == targetID }) else { throw RikuganError("Failed to find extension with id \(targetID).") }
            let options = api == "management.uninstallSelf" ? dict(0) : dict(1)
            // Removing another extension always asks; self-removal asks when the caller requests it.
            if api == "management.uninstall" || options["showConfirmDialog"] as? Bool == true {
                let message = targetID == ext.id ? nil : "“\(ext.displayName)”请求移除这个扩展。"
                let ok = await Presenter.confirm(title: "移除“\(record.name)”？", message: message, confirm: "移除", destructive: true)
                guard ok else { throw RikuganError("User cancelled uninstall of extension \(targetID).") }
            }
            // Deferred so the reply reaches the caller before its own runtime is torn down.
            let runtime = runtime
            Task { @MainActor in runtime.remove(targetID) }
            return Handled(value: nil)

        // ---- browsingData -------------------------------------------------------------------------
        case "browsingData.remove":
            try requirePermission(ext, "browsingData")
            try await removeBrowsingData(options: dict(0), types: dict(1), profile: profile)
            return Handled(value: nil)
        case "browsingData.settings":
            try requirePermission(ext, "browsingData")
            var permitted: [String: Bool] = [:]
            for key in Self.browsingDataKeys { permitted[key] = Self.supportedBrowsingData.contains(key) }
            return Handled(value: ["options": ["since": 0, "originTypes": ["unprotectedWeb": true]],
                                   "dataToRemove": permitted.mapValues { _ in false }, "dataRemovalPermitted": permitted])

        // ---- idle ---------------------------------------------------------------------------------
        case "idle.queryState":
            try requirePermission(ext, "idle")
            IdleMonitor.shared.start(runtime: runtime)
            return Handled(value: IdleMonitor.shared.state(threshold: TimeInterval(Swift.max(15, arg(0) as? Int ?? 60))))
        case "idle.setDetectionInterval":
            try requirePermission(ext, "idle")
            IdleMonitor.shared.setInterval(TimeInterval(Swift.max(15, arg(0) as? Int ?? 60)), for: ext.id)
            IdleMonitor.shared.start(runtime: runtime)
            return Handled(value: nil)

        // ---- tabs (additional) --------------------------------------------------------------------
        case "tabs.move":
            let ids = (arg(0) as? [Int]) ?? (arg(0) as? Int).map { [$0] } ?? []
            let props = dict(1)
            guard var index = props["index"] as? Int else { throw RikuganError("moveProperties.index is required") }
            var moved: [[String: Any]] = []
            for id in ids {
                guard let tab = TabRegistry.shared.tab(id), !tab.isPrivate, let manager = tab.manager else { throw RikuganError("No tab with id: \(id).") }
                if let windowID = props["windowId"] as? Int, windowID != manager.numericID {
                    throw RikuganError("Tabs can only be moved within their window in Rikugan.")
                }
                let from = manager.tabs.filter { !$0.isPrivate }.firstIndex { $0.id == tab.id } ?? 0
                let to = manager.moveTab(tab, toIndex: index)
                if from != to { runtime.dispatchAll("tabs.onMoved") { _ in [tab.numericID, ["windowId": manager.numericID, "fromIndex": from, "toIndex": to]] } }
                moved.append(tabJSON(tab, for: ext))
                if index >= 0 { index = to + 1 }
            }
            return Handled(value: arg(0) is Int ? moved.first : moved)
        case "tabs.discard":
            let tab = try tabFor(arg(0) as? Int, caller: caller)
            guard tab.manager?.activeTabID != tab.id else { throw RikuganError("Cannot discard the active tab.") }
            if tab.webView != nil { await tab.suspend() }
            return Handled(value: tab.webView == nil ? tabJSON(tab, for: ext) : nil)
        case "tabs.highlight":
            let info = dict(0)
            let indices = (info["tabs"] as? [Int]) ?? (info["tabs"] as? Int).map { [$0] } ?? []
            guard let manager = (info["windowId"] as? Int).flatMap(TabRegistry.shared.window) ?? caller.tab?.manager ?? TabRegistry.shared.focusedWindow else {
                throw RikuganError("No window")
            }
            let tabs = manager.tabs.filter { !$0.isPrivate }
            guard let first = indices.first, tabs.indices.contains(first) else { throw RikuganError("No tab at index: \(indices.first ?? -1).") }
            manager.select(tabs[first])
            var window: [String: Any] = ["id": manager.numericID, "focused": TabRegistry.shared.focusedWindow === manager, "incognito": false,
                                         "type": "normal", "state": "normal", "alwaysOnTop": false]
            window["tabs"] = tabs.map { tabJSON($0, for: ext) }
            return Handled(value: window)

        // ---- downloads (additional) ---------------------------------------------------------------
        case "downloads.removeFile":
            try requirePermission(ext, "downloads")
            let id = arg(0) as? Int ?? -1
            guard let item = AppServices.shared.downloads.extensionVisibleItems.first(where: { $0.numericID == id }) else { throw RikuganError("Invalid download id \(id)") }
            guard item.chromeState == "complete", let file = item.fileURL else { throw RikuganError("Download must be complete") }
            try? FileManager.default.removeItem(at: file)
            runtime.dispatchAll("downloads.onChanged", permission: "downloads") { _ in [["id": id, "exists": ["previous": true, "current": false]]] }
            return Handled(value: nil)
        case "downloads.getFileIcon":
            try requirePermission(ext, "downloads")
            let id = arg(0) as? Int ?? -1
            guard let item = AppServices.shared.downloads.extensionVisibleItems.first(where: { $0.numericID == id }) else { throw RikuganError("Invalid download id \(id)") }
            let size = CGFloat(dict(1)["size"] as? Int ?? 32)
            return Handled(value: Self.symbolDataURL(DownloadRow.symbol(forFileName: item.fileName), size: size))

        default:
            return nil
        }
    }

    // MARK: history / bookmarks / sessions JSON

    /// Chrome IDs are opaque strings; derive stable ones from the URL (FNV-1a, 64 bit).
    static func stableID(_ text: String) -> String {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100_0000_01b3 }
        return String(hash % 1_000_000_000_000)
    }

    static func date(_ value: Any?) -> Date? {
        (value as? Double).map { Date(timeIntervalSince1970: $0 / 1000) }
    }

    func historyItem(_ entry: HistoryEntry, in store: HistoryStore) -> [String: Any] {
        let visits = store.entries.filter { $0.url == entry.url }
        return ["id": Self.stableID(entry.url), "url": entry.url, "title": entry.title,
                "lastVisitTime": entry.visitedAt.timeIntervalSince1970 * 1000,
                "visitCount": visits.map(\.visitCount).max() ?? entry.visitCount, "typedCount": 0]
    }

    private func bookmark(_ id: String, in store: BookmarkStore, modifying: Bool = false) throws -> BookmarkNode {
        if modifying, id == "0" || id == BookmarkNode.favoritesID.uuidString { throw RikuganError("Can't modify the root bookmark folders.") }
        guard let uuid = UUID(uuidString: id), let node = store.nodes.first(where: { $0.id == uuid }) else { throw RikuganError("Can't find bookmark for id.") }
        return node
    }

    private func bookmarkParent(_ id: String, in store: BookmarkStore) throws -> UUID? {
        if id == "0" { return nil }
        let node = try bookmark(id, in: store)
        guard node.isFolder else { throw RikuganError("Can't find parent bookmark for id.") }
        return node.id
    }

    func bookmarkJSON(_ node: BookmarkNode, store: BookmarkStore, recursive: Bool) -> [String: Any] {
        var json: [String: Any] = ["id": node.id.uuidString, "parentId": node.parentID?.uuidString ?? "0", "index": store.index(of: node),
                                   "title": node.title, "dateAdded": node.createdAt.timeIntervalSince1970 * 1000, "syncing": false]
        if node.isFolder {
            if recursive { json["children"] = store.children(of: node.id).map { bookmarkJSON($0, store: store, recursive: true) } }
            if node.id == BookmarkNode.favoritesID { json["folderType"] = "bookmarks-bar" }
        } else {
            json["url"] = node.url ?? ""
        }
        return json
    }

    private func bookmarkRoot(_ store: BookmarkStore, recursive: Bool) -> [String: Any] {
        var json: [String: Any] = ["id": "0", "title": "", "dateAdded": 0, "syncing": false]
        if recursive { json["children"] = store.children(of: nil).map { bookmarkJSON($0, store: store, recursive: true) } }
        return json
    }

    private func sessionJSON(_ snapshot: TabSnapshot, window: TabManager, ext: LoadedExtension) -> [String: Any] {
        var tab: [String: Any] = ["sessionId": snapshot.id.uuidString, "index": 0, "windowId": window.numericID, "active": false,
                                  "highlighted": false, "selected": false, "pinned": snapshot.pinned, "incognito": false,
                                  "discarded": true, "autoDiscardable": true, "groupId": -1, "frozen": false]
        if ext.has("tabs") { tab["url"] = snapshot.url; tab["title"] = snapshot.title }
        return ["lastModified": Int(snapshot.lastActiveAt.timeIntervalSince1970), "tab": tab]
    }

    func managementInfo(_ record: InstalledExtension) -> [String: Any] {
        let loadedExt = runtime.loaded[record.id]
        var json: [String: Any] = ["id": record.id, "name": loadedExt?.displayName ?? record.name, "shortName": loadedExt?.manifest.shortName ?? record.name,
                                   "description": record.description, "version": record.version, "enabled": record.enabled,
                                   "mayDisable": true, "mayEnable": true, "isApp": false, "type": "extension", "offlineEnabled": false,
                                   "installType": "normal", "permissions": record.grantedPermissions, "hostPermissions": record.grantedHosts,
                                   "homepageUrl": record.storeURL ?? ""]
        if let options = loadedExt?.manifest.optionsPage, let loadedExt { json["optionsUrl"] = loadedExt.baseURL + options }
        else { json["optionsUrl"] = "" }
        if !record.enabled { json["disabledReason"] = "unknown" }
        return json
    }

    static func symbolDataURL(_ symbol: String, size: CGFloat) -> String {
        let config = UIImage.SymbolConfiguration(pointSize: size * 0.8)
        let image = UIImage(systemName: symbol, withConfiguration: config) ?? UIImage(systemName: "doc", withConfiguration: config)
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: size, height: size))
        let png = renderer.pngData { _ in
            guard let image else { return }
            let tinted = image.withTintColor(.systemBlue, renderingMode: .alwaysOriginal)
            tinted.draw(in: CGRect(x: (size - tinted.size.width) / 2, y: (size - tinted.size.height) / 2, width: tinted.size.width, height: tinted.size.height))
        }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    // MARK: browsingData

    static let browsingDataKeys = ["appcache", "cache", "cacheStorage", "cookies", "downloads", "fileSystems", "formData", "history",
                                   "indexedDB", "localStorage", "passwords", "serviceWorkers", "webSQL"]
    /// formData / passwords are never touched by extensions in Rikugan.
    static let supportedBrowsingData: Set<String> = ["appcache", "cache", "cacheStorage", "cookies", "downloads", "fileSystems", "history",
                                                     "indexedDB", "localStorage", "serviceWorkers", "webSQL"]

    private func removeBrowsingData(options: [String: Any], types: [String: Any], profile: ProfileContext) async throws {
        let requested = Set(types.filter { $0.value as? Bool == true }.map(\.key))
        if requested.contains("passwords") || requested.contains("formData") {
            throw RikuganError("Unsupported API: removing passwords / formData is not available to extensions in Rikugan")
        }
        let since = Self.date(options["since"]) ?? .distantPast
        var webTypes: Set<String> = []
        for key in requested {
            switch key {
            case "appcache": webTypes.insert(WKWebsiteDataTypeOfflineWebApplicationCache)
            case "cache": webTypes.formUnion([WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache])
            case "cacheStorage": webTypes.insert(WKWebsiteDataTypeFetchCache)
            case "cookies": webTypes.insert(WKWebsiteDataTypeCookies)
            case "fileSystems": webTypes.insert(WKWebsiteDataTypeFileSystem)
            case "indexedDB": webTypes.insert(WKWebsiteDataTypeIndexedDBDatabases)
            case "localStorage": webTypes.formUnion([WKWebsiteDataTypeLocalStorage, WKWebsiteDataTypeSessionStorage])
            case "serviceWorkers": webTypes.insert(WKWebsiteDataTypeServiceWorkerRegistrations)
            case "webSQL": webTypes.insert(WKWebsiteDataTypeWebSQLDatabases)
            default: break
            }
        }
        let origins = (options["origins"] as? [String] ?? []).compactMap { URL(string: $0)?.host?.lowercased() }
        let excluded = (options["excludeOrigins"] as? [String] ?? []).compactMap { URL(string: $0)?.host?.lowercased() }
        if !webTypes.isEmpty {
            let store = profile.dataStore
            if origins.isEmpty && excluded.isEmpty {
                await store.removeData(ofTypes: webTypes, modifiedSince: since)
            } else {
                // Record-level removal (WebKit groups records by registrable domain; `since` does not apply).
                func covers(_ record: WKWebsiteDataRecord, _ hosts: [String]) -> Bool {
                    let name = record.displayName.lowercased()
                    return hosts.contains { $0 == name || $0.hasSuffix("." + name) }
                }
                let records = await store.dataRecords(ofTypes: webTypes).filter { record in
                    origins.isEmpty ? !covers(record, excluded) : covers(record, origins) && !covers(record, excluded)
                }
                if !records.isEmpty { await store.removeData(ofTypes: webTypes, for: records) }
            }
        }
        if requested.contains("history") {
            if origins.isEmpty && excluded.isEmpty {
                profile.history.delete(from: since, to: .distantFuture)
            } else {
                for entry in profile.history.entries where entry.visitedAt >= since {
                    let host = URL(string: entry.url)?.host?.lowercased() ?? ""
                    let inOrigins = origins.isEmpty || origins.contains(host)
                    if inOrigins, !excluded.contains(host) { profile.history.delete(entry) }
                }
            }
        }
        if requested.contains("downloads") {
            let manager = AppServices.shared.downloads
            for item in manager.extensionVisibleItems where item.chromeState != "in_progress" && item.startDate >= since {
                manager.remove(item, deleteFile: false)
            }
        }
    }
}

// MARK: - Runtime event hooks

extension ExtensionRuntime {
    func historyVisited(_ entry: HistoryEntry) {
        guard !loaded.isEmpty else { return }
        dispatchAll("history.onVisited", permission: "history") { _ in [self.bridge.historyItem(entry, in: self.profile.history)] }
    }

    func historyRemoved(all: Bool, urls: [String]) {
        guard !loaded.isEmpty else { return }
        dispatchAll("history.onVisitRemoved", permission: "history") { _ in [["allHistory": all, "urls": urls]] }
    }

    func bookmarkChanged(_ change: BookmarkStore.Change) {
        guard !loaded.isEmpty else { return }
        let store = profile.bookmarks
        switch change {
        case .created(let node):
            dispatchAll("bookmarks.onCreated", permission: "bookmarks") { _ in [node.id.uuidString, self.bridge.bookmarkJSON(node, store: store, recursive: false)] }
        case .changed(let node):
            var info: [String: Any] = ["title": node.title]
            if let url = node.url { info["url"] = url }
            dispatchAll("bookmarks.onChanged", permission: "bookmarks") { _ in [node.id.uuidString, info] }
        case .moved(let node, let oldParent, let oldIndex):
            let info: [String: Any] = ["parentId": node.parentID?.uuidString ?? "0", "index": store.index(of: node),
                                       "oldParentId": oldParent?.uuidString ?? "0", "oldIndex": oldIndex]
            dispatchAll("bookmarks.onMoved", permission: "bookmarks") { _ in [node.id.uuidString, info] }
        case .removed(let node, let index):
            let info: [String: Any] = ["parentId": node.parentID?.uuidString ?? "0", "index": index,
                                       "node": self.bridge.bookmarkJSON(node, store: store, recursive: false)]
            dispatchAll("bookmarks.onRemoved", permission: "bookmarks") { _ in [node.id.uuidString, info] }
        }
    }

    func sessionsChanged() {
        guard !loaded.isEmpty else { return }
        dispatchAll("sessions.onChanged", permission: "sessions") { _ in [] }
    }

    func downloadCreated(_ item: DownloadItem) {
        guard !loaded.isEmpty else { return }
        dispatchAll("downloads.onCreated", permission: "downloads") { _ in [item.chromeJSON] }
    }

    func downloadErased(_ id: Int) {
        guard !loaded.isEmpty else { return }
        dispatchAll("downloads.onErased", permission: "downloads") { _ in [id] }
    }

    /// management.onInstalled / onUninstalled / onEnabled / onDisabled for the *other* extensions.
    func managementEvent(_ event: String, _ record: InstalledExtension?, id: String) {
        guard !loaded.isEmpty else { return }
        dispatchAll("management.\(event)", permission: "management") { ext in
            guard ext.id != id else { return nil }
            if event == "onUninstalled" { return [id] }
            return [record.map(self.bridge.managementInfo) ?? ["id": id]]
        }
    }

    /// Starts forwarding cookie-store changes once an extension listens to cookies.onChanged.
    func observeCookiesIfNeeded() {
        guard cookieObserver == nil else { return }
        let observer = CookieChangeObserver(runtime: self)
        cookieObserver = observer
        profile.dataStore.httpCookieStore.add(observer)
        observer.prime()
    }
}

// MARK: - identity.launchWebAuthFlow

/// Loads an OAuth / OpenID authorization page and returns the URL it finally redirects to on
/// `https://<extension id>.chromiumapp.org/`, like Chrome. Interactive flows are shown in a sheet
/// with the current site in the navigation bar; the user can cancel at any time.
@MainActor final class AuthFlowSession: NSObject, WKNavigationDelegate, WKUIDelegate {
    private static var active: [AuthFlowSession] = []
    private let redirectHost: String
    private let webView: WKWebView
    private let interactive: Bool
    private let abortOnLoad: Bool
    private let nonInteractiveTimeout: TimeInterval
    private var continuation: CheckedContinuation<URL, Error>?
    private var controller: UIViewController?
    private var timeout: Task<Void, Never>?
    private var committed = false

    static func redirectHost(for extID: String) -> String { "\(extID).chromiumapp.org" }

    static func run(url: URL, extID: String, extName: String, dataStore: WKWebsiteDataStore, interactive: Bool,
                    abortOnLoad: Bool, nonInteractiveTimeout: TimeInterval) async throws -> URL {
        let session = AuthFlowSession(extID: extID, dataStore: dataStore, interactive: interactive,
                                      abortOnLoad: abortOnLoad, nonInteractiveTimeout: nonInteractiveTimeout)
        active.append(session)
        defer { active.removeAll { $0 === session } }
        return try await withCheckedThrowingContinuation { continuation in
            session.continuation = continuation
            session.start(url: url, title: extName)
        }
    }

    private init(extID: String, dataStore: WKWebsiteDataStore, interactive: Bool, abortOnLoad: Bool, nonInteractiveTimeout: TimeInterval) {
        redirectHost = Self.redirectHost(for: extID)
        self.interactive = interactive
        self.abortOnLoad = abortOnLoad
        self.nonInteractiveTimeout = max(0.2, nonInteractiveTimeout)
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = dataStore
        configuration.applicationNameForUserAgent = WebViewFactory.safariUserAgentSuffix
        webView = WKWebView(frame: .zero, configuration: configuration)
        super.init()
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    private func start(url: URL, title: String) {
        if interactive {
            let content = AuthFlowController(webView: webView, extName: title) { [weak self] in
                self?.finish(.failure(RikuganError("The user did not approve access.")))
            }
            let navigation = UINavigationController(rootViewController: content)
            navigation.presentationController?.delegate = content
            controller = navigation
            Presenter.present(navigation)
        } else {
            // Hard cap for silent flows that never finish loading.
            arm(after: 30, "User interaction required.")
        }
        webView.load(URLRequest(url: url))
    }

    private func isRedirect(_ url: URL?) -> Bool {
        guard let url, url.scheme?.lowercased() == "https" else { return false }
        return url.host?.lowercased() == redirectHost
    }

    /// Silent-flow deadline (Chrome fails non-interactive flows that need the user).
    private func arm(after seconds: TimeInterval, _ message: String) {
        timeout?.cancel()
        timeout = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.finish(.failure(RikuganError(message)))
        }
    }

    private func finish(_ result: Result<URL, Error>) {
        guard let continuation else { return }
        self.continuation = nil
        timeout?.cancel()
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        controller?.dismiss(animated: true)
        controller = nil
        continuation.resume(with: result)
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if isRedirect(navigationAction.request.url), let url = navigationAction.request.url {
            decisionHandler(.cancel)
            finish(.success(url))
            return
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didReceiveServerRedirectForProvisionalNavigation navigation: WKNavigation!) {
        if isRedirect(webView.url), let url = webView.url { finish(.success(url)) }
    }

    func webView(_ webView: WKWebView, didCommit navigation: WKNavigation!) { committed = true }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !interactive else { return }
        // The page needs the user (a login form): a silent flow fails like Chrome's.
        arm(after: abortOnLoad ? 0.3 : nonInteractiveTimeout, "User interaction required.")
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        let failing = (error as NSError).userInfo[NSURLErrorFailingURLErrorKey] as? URL
        if isRedirect(failing), let failing { finish(.success(failing)); return }
        if (error as NSError).code == NSURLErrorCancelled { return }
        if !committed || !interactive { finish(.failure(RikuganError("Authorization page could not be loaded."))) }
    }

    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration, for navigationAction: WKNavigationAction,
                 windowFeatures: WKWindowFeatures) -> WKWebView? {
        // Popups opened by the login page load in the same sheet.
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }
}

private final class AuthFlowController: UIViewController, UIAdaptivePresentationControllerDelegate {
    private let webView: WKWebView
    private let extName: String
    private let onCancel: () -> Void
    private var observation: NSKeyValueObservation?

    init(webView: WKWebView, extName: String, onCancel: @escaping () -> Void) {
        self.webView = webView
        self.extName = extName
        self.onCancel = onCancel
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func loadView() { view = webView }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "登录 · \(extName)"
        navigationItem.leftBarButtonItem = UIBarButtonItem(systemItem: .cancel, primaryAction: UIAction { [weak self] _ in self?.onCancel() })
        // Always show which site the user is signing in to.
        observation = webView.observe(\.url, options: [.initial, .new]) { [weak self] webView, _ in
            MainActor.assumeIsolated { self?.navigationItem.prompt = webView.url?.host }
        }
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) { onCancel() }
}

// MARK: - tts

@MainActor final class TTSController: NSObject, AVSpeechSynthesizerDelegate {
    static let shared = TTSController()
    private let synthesizer = AVSpeechSynthesizer()
    private struct Owner { let extID: String; let callbackID: String?; weak var runtime: ExtensionRuntime? }
    private var owners: [ObjectIdentifier: Owner] = [:]

    override private init() {
        super.init()
        synthesizer.delegate = self
    }

    var isSpeaking: Bool { synthesizer.isSpeaking }

    static func voices() -> [[String: Any]] {
        AVSpeechSynthesisVoice.speechVoices().map {
            ["voiceName": $0.name, "lang": $0.language, "remote": false, "extensionId": "",
             "eventTypes": ["start", "end", "word", "interrupted", "cancelled", "pause", "resume"]]
        }
    }

    func speak(_ text: String, options: [String: Any], callbackID: String?, ext: LoadedExtension, runtime: ExtensionRuntime) {
        if options["enqueue"] as? Bool != true, synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
        let utterance = AVSpeechUtterance(string: String(text.prefix(32_768)))
        if let name = options["voiceName"] as? String, let voice = AVSpeechSynthesisVoice.speechVoices().first(where: { $0.name == name }) {
            utterance.voice = voice
        } else if let lang = options["lang"] as? String {
            utterance.voice = AVSpeechSynthesisVoice(language: lang)
        }
        // Chrome: rate 1.0 = normal (0.1…10), pitch 1.0 = normal (0…2), volume 0…1.
        if let rate = options["rate"] as? Double {
            utterance.rate = Float(min(max(Double(AVSpeechUtteranceDefaultSpeechRate) * rate, Double(AVSpeechUtteranceMinimumSpeechRate)),
                                       Double(AVSpeechUtteranceMaximumSpeechRate)))
        }
        if let pitch = options["pitch"] as? Double { utterance.pitchMultiplier = Float(min(max(pitch, 0.5), 2)) }
        if let volume = options["volume"] as? Double { utterance.volume = Float(min(max(volume, 0), 1)) }
        owners[ObjectIdentifier(utterance)] = Owner(extID: ext.id, callbackID: callbackID, runtime: runtime)
        synthesizer.speak(utterance)
    }

    func stop() { synthesizer.stopSpeaking(at: .immediate) }
    func pause() { synthesizer.pauseSpeaking(at: .immediate) }
    func resume() { synthesizer.continueSpeaking() }

    private func emit(_ key: ObjectIdentifier, _ event: [String: Any], final: Bool) {
        guard let owner = owners[key] else { return }
        if final { owners[key] = nil }
        guard let callbackID = owner.callbackID, let runtime = owner.runtime, let ext = runtime.loaded[owner.extID] else { return }
        runtime.dispatch(ext, "tts._event", [callbackID, event])
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.emit(key, ["type": "start", "charIndex": 0], final: false) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        let length = (utterance.speechString as NSString).length
        Task { @MainActor in self.emit(key, ["type": "end", "charIndex": length], final: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.emit(key, ["type": "interrupted"], final: true) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didPause utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.emit(key, ["type": "pause"], final: false) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didContinue utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        Task { @MainActor in self.emit(key, ["type": "resume"], final: false) }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, willSpeakRangeOfSpeechString characterRange: NSRange, utterance: AVSpeechUtterance) {
        let key = ObjectIdentifier(utterance)
        let location = characterRange.location, length = characterRange.length
        Task { @MainActor in self.emit(key, ["type": "word", "charIndex": location, "length": length], final: false) }
    }
}

// MARK: - idle

/// chrome.idle for Rikugan: "locked" while the device is locked (protected data unavailable),
/// "idle" when there was no touch in Rikugan for the detection interval, otherwise "active".
@MainActor final class IdleMonitor {
    static let shared = IdleMonitor()
    private var lastInput = Date()
    private var locked = false
    private var intervals: [String: TimeInterval] = [:]
    private var lastStates: [String: String] = [:]
    private var timer: Timer?
    private weak var runtime: ExtensionRuntime?
    private var trackedWindows: [ObjectIdentifier: WeakBox<UIWindow>] = [:]

    func setInterval(_ seconds: TimeInterval, for extID: String) { intervals[extID] = seconds }

    func state(threshold: TimeInterval) -> String {
        if locked || UIApplication.shared.isProtectedDataAvailable == false { return "locked" }
        return Date().timeIntervalSince(lastInput) >= threshold ? "idle" : "active"
    }

    func noteInput() { lastInput = Date() }

    func start(runtime: ExtensionRuntime) {
        self.runtime = runtime
        attachTracker()
        guard timer == nil else { return }
        let center = NotificationCenter.default
        center.addObserver(forName: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { IdleMonitor.shared.locked = true; IdleMonitor.shared.tick() }
        }
        center.addObserver(forName: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { IdleMonitor.shared.locked = false; IdleMonitor.shared.noteInput(); IdleMonitor.shared.tick() }
        }
        center.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { IdleMonitor.shared.attachTracker(); IdleMonitor.shared.noteInput(); IdleMonitor.shared.tick() }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            MainActor.assumeIsolated { IdleMonitor.shared.tick() }
        }
    }

    private func attachTracker() {
        for scene in UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }) {
            for window in scene.windows where trackedWindows[ObjectIdentifier(window)]?.value == nil {
                window.addGestureRecognizer(InputTracker.make())
                trackedWindows[ObjectIdentifier(window)] = WeakBox(window)
            }
        }
    }

    private func tick() {
        guard let runtime else { return }
        for ext in runtime.enabledExtensions where ext.has("idle") {
            let current = state(threshold: intervals[ext.id] ?? 60)
            guard lastStates[ext.id] != current else { continue }
            let first = lastStates[ext.id] == nil
            lastStates[ext.id] = current
            if !first { runtime.dispatch(ext, "idle.onStateChanged", [current]) }
        }
    }
}

/// Observes touches anywhere in the window without taking part in gesture handling.
private final class InputTracker: UIGestureRecognizer, UIGestureRecognizerDelegate {
    static func make() -> InputTracker {
        let tracker = InputTracker(target: nil, action: nil)
        tracker.cancelsTouchesInView = false
        tracker.delaysTouchesBegan = false
        tracker.delaysTouchesEnded = false
        tracker.delegate = tracker
        return tracker
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        IdleMonitor.shared.noteInput()
        state = .failed
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}

// MARK: - cookies.onChanged

/// Diffs the cookie store on every WebKit change notification and reports additions / removals
/// to extensions with the cookies permission and host access to the cookie's domain.
@MainActor final class CookieChangeObserver: NSObject, WKHTTPCookieStoreObserver {
    private weak var runtime: ExtensionRuntime?
    private var known: [String: HTTPCookie] = [:]
    private var primed = false

    init(runtime: ExtensionRuntime) { self.runtime = runtime }

    private static func key(_ c: HTTPCookie) -> String { "\(c.name)|\(c.domain)|\(c.path)" }

    func prime() {
        runtime?.profile.dataStore.httpCookieStore.getAllCookies { cookies in
            MainActor.assumeIsolated {
                self.known = Dictionary(cookies.map { (Self.key($0), $0) }, uniquingKeysWith: { a, _ in a })
                self.primed = true
            }
        }
    }

    nonisolated func cookiesDidChange(in cookieStore: WKHTTPCookieStore) {
        Task { @MainActor in self.refresh() }
    }

    private func refresh() {
        guard primed, let runtime else { return }
        runtime.profile.dataStore.httpCookieStore.getAllCookies { cookies in
            MainActor.assumeIsolated { self.apply(cookies, runtime: runtime) }
        }
    }

    private func apply(_ cookies: [HTTPCookie], runtime: ExtensionRuntime) {
        let current = Dictionary(cookies.map { (Self.key($0), $0) }, uniquingKeysWith: { a, _ in a })
        var changes: [(HTTPCookie, removed: Bool, cause: String)] = []
        for (key, old) in known where current[key] == nil {
            let expired = old.expiresDate.map { $0 < Date() } ?? false
            changes.append((old, true, expired ? "expired" : "explicit"))
        }
        for (key, cookie) in current {
            if let old = known[key] {
                guard old.value != cookie.value || old.expiresDate != cookie.expiresDate else { continue }
                changes.append((old, true, "overwrite"))
            }
            changes.append((cookie, false, "explicit"))
        }
        known = current
        guard !changes.isEmpty else { return }
        for ext in runtime.enabledExtensions where ext.has("cookies") {
            for change in changes {
                let host = change.0.domain.hasPrefix(".") ? String(change.0.domain.dropFirst()) : change.0.domain
                guard ext.hostAllowed(URL(string: "https://\(host)/")) else { continue }
                runtime.dispatch(ext, "cookies.onChanged", [["removed": change.removed, "cause": change.cause, "cookie": runtime.bridge.cookieJSON(change.0)]])
            }
        }
    }
}
