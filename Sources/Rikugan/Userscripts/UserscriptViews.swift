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
                            Button("编辑") { editorTarget = EditorTarget(script: script, source: script.source) }.tint(.blue)
                        }
                }
                .onMove { store.move(from: $0, to: $1) }
            } footer: {
                if !store.scripts.isEmpty { Text("脚本按列表顺序注入。修改后刷新网页生效。") }
            }
            Section("添加") {
                Button { editorTarget = EditorTarget(script: nil, source: Self.template) } label: { Label("新建脚本", systemImage: "square.and.pencil") }
                Button {
                    if let text = UIPasteboard.general.string { installer.present(source: text, sourceURL: nil) }
                } label: { Label("从剪贴板粘贴", systemImage: "doc.on.clipboard") }
                Button { showURLPrompt = true } label: { Label("从网址安装", systemImage: "link") }
                Button { importKind = .userscript } label: { Label("从“文件”导入", systemImage: "folder") }
            }
            Section {
                Button {
                    checking = true
                    Task {
                        let result = await UserscriptUpdater.checkAll(store)
                        checking = false
                        ToastCenter.shared.show("已更新 \(result.updated) 个脚本" + (result.failed > 0 ? "，\(result.failed) 个检查失败" : ""), symbol: "arrow.triangle.2.circlepath")
                    }
                } label: { HStack { Label("检查全部更新", systemImage: "arrow.triangle.2.circlepath"); if checking { Spacer(); ProgressView() } } }
                NavigationLink { CompatibilityView() } label: { Label("GM API 兼容性", systemImage: "checklist") }
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
                Text("v\(script.metadata.version) · \(matchSummary)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
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
    var body: some View {
        AsyncImage(url: url.flatMap(URL.init(string:))) { image in
            image.resizable().scaledToFit()
        } placeholder: {
            Image(systemName: "curlybraces.square.fill").resizable().scaledToFit().foregroundStyle(.orange)
        }
        .frame(width: 32, height: 32)
        .clipShape(RoundedRectangle(cornerRadius: 7))
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
                    HStack(spacing: 14) {
                        ScriptIcon(url: script.metadata.icon).frame(width: 48, height: 48)
                        VStack(alignment: .leading) {
                            Text(script.name).font(.headline)
                            Text(script.metadata.description).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Toggle("启用", isOn: Binding(get: { script.enabled }, set: { store.setEnabled(script.id, $0) }))
                    LabeledContent("版本", value: script.metadata.version)
                    if !script.metadata.author.isEmpty { LabeledContent("作者", value: script.metadata.author) }
                    LabeledContent("运行时机", value: script.metadata.runAt.rawValue)
                    LabeledContent("运行环境", value: script.usesPageWorld ? "页面环境（unsafeWindow 可用）" : "隔离环境")
                    LabeledContent("上次更新", value: script.updatedAt.formatted(date: .abbreviated, time: .shortened))
                    if let checked = script.lastUpdateCheck { LabeledContent("上次检查", value: checked.formatted(date: .abbreviated, time: .shortened)) }
                }
                Section("匹配网站") {
                    ForEach(script.metadata.matches, id: \.self) { Text("@match " + $0).font(.caption.monospaced()) }
                    ForEach(script.metadata.includes, id: \.self) { Text("@include " + $0).font(.caption.monospaced()) }
                    ForEach(script.metadata.excludes + script.metadata.excludeMatches, id: \.self) { Text("@exclude " + $0).font(.caption.monospaced()).foregroundStyle(.secondary) }
                }
                Section("权限") {
                    if script.metadata.grants.isEmpty || script.metadata.grantsNone { Text("@grant none（在页面环境运行，无特殊权限）").font(.caption) }
                    ForEach(script.metadata.grants.filter { $0 != "none" }, id: \.self) { grant in
                        HStack {
                            Text(grant).font(.caption.monospaced())
                            Spacer()
                            if !GMCompatibility.supportedGrants.contains(grant) { Text("不支持").font(.caption2).foregroundStyle(.red) }
                        }
                    }
                    ForEach(script.metadata.connects, id: \.self) { Text("@connect " + $0).font(.caption.monospaced()) }
                    if !script.metadata.requires.isEmpty { Text("\(script.metadata.requires.count) 个 @require 依赖").font(.caption) }
                    if !script.metadata.resources.isEmpty { Text("\(script.metadata.resources.count) 个 @resource 资源").font(.caption) }
                }
                Section {
                    Button { editorTarget = .init(script: script, source: script.source) } label: { Label("编辑", systemImage: "pencil") }
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
                    } label: { HStack { Label("检查更新", systemImage: "arrow.triangle.2.circlepath"); if busy { Spacer(); ProgressView() } } }
                    Button {
                        Task {
                            let outcome = await UserscriptUpdater.check(script, in: store, force: true)
                            if case .failed(let m) = outcome { status = "重新安装失败：\(m)" } else if case .noUpdateURL = outcome { status = "脚本没有下载地址" } else { status = "已重新安装" }
                        }
                    } label: { Label("重新安装", systemImage: "arrow.down.circle") }
                    Button { export(script) } label: { Label("导出 .user.js", systemImage: "square.and.arrow.up") }
                    Button(role: .destructive) { store.replaceValues([:], for: script.id); status = "已清除脚本存储" } label: { Label("清除脚本存储（\(store.values(for: script.id).count) 项）", systemImage: "externaldrive.badge.xmark") }
                    Button(role: .destructive) { store.delete(script.id); dismiss() } label: { Label("删除", systemImage: "trash") }
                }
                if let status { Section { Text(status).font(.footnote) } }
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

    private var diagnostics: MetadataParser.Result { MetadataParser.parse(source) }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                if !diagnostics.issues.isEmpty {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack {
                            ForEach(diagnostics.issues) { issue in
                                Label("第 \(issue.line) 行：\(issue.message)", systemImage: issue.severity == .error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
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
                ToolbarItem(placement: .confirmationAction) { Button("保存") { save() }.disabled(diagnostics.hasErrors) }
            }
            .alert("无法保存", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") {} } message: { Text(error ?? "") }
        }
        .onAppear { source = target.source }
        .interactiveDismissDisabled(source != target.source)
    }

    private func save() {
        do {
            if let script = target.script {
                try store.updateSource(script.id, source: source)
            } else {
                try store.install(source: source, sourceURL: nil, requires: [:], resources: [:])
            }
            Task {
                // Fetch any newly-added dependencies in the background.
                let meta = MetadataParser.parse(source).metadata
                if let deps = try? await UserscriptDependencies.fetch(for: meta),
                   var script = store.scripts.first(where: { $0.metadata.name == meta.name && $0.metadata.namespace == meta.namespace }) {
                    script.requireCode = deps.requires
                    script.resourceData = deps.resources
                    store.update(script)
                }
            }
            dismiss()
        } catch {
            self.error = error.localizedDescription
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
                        HStack(spacing: 14) {
                            ScriptIcon(url: meta.icon).frame(width: 52, height: 52)
                            VStack(alignment: .leading, spacing: 4) {
                                Text(meta.name.isEmpty ? "未命名脚本" : meta.name).font(.headline)
                                Text("版本 \(meta.version)" + (meta.author.isEmpty ? "" : " · \(meta.author)")).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if !meta.description.isEmpty { Text(meta.description).font(.subheadline) }
                        if let existing = pending.existing {
                            Label("将\(MetadataParser.compareVersions(meta.version, existing.metadata.version) == .orderedDescending ? "更新" : "重新安装")已安装的 v\(existing.metadata.version)",
                                  systemImage: "arrow.triangle.2.circlepath").font(.footnote).foregroundStyle(.orange)
                        }
                        if let url = pending.sourceURL { Text(url.absoluteString).font(.caption2).foregroundStyle(.secondary).lineLimit(2) }
                    }
                    if !pending.result.issues.isEmpty {
                        Section("检查结果") {
                            ForEach(pending.result.issues) { issue in
                                Label("第 \(issue.line) 行：\(issue.message)", systemImage: issue.severity == .error ? "xmark.octagon" : "exclamationmark.triangle")
                                    .font(.caption).foregroundStyle(issue.severity == .error ? .red : .orange)
                            }
                        }
                    }
                    Section("将在以下网站运行") {
                        ForEach(meta.matches + meta.includes, id: \.self) { Text($0).font(.caption.monospaced()) }
                        if meta.matches.isEmpty && meta.includes.isEmpty { Text("无").foregroundStyle(.secondary) }
                    }
                    Section("请求的权限") {
                        if meta.grantsNone { Text("无（@grant none）").font(.caption) }
                        ForEach(meta.grants.filter { $0 != "none" }, id: \.self) { Text($0).font(.caption.monospaced()) }
                        ForEach(meta.connects, id: \.self) { Text("可访问：\($0)").font(.caption) }
                        if !meta.requires.isEmpty { Text("将下载 \(meta.requires.count) 个外部依赖（@require）").font(.caption) }
                    }
                    Section {
                        Button { showSource = true } label: { Label("查看源代码", systemImage: "doc.text") }
                    }
                    if let error { Section { Text(error).foregroundStyle(.red).font(.footnote) } }
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
                        ScrollView { Text(pending.source).font(.caption.monospaced()).textSelection(.enabled).padding() }
                            .navigationTitle("源代码").navigationBarTitleDisplayMode(.inline)
                    }
                }
            }
        }
    }
}
