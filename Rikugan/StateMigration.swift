import Foundation

enum StateMigration {
    static func decode(_ data: Data) throws -> AppState {
        let decoder = JSONDecoder()
        if let state = try? decoder.decode(AppState.self, from: data), state.schema == 2, !state.profiles.isEmpty {
            return state
        }
        let legacy = try decoder.decode(LegacyAppState.self, from: data)
        guard legacy.schema == 1, !legacy.profiles.isEmpty else { throw RikuganError.message("不支持的资料格式") }
        return legacy.upgraded()
    }
}

private struct LegacyAppState: Decodable {
    var schema: Int
    var profiles: [LegacyProfile]
    var activeProfileID: UUID
    func upgraded() -> AppState {
        AppState(schema: 2, profiles: profiles.map { $0.upgraded() }, activeProfileID: activeProfileID)
    }
}

private struct LegacyProfile: Decodable {
    var id: UUID
    var name: String
    var symbol: String
    var tabs: [LegacyTab]
    var selectedTabID: UUID?
    var bookmarks: [LegacyPage]
    var history: [LegacyPage]
    var scripts: [LegacyScript]
    var extensions: [LegacyExtension]
    var searchEngine: String
    func upgraded() -> BrowserProfile {
        var profile = BrowserProfile(id: id, name: name, symbol: symbol, searchEngine: searchEngine)
        profile.tabs = tabs.map { SavedTab(id: $0.id, url: $0.url, title: $0.title, desktop: $0.desktop) }
        profile.selectedTabID = selectedTabID
        profile.bookmarks = bookmarks.map { PageRecord(id: $0.id, title: $0.title, url: $0.url, date: $0.date) }
        profile.history = history.map { PageRecord(id: $0.id, title: $0.title, url: $0.url, date: $0.date) }
        profile.scripts = scripts.map { $0.upgraded() }
        profile.extensions = extensions.map { $0.upgraded() }
        return profile
    }
}

private struct LegacyTab: Decodable { var id: UUID; var url: String; var title: String; var desktop: Bool }
private struct LegacyPage: Decodable { var id: UUID; var title: String; var url: String; var date: Date }
private struct LegacyExtension: Decodable {
    var id: UUID
    var name: String
    var version: String
    var detail: String
    var relativePath: String
    var enabled: Bool
    var allowedPermissions: [String]
    var allowedPatterns: [String]
    var requestedPatterns: [String]
    func upgraded() -> ExtensionRecord {
        ExtensionRecord(id: id, name: name, version: version, detail: detail, relativePath: relativePath, enabled: enabled,
                        allowedPermissions: allowedPermissions, allowedPatterns: allowedPatterns, requestedPatterns: requestedPatterns)
    }
}

private struct LegacyScript: Decodable {
    var id: UUID
    var name: String
    var version: String
    var description: String
    var source: String
    var matches: [String]
    var includes: [String]
    var excludes: [String]
    var excludeMatches: [String]
    var grants: [String]
    var connects: [String]
    var requires: [String]
    var dependencies: [String]
    var runAt: String
    var noFrames: Bool
    var enabled: Bool
    var storageJSON: String
    func upgraded() -> UserScript {
        UserScript(id: id, name: name, version: version, description: description, source: source, matches: matches, includes: includes,
                   excludes: excludes, excludeMatches: excludeMatches, grants: grants, connects: connects, requires: requires,
                   dependencies: dependencies, runAt: runAt, noFrames: noFrames, enabled: enabled, storageJSON: storageJSON)
    }
}
