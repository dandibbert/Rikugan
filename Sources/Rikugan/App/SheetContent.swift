import SwiftUI
import UniformTypeIdentifiers

struct SheetContent: View {
    let item: BrowserSheet
    @Binding var importKind: BrowserView.ImportKind?
    @EnvironmentObject private var manager: TabManager

    var body: some View {
        content
            .fileImporter(isPresented: Binding(get: { importKind != nil }, set: { if !$0 { importKind = nil } }),
                          allowedContentTypes: ImportRouter.allowedTypes(importKind), allowsMultipleSelection: false) { result in
                let kind = importKind
                importKind = nil
                ImportRouter.handle(result, kind: kind, manager: manager)
            }
    }

    @ViewBuilder private var content: some View {
        switch item {
        case .settings: SettingsView(importKind: $importKind)
        case .extensions: NavigationStack { ExtensionManagerView(importKind: $importKind) }
        case .userscripts: NavigationStack { UserscriptManagerView(importKind: $importKind) }
        case .bookmarks: BookmarksAndHistoryView(initialTab: 0)
        case .history: BookmarksAndHistoryView(initialTab: 1)
        case .downloads: NavigationStack { DownloadsView() }
        case .adblock: NavigationStack { AdBlockSettingsView() }
        case .tabs: TabSwitcherView()
        case .media: if let tab = manager.activeTab { MediaSnifferView(tab: tab) }
        case .images: if let tab = manager.activeTab { ImageGalleryView(tab: tab) }
        case .reader: if let tab = manager.activeTab { ReaderView(tab: tab) }
        case .console: if let tab = manager.activeTab { WebInspectorView(tab: tab) }
        case .siteSettings: if let tab = manager.activeTab { NavigationStack { SiteSettingsDetailView(host: tab.host ?? "", tab: tab) } }
        case .qrScanner: QRScannerSheet()
        case .qrCode(let text): QRCodeSheet(text: text)
        case .pageTools: EmptyView()
        case .translate: EmptyView()
        case .profiles: NavigationStack { ProfilesView() }
        case .selfTest: SelfTestView()
        }
    }
}
