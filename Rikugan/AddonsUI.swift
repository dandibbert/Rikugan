import SwiftUI
import UniformTypeIdentifiers
import WebKit

struct AddonsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var session: BrowserSession
    @State private var kind = 0
    @State private var importFile = false
    @State private var enterURL = false
    @State private var scriptURL = ""
    @State private var confirmDemo = false
    @State private var toggling = Set<UUID>()
    var body: some View {
        NavigationStack {
            List {
                Picker("组件类型", selection: $kind) { Text("浏览器扩展").tag(0); Text("用户脚本").tag(1) }.pickerStyle(.segmented)
                if kind == 0 {
                    Section {
                        if model.profile.extensions.isEmpty {
                            ContentUnavailableView("把常用扩展带进来", systemImage: "puzzlepiece.extension", description: Text("从文件导入 WebExtension ZIP 或已解压文件夹。根目录需要包含 manifest.json。"))
                        }
                        ForEach(model.profile.extensions) { record in
                            VStack(alignment: .leading, spacing: 12) {
                                NavigationLink { ExtensionDetails(recordID: record.id, session: session, onClose: { dismiss() }) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: "puzzlepiece.extension.fill").font(.title2).foregroundStyle(.indigo)
                                        VStack(alignment: .leading, spacing: 4) { Text(record.name).font(.headline); Text(record.version).font(.caption).foregroundStyle(.secondary) }
                                    }
                                }
                                HStack {
                                    Button("打开扩展", systemImage: "arrow.up.forward.app") { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { session.performExtension(record.id) } }
                                        .font(.subheadline).buttonStyle(.bordered).disabled(!record.enabled || session.contexts[record.id] == nil)
                                        .accessibilityIdentifier("extension.run.\(record.name)")
                                    Spacer()
                                    Toggle("启用", isOn: Binding(get: { record.enabled }, set: { enabled in
                                        toggling.insert(record.id)
                                        Task { await session.toggleExtension(record, enabled: enabled); toggling.remove(record.id) }
                                    })).labelsHidden().disabled(toggling.contains(record.id)).accessibilityLabel("启用 " + record.name)
                                }
                                if let error = session.extensionErrors[record.id] { Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled) }
                            }.padding(.vertical, 5)
                        }
                    } footer: { Text("兼容性取决于 iOS 的 WebKit 扩展 API。桌面 Chrome 的全部扩展不保证可用。安装或更改扩展后，请刷新目标页面。") }
                } else {
                    Section {
                        if model.profile.scripts.isEmpty {
                            ContentUnavailableView("让网页按你的方式工作", systemImage: "curlybraces", description: Text("导入 .user.js、粘贴 HTTPS 直链，或创建自己的脚本。"))
                        }
                        ForEach(model.profile.scripts) { script in
                            HStack {
                                Button { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.scriptDraft = ScriptDraft(source: script.source, existingID: script.id) } } label: {
                                    VStack(alignment: .leading, spacing: 4) { Text(script.name).font(.headline); Text(script.matches.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary).lineLimit(2); Text(script.isolated ? "隔离环境 · \(script.runAt)" : "页面环境 · \(script.runAt)").font(.caption2).foregroundStyle(.secondary) }
                                }.buttonStyle(.plain)
                                Spacer()
                                Toggle("启用", isOn: Binding(get: { script.enabled }, set: { enabled in
                                    model.updateProfile(session.profileID) { profile in if let index = profile.scripts.firstIndex(where: { $0.id == script.id }) { profile.scripts[index].enabled = enabled } }
                                    session.commands.removeAll { $0.scriptID == script.id }; session.refreshScripts()
                                })).labelsHidden().accessibilityLabel("启用 " + script.name)
                            }.swipeActions { Button("删除", role: .destructive) {
                                model.updateProfile(session.profileID) { $0.scripts.removeAll { $0.id == script.id } }; session.commands.removeAll { $0.scriptID == script.id }; session.refreshScripts()
                            } }
                        }
                    } footer: { Text("脚本只在匹配的网站运行。GM 存储按身份和脚本隔离。保存、启停或删除后请刷新已打开的页面。") }
                }
                Section("添加组件") {
                    Button("从文件导入", systemImage: "square.and.arrow.down") { importFile = true }.accessibilityIdentifier("addons.import")
                    Button("从网址导入用户脚本", systemImage: "link") { enterURL = true }
                    Button("新建用户脚本", systemImage: "square.and.pencil") {
                        dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.scriptDraft = ScriptDraft(source: ScriptEditor.template) }
                    }
                }
                Section {
                    Button("安装功能自检示例", systemImage: "checkmark.seal") { confirmDemo = true }.accessibilityIdentifier("addons.demo")
                    Text("示例只匹配 example.com 和本机测试站点，用于检查脚本注入、GM 存储、扩展后台通信、storage 与弹窗。").font(.caption).foregroundStyle(.secondary)
                }
            }.navigationTitle("扩展与脚本")
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("完成") { dismiss() }.accessibilityIdentifier("addons.done") } }
                .fileImporter(isPresented: $importFile, allowedContentTypes: [.zip, .javaScript, .plainText, .folder, .data], allowsMultipleSelection: false) { result in
                    switch result {
                    case .success(let urls): if let url = urls.first { dismiss(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { model.handleFile(url) } }
                    case .failure(let error): model.message = error.localizedDescription
                    }
                }
                .alert("用户脚本直链", isPresented: $enterURL) {
                    TextField("https://…/script.user.js", text: $scriptURL).textInputAutocapitalization(.never).autocorrectionDisabled()
                    Button("取消", role: .cancel) {}
                    Button("读取") { dismiss(); Task { try? await Task.sleep(nanoseconds: 350_000_000); await model.importScriptURL(scriptURL) } }
                } message: { Text("先读取并展示源码与权限，不会自动执行。") }
                .alert("安装自检组件？", isPresented: $confirmDemo) {
                    Button("取消", role: .cancel) {}
                    Button("安装示例") { Task { await model.installDemos() } }
                } message: { Text("将安装一个示例扩展和一个示例脚本。扩展申请 tabs、storage，以及 example.com 和 127.0.0.1 测试页访问权限。") }
        }
    }
}

