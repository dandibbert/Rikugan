import SwiftUI

/// Settings → Userscripts (spec §10).
struct UserscriptManagerView: View {
    @EnvironmentObject private var store: UserScriptStore
    @EnvironmentObject private var installer: UserscriptInstallCoordinator
    @Binding var importKind: BrowserView.ImportKind?
    @State private var showURLPrompt = false
    @State private var urlText = ""
    @State private var editorTarget: EditorTarget?
    @State private var checking = false
    @Environment(\.dismiss) private var dismiss

    struct EditorTarget: Identifiable { let id = UUID(); let script: InstalledUserScript?; let source: String }

    static let template = """
    // ==UserScript==
    // @name         新脚本
    // @namespace    https://rikugan.local/
    // @version      1.0
    // @description  描述
    // @match        https://*/*
    // @grant        none
    // @run-at       document-end
    // ==/UserScript==

    (function () {
        'use strict';

    })();
    """

    var body: some View {
        List {
            if store.scripts.isEmpty {
                Section {
                    Text("还没有用户脚本。打开任何 .user.js 链接，或从下方导入。").foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(store.scripts) { script in
                    NavigationLink { UserscriptDetailView(scriptID: script.id, editorTarget: $editorTarget) } label: { UserscriptRow(script: script) }
                        .swipeActions {
                            Button("删除", role: .destructive) { store.delete(script.id) }
                            Button("编辑") { editorTarget = EditorTarget(script: script, source: script.source) }.tint(Theme.color)
                        }
                }
                .onMove { store.move(from: $0, to: $1) }
            } footer: {
                if !store.scripts.isEmpty { Text("脚本按列表顺序注入。修改后刷新网页生效。") }
            }
            Section("添加") {
                Button("新建脚本") { editorTarget = EditorTarget(script: nil, source: Self.template) }
                Button("从剪贴板粘贴") {
                    if let text = UIPasteboard.general.string { installer.present(source: text, sourceURL: nil) }
                }
                Button("从网址安装…") { showURLPrompt = true }
                Button("从“文件”导入…") { importKind = .userscript }
            }
            Section {
                Button {
                    checking = true
                    Task {
                        let result = await UserscriptUpdater.checkAll(store)
                        checking = false
                        ToastCenter.shared.show("已更新 \(result.updated) 个脚本" + (result.failed > 0 ? "，\(result.failed) 个检查失败" : ""), symbol: "arrow.triangle.2.circlepath")
                    }
                } label: {
                    HStack { Text("检查全部更新"); Spacer(); if checking { ProgressView() } }
                }
                .disabled(checking || store.scripts.isEmpty)
                NavigationLink("GM API 兼容性") { CompatibilityView() }
            }
        }
        .navigationTitle("用户脚本")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
        }
        .alert("从网址安装", isPresented: $showURLPrompt) {
            TextField("https://…/script.user.js", text: $urlText).textInputAutocapitalization(.never).keyboardType(.URL)
            Button("取消", role: .cancel) {}
            Button("获取") { if let url = URL(string: urlText) { installer.beginInstall(from: url, tab: nil) }; urlText = "" }
        }
        .sheet(item: $editorTarget) { target in ScriptEditorSheet(target: target).environmentObject(store) }
    }
}

struct UserscriptRow: View {
    let script: InstalledUserScript
    @EnvironmentObject private var store: UserScriptStore

    var body: some View {
        HStack(spacing: 12) {
            ScriptIcon(url: script.metadata.icon)
            VStack(alignment: .leading, spacing: 3) {
                Text(script.name).font(.body.weight(.medium)).lineLimit(1)
                Text("v\(script.metadata.version) · \(matchSummary)").font(.subheadline).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Toggle("", isOn: Binding(get: { script.enabled }, set: { store.setEnabled(script.id, $0) })).labelsHidden()
        }
    }

    private var matchSummary: String {
        let all = script.metadata.matches + script.metadata.includes
        if all.isEmpty { return "不匹配任何网站" }
        return all.prefix(2).joined(separator: ", ") + (all.count > 2 ? " 等 \(all.count) 条" : "")
    }
}

struct ScriptIcon: View {
    let url: String?
    var size: CGFloat = 32
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(icon: "curlybraces.square.fill").resizable().scaledToFit().foregroundStyle(.orange)
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }
}

