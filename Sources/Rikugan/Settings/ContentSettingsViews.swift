import SwiftUI

// MARK: - AdBlock (spec §21 / §22)

struct AdBlockSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var adBlock: AdBlockEngine
    @State private var newRule = ""
    @State private var subName = ""
    @State private var subURL = ""
    @State private var editingAll = false
    @State private var allText = ""
    @State private var updating = false

    var body: some View {
        Form {
            Section {
                Toggle("启用内容拦截", isOn: $services.prefs.adBlockEnabled)
                if adBlock.isCompiling { HStack { ProgressView(); Text("正在编译规则…").foregroundStyle(.secondary) } }
                LabeledContent("网络规则", value: "\(adBlock.stats.network)")
                LabeledContent("元素隐藏规则", value: "\(adBlock.stats.cosmetic)")
                LabeledContent("不支持的规则", value: "\(adBlock.stats.unsupported)")
                if let error = adBlock.lastError { Text(error).font(.caption).foregroundStyle(.red) }
            } footer: {
                Text("兼容 AdGuard / Adblock Plus 语法。网络规则编译为 WebKit 内容拦截列表，元素隐藏规则注入 CSS。脚本注入类规则（#%#、##+js）、$redirect、$removeparam 等暂不支持，会计入“不支持”。")
            }
            Section("过滤列表订阅") {
                ForEach(adBlock.subscriptions) { sub in
                    Toggle(isOn: Binding(get: { sub.enabled }, set: { adBlock.setSubscription(sub.id, enabled: $0) })) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sub.name)
                            Text(sub.lastUpdated.map { "\(sub.ruleCount) 条 · 更新于 \($0.formatted(date: .abbreviated, time: .shortened))" } ?? "尚未下载")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                    }
                    .swipeActions { if !sub.isBuiltIn { Button("删除", role: .destructive) { adBlock.removeSubscription(sub.id) } } }
                }
                Button {
                    updating = true
                    Task { await adBlock.updateSubscriptions(); updating = false }
                } label: { HStack { Text("立即更新全部"); if updating { Spacer(); ProgressView() } } }
                .disabled(updating)
            }
            Section("添加第三方规则（AdGuard 等）") {
                TextField("名称", text: $subName)
                TextField("https://…/filter.txt", text: $subURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("订阅") { adBlock.addSubscription(name: subName, url: subURL); subName = ""; subURL = "" }.disabled(subURL.isEmpty)
            }
            Section {
                ForEach(adBlock.customRuleLines, id: \.self) { rule in
                    Text(rule).font(.caption.monospaced())
                }
                .onDelete { idx in idx.map { adBlock.customRuleLines[$0] }.forEach { adBlock.removeCustomRule($0) } }
                HStack {
                    TextField("example.com##.ad 或 ||ads.example^", text: $newRule).font(.caption.monospaced())
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("添加") { adBlock.addCustomRule(newRule); newRule = "" }.disabled(newRule.isEmpty)
                }
                Button("以文本方式编辑全部") { allText = adBlock.customRules; editingAll = true }
            } header: { Text("自定义规则") } footer: { Text("用“隐藏网页元素”生成的规则也会出现在这里，左滑可删除。") }
            Section("已停用拦截的网站") {
                ForEach(adBlock.allowlist, id: \.self) { host in Text(host) }
                    .onDelete { idx in idx.map { adBlock.allowlist[$0] }.forEach { adBlock.setAllowlisted($0, false) } }
            }
        }
        .navigationTitle("内容拦截")
        .sheet(isPresented: $editingAll) {
            NavigationStack {
                TextEditor(text: $allText).font(.caption.monospaced()).padding(.horizontal, 8)
                    .navigationTitle("自定义规则").navigationBarTitleDisplayMode(.inline)
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) { Button("取消") { editingAll = false } }
                        ToolbarItem(placement: .confirmationAction) { Button("保存") { adBlock.setCustomRules(allText); editingAll = false } }
                    }
            }
        }
    }
}

// MARK: - Site settings (spec §47 / §48)

struct SiteSettingsListView: View {
    @EnvironmentObject private var profile: ProfileContext
    var body: some View {
        List {
            if profile.siteSettings.sites.isEmpty { Text("尚未为任何网站单独设置").foregroundStyle(.secondary) }
            ForEach(profile.siteSettings.sites.keys.sorted(), id: \.self) { host in
                NavigationLink(host) { SiteSettingsDetailView(host: host, tab: nil) }
            }
            .onDelete { idx in let keys = profile.siteSettings.sites.keys.sorted(); idx.forEach { profile.siteSettings.remove(keys[$0]) } }
        }
        .navigationTitle("网站设置")
    }
}

