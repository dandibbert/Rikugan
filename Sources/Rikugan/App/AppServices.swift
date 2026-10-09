import Foundation
import SwiftUI
import WebKit
import Combine

/// App-wide services. Browsing state that belongs to a profile lives in `ProfileContext`.
@MainActor final class AppServices: ObservableObject {
    static let shared = AppServices()

    @Published var prefs: Preferences { didSet { if prefs != oldValue { prefsFile.save(prefs); prefsChanged(old: oldValue) } } }
    let profiles: ProfileManager
    let downloads = DownloadManager()
    let adBlock = AdBlockEngine()
    let fonts = FontManager()
    let autofill = AutofillStore()
    let translator = TranslationService()
    let toasts = ToastCenter.shared
    private let prefsFile = JSONFile<Preferences>(AppPaths.support.appendingPathComponent("preferences.json"))
    private var cancellables: Set<AnyCancellable> = []
    private(set) var started = false

    /// Pending URL requests from other apps (share extension, openURL) for the next focused window.
    @Published var pendingOpen: [PendingOpen] = []

    struct PendingOpen: Identifiable, Equatable {
        let id = UUID()
        enum Kind: Equatable { case url(URL), search(String), importFile(URL) }
        let kind: Kind
    }

    var profile: ProfileContext { profiles.active }