struct UserscriptDetailView: View {
    let scriptID: UUID
    @Binding var editorTarget: UserscriptManagerView.EditorTarget?
    @EnvironmentObject private var store: UserScriptStore
    @State private var status: String?
    @State private var busy = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        if let script = store.script(scriptID) {
            Form {
                Section {
                    ItemHeader(title: script.name, subtitle: script.metadata.description) {
                        ScriptIcon(url: script.metadata.icon, size: 44)
                    }
                    Toggle("启用", isOn: Binding(get: { script.enabled }, set: { store.setEnabled(script.id, $0) }))
                }
                Section {
                    LabeledContent("版本", value: script.metadata.version)
                    if !script.metadata.author.isEmpty { LabeledContent("作者", value: script.metadata.author) }
                    LabeledContent("运行时机", value: script.metadata.runAt.rawValue)
                    LabeledContent("运行环境", value: script.usesPageWorld ? "页面环境" : "隔离环境")
                    LabeledContent("上次更新", value: script.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    if let checked = script.lastUpdateCheck { LabeledContent("上次检查", value: checked.formatted(date: .abbreviated, time: .shortened)) }
                } footer: {
                    if !script.metadata.unavailableInPageWorld.isEmpty {
                        Text("此脚本以 @inject-into page 运行在页面环境，出于安全以下 API 不可用：" + script.metadata.unavailableInPageWorld.joined(separator: "、"))
                    } else {
                        Text(script.usesPageWorld ? "页面环境：unsafeWindow 就是网页窗口，没有特权 GM API。" : "隔离环境：可使用特权 GM API；unsafeWindow 看不到网页的 JS 全局变量。")
                    }
                }
                Section("来源") {
                    let links: [(String, String)] = [
                        ("安装来源", script.sourceURL ?? ""),
                        ("主页", script.metadata.homepage ?? ""),
                        ("更新地址", script.metadata.updateURL ?? ""),
                        ("下载地址", script.metadata.downloadURL ?? ""),
                    ].filter { !$0.1.isEmpty }
                    if links.isEmpty { Text("未记录（从文件、剪贴板或编辑器导入）").foregroundStyle(.secondary) }
                    ForEach(links, id: \.0) { title, link in LinkRow(title: title, value: link) { openInNewTab($0) } }
                }
                Section("匹配网站") {
                    ForEach(script.metadata.matches, id: \.self) { PatternRow(kind: "match", value: $0) }
                    ForEach(script.metadata.includes, id: \.self) { PatternRow(kind: "include", value: $0) }
                    ForEach(script.metadata.excludes + script.metadata.excludeMatches, id: \.self) { PatternRow(kind: "exclude", value: $0) }
                    if (script.metadata.matches + script.metadata.includes).isEmpty { Text("不匹配任何网站").foregroundStyle(.secondary) }
                }
                Section("权限") {
                    if script.metadata.grants.isEmpty || script.metadata.grantsNone { Text("无（@grant none）").foregroundStyle(.secondary) }
                    ForEach(script.metadata.grants.filter { $0 != "none" }, id: \.self) { grant in
                        LabeledContent {
                            if !GMCompatibility.supportedGrants.contains(grant) { Text("不支持").foregroundStyle(.red) }
                        } label: { Text(grant).font(.body.monospaced()) }
                    }
                    ForEach(script.metadata.connects, id: \.self) { PatternRow(kind: "connect", value: $0) }
                    if !script.metadata.requires.isEmpty { LabeledContent("@require 依赖", value: "\(script.metadata.requires.count) 个") }
                    if !script.metadata.resources.isEmpty { LabeledContent("@resource 资源", value: "\(script.metadata.resources.count) 个") }
                }
                Section {
                    Button("编辑脚本") { editorTarget = .init(script: script, source: script.source) }
                    Button {
                        busy = true
                        Task {
                            let outcome = await UserscriptUpdater.check(script, in: store)
                            busy = false
                            switch outcome {
                            case .upToDate: status = "已是最新版本"
                            case .updated(let version): status = "已更新到 \(version)"
                            case .noUpdateURL: status = "脚本没有 @updateURL / @downloadURL"
                            case .failed(let message): status = "检查失败：\(message)"
                            }
                        }
                    } label: { HStack { Text("检查更新"); Spacer(); if busy { ProgressView() } } }
                    .disabled(busy)
                    Button("重新安装") {
                        Task {
                            let outcome = await UserscriptUpdater.check(script, in: store, force: true)
                            if case .failed(let m) = outcome { status = "重新安装失败：\(m)" } else if case .noUpdateURL = outcome { status = "脚本没有下载地址" } else { status = "已重新安装" }
                        }
                    }
                    Button("导出 .user.js") { export(script) }
                } footer: {
                    if let status { Text(status) }
                }
                Section {
                    Button("清除脚本存储（\(store.values(for: script.id).count) 项）", role: .destructive) {
                        store.replaceValues([:], for: script.id); status = "已清除脚本存储"
                    }
                    Button("删除脚本", role: .destructive) { store.delete(script.id); dismiss() }
                }
            }
            .navigationTitle(script.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func export(_ script: InstalledUserScript) {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent(AppPaths.sanitize(script.name) + ".user.js")
        try? script.source.write(to: file, atomically: true, encoding: .utf8)
        Presenter.share([file])
    }
}

/// Script editor with line numbers, find, save and metadata diagnostics.
struct ScriptEditorSheet: View {
    let target: UserscriptManagerView.EditorTarget
    @EnvironmentObject private var store: UserScriptStore
    @Environment(\.dismiss) private var dismiss
    @State private var source = ""
    @State private var error: String?
    @State private var saving = false

    private var diagnostics: MetadataParser.Result { MetadataParser.parse(source) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !diagnostics.issues.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(diagnostics.issues) { issue in
                                Label("第 \(issue.line) 行：\(issue.message)", icon: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
                                    .font(.caption)
                                    .foregroundStyle(issue.severity == .error ? .red : .orange)
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .background(Color(.secondarySystemBackground), in: Capsule())
                            }
                        }
                        .padding(8)
                    }
                    Divider()
                }
                CodeEditorView(text: $source, highlightLines: Set(diagnostics.issues.filter { $0.severity == .error }.map(\.line)))
                    .ignoresSafeArea(.keyboard, edges: .bottom)
            }
            .navigationTitle(target.script?.name ?? "新脚本")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    if saving { ProgressView() } else { Button("保存") { save() }.disabled(diagnostics.hasErrors) }
                }
            }
            .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") {} } message: { Text(error ?? "") }
        }
        .onAppear { source = target.source }
        .interactiveDismissDisabled(source != target.source)
    }

    /// Downloads @require / @resource first; the new source is saved together with them, or not
    /// at all (the editor stays open with the error).
    private func save() {
        let text = source
        saving = true
        Task {
            defer { saving = false }
            do {
                let meta = MetadataParser.parse(text).metadata
                let deps = try await UserscriptDependencies.fetch(for: meta)
                if let script = target.script {
                    try store.updateSource(script.id, source: text, dependencies: deps)
                } else {
                    try store.install(source: text, sourceURL: nil, requires: deps.requires, resources: deps.resources)
                }
                dismiss()
            } catch {
                self.error = "脚本未保存：\(error.localizedDescription)"
            }
        }
    }
}