struct SiteSettingsDetailView: View {
    let host: String
    let tab: BrowserTab?
    @EnvironmentObject private var profile: ProfileContext
    @EnvironmentObject private var adBlock: AdBlockEngine
    @Environment(\.dismiss) private var dismiss

    private var site: SiteSettings { profile.siteSettings.sites[host.lowercased()] ?? SiteSettings(host: host) }

    private func optionalBool(_ keyPath: WritableKeyPath<SiteSettings, Bool?>) -> Binding<Int> {
        Binding(get: { site[keyPath: keyPath].map { $0 ? 1 : 2 } ?? 0 },
                set: { v in profile.siteSettings.update(host) { $0[keyPath: keyPath] = v == 0 ? nil : v == 1 } })
    }

    private func decision(_ keyPath: WritableKeyPath<SiteSettings, PermissionDecision?>) -> Binding<PermissionDecision> {
        Binding(get: { site[keyPath: keyPath] ?? .ask }, set: { v in profile.siteSettings.update(host) { $0[keyPath: keyPath] = v == .ask ? nil : v } })
    }

    var body: some View {
        Form {
            if host.isEmpty {
                Text("当前页面没有可设置的网站").foregroundStyle(.secondary)
            } else {
                Section("页面") {
                    Picker("桌面版网站", selection: optionalBool(\.desktopMode)) { Text("默认").tag(0); Text("开").tag(1); Text("关").tag(2) }
                    Picker("网页深色模式", selection: Binding(get: { site.darkMode }, set: { v in profile.siteSettings.update(host) { $0.darkMode = v }; tab?.applyLiveStyles() })) {
                        Text("跟随全局").tag(TriState?.none); Text("开").tag(TriState?.some(.on)); Text("关").tag(TriState?.some(.off))
                    }
                    Picker("JavaScript", selection: optionalBool(\.javaScript)) { Text("允许（默认）").tag(0); Text("允许").tag(1); Text("禁止").tag(2) }
                    Picker("自定义字体", selection: optionalBool(\.webFont)) { Text("默认").tag(0); Text("开").tag(1); Text("关").tag(2) }
                }
                Section("内容") {
                    Toggle("内容拦截", isOn: Binding(get: { !adBlock.isAllowlisted(host) && site.contentBlocking != false },
                                                  set: { on in adBlock.setAllowlisted(host, !on); profile.siteSettings.update(host) { $0.contentBlocking = on ? nil : false } }))
                    Picker("用户脚本", selection: optionalBool(\.userScriptsEnabled)) { Text("运行（默认）").tag(0); Text("运行").tag(1); Text("不运行").tag(2) }
                    Picker("扩展", selection: optionalBool(\.extensionsEnabled)) { Text("运行（默认）").tag(0); Text("运行").tag(1); Text("不运行").tag(2) }
                    Picker("弹出窗口", selection: decision(\.popups)) { Text("默认").tag(PermissionDecision.ask); Text("允许").tag(PermissionDecision.allow); Text("阻止").tag(PermissionDecision.block) }
                    Picker("打开外部 App", selection: decision(\.externalNavigation)) { Text("询问").tag(PermissionDecision.ask); Text("允许").tag(PermissionDecision.allow); Text("阻止").tag(PermissionDecision.block) }
                }
                Section {
                    Toggle("兼容模式", isOn: Binding(get: { site.compatibilityMode == true },
                                                  set: { on in profile.siteSettings.update(host) { $0.compatibilityMode = on ? true : nil } }))
                } footer: {
                    Text("开启后，Rikugan 不在此网站注入自己的页面脚本（深色模式、自定义字体、元素隐藏、页内查找、阅读模式、翻译、媒体嗅探、控制台和权限适配都会失效）。网站表现异常时可以试试，刷新页面后生效。用户脚本和扩展由上面的开关单独控制。")
                }
                Section("网页权限") {
                    ForEach(Array(SiteSettings.webPermissionKinds.enumerated()), id: \.offset) { _, kind in
                        Picker(kind.title, selection: Binding(get: { site.permissions[kind.key] ?? .ask },
                                                              set: { v in profile.siteSettings.update(host) { $0.permissions[kind.key] = v == .ask ? nil : v } })) {
                            Text("询问").tag(PermissionDecision.ask); Text("允许").tag(PermissionDecision.allow); Text("阻止").tag(PermissionDecision.block)
                        }
                    }
                }
                Section {
                    Button("重置此网站的设置", role: .destructive) { profile.siteSettings.remove(host.lowercased()) }
                } footer: { Text("网页权限与扩展权限相互独立。部分设置在刷新页面后生效。") }
            }
        }
        .navigationTitle(host.isEmpty ? "网站设置" : host)
        .toolbar {
            if let tab {
                ToolbarItem(placement: .confirmationAction) { Button("刷新页面") { tab.markInjected(for: URL(string: "about:invalid")!); tab.reload(); dismiss() } }
            }
        }
    }
}

