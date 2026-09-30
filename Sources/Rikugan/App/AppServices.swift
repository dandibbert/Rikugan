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
        if url.isFileURL {
            pendingOpen.append(PendingOpen(kind: .importFile(url)))
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

    /// Picks up items left in the App Group container by the share extension.
    func consumeSharedPendingItems() {
        guard let defaults = UserDefaults(suiteName: "group.com.dandibbert.Rikugan"),
              let value = defaults.string(forKey: "pendingShare"), let url = URL(string: value) else { return }
        let date = defaults.double(forKey: "pendingShareDate")
        defaults.removeObject(forKey: "pendingShare")
        if Date().timeIntervalSince1970 - date < 120 { handleIncoming(url) }
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
