import SwiftUI
import PhotosUI

struct SettingsView: View {
    private var showDiagnostics: Bool {
        #if DEBUG
        return true
        #else
        return AppServices.shared.prefs.showDiagnostics
        #endif
    }
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var manager: TabManager
    @EnvironmentObject private var profile: ProfileContext
    @Binding var importKind: BrowserView.ImportKind?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    NavigationLink { ProfilesView() } label: {
                        Label("身份：\(profile.info.name)", icon: profile.info.symbol)
                    }
                }
                Section("浏览") {
                    NavigationLink { SearchSettingsView() } label: { Label("搜索引擎：\(services.prefs.searchEngine.name)", icon: "magnifyingglass") }
                    NavigationLink { AppearanceSettingsView() } label: { Label("外观与工具栏", icon: "paintbrush") }
                    NavigationLink { HomepageSettingsView() } label: { Label("起始页与壁纸", icon: "house") }
                    NavigationLink { WebFontSettingsView(importKind: $importKind) } label: { Label("网页字体", icon: "textformat") }
                    NavigationLink { DarkModeSettingsView() } label: { Label("网页深色模式", icon: "moon") }
                    NavigationLink { TranslationSettingsView() } label: { Label("网页翻译", icon: "character.bubble") }
                    NavigationLink { NavigationControlSettingsView() } label: { Label("页面跳转控制", icon: "arrow.triangle.branch") }
                }
                Section("内容") {
                    NavigationLink { UserscriptManagerView(importKind: $importKind) } label: { Label("用户脚本", icon: "curlybraces") }
                    NavigationLink { ExtensionManagerView(importKind: $importKind) } label: { Label("扩展", icon: "puzzlepiece.extension") }
                    NavigationLink { AdBlockSettingsView() } label: { Label("内容拦截", icon: "shield.lefthalf.filled") }
                    NavigationLink { SiteSettingsListView() } label: { Label("网站设置", icon: "slider.horizontal.3") }
                    NavigationLink { MediaSettingsView() } label: { Label("媒体与下载", icon: "play.rectangle") }
                }
                Section("隐私与数据") {
                    NavigationLink { AutofillSettingsView() } label: { Label("密码与自动填充", icon: "key") }
                    NavigationLink { PrivacySettingsView() } label: { Label("清除浏览数据", icon: "trash") }
                    NavigationLink { ImportExportView(importKind: $importKind) } label: { Label("导入与导出", icon: "arrow.up.arrow.down.square") }
                }
                Section("高级") {
                    NavigationLink { DeveloperSettingsView() } label: { Label("开发者与网页检查器", icon: "hammer") }
                    NavigationLink { CompatibilityView() } label: { Label("兼容性矩阵", icon: "checklist") }
                    if showDiagnostics {
                        NavigationLink { DiagnosticsView() } label: { Label("诊断", icon: "waveform.path.ecg") }
                    }
                    NavigationLink { SelfTestView() } label: { Label("自检（扩展 / 脚本 / 拦截）", icon: "stethoscope") }
                    NavigationLink { AboutView() } label: { Label("关于 Rikugan", icon: "info.circle") }
                }
                Section {
                    Text(BuildInfo.line).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        .accessibilityIdentifier("build-info")
                }
            }
            .navigationTitle("设置")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

// MARK: - Search