// MARK: - Autofill

struct AutofillSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @EnvironmentObject private var autofill: AutofillStore
    @State private var unlocked = false
    @State private var card = PaymentCard()

    var body: some View {
        Form {
            Section { Toggle("提示保存密码", isOn: $services.prefs.autofillEnabled) } footer: {
                Text("密码、个人信息和支付卡保存在本机钥匙串（Keychain）中，不写入 UserDefaults，查看和填充前需要面容 ID / 密码验证（设备未设置密码时无法验证）。密码只填充到保存它的同一网站的 HTTPS 页面。")
            }
            if unlocked {
                Section("密码") {
                    ForEach(autofill.credentials) { c in
                        VStack(alignment: .leading) {
                            Text(c.host).font(.headline)
                            Text(c.username).font(.subheadline)
                            Text(c.password).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                        }
                    }
                    .onDelete { idx in idx.map { autofill.credentials[$0] }.forEach { c in Self.report { try autofill.delete(c) } } }
                }
                Section("个人信息") {
                    TextField("姓名", text: $autofill.profile.name)
                    TextField("名", text: $autofill.profile.givenName)
                    TextField("姓", text: $autofill.profile.familyName)
                    TextField("电子邮件", text: $autofill.profile.email).keyboardType(.emailAddress).textInputAutocapitalization(.never)
                    TextField("电话", text: $autofill.profile.phone).keyboardType(.phonePad)
                    TextField("公司", text: $autofill.profile.organization)
                    TextField("街道地址", text: $autofill.profile.street)
                    TextField("城市", text: $autofill.profile.city)
                    TextField("省 / 州", text: $autofill.profile.region)
                    TextField("邮编", text: $autofill.profile.postalCode)
                    TextField("国家或地区", text: $autofill.profile.country)
                    Button("保存个人信息") { if Self.report({ try autofill.saveProfile() }) { ToastCenter.shared.show("已保存", symbol: "checkmark") } }
                }
                Section("支付卡") {
                    ForEach(autofill.cards) { c in Text("\(c.nickname.isEmpty ? "卡片" : c.nickname)  \(c.masked)  \(c.expMonth)/\(c.expYear)") }
                        .onDelete { idx in idx.map { autofill.cards[$0] }.forEach { c in Self.report { try autofill.delete(c) } } }
                    TextField("备注名", text: $card.nickname)
                    TextField("持卡人", text: $card.cardName)
                    TextField("卡号", text: $card.cardNumber).keyboardType(.numberPad)
                    HStack {
                        TextField("月 MM", text: $card.expMonth).keyboardType(.numberPad)
                        TextField("年 YYYY", text: $card.expYear).keyboardType(.numberPad)
                    }
                    Button("添加支付卡") { if Self.report({ try autofill.save(card) }) { card = PaymentCard() } }.disabled(card.cardNumber.count < 12)
                }
            } else {
                Button { Task { unlocked = await Keychain.authenticate(reason: "查看保存的密码与支付信息") } } label: { Text("解锁以查看") }
            }
        }
        .navigationTitle("密码与自动填充")
    }
}

// MARK: - Profiles (spec §36)

extension AutofillSettingsView {
    /// Runs a Keychain write and shows its error; true when it succeeded.
    @discardableResult
    static func report(_ body: () throws -> Void) -> Bool {
        do { try body(); return true } catch {
            ToastCenter.shared.show("未保存：\(error.localizedDescription)", symbol: "exclamationmark.triangle")
            return false
        }
    }
}

struct ProfilesView: View {
    @EnvironmentObject private var services: AppServices
    @State private var name = ""
    @State private var symbol = "briefcase"
    private let symbols = ["person.crop.circle", "person.2", "figure.child", "briefcase", "building.2", "house", "graduationcap", "book",
                           "hammer", "flask", "paintpalette", "camera", "headphones", "gamecontroller", "dumbbell", "airplane",
                           "sailboat", "cart", "bag", "banknote", "gift", "ticket", "cup.and.saucer", "fork.knife",
                           "heart", "star", "sparkles", "flame", "bolt", "leaf", "tree", "pawprint",
                           "sun.max", "moon", "cloud", "globe", "shield", "key", "clipboard", "curlybraces"]
    private let iconColumns = [GridItem(.adaptive(minimum: 44), spacing: 8)]