/// Install confirmation page shown when opening a `.user.js` (spec §6.1).
struct UserscriptInstallSheet: View {
    @EnvironmentObject private var installer: UserscriptInstallCoordinator
    @State private var installing = false
    @State private var error: String?
    @State private var showSource = false

    var body: some View {
        NavigationStack {
            if let pending = installer.pending {
                let meta = pending.result.metadata
                Form {
                    Section {
                        ItemHeader(title: meta.name.isEmpty ? "未命名脚本" : meta.name,
                                   subtitle: "版本 \(meta.version)" + (meta.author.isEmpty ? "" : " · \(meta.author)")) {
                            ScriptIcon(url: meta.icon, size: 44)
                        }
                        if !meta.description.isEmpty { Text(meta.description).foregroundStyle(.secondary) }
                        if let url = pending.sourceURL { LinkRow(title: "来源", value: url.absoluteString) }
                    } footer: {
                        if let existing = pending.existing {
                            Text("将\(MetadataParser.compareVersions(meta.version, existing.metadata.version) == .orderedDescending ? "更新" : "重新安装")已安装的 v\(existing.metadata.version)。")
                        }
                    }
                    if !pending.result.issues.isEmpty {
                        Section("检查结果") {
                            ForEach(pending.result.issues) { issue in
                                Text("第 \(issue.line) 行：\(issue.message)").foregroundStyle(issue.severity == .error ? .red : .orange)
                            }
                        }
                    }
                    Section("将在以下网站运行") {
                        ForEach(meta.matches, id: \.self) { PatternRow(kind: "match", value: $0) }
                        ForEach(meta.includes, id: \.self) { PatternRow(kind: "include", value: $0) }
                        if meta.matches.isEmpty && meta.includes.isEmpty { Text("无").foregroundStyle(.secondary) }
                    }
                    Section("请求的权限") {
                        if meta.grantsNone { Text("无（@grant none）").foregroundStyle(.secondary) }
                        ForEach(meta.grants.filter { $0 != "none" }, id: \.self) { Text($0).font(.body.monospaced()) }
                        ForEach(meta.connects, id: \.self) { PatternRow(kind: "connect", value: $0) }
                        if !meta.requires.isEmpty { LabeledContent("外部依赖（@require）", value: "\(meta.requires.count) 个") }
                    }
                    Section {
                        Button { showSource = true } label: { Text("查看源代码") }
                    }
                    if let error { Section { Text(error).foregroundStyle(.red) } }
                }
                .navigationTitle("安装用户脚本")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { installer.pending = nil } }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(installing ? "安装中…" : (pending.existing == nil ? "安装" : "更新")) {
                            installing = true
                            Task {
                                do { try await installer.confirm() } catch { self.error = error.localizedDescription }
                                installing = false
                            }
                        }
                        .disabled(pending.result.hasErrors || installing)
                        .accessibilityIdentifier("installUserscript")
                    }
                }
                .sheet(isPresented: $showSource) {
                    NavigationStack {
                        ScrollView { Text(pending.source).font(.footnote.monospaced()).textSelection(.enabled).padding().frame(maxWidth: .infinity, alignment: .leading) }
                            .navigationTitle("源代码").navigationBarTitleDisplayMode(.inline)
                            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { showSource = false } } }
                    }
                }
            }
        }
    }
}


extension UserscriptDetailView {
    /// Opens a link in a new tab of the focused window and closes the settings sheet.
    @MainActor func openInNewTab(_ url: URL) {
        guard let manager = TabRegistry.shared.focusedWindow ?? TabRegistry.shared.allWindows.first else { return }
        manager.newTab(url: url)
        NotificationCenter.default.post(name: .rikuganCloseSheet, object: manager)
    }
}


/// "@match https://example.com/*" as a quiet two-part row.
struct PatternRow: View {
    let kind: String
    let value: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("@" + kind).font(.footnote).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
            Text(value).font(.callout.monospaced()).foregroundStyle(kind == "exclude" ? .secondary : .primary).textSelection(.enabled)
        }
    }
}