struct ExtensionDetails: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let recordID: UUID
    @ObservedObject var session: BrowserSession
    var onClose: () -> Void
    @State private var deleting = false
    var body: some View {
        Group {
            if let record = model.profile.extensions.first(where: { $0.id == recordID }) {
                Form {
                    Section { Text(record.name).font(.title2.bold()); Text(record.detail).foregroundStyle(.secondary); LabeledContent("版本", value: record.version) }
                    Section("功能") {
                        Button("打开扩展弹窗") { onClose(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { session.performExtension(record.id) } }.disabled(session.contexts[record.id] == nil)
                        Button("打开扩展设置页") { onClose(); DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { session.openOptions(record.id) } }.disabled(session.contexts[record.id]?.optionsPageURL == nil)
                    }
                    Section("网站权限") {
                        if record.requestedPatterns.isEmpty { Text("未申请固定网站权限").foregroundStyle(.secondary) }
                        ForEach(record.requestedPatterns, id: \.self) { pattern in
                            Toggle(pattern, isOn: Binding(get: { record.allowedPatterns.contains(pattern) }, set: { session.setHostPermission(pattern, record: record, allowed: $0) })).font(.subheadline)
                        }
                    }
                    Section("已授权 API") { ForEach(record.allowedPermissions, id: \.self) { Text($0).font(.system(.footnote, design: .monospaced)) } }
                    if let context = session.contexts[record.id], !context.errors.isEmpty { Section("运行时诊断") { Text(context.errors.map(\.localizedDescription).joined(separator: "\n")).font(.footnote).textSelection(.enabled) } }
                    if let error = session.extensionErrors[record.id] { Section("加载错误") { Text(error).font(.footnote).foregroundStyle(.red).textSelection(.enabled) } }
                    Section { Button("删除扩展", role: .destructive) { deleting = true } }
                }.navigationTitle("扩展详情").navigationBarTitleDisplayMode(.inline)
                    .confirmationDialog("删除扩展和本身份中的扩展数据？", isPresented: $deleting, titleVisibility: .visible) { Button("删除", role: .destructive) { session.removeExtension(record); dismiss() } }
            } else { ContentUnavailableView("扩展已删除", systemImage: "puzzlepiece.extension") }
        }
    }
}