    var body: some View {
        Form {
            Section {
                ForEach(services.profiles.profiles) { info in
                    Button {
                        services.profiles.switchTo(info.id)
                    } label: {
                        HStack {
                            Label(info.name, icon: info.symbol)
                            Spacer()
                            if info.id == services.profile.id { Image(icon: "checkmark").foregroundStyle(.tint) }
                        }
                    }
                    .foregroundStyle(.primary)
                    .swipeActions {
                        if !info.isDefault && info.id != services.profile.id {
                            Button("删除", role: .destructive) { Task { await services.profiles.delete(info.id) } }
                        }
                    }
                }
            } footer: {
                Text("每个身份拥有独立的 Cookie、localStorage、缓存、历史、书签、用户脚本、扩展设置和网站设置。切换身份会关闭当前身份的标签页并恢复目标身份的标签页。")
            }
            Section("新建身份") {
                TextField("名称，例如 工作", text: $name)
                VStack(alignment: .leading, spacing: 8) {
                    Text("图标")
                    LazyVGrid(columns: iconColumns, spacing: 8) {
                        ForEach(symbols, id: \.self) { name in
                            Button { symbol = name } label: {
                                Image(icon: name).font(.title3)
                                    .frame(width: 42, height: 42)
                                    .foregroundStyle(symbol == name ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
                                    .background(symbol == name ? AnyShapeStyle(.tint) : AnyShapeStyle(Color(.tertiarySystemFill)),
                                                in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(symbol == name ? .isSelected : [])
                        }
                    }
                }
                .padding(.vertical, 4)
                Button("创建") { services.profiles.create(name: name.isEmpty ? "新身份" : name, symbol: symbol); name = "" }
            }
        }
        .navigationTitle("身份")
    }
}

// MARK: - Import / export (formal archive format, see Core/Archive.swift)

struct ImportExportView: View {
    @EnvironmentObject private var manager: TabManager
    @Binding var importKind: BrowserView.ImportKind?
    @State private var includeSource = true
    @State private var includeValues = true

    var body: some View {
        Form {
            Section {
                Toggle("包含用户脚本源代码", isOn: $includeSource)
                Toggle("包含用户脚本存储值（GM_setValue）", isOn: $includeValues)
                Button { ImportExport.exportAll(from: manager, includeSource: includeSource, includeValues: includeValues) } label: {
                    Label("导出全部身份的设置、标签页与分组", icon: "square.and.arrow.up")
                }
                Button { importKind = .settings } label: { Text("从文件导入…") }
            } footer: {
                Text("格式：rikugan-archive，版本 \(RikuganArchive.currentFormatVersion)。包含：设置、搜索引擎、网站设置、身份、标签页组、标签页（含顺序、当前组、当前标签页）、书签、用户脚本、字体元数据、内容拦截规则、扩展列表（仅元数据）。\n\n不包含：" + RikuganArchive.excludedAlways.joined(separator: "、") + "。\n\n导入前会显示预览，可选择“合并”或“替换”；导入前自动备份当前状态到 App 的 Backups 目录。")
            }
        }
        .navigationTitle("导入与导出")
    }
}

/// Preview shown before anything is imported.
struct ArchiveImportSheet: View {
    let archive: RikuganArchive
    let source: String
    @EnvironmentObject private var manager: TabManager
    @Environment(\.dismiss) private var dismiss
    @State private var mode: ArchiveCodec.ImportMode = .merge
    @State private var importing = false

    var body: some View {
        let s = archive.summary
        NavigationStack {
            Form {
                Section("文件") {
                    LabeledContent("来源", value: source)
                    LabeledContent("导出时间", value: archive.exportedAt.formatted(date: .abbreviated, time: .shortened))
                    LabeledContent("导出版本", value: archive.appVersion)
                    LabeledContent("格式版本", value: "\(archive.formatVersion)")
                }
                Section("内容") {
                    LabeledContent("身份", value: "\(s.profiles)")
                    LabeledContent("窗口 / 标签页组 / 标签页", value: "\(s.windows) / \(s.groups) / \(s.tabs)")
                    LabeledContent("书签", value: "\(s.bookmarks)")
                    LabeledContent("网站设置", value: "\(s.siteSettings)")
                    LabeledContent("用户脚本", value: "\(s.userscripts)" + (archive.contents.userscriptSource ? "" : "（仅元数据，无法安装）"))
                    LabeledContent("扩展（仅列表）", value: "\(s.extensions)")
                    LabeledContent("自定义拦截规则", value: "\(s.customRules)")
                    LabeledContent("字体（仅元数据）", value: "\(s.fonts)")
                }
                Section {
                    Picker("导入方式", selection: $mode) {
                        Text("合并到现有数据").tag(ArchiveCodec.ImportMode.merge)
                        Text("替换现有数据").tag(ArchiveCodec.ImportMode.replace)
                    }
                    .pickerStyle(.inline)
                } footer: {
                    Text(mode == .merge ? "合并：网站设置按域名覆盖，书签去重，标签页和分组追加为新窗口内容，同名脚本被更新。" :
                            "替换：同一身份的网站设置、书签、标签页与分组、用户脚本会被文件中的内容替换，全局设置也会被替换。导入前会自动备份。")
                }
                Section("不会导入的内容") { Text(archive.excluded.joined(separator: "、")).font(.footnote) }
            }
            .navigationTitle("导入预览")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button(importing ? "导入中…" : "导入") {
                        importing = true
                        Task {
                            await ImportExport.apply(archive, mode: mode, into: manager)
                            importing = false
                            dismiss()
                        }
                    }
                    .disabled(importing)
                }
            }
        }
    }
}

@MainActor enum ImportExport {
    // MARK: Export