    private init() {
        let prefsURL = AppPaths.support.appendingPathComponent("preferences.json")
        // Earlier builds stored the translation API key in preferences.json: move it to the
        // Keychain once and rewrite the file without it.
        if let data = try? Data(contentsOf: prefsURL), var raw = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let legacyKey = raw.removeValue(forKey: Preferences.translationKeyAccount) as? String {
            if legacyKey.isEmpty || Secrets.set(legacyKey, for: Preferences.translationKeyAccount),
               let cleaned = try? JSONSerialization.data(withJSONObject: raw) {
                try? cleaned.write(to: prefsURL, options: .atomic)
            }
        }
        prefs = JSONFile<Preferences>(prefsURL).load() ?? Preferences()
        profiles = ProfileManager()
        profiles.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        adBlock.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &cancellables)
        NotificationCenter.default.publisher(for: .rikuganSiteSettingsChanged)
            .sink { note in
                let host = note.object as? String
                Task { @MainActor in
                    for tab in TabRegistry.shared.allTabs where host == nil || tab.host == host || tab.host?.hasSuffix("." + (host ?? "")) == true {
                        tab.invalidateInjection()
                        tab.applyLiveStyles()
                    }
                }
            }
            .store(in: &cancellables)
    }

    func start() {
        guard !started else { return }
        started = true
        profile.start()
        adBlock.start(prefs: prefs)
        fonts.reload()
        downloads.restore()
    }

    private func prefsChanged(old: Preferences) {
        if old.themeColor != prefs.themeColor { Theme.applyToWindows() }
        if old.adBlockEnabled != prefs.adBlockEnabled { adBlock.setEnabled(prefs.adBlockEnabled) }
        let affectsPages = old.pageDarkMode != prefs.pageDarkMode || old.webFontEnabled != prefs.webFontEnabled ||
            old.webFontFamily != prefs.webFontFamily || old.webFontKeepMonospace != prefs.webFontKeepMonospace ||
            old.webFontHeading != prefs.webFontHeading || old.webFontMono != prefs.webFontMono || old.webFontExcludedHosts != prefs.webFontExcludedHosts ||
            old.darkModeBrightness != prefs.darkModeBrightness || old.darkModeContrast != prefs.darkModeContrast
        if affectsPages {
            // Live-apply to loaded pages, and rebuild injected config on the next load / reload
            // (the config is baked into the document-start scripts).
            for tab in TabRegistry.shared.allTabs { tab.invalidateInjection(); tab.applyLiveStyles() }
        }
        if old.webInspectorEnabled != prefs.webInspectorEnabled {
            for tab in TabRegistry.shared.allTabs { tab.webView?.isInspectable = prefs.webInspectorEnabled }
        }
        if old.consoleCaptureEnabled != prefs.consoleCaptureEnabled || old.mediaSnifferEnabled != prefs.mediaSnifferEnabled ||
            old.geolocationShim != prefs.geolocationShim {
            NotificationCenter.default.post(name: .rikuganContentChanged, object: nil)
        }
    }

    // MARK: Incoming URLs

    /// Handles `rikugan://open?url=`, `rikugan://search?q=`, http(s) URLs and files opened with the app.
    func handleIncoming(_ url: URL) {
        // Share-extension items carry an ID and may arrive twice (URL scheme and App Group inbox):
        // each ID is handled once and removed from the inbox.
        if url.scheme == "rikugan", let shareID = URLComponents(url: url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "shareID" })?.value {
            guard handledShareIDs.insert(shareID).inserted else { return }
            removeFromShareInbox([shareID])
        }
        if url.isFileURL {
            pendingOpen.append(PendingOpen(kind: .importFile(Self.localCopy(of: url))))
            return
        }
        if url.scheme == "rikugan" {
            let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
            switch url.host {
            case "open":
                if let value = items.first(where: { $0.name == "url" })?.value, let target = URL(string: value) {
                    pendingOpen.append(PendingOpen(kind: .url(target)))
                }
            case "search":
                if let q = items.first(where: { $0.name == "q" })?.value { pendingOpen.append(PendingOpen(kind: .search(q))) }
            default:
                pendingOpen.append(PendingOpen(kind: .url(url)))
            }
            return
        }
        pendingOpen.append(PendingOpen(kind: .url(url)))
    }

    /// Files opened from other apps arrive in place (LSSupportsOpeningDocumentsInPlace, needed so
    /// the folder picker can grant a download folder): one outside the app's container is copied
    /// into a temporary folder while its security scope is open, so every importer and the web
    /// view get a plain local file, as with the old Inbox copies.
    static func localCopy(of url: URL) -> URL {
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        guard !url.standardizedFileURL.path.hasPrefix(home) else { return url }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Incoming/\(UUID().uuidString)", isDirectory: true)
        let target = folder.appendingPathComponent(url.lastPathComponent)
        var copyError: Error?
        var coordinationError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: .withoutChanges, error: &coordinationError) { source in
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: source, to: target)
            } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError {
            ErrorLog.shared.record("copy of opened file failed: \(error.localizedDescription)", source: "打开文件")
            return url
        }
        return target
    }

    static let appGroup = "group.com.dandibbert.Rikugan"
    private var handledShareIDs = Set<String>()

    /// Picks up items the share extension left in the App Group inbox, oldest first. Items stay
    /// until the app has handled them (no expiry: a share is not dropped because the app was
    /// opened late).
    func consumeSharedPendingItems() {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) != nil,
              let defaults = UserDefaults(suiteName: Self.appGroup) else { return }
        // Items from the single-slot format of earlier builds.
        if let legacy = defaults.string(forKey: "pendingShare") {
            defaults.removeObject(forKey: "pendingShare")
            if let url = URL(string: legacy) { handleIncoming(url) }
        }
        let inbox = defaults.array(forKey: "pendingShares") as? [[String: Any]] ?? []
        for entry in inbox {
            guard let raw = entry["url"] as? String, let url = URL(string: raw) else { continue }
            handleIncoming(url) // de-duplicates by shareID and removes the entry
        }
        // Entries without a usable URL / ID are dropped rather than retried forever.
        let remaining = (defaults.array(forKey: "pendingShares") as? [[String: Any]] ?? []).filter { entry in
            guard let id = entry["id"] as? String, let raw = entry["url"] as? String, URL(string: raw) != nil else { return false }
            return !handledShareIDs.contains(id)
        }
        defaults.set(remaining, forKey: "pendingShares")
    }

    private func removeFromShareInbox(_ ids: Set<String>) {
        guard FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: Self.appGroup) != nil,
              let defaults = UserDefaults(suiteName: Self.appGroup),
              let inbox = defaults.array(forKey: "pendingShares") as? [[String: Any]] else { return }
        defaults.set(inbox.filter { !ids.contains($0["id"] as? String ?? "") }, forKey: "pendingShares")
    }

    var appVersion: String {
        (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0") + " (" +
            (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1") + ")"
    }

    /// Status of the default-browser capability (spec §42). Never claims availability without the entitlement.
    var defaultBrowserStatus: String {
        if #available(iOS 18.2, *) {
            if let isDefault = try? UIApplication.shared.isDefault(.webBrowser) {
                return isDefault ? "Rikugan 已是默认浏览器" : "可在 设置 → App → 默认 App 中选择 Rikugan"
            }
        }
        return "此构建未包含 com.apple.developer.web-browser 权利，因此不会出现在系统默认浏览器列表中。需要 Apple 批准该权利并用对应描述文件签名后才可用。"
    }
}