struct ExtensionInstaller: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let prepared: PreparedExtension
    @State private var installed = false
    @State private var error: String?
    var body: some View {
        NavigationStack {
            List {
                Section { Label(prepared.name, systemImage: "puzzlepiece.extension.fill").font(.title2.bold()); Text(prepared.webExtension.displayDescription ?? "").foregroundStyle(.secondary) }
                Section("将获得以下 API 权限") {
                    if prepared.permissions.isEmpty { Text("无额外 API 权限") }
                    ForEach(prepared.permissions, id: \.self) { Text($0).font(.system(.subheadline, design: .monospaced)) }
                }
                Section("可读取和更改以下网站") {
                    if prepared.patterns.isEmpty { Text("未申请固定网站权限") }
                    ForEach(prepared.patterns, id: \.self) { Text($0).font(.footnote).textSelection(.enabled) }
                }
                if !prepared.warnings.isEmpty { Section("WebKit 诊断") { Text(prepared.warnings).font(.footnote).foregroundStyle(.orange) } }
                Section { Text("只安装你信任的扩展。扩展能读取获授权页面上的内容，包括你登录后看到的信息。安装仅影响当前身份。此版本不验证扩展商店签名，也不自动更新扩展。").font(.footnote).foregroundStyle(.secondary) }
            }.navigationTitle("安装扩展").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("允许并安装") {
                        do { try model.session?.installExtension(prepared); installed = true; dismiss() } catch { self.error = error.localizedDescription }
                    }.bold() }
                }
                .alert("安装失败", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
                .onDisappear { if !installed { model.session?.discardExtension(prepared) } }
        }
    }
}

struct ScriptEditor: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let draft: ScriptDraft
    @State private var source: String
    @State private var selection = 0
    @State private var saving = false
    @State private var error: String?
    init(draft: ScriptDraft) { self.draft = draft; _source = State(initialValue: draft.source) }
    var parsed: UserScript? { try? UserScript.parse(source) }
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("编辑模式", selection: $selection) { Text("说明与权限").tag(0); Text("源代码").tag(1) }.pickerStyle(.segmented).padding()
                if selection == 1 {
                    TextEditor(text: $source).font(.system(size: 12, design: .monospaced)).textInputAutocapitalization(.never).autocorrectionDisabled().accessibilityIdentifier("script.source")
                } else {
                    Form {
                        if let script = parsed {
                            Section { Text(script.name).font(.title2.bold()); Text(script.description).foregroundStyle(.secondary); LabeledContent("版本", value: script.version); LabeledContent("注入时机", value: script.runAt); LabeledContent("运行环境", value: script.isolated ? "脚本独立隔离环境" : "网页环境（@grant none）") }
                            Section("匹配的网站") { ForEach(script.matches + script.includes, id: \.self) { Text($0).font(.footnote).textSelection(.enabled) } }
                            Section("脚本权限") { ForEach(script.grants, id: \.self) { Text($0).font(.system(.footnote, design: .monospaced)) }; if script.grants.isEmpty { Text("没有原生权限") } }
                            if !script.connects.isEmpty { Section("跨域网络 @connect") { ForEach(script.connects, id: \.self) { Text($0).font(.footnote) } } }
                            if !script.requires.isEmpty { Section("安装时下载的 @require 依赖") { ForEach(script.requires, id: \.self) { Text($0).font(.footnote).textSelection(.enabled) } } }
                        } else { Text("元数据或权限声明暂不支持。打开源代码修改，保存时会显示具体原因。").foregroundStyle(.orange) }
                        Section { Text("只运行可信源码。页面环境中的脚本可以访问页面 JavaScript；带 GM 原生权限的脚本保持隔离。保存后刷新网页生效，不会自动更新脚本。").font(.footnote).foregroundStyle(.secondary) }
                    }
                }
            }.navigationTitle(draft.existingID == nil ? "安装用户脚本" : "编辑用户脚本").navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() }.disabled(saving) }
                    ToolbarItem(placement: .confirmationAction) { Button(saving ? "保存中…" : (draft.existingID == nil ? "保存并启用" : "保存")) {
                        saving = true
                        Task { do { try await model.installScript(source, existingID: draft.existingID); dismiss() } catch { self.error = error.localizedDescription }; saving = false }
                    }.bold().disabled(saving) }
                }
                .interactiveDismissDisabled(saving)
                .alert("未能保存脚本", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) { Button("好") { error = nil } } message: { Text(error ?? "") }
        }
    }
    static let template = """
    // ==UserScript==
    // @name         我的脚本
    // @version      1.0
    // @description  在指定网页运行
    // @match        https://example.com/*
    // @run-at       document-end
    // @grant        none
    // ==/UserScript==

    document.body.style.fontFamily = 'system-ui';
    """
}