    static func buildArchive(includeSource: Bool = true, includeValues: Bool = true) -> RikuganArchive {
        let services = AppServices.shared
        for window in TabRegistry.shared.allWindows { window.save() }
        var profiles: [ProfileArchive] = []
        for info in services.profiles.profiles {
            let isActive = info.id == services.profile.id
            let dir = AppPaths.directory(info.id.uuidString, in: AppPaths.directory("Profiles"))
            let sites: [SiteSettings]
            let bookmarks: [BookmarkNode]
            let scriptStore: UserScriptStore
            var windows: [WindowSessionSnapshot]
            if isActive {
                sites = Array(services.profile.siteSettings.sites.values)
                bookmarks = services.profile.bookmarks.nodes
                scriptStore = services.profile.userscripts
                // Open windows plus saved windows of this identity that are not open right now.
                let open = TabRegistry.shared.allWindows.filter { $0.profile === services.profile }
                let openFiles = Set(open.map { $0.windowID.uuidString + ".json" })
                windows = open.map(\.sessionSnapshot) + sessionFiles(in: dir).filter { !openFiles.contains($0.lastPathComponent) }
                    .compactMap { JSONFile<WindowSessionSnapshot>($0).load() }.filter { !$0.tabs.isEmpty }
            } else {
                sites = Array(SiteSettingsStore(directory: dir).sites.values)
                bookmarks = BookmarkStore(directory: dir).nodes
                scriptStore = UserScriptStore(directory: AppPaths.directory("Userscripts", in: dir))
                windows = []
            }
            if windows.isEmpty { windows = sessionFiles(in: dir).compactMap { JSONFile<WindowSessionSnapshot>($0).load() } }
            let scripts = scriptStore.scripts.map { script in
                ArchivedUserscript(name: script.metadata.name, namespace: script.metadata.namespace, version: script.metadata.version,
                                   enabled: script.enabled, sourceURL: script.sourceURL,
                                   source: includeSource ? script.source : nil, values: includeValues ? scriptStore.values(for: script.id) : nil)
            }
            let extensions = (JSONFile<[InstalledExtension]>(AppPaths.directory("Extensions", in: dir).appendingPathComponent("extensions.json")).load() ?? []).map {
                ExtensionMetadata(id: $0.id, name: $0.name, version: $0.version, enabled: $0.enabled, source: $0.source.rawValue, storeURL: $0.storeURL)
            }
            profiles.append(ProfileArchive(id: info.id, name: info.name, symbol: info.symbol, isDefault: info.isDefault,
                                           siteSettings: sites.sorted { $0.host < $1.host }, bookmarks: bookmarks,
                                           windows: windows, userscripts: scripts, extensions: extensions))
        }
        let adBlock = services.adBlock
        return RikuganArchive(appVersion: services.appVersion, settings: services.prefs, activeProfileID: services.profile.id, profiles: profiles,
                              fonts: services.fonts.imported.map { FontMetadata(family: $0.family, fileName: $0.fileURL.lastPathComponent) },
                              contentBlocking: ContentBlockingArchive(enabled: services.prefs.adBlockEnabled, customRules: adBlock.customRules,
                                                                      subscriptions: adBlock.subscriptions, allowlist: adBlock.allowlist),
                              contents: .init(userscriptSource: includeSource, userscriptValues: includeValues))
    }