struct SearchSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @State private var name = ""
    @State private var template = ""
    @State private var keyword = ""
    @State private var shortcutTemplate = ""

    var body: some View {
        Form {
            Section("默认搜索引擎") {
                Picker("搜索引擎", selection: $services.prefs.searchEngineID) {
                    ForEach(services.prefs.allEngines) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section { Toggle("搜索建议", isOn: $services.prefs.searchSuggestions) } footer: {
                Text("输入时向所选搜索引擎请求建议。无痕模式下不会请求。")
            }
            Section("自定义搜索引擎") {
                ForEach(services.prefs.customEngines) { engine in
                    VStack(alignment: .leading) {
                        Text(engine.name)
                        Text(engine.searchTemplate).font(.subheadline).foregroundStyle(.secondary)
                    }
                }
                .onDelete { services.prefs.customEngines.remove(atOffsets: $0) }
                TextField("名称", text: $name)
                TextField("https://example.com/search?q={query}", text: $template).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("添加") {
                    guard SearchEngine.isValidTemplate(template) else { ToastCenter.shared.show("模板需要包含 {query}", symbol: "exclamationmark.triangle"); return }
                    services.prefs.customEngines.append(SearchEngine(id: UUID().uuidString, name: name.isEmpty ? template : name, searchTemplate: template))
                    name = ""; template = ""
                }
            }
            Section {
                ForEach(services.prefs.shortcuts) { s in
                    HStack { Text(s.keyword).bold(); Text(s.template).font(.subheadline).foregroundStyle(.secondary).lineLimit(1) }
                }
                .onDelete { services.prefs.shortcuts.remove(atOffsets: $0) }
                TextField("关键词，例如 gh", text: $keyword).textInputAutocapitalization(.never)
                TextField("https://github.com/search?q={query}", text: $shortcutTemplate).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("添加快捷方式") {
                    guard !keyword.isEmpty, SearchEngine.isValidTemplate(shortcutTemplate) else { return }
                    services.prefs.shortcuts.append(URLShortcut(keyword: keyword, template: shortcutTemplate))
                    keyword = ""; shortcutTemplate = ""
                }
            } header: { Text("网址快捷方式") } footer: { Text("在地址栏输入「关键词 空格 内容」，例如「gh swift」。") }
        }
        .navigationTitle("搜索")
    }
}

// MARK: - Appearance / toolbar

struct AppearanceSettingsView: View {
    @EnvironmentObject private var services: AppServices
    var body: some View {
        Form {
            Section {
                Picker("地址栏位置（iPhone）", selection: $services.prefs.toolbarPosition) {
                    Text("底部").tag(ToolbarPosition.bottom)
                    Text("顶部").tag(ToolbarPosition.top)
                }
            }
            Section {
                Picker("地址栏显示", selection: $services.prefs.addressBarDisplay) {
                    Text("标题和域名").tag(AddressBarDisplay.titleAndDomain)
                    Text("网页标题").tag(AddressBarDisplay.title)
                    Text("域名").tag(AddressBarDisplay.domain)
                    Text("完整网址").tag(AddressBarDisplay.fullURL)
                }
            } footer: { Text("浏览时地址栏显示的内容；点击地址栏编辑时总是显示完整网址。") }
            Section {
                NavigationLink { ToolbarCustomizeView() } label: { Text("工具栏按钮与手势") }
            } footer: { Text("自定义底部工具栏 5 个按钮、每个按钮的长按动作，以及滑动 / 双击手势。长按没有设置长按动作的按钮也会打开这里。") }
            Section {
                NavigationLink { ThemeColorView() } label: {
                    HStack {
                        Text("主题色")
                        Spacer()
                        Text(Theme.presets.first { $0.hex.uppercased() == services.prefs.themeColor.uppercased() }?.name ?? "自选")
                            .foregroundStyle(.secondary)
                        Circle().fill(Theme.color).frame(width: 22, height: 22)
                    }
                }
                NavigationLink { AppIconPickerView() } label: {
                    HStack {
                        Text("App 图标")
                        Spacer()
                        Image(AppIconOption.current.previewImage).resizable().frame(width: 28, height: 28)
                            .clipShape(RoundedRectangle(cornerRadius: 6.5, style: .continuous))
                    }
                }
            }
            Section {
                Toggle("在后台打开新链接", isOn: $services.prefs.openLinksInBackground)
                Toggle("默认请求桌面版网站", isOn: $services.prefs.defaultDesktopMode)
                Toggle("恢复上次的标签页", isOn: $services.prefs.restoreTabs)
            }
        }
        .navigationTitle("外观与工具栏")
    }
}

struct HomepageSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @State private var photo: PhotosPickerItem?

    var body: some View {
        Form {
            Section {
                Picker("新标签页", selection: $services.prefs.homepageMode) {
                    Text("起始页").tag(HomepageMode.start)
                    Text("空白页").tag(HomepageMode.blank)
                    Text("自定义网址").tag(HomepageMode.custom)
                }
                if services.prefs.homepageMode == .custom {
                    TextField("https://", text: $services.prefs.homepageURL).keyboardType(.URL).textInputAutocapitalization(.never)
                }
                Toggle("显示经常访问", isOn: $services.prefs.showFrequentlyVisited)
            }
            Section("壁纸") {
                PhotosPicker(selection: $photo, matching: .images) { Text("选择壁纸") }
                if services.prefs.wallpaperFileName != nil {
                    Toggle("沉浸式壁纸", isOn: $services.prefs.immersiveWallpaper)
                    Button("移除壁纸", role: .destructive) { services.prefs.wallpaperFileName = nil }
                }
            }
        }
        .navigationTitle("起始页")
        .onChange(of: photo) { _, item in
            guard let item else { return }
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                let name = "wallpaper-\(UUID().uuidString).jpg"
                let image = UIImage(data: data)
                try? (image?.jpegData(compressionQuality: 0.9) ?? data).write(to: AppPaths.wallpapers.appendingPathComponent(name))
                services.prefs.wallpaperFileName = name
            }
        }
    }
}

