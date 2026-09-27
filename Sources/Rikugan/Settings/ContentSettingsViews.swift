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
                                .font(.caption).foregroundStyle(.secondary)
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
                Text("密码、个人信息和支付卡保存在本机钥匙串（Keychain）中，不写入 UserDefaults，查看前需要面容 ID / 密码验证。")
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
                    .onDelete { idx in idx.map { autofill.credentials[$0] }.forEach { autofill.delete($0) } }
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
                    Button("保存个人信息") { autofill.saveProfile(); ToastCenter.shared.show("已保存", symbol: "checkmark") }
                }
                Section("支付卡") {
                    ForEach(autofill.cards) { c in Text("\(c.nickname.isEmpty ? "卡片" : c.nickname)  \(c.masked)  \(c.expMonth)/\(c.expYear)") }
                        .onDelete { idx in idx.map { autofill.cards[$0] }.forEach { autofill.delete($0) } }
                    TextField("备注名", text: $card.nickname)
                    TextField("持卡人", text: $card.cardName)
                    TextField("卡号", text: $card.cardNumber).keyboardType(.numberPad)
                    HStack {
                        TextField("月 MM", text: $card.expMonth).keyboardType(.numberPad)
                        TextField("年 YYYY", text: $card.expYear).keyboardType(.numberPad)
                    }
                    Button("添加支付卡") { autofill.save(card); card = PaymentCard() }.disabled(card.cardNumber.count < 12)
                }
            } else {
                Button { Task { unlocked = await Keychain.authenticate(reason: "查看保存的密码与支付信息") } } label: { Label("解锁以查看", systemImage: "lock") }
            }
        }
        .navigationTitle("密码与自动填充")
    }
}

// MARK: - Profiles (spec §36)

struct ProfilesView: View {
    @EnvironmentObject private var services: AppServices
    @State private var name = ""
    @State private var symbol = "briefcase"
    private let symbols = ["person.crop.circle", "briefcase", "hammer", "gamecontroller", "house", "graduationcap", "cart", "flask"]

    var body: some View {
        Form {
            Section {
                ForEach(services.profiles.profiles) { info in
                    Button {
                        services.profiles.switchTo(info.id)
                    } label: {
                        HStack {
                            Label(info.name, systemImage: info.symbol)
                            Spacer()
                            if info.id == services.profile.id { Image(systemName: "checkmark").foregroundStyle(.tint) }
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
                Picker("图标", selection: $symbol) { ForEach(symbols, id: \.self) { Image(systemName: $0).tag($0) } }
                Button("创建") { services.profiles.create(name: name.isEmpty ? "新身份" : name, symbol: symbol); name = "" }
            }
        }
        .navigationTitle("身份")
    }
}

// MARK: - Import / export (spec §39)

struct ImportExportView: View {
    @EnvironmentObject private var manager: TabManager
    @Binding var importKind: BrowserView.ImportKind?

    var body: some View {
        Form {
            Section {
                Button { ImportExport.exportAll(from: manager) } label: { Label("导出设置、标签页与分组", systemImage: "square.and.arrow.up") }
                Button { importKind = .settings } label: { Label("从文件导入", systemImage: "square.and.arrow.down") }
            } footer: {
                Text("导出文件包含：所有窗口的标签页（含标签页组和浏览历史状态）、偏好设置、网站设置、书签、内容拦截规则与订阅、用户脚本及其存储值。不包含密码和支付卡。导入时标签页会追加到当前窗口。")
            }
        }
        .navigationTitle("导入与导出")
    }
}

@MainActor enum ImportExport {
    static func exportAll(from manager: TabManager) {
        let services = AppServices.shared
        let profile = services.profile
        for window in TabRegistry.shared.allWindows { window.save() }
        var sessions = TabRegistry.shared.allWindows.map(\.sessionSnapshot)
        if sessions.isEmpty { sessions = [manager.sessionSnapshot] }
        let bundle = ExportBundle(preferences: services.prefs, sessions: sessions, siteSettings: Array(profile.siteSettings.sites.values),
                                  bookmarks: profile.bookmarks.nodes, adBlockCustomRules: services.adBlock.customRules,
                                  adBlockSubscriptions: services.adBlock.subscriptions, adBlockAllowlist: services.adBlock.allowlist,
                                  userscripts: profile.userscripts.exported)
        do {
            let data = try ExportBundle.encoder().encode(bundle)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd-HHmm"
            let file = FileManager.default.temporaryDirectory.appendingPathComponent("Rikugan-\(formatter.string(from: Date())).json")
            try data.write(to: file)
            Presenter.share([file])
        } catch {
            ToastCenter.shared.show("导出失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }

    static func importBundle(from url: URL, into manager: TabManager) {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let bundle = try ExportBundle.decode(try Data(contentsOf: url))
            let services = AppServices.shared
            let profile = services.profile
            services.prefs = bundle.preferences
            profile.siteSettings.replaceAll(bundle.siteSettings)
            if !bundle.bookmarks.isEmpty { profile.bookmarks.replaceAll(bundle.bookmarks) }
            services.adBlock.replaceState(customRules: bundle.adBlockCustomRules, subscriptions: bundle.adBlockSubscriptions, allowlist: bundle.adBlockAllowlist)
            for session in bundle.sessions { manager.importSession(session) }
            Task { await profile.userscripts.importScripts(bundle.userscripts) }
            ToastCenter.shared.show("已导入 \(bundle.sessions.reduce(0) { $0 + $1.tabs.count }) 个标签页和设置", symbol: "checkmark.circle")
        } catch {
            ToastCenter.shared.show("导入失败：\(error.localizedDescription)", symbol: "exclamationmark.triangle")
        }
    }
}