    static func sessionFiles(in profileDir: URL) -> [URL] {
        let dir = AppPaths.directory("Sessions", in: profileDir)
        return ((try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []).filter { $0.pathExtension == "json" }
    }

    static func exportAll(from manager: TabManager, includeSource: Bool = true, includeValues: Bool = true) {
        do {
            let data = try ArchiveCodec.encode(buildArchive(includeSource: includeSource, includeValues: includeValues))
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmm"
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Rikugan-\(formatter.string(from: Date())).rikugan.json")
            try data.write(to: file)
            Presenter.share([file])
        } catch {
            ToastCenter.shared.show("导出失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }

    // MARK: Import

    /// Step 1: decode + validate only. Nothing is changed until the user confirms the preview.
    static func importBundle(from url: URL, into manager: TabManager) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let archive = try ArchiveCodec.decode(try Data(contentsOf: url))
            NotificationCenter.default.post(name: .rikuganImportPreview, object: manager, userInfo: ["archive": ArchiveBox(archive), "source": url.lastPathComponent])
        } catch {
            ToastCenter.shared.show("无法导入：\(error.localizedDescription)", symbol: "exclamationmark.triangle", duration: 5)
        }
    }

    /// A userscript prepared before anything is written: source parsed and every @require /
    /// @resource downloaded.
    private struct PreparedScript {
        let item: ArchivedUserscript
        let source: String
        let deps: UserscriptDependencies.Result
    }

    /// Step 2: apply, as a transaction.
    /// 1. A backup of the current state is written (no backup → nothing happens).
    /// 2. Everything is prepared and validated without writing: the resulting data of every
    ///    profile, and every userscript (metadata + downloaded dependencies). A script that cannot
    ///    be prepared is reported; the import continues only if the user accepts importing
    ///    without it.
    /// 3. Changes are written; if a write fails, the backup is restored and the failure shown.
    static func apply(_ archive: RikuganArchive, mode: ArchiveCodec.ImportMode, into manager: TabManager) async {
        let services = AppServices.shared
        let backupFile: URL
        do {
            let backup = try ArchiveCodec.encode(buildArchive())
            backupFile = AppPaths.directory("Backups").appendingPathComponent("pre-import-\(Int(Date().timeIntervalSince1970)).rikugan.json")
            try backup.write(to: backupFile, options: .atomic)
        } catch {
            ToastCenter.shared.show("无法创建导入前备份，已取消导入：\(error.localizedDescription)", symbol: "exclamationmark.triangle", duration: 5)
            return
        }

        // ---- Prepare (no writes) ----
        var plans: [(ProfileArchive, ProfileData, Bool)] = []
        for incoming in archive.profiles {
            let isActive = incoming.id == services.profile.id || (incoming.isDefault && services.profile.info.isDefault)
            let dir = AppPaths.directory((isActive ? services.profile.id : incoming.id).uuidString, in: AppPaths.directory("Profiles"))
            let current: ProfileData
            if isActive {
                current = ProfileData(siteSettings: Array(services.profile.siteSettings.sites.values), bookmarks: services.profile.bookmarks.nodes,
                                      windows: [], userscripts: [])
            } else {
                current = ProfileData(siteSettings: Array(SiteSettingsStore(directory: dir).sites.values), bookmarks: BookmarkStore(directory: dir).nodes,
                                      windows: sessionFiles(in: dir).compactMap { JSONFile<WindowSessionSnapshot>($0).load() }, userscripts: [])
            }
            let result = ArchiveCodec.apply(incoming, to: current, mode: mode)
            let problems = BookmarkTree.problems(result.bookmarks)
            guard problems.isEmpty else {
                ToastCenter.shared.show("导入已取消：身份「\(incoming.name)」的书签合并结果无效（\(problems[0])）", symbol: "exclamationmark.triangle", duration: 6)
                return
            }
            plans.append((incoming, result, isActive))
        }
        var prepared: [UUID: [PreparedScript]] = [:]
        var failed: [String] = []
        for (incoming, _, _) in plans {
            var list: [PreparedScript] = []
            for item in incoming.userscripts {
                guard let source = item.source else { failed.append("\(item.name)（归档中没有源码）"); continue }
                let parsed = MetadataParser.parse(source)
                if parsed.hasErrors { failed.append("\(item.name)（\(parsed.firstError ?? "元数据无效")）"); continue }
                do {
                    list.append(PreparedScript(item: item, source: source, deps: try await UserscriptDependencies.fetch(for: parsed.metadata)))
                } catch {
                    failed.append("\(item.name)（依赖下载失败：\(error.localizedDescription)）")
                }
            }
            prepared[incoming.id] = list
        }
        if !failed.isEmpty {
            let proceed = await Presenter.confirm(
                title: "\(failed.count) 个脚本无法导入",
                message: failed.prefix(6).joined(separator: "\n") + (failed.count > 6 ? "\n…" : "") + "\n\n继续导入其余内容（这些脚本不导入，\(mode == .replace ? "当前同名脚本保持不变" : "不影响现有脚本")）？",
                confirm: "继续导入", cancel: "取消导入")
            guard proceed else { ToastCenter.shared.show("已取消导入，没有做任何更改", symbol: "xmark.circle"); return }
        }

        // ---- Commit ----
        do {
            try await commit(archive, mode: mode, plans: plans, prepared: prepared, failedNames: Set(failed.map { $0.components(separatedBy: "（").first ?? $0 }), into: manager)
        } catch {
            // Restore the state saved above.
            if let data = try? Data(contentsOf: backupFile), let backup = try? ArchiveCodec.decode(data) {
                try? await commit(backup, mode: .replace, plans: backup.profiles.map { ($0, $0.data, $0.id == services.profile.id) },
                                  prepared: [:], failedNames: [], into: manager, restoringBackup: true)
            }
            ToastCenter.shared.show("导入失败，已恢复导入前的状态：\(error.localizedDescription)", symbol: "exclamationmark.triangle", duration: 6)
            return
        }
        let s = archive.summary
        let fontNote = archive.fonts.isEmpty ? "" : "；\(archive.fonts.count) 个导入字体需要重新导入字体文件"
        ToastCenter.shared.show("已导入 \(s.tabs) 个标签页、\(s.groups) 个组、\(s.userscripts - failed.count) 个脚本" +
                                (failed.isEmpty ? "" : "（\(failed.count) 个脚本未导入）") + fontNote,
                                symbol: failed.isEmpty ? "checkmark.circle" : "exclamationmark.circle", duration: 5)
    }

    /// Writes a prepared import. Throws on the first failed write (the caller restores the backup).
    private static func commit(_ archive: RikuganArchive, mode: ArchiveCodec.ImportMode, plans: [(ProfileArchive, ProfileData, Bool)],
                               prepared: [UUID: [PreparedScript]], failedNames: Set<String>, into manager: TabManager,
                               restoringBackup: Bool = false) async throws {
        let services = AppServices.shared
        var settings = mode == .replace ? archive.settings : mergedPreferences(services.prefs, archive.settings)
        // The wallpaper image is not part of an archive: keep a setting only if its file exists here.
        if let wallpaper = settings.wallpaperFileName, !FileManager.default.fileExists(atPath: AppPaths.wallpapers.appendingPathComponent(wallpaper).path) {
            settings.wallpaperFileName = services.prefs.wallpaperFileName
        }
        services.prefs = settings
        let cb = archive.contentBlocking
        if mode == .replace {
            services.adBlock.replaceState(customRules: cb.customRules, subscriptions: cb.subscriptions, allowlist: cb.allowlist)
        } else {
            let lines = Set(services.adBlock.customRules.components(separatedBy: .newlines))
            let merged = services.adBlock.customRules + cb.customRules.components(separatedBy: .newlines).filter { !$0.isEmpty && !lines.contains($0) }.map { "\n" + $0 }.joined()
            // Subscriptions are merged by URL (existing entries keep their state).
            let existing = Set(services.adBlock.subscriptions.map(\.url))
            let subscriptions = services.adBlock.subscriptions + cb.subscriptions.filter { !existing.contains($0.url) }
            services.adBlock.replaceState(customRules: merged, subscriptions: subscriptions,
                                          allowlist: Array(Set(services.adBlock.allowlist + cb.allowlist)).sorted())
        }
        for (incoming, data, isActive) in plans {
            let scripts = prepared[incoming.id] ?? []
            if isActive {
                let profile = services.profile
                profile.siteSettings.replaceAll(data.siteSettings)
                profile.bookmarks.replaceAll(data.bookmarks)
                if mode == .replace {
                    try replaceWindows(of: profile, with: incoming.windows, initiator: manager)
                } else {
                    for window in data.windows { manager.importSession(window) }
                }
                try installScripts(scripts, into: profile.userscripts, replace: mode == .replace, keeping: failedNames, restoringBackup: restoringBackup, archived: incoming.userscripts)
            } else {
                if let info = services.profiles.profiles.first(where: { $0.id == incoming.id }) {
                    if info.name != incoming.name || info.symbol != incoming.symbol { services.profiles.rename(incoming.id, name: incoming.name, symbol: incoming.symbol) }
                } else {
                    services.profiles.adopt(ProfileInfo(id: incoming.id, name: incoming.name, symbol: incoming.symbol, isDefault: false))
                }
                let dir = AppPaths.directory(incoming.id.uuidString, in: AppPaths.directory("Profiles"))
                try JSONFile<[String: SiteSettings]>(dir.appendingPathComponent("site-settings.json"))
                    .write(Dictionary(data.siteSettings.map { ($0.host, $0) }, uniquingKeysWith: { a, _ in a }))
                try JSONFile<[BookmarkNode]>(dir.appendingPathComponent("bookmarks.json")).write(data.bookmarks)
                if mode == .replace { for file in sessionFiles(in: dir) { try FileManager.default.removeItem(at: file) } }
                for window in (mode == .replace ? incoming.windows : Array(data.windows.suffix(incoming.windows.count))) {
                    try JSONFile<WindowSessionSnapshot>(AppPaths.directory("Sessions", in: dir).appendingPathComponent(UUID().uuidString + ".json")).write(window)
                }
                let store = UserScriptStore(directory: AppPaths.directory("Userscripts", in: dir))
                try installScripts(scripts, into: store, replace: mode == .replace, keeping: failedNames, restoringBackup: restoringBackup, archived: incoming.userscripts)
            }
        }
        PersistenceQueue.shared.flush()
        // Replace also restores which identity was active when the archive was exported.
        if mode == .replace, !restoringBackup, let active = archive.activeProfileID, active != services.profile.id,
           services.profiles.profiles.contains(where: { $0.id == active }) {
            services.profiles.switchTo(active)
        }
    }

    /// Replace mode for the active identity: every open window of it is replaced (the first
    /// archived window goes to the window that started the import, further ones to other open
    /// windows; open windows without an archived counterpart are emptied) and saved sessions
    /// of windows that are not open are replaced by the remaining archived windows.
    private static func replaceWindows(of profile: ProfileContext, with windows: [WindowSessionSnapshot], initiator: TabManager) throws {
        let open = [initiator] + TabRegistry.shared.allWindows.filter { $0 !== initiator && $0.profile === profile }
        var remaining = windows[...]
        for window in open {
            window.apply(remaining.popFirst() ?? WindowSessionSnapshot())
            window.save()
        }
        let openIDs = Set(open.map { $0.windowID.uuidString + ".json" })
        for file in sessionFiles(in: profile.directory) where !openIDs.contains(file.lastPathComponent) {
            try FileManager.default.removeItem(at: file)
        }
        for extra in remaining {
            try JSONFile<WindowSessionSnapshot>(AppPaths.directory("Sessions", in: profile.directory).appendingPathComponent(UUID().uuidString + ".json")).write(extra)
        }
    }

    private static func mergedPreferences(_ current: Preferences, _ incoming: Preferences) -> Preferences {
        var merged = incoming
        merged.customEngines = current.customEngines + incoming.customEngines.filter { e in !current.customEngines.contains { $0.searchTemplate == e.searchTemplate } }
        merged.shortcuts = current.shortcuts + incoming.shortcuts.filter { s in !current.shortcuts.contains { $0.keyword == s.keyword } }
        merged.webFontExcludedHosts = Array(Set(current.webFontExcludedHosts + incoming.webFontExcludedHosts)).sorted()
        return merged
    }

    /// Installs prepared scripts. In replace mode, scripts that are not in the archive are removed,
    /// except those whose archived copy could not be prepared (they stay as they are).
    private static func installScripts(_ scripts: [PreparedScript], into store: UserScriptStore, replace: Bool, keeping failedNames: Set<String>,
                                       restoringBackup: Bool, archived: [ArchivedUserscript]) throws {
        if replace {
            let keep = Set(archived.map { $0.name + "\u{0}" + $0.namespace })
            for script in store.scripts where !keep.contains(script.metadata.name + "\u{0}" + script.metadata.namespace) { store.delete(script.id) }
        }
        // A backup restore re-installs from sources without re-downloading dependencies.
        let items: [PreparedScript] = restoringBackup
            ? archived.compactMap { item in item.source.map { PreparedScript(item: item, source: $0, deps: UserscriptDependencies.Result()) } }
            : scripts
        for prepared in items where !failedNames.contains(prepared.item.name) {
            let script = try store.install(source: prepared.source, sourceURL: prepared.item.sourceURL, requires: prepared.deps.requires,
                                           resources: prepared.deps.resources, enabled: prepared.item.enabled)
            if let values = prepared.item.values { store.replaceValues(values, for: script.id) }
        }
    }
}

/// Reference wrapper to pass a value type through NotificationCenter userInfo.
final class ArchiveBox { let archive: RikuganArchive; init(_ archive: RikuganArchive) { self.archive = archive } }

extension Notification.Name {
    static let rikuganImportPreview = Notification.Name("rikugan.importPreview")
}