// MARK: - Web font

struct WebFontSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var fonts: FontManager
    @EnvironmentObject private var profile: ProfileContext
    @Binding var importKind: BrowserView.ImportKind?
    @State private var excluded = ""
    @State private var newSite = ""

    var body: some View {
        Form {
            Section {
                Toggle("使用自定义网页字体", isOn: $services.prefs.webFontEnabled)
                FontChooser(title: "正文字体", selection: $services.prefs.webFontFamily, allowNone: false)
                FontChooser(title: "标题字体", selection: $services.prefs.webFontHeading, allowNone: true)
                FontChooser(title: "等宽字体（代码）", selection: $services.prefs.webFontMono, allowNone: true)
            } footer: {
                Text("“保持网页字体”表示该类文字不替换。图标字体（Material Icons、Font Awesome、网页自带的图标字体等）会被自动识别并保留，不会变成乱码。通过配置描述文件安装的字体对 WebKit 全局可用，可直接选择；导入的字体文件通过 FontFace API 注入网页，不受网页 CSP 限制。")
            }
            if !services.prefs.webFontFamily.isEmpty {
                Section("预览") {
                    Text("六眼 Rikugan — The quick brown fox jumps over the lazy dog. 永和九年，岁在癸丑。")
                        .font(.custom(services.prefs.webFontFamily, size: 18))
                    if !services.prefs.webFontHeading.isEmpty { Text("标题 Heading").font(.custom(services.prefs.webFontHeading, size: 22)) }
                    if !services.prefs.webFontMono.isEmpty { Text("let code = 0x1F // 代码").font(.custom(services.prefs.webFontMono, size: 15)) }
                }
            }
            Section("已导入的字体文件") {
                ForEach(fonts.imported) { font in
                    HStack {
                        Text(font.family).font(.custom(font.postScriptName, size: 17))
                        Spacer()
                        Text(font.fileURL.pathExtension.uppercased()).font(.footnote).foregroundStyle(.secondary)
                    }
                }
                .onDelete { idx in idx.map { fonts.imported[$0] }.forEach { fonts.delete($0) } }
                Button { importKind = .font } label: { Text("导入字体文件（TTF / OTF / TTC / WOFF2）") }
            }
            Section {
                ForEach(profile.siteSettings.sites.values.filter { $0.fontBody != nil || $0.fontHeading != nil || $0.fontMono != nil || $0.webFont != nil }.sorted { $0.host < $1.host }) { site in
                    NavigationLink { SiteFontEditor(host: site.host) } label: {
                        VStack(alignment: .leading) {
                            Text(site.host)
                            Text(site.webFont == false ? "已停用" : [site.fontBody, site.fontHeading, site.fontMono].compactMap { $0 }.joined(separator: " / "))
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                }
                HStack {
                    TextField("github.com", text: $newSite).textInputAutocapitalization(.never).autocorrectionDisabled()
                    NavigationLink("设置") { SiteFontEditor(host: newSite.lowercased()) }.disabled(newSite.isEmpty)
                }
            } header: { Text("按网站覆盖") } footer: { Text("例如：全局使用字体 A，github.com 使用字体 B，example.com 停用。") }
            Section {
                ForEach(services.prefs.webFontExcludedHosts, id: \.self) { Text($0) }
                    .onDelete { services.prefs.webFontExcludedHosts.remove(atOffsets: $0) }
                HStack {
                    TextField("example.com", text: $excluded).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("添加") { if !excluded.isEmpty { services.prefs.webFontExcludedHosts.append(excluded.lowercased()); excluded = "" } }
                }
            } header: { Text("不替换字体的网站") }
        }
        .navigationTitle("网页字体")
    }
}

/// Picks a font family: keep page font, imported fonts, or any system / profile-installed family.
struct FontChooser: View {
    let title: String
    @Binding var selection: String
    let allowNone: Bool
    @EnvironmentObject private var fonts: FontManager
    @State private var showSystemPicker = false

    var body: some View {
        Menu {
            if allowNone { Button("保持网页字体") { selection = "" } }
            if !fonts.imported.isEmpty {
                Section("导入的字体") { ForEach(fonts.imported) { font in Button(font.family) { selection = font.family } } }
            }
            Button("系统 / 描述文件字体…") { showSystemPicker = true }
        } label: {
            HStack {
                Text(title).foregroundStyle(.primary)
                Spacer()
                Text(selection.isEmpty ? (allowNone ? "保持网页字体" : "未选择") : selection).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .sheet(isPresented: $showSystemPicker) { SystemFontPicker { selection = $0 } }
    }
}

struct SiteFontEditor: View {
    let host: String
    @EnvironmentObject private var profile: ProfileContext

    private func binding(_ keyPath: WritableKeyPath<SiteSettings, String?>) -> Binding<String> {
        Binding(get: { profile.siteSettings.sites[host]?[keyPath: keyPath] ?? "" },
                set: { value in profile.siteSettings.update(host) { $0[keyPath: keyPath] = value.isEmpty ? nil : value } })
    }

    var body: some View {
        Form {
            Section {
                Picker("此网站", selection: Binding(get: { profile.siteSettings.sites[host]?.webFont.map { $0 ? 1 : 2 } ?? 0 },
                                                  set: { v in profile.siteSettings.update(host) { $0.webFont = v == 0 ? nil : v == 1 } })) {
                    Text("跟随全局").tag(0); Text("启用").tag(1); Text("停用").tag(2)
                }
            }
            Section("覆盖（留空 = 使用全局）") {
                FontChooser(title: "正文字体", selection: binding(\.fontBody), allowNone: true)
                FontChooser(title: "标题字体", selection: binding(\.fontHeading), allowNone: true)
                FontChooser(title: "等宽字体", selection: binding(\.fontMono), allowNone: true)
            }
        }
        .navigationTitle(host)
    }
}

struct DarkModeSettingsView: View {
    @EnvironmentObject private var services: AppServices
    var body: some View {
        Form {
            Section {
                Picker("网页深色模式", selection: $services.prefs.pageDarkMode) {
                    Text("关").tag(TriState.off)
                    Text("自动（跟随系统外观）").tag(TriState.auto)
                    Text("开").tag(TriState.on)
                }
                .pickerStyle(.inline)
            } header: { Text("全局（所有网站的默认值）") } footer: { Text("这是网页内容的深色模式，而不只是 App 界面。已经是深色的网页会自动跳过。单个网站可以覆盖这里的设置：页面菜单 → 网页工具 → 网页深色模式，选择“本网站始终开启 / 关闭”；选“跟随全局设置”则使用这里的值。") }
            DarkModeSiteOverrides(store: services.profile.siteSettings)
            Section("调整") {
                Stepper("亮度 \(services.prefs.darkModeBrightness)%", value: $services.prefs.darkModeBrightness, in: 50...150, step: 5)
                Stepper("对比度 \(services.prefs.darkModeContrast)%", value: $services.prefs.darkModeContrast, in: 50...150, step: 5)
            }
        }
        .navigationTitle("网页深色模式")
    }
}

/// Sites whose dark mode differs from the global setting (observes the store so resets show at once).
struct DarkModeSiteOverrides: View {
    @ObservedObject var store: SiteSettingsStore

    var body: some View {
        Section {
            let overrides = store.sites.filter { $0.value.darkMode != nil }.sorted { $0.key < $1.key }
            if overrides.isEmpty { Text("没有单独设置的网站").foregroundStyle(.secondary) }
            ForEach(overrides, id: \.key) { host, site in
                LabeledContent(host, value: site.darkMode == .on ? "始终开启" : (site.darkMode == .off ? "始终关闭" : "自动"))
                    .swipeActions { Button("跟随全局") { store.update(host) { $0.darkMode = nil } } }
            }
        } header: { Text("单独设置的网站") } footer: { Text("左滑可恢复为跟随全局设置。") }
    }
}

struct TranslationSettingsView: View {
    @EnvironmentObject private var services: AppServices
    var body: some View {
        Form {
            Section {
                Picker("服务", selection: $services.prefs.translationProvider) {
                    ForEach(Array(TranslationService.providerOptions.enumerated()), id: \.offset) { _, option in Text(option.name).tag(option.id) }
                }
                if services.prefs.translationProvider == "libre" {
                    TextField("https://libretranslate.example.com", text: $services.prefs.translationServerURL).textInputAutocapitalization(.never)
                }
                if services.prefs.translationProvider == "libre" || services.prefs.translationProvider == "deepl" {
                    SecureField("API Key", text: $services.prefs.translationAPIKey)
                }
                if ["google", "microsoft"].contains(services.prefs.translationProvider) {
                    Toggle("失败时改用另一个免费服务", isOn: $services.prefs.translationFreeFallback)
                }
            } header: {
                Text("翻译服务")
            } footer: {
                Text(["libre", "deepl"].contains(services.prefs.translationProvider)
                     ? "网页文本只发送到这里选择的服务，失败时不会改用其他服务。API Key 保存在钥匙串中，不会出现在导出文件里。"
                     : "网页文本只发送到这里选择的服务。打开上面的开关后，Google 与 Microsoft 其中一个失败时会改用另一个。")
            }
            Section("目标语言") {
                Picker("翻译为", selection: $services.prefs.translationTargetLanguage) {
                    ForEach(TranslationLanguage.common) { Text($0.name).tag($0.code) }
                }
            }
            Section {
                ForEach(TranslationLanguage.common.filter { $0.code != services.prefs.translationTargetLanguage }) { language in
                    Toggle(language.name, isOn: Binding(get: { services.prefs.autoTranslateLanguages.contains(language.code) }, set: { on in
                        services.prefs.autoTranslateLanguages.removeAll { $0 == language.code }
                        if on { services.prefs.autoTranslateLanguages.append(language.code) }
                    }))
                }
            } header: { Text("自动翻译这些语言的网页") }
        }
        .navigationTitle("网页翻译")
    }
}

struct NavigationControlSettingsView: View {
    @EnvironmentObject private var services: AppServices
    var body: some View {
        Form {
            Section {
                Toggle("阻止跳转到 App Store", isOn: $services.prefs.preventAppStoreRedirect)
                Toggle("阻止打开外部 App", isOn: $services.prefs.preventExternalAppRedirect)
                Toggle("阻止弹出窗口", isOn: $services.prefs.blockPopups)
            } footer: {
                Text("未阻止时，网页尝试打开其他 App（如 youtube://、weixin://）会先询问。Android intent:// 链接会改用网页提供的备用地址。每个网站可在网站设置中单独允许或阻止。")
            }
        }
        .navigationTitle("页面跳转控制")
    }
}

struct MediaSettingsView: View {
    @EnvironmentObject private var services: AppServices
    var body: some View {
        Form {
            Section {
                Toggle("媒体资源嗅探", isOn: $services.prefs.mediaSnifferEnabled)
            } footer: { Text("记录网页通过 fetch / XHR / DOM 加载的视频、音频和 M3U8 地址。受 DRM（FairPlay / Widevine）保护的内容不在支持范围内。") }
            Section {
                Toggle("下载前询问文件名和保存位置", isOn: $services.prefs.downloadConfirm)
            } header: { Text("下载") } footer: {
                Text("开启后，网页下载、长按链接下载和媒体面板下载会先让你修改文件名，并选择保存到 Rikugan 下载文件夹或完成后在“文件”中选择位置。默认位置：文件 App → 我的 iPhone → Rikugan → Downloads。")
            }
            Section {
                Toggle("重启后保留标签页缩略图", isOn: $services.prefs.persistTabThumbnails)
            } footer: { Text("缩略图保存在 App 缓存中（无痕标签页不保存），关闭标签页时删除。") }
        }
        .navigationTitle("媒体与下载")
    }
}

struct PrivacySettingsView: View {
    @EnvironmentObject private var profile: ProfileContext
    @State private var confirm = false

    var body: some View {
        Form {
            Section {
                Button("清除历史记录", role: .destructive) { profile.history.clearAll(); ToastCenter.shared.show("历史记录已清除", symbol: "trash") }
                Button("清除 Cookie 与网站数据", role: .destructive) { confirm = true }
            } footer: { Text("只影响当前身份「\(profile.info.name)」。无痕标签页的数据在关闭后自动丢弃。") }
        }
        .navigationTitle("清除浏览数据")
        .confirmationDialog("清除所有网站数据？将退出所有网站的登录。", isPresented: $confirm, titleVisibility: .visible) {
            Button("清除", role: .destructive) {
                Task { await profile.clearWebsiteData(); ToastCenter.shared.show("网站数据已清除", symbol: "trash") }
            }
        }
    }
}

struct DeveloperSettingsView: View {
    @EnvironmentObject private var services: AppServices
    var body: some View {
        Form {
            Section {
                Toggle("允许 Safari 网页检查器", isOn: $services.prefs.webInspectorEnabled)
            } footer: { Text("开启后可在 Mac 的 Safari → 开发 菜单中调试 Rikugan 的网页（WKWebView.isInspectable）。扩展后台页面始终可调试。") }
            Section {
                Toggle("应用内控制台（实验）", isOn: $services.prefs.consoleCaptureEnabled)
                Toggle("位置权限按网站询问", isOn: $services.prefs.geolocationShim)
            } footer: { Text("应用内检查器可查看 console 输出、执行 JavaScript、查看 DOM 与资源。新设置在下次加载页面时生效。") }
            Section("测试与调试") {
                NavigationLink { BackgroundRuntimesView() } label: { Text("扩展后台运行时") }
                NavigationLink { ManualTestChecklistView() } label: { Text("人工测试清单") }
                NavigationLink { SecurityLogView() } label: { Text("安全拒绝记录") }
            }
            Section {
                Toggle("在设置中显示“诊断”页", isOn: $services.prefs.showDiagnostics)
                NavigationLink { DiagnosticsView() } label: { Text("打开诊断") }
            } footer: { Text("诊断页显示构建信息、标签页生命周期、扩展后台状态、API 兼容性、DNR 能力与最近错误，可导出为不含敏感信息的 JSON。") }
            Section {
                Stepper("后台存活标签页上限：\(services.prefs.maxLiveBackgroundTabs)", value: $services.prefs.maxLiveBackgroundTabs, in: 0...20)
                    .onChange(of: services.prefs.maxLiveBackgroundTabs) {
                        for window in TabRegistry.shared.allWindows { window.enforceLifecycle(memoryPressure: false) }
                    }
                Stepper("扩展后台空闲挂起：\(services.prefs.backgroundIdleSeconds) 秒", value: $services.prefs.backgroundIdleSeconds, in: 30...1800, step: 30)
            } footer: { Text("超过上限的后台标签页会被挂起（保存网址、历史、滚动位置与快照，释放 WKWebView），切回时恢复。收到内存警告时会挂起全部后台标签页。有打开端口的扩展后台不会被挂起。") }
        }
        .navigationTitle("开发者")
    }
}

struct CompatibilityView: View {
    var body: some View {
        List {
            Section {
                Text("本表由 chrome-api-matrix.json 生成；CI 会校验每个标为支持的方法都在 JS 运行时和原生桥中真实存在，标为不支持的方法调用时返回明确错误并记录到诊断页。").font(.footnote).foregroundStyle(.secondary)
            }
            Section("Chrome 扩展 API") {
                ForEach(ChromeAPIMatrix.entries) { entry in
                    NavigationLink { CompatibilityDetailView(entry: entry) } label: {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack {
                                Text(entry.level.symbol)
                                Text("chrome." + entry.namespace).font(.body.monospaced())
                                Spacer()
                                if !entry.methods.isEmpty { Text("\(entry.implemented.count)/\(entry.methods.count)").font(.caption.monospacedDigit()).foregroundStyle(.secondary) }
                            }
                            if !entry.reason.isEmpty { Text(entry.reason).font(.subheadline).foregroundStyle(.secondary).lineLimit(2) }
                        }
                    }
                }
            }
            Section("用户脚本 API") {
                ForEach(Array(GMCompatibility.table.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack { Text(entry.level.symbol); Text(entry.api).font(.callout.monospaced()) }
                        if !entry.note.isEmpty { Text(entry.note).font(.subheadline).foregroundStyle(.secondary) }
                    }
                }
            }
        }
        .navigationTitle("兼容性矩阵")
    }
}

struct CompatibilityDetailView: View {
    let entry: ChromeAPIMatrix.Entry
    var body: some View {
        List {
            Section("级别") {
                LabeledContent("chrome.\(entry.namespace)", value: "\(entry.level.symbol) \(entry.level.rawValue)")
                if !entry.reason.isEmpty { Text(entry.reason).font(.footnote) }
            }
            if !entry.differences.isEmpty {
                Section("与 Chrome 的语义差异") { ForEach(entry.differences, id: \.self) { Text($0).font(.footnote) } }
            }
            if !entry.implemented.isEmpty {
                Section("已实现（\(entry.implemented.count)）") { ForEach(entry.implemented) { methodRow($0) } }
            }
            if !entry.missing.isEmpty {
                Section("未实现（\(entry.missing.count)）") { ForEach(entry.missing) { methodRow($0) } }
            }
            if !entry.actions.isEmpty {
                Section("规则动作") { ForEach(entry.actions) { methodRow($0) } }
            }
        }
        .navigationTitle("chrome.\(entry.namespace)")
    }

    private func methodRow(_ method: ChromeAPIMatrix.Method) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack { Text(method.level.symbol); Text(method.name).font(.callout.monospaced()) }
            if !method.note.isEmpty { Text(method.note).font(.subheadline).foregroundStyle(.secondary) }
        }
    }
}

struct AboutView: View {
    @EnvironmentObject private var services: AppServices
    var body: some View {
        Form {
            Section {
                LabeledContent("版本", value: services.appVersion)
                LabeledContent("引擎", value: "WebKit / WKWebView")
            }
            Section("默认浏览器") {
                Text(services.defaultBrowserStatus).font(.footnote)
            }
            Section {
                Text("Rikugan 是一个原生 iOS / iPadOS 浏览器，内置用户脚本管理器、Chrome MV3 兼容运行时、内容拦截与网页工具。没有信息流、推荐内容或广告。").font(.footnote)
            }
        }
        .navigationTitle("关于")
    }
}
