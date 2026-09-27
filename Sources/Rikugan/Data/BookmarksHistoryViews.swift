import SwiftUI

/// Bookmarks (spec §37) and History (spec §38).
struct BookmarksAndHistoryView: View {
    @State var initialTab: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("", selection: $initialTab) {
                    Text("书签").tag(0)
                    Text("历史记录").tag(1)
                }
                .pickerStyle(.segmented)
                .padding(.horizontal).padding(.vertical, 8)
                if initialTab == 0 { BookmarkFolderView(parent: nil, onOpen: { dismiss() }) } else { HistoryListView(onOpen: { dismiss() }) }
            }
            .navigationTitle(initialTab == 0 ? "书签" : "历史记录")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } } }
        }
    }
}

struct BookmarkFolderView: View {
    let parent: UUID?
    let onOpen: () -> Void
    @EnvironmentObject private var profile: ProfileContext
    @EnvironmentObject private var manager: TabManager
    @State private var search = ""
    @State private var editing: BookmarkNode?
    @State private var newFolder = false
    @State private var folderName = ""
    @State private var moving: BookmarkNode?

    private var nodes: [BookmarkNode] {
        search.isEmpty ? profile.bookmarks.children(of: parent) : profile.bookmarks.search(search, limit: 200)
    }

    var body: some View {
        List {
            ForEach(nodes) { node in
                Group {
                    if node.isFolder {
                        NavigationLink { BookmarkFolderView(parent: node.id, onOpen: onOpen).navigationTitle(node.title) } label: {
                            Label(node.title, systemImage: node.id == BookmarkNode.favoritesID ? "star" : "folder")
                        }
                    } else {
                        Button {
                            if let url = node.url.flatMap(URL.init(string:)) { (manager.activeTab ?? manager.newTab()).load(url); onOpen() }
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(node.title).foregroundStyle(.primary).lineLimit(1)
                                Text(node.url ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                        }
                    }
                }
                .swipeActions {
                    if node.id != BookmarkNode.favoritesID {
                        Button("删除", role: .destructive) { profile.bookmarks.delete(node) }
                        Button("编辑") { editing = node }.tint(.blue)
                        Button("移动") { moving = node }.tint(.orange)
                    }
                }
                .contextMenu {
                    if let url = node.url.flatMap(URL.init(string:)) {
                        Button { manager.newTab(url: url); onOpen() } label: { Label("在新标签页打开", systemImage: "plus.square.on.square") }
                        Button { manager.newTab(url: url, isPrivate: true); onOpen() } label: { Label("在无痕标签页打开", systemImage: "hand.raised") }
                        Button { UIPasteboard.general.url = url } label: { Label("拷贝链接", systemImage: "doc.on.doc") }
                    }
                }
            }
            .onMove { if search.isEmpty { profile.bookmarks.reorder(parent: parent, from: $0, to: $1) } }
            if nodes.isEmpty { Text(search.isEmpty ? "此文件夹为空" : "没有匹配的书签").foregroundStyle(.secondary) }
        }
        .searchable(text: $search, prompt: "搜索书签")
        .toolbar {
            ToolbarItemGroup(placement: .bottomBar) {
                Button("新建文件夹") { newFolder = true }
                Spacer()
                EditButton()
            }
        }
        .alert("新建文件夹", isPresented: $newFolder) {
            TextField("名称", text: $folderName)
            Button("取消", role: .cancel) {}
            Button("创建") { profile.bookmarks.add(title: folderName.isEmpty ? "新文件夹" : folderName, url: nil, parent: parent, isFolder: true); folderName = "" }
        }
        .sheet(item: $editing) { node in BookmarkEditor(node: node) }
        .sheet(item: $moving) { node in BookmarkMoveSheet(node: node) }
    }
}

struct BookmarkEditor: View {
    @State var node: BookmarkNode
    @EnvironmentObject private var profile: ProfileContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                TextField("标题", text: $node.title)
                if !node.isFolder {
                    TextField("网址", text: Binding(get: { node.url ?? "" }, set: { node.url = $0 })).keyboardType(.URL).textInputAutocapitalization(.never)
                }
            }
            .navigationTitle("编辑书签")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("保存") { profile.bookmarks.update(node); dismiss() } }
            }
        }
    }
}

struct BookmarkMoveSheet: View {
    let node: BookmarkNode
    @EnvironmentObject private var profile: ProfileContext
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button("书签（顶层）") { profile.bookmarks.move(node, to: nil); dismiss() }
                ForEach(profile.bookmarks.folders.filter { $0.id != node.id }) { folder in
                    Button { profile.bookmarks.move(node, to: folder.id); dismiss() } label: { Label(folder.title, systemImage: "folder") }
                }
            }
            .navigationTitle("移动到")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
    }
}

struct HistoryListView: View {
    let onOpen: () -> Void
    @EnvironmentObject private var profile: ProfileContext
    @EnvironmentObject private var manager: TabManager
    @State private var search = ""
    @State private var confirmClear = false

    var body: some View {
        List {
            if search.isEmpty {
                ForEach(profile.history.groupedByDay) { group in
                    Section {
                        ForEach(group.entries) { entry in row(entry) }
                    } header: {
                        HStack {
                            Text(group.day.formatted(date: .complete, time: .omitted))
                            Spacer()
                            Button("删除当天") { profile.history.delete(day: group.day) }.font(.caption)
                        }
                    }
                }
            } else {
                ForEach(profile.history.search(search, limit: 300)) { entry in row(entry) }
            }
            if profile.history.entries.isEmpty { Text("没有历史记录").foregroundStyle(.secondary) }
        }
        .searchable(text: $search, prompt: "搜索历史记录")
        .toolbar {
            ToolbarItem(placement: .bottomBar) { Button("清除全部…", role: .destructive) { confirmClear = true } }
        }
        .confirmationDialog("清除全部历史记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive) { profile.history.clearAll() }
        }
    }

    private func row(_ entry: HistoryEntry) -> some View {
        Button {
            if let url = URL(string: entry.url) { (manager.activeTab ?? manager.newTab()).load(url); onOpen() }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.title).foregroundStyle(.primary).lineLimit(1)
                Text("\(entry.visitedAt.formatted(date: .omitted, time: .shortened))  \(entry.url)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .swipeActions { Button("删除", role: .destructive) { profile.history.delete(entry) } }
    }
}

/// Download manager UI (spec §29).
struct DownloadsView: View {
    @EnvironmentObject private var downloads: DownloadManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            if downloads.items.isEmpty { Text("没有下载项").foregroundStyle(.secondary) }
            ForEach(downloads.items) { item in DownloadRow(item: item) }
        }
        .navigationTitle("下载")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            ToolbarItem(placement: .topBarLeading) { Button("清除已完成") { downloads.clearFinished() } }
        }
    }
}

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: symbol).foregroundStyle(.tint)
                Text(item.fileName).lineLimit(1)
                Spacer()
            }
            switch item.state {
            case .downloading, .paused:
                ProgressView(value: item.total > 0 ? item.fraction : nil)
                Text(progressText).font(.caption).foregroundStyle(.secondary)
            case .completed:
                Text(ByteCountFormatter.string(fromByteCount: item.total, countStyle: .file)).font(.caption).foregroundStyle(.secondary)
            case .failed(let message):
                Text("失败：\(message)").font(.caption).foregroundStyle(.red)
            case .cancelled:
                Text("已取消").font(.caption).foregroundStyle(.secondary)
            }
            HStack(spacing: 18) {
                switch item.state {
                case .downloading:
                    Button("暂停") { downloads.pause(item) }
                    Button("取消") { downloads.cancel(item) }
                case .paused, .failed:
                    Button("继续") { downloads.resume(item) }
                    Button("删除") { downloads.remove(item, deleteFile: true) }
                case .completed:
                    Button("打开") { downloads.open(item) }
                    Button("分享") { downloads.share(item) }
                    Button("存储到“文件”") { downloads.saveToFiles(item) }
                    Button("删除", role: .destructive) { downloads.remove(item, deleteFile: true) }
                case .cancelled:
                    Button("移除") { downloads.remove(item, deleteFile: true) }
                }
            }
            .buttonStyle(.borderless)
            .font(.caption)
        }
        .padding(.vertical, 4)
    }

    private var symbol: String {
        switch item.state {
        case .completed: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        case .paused: return "pause.circle"
        default: return "arrow.down.circle"
        }
    }

    private var progressText: String {
        let done = ByteCountFormatter.string(fromByteCount: item.received, countStyle: .file)
        var text = item.total > 0 ? "\(Int(item.fraction * 100))%  \(done) / \(ByteCountFormatter.string(fromByteCount: item.total, countStyle: .file))" : done
        if item.state == .paused { return text + "  已暂停" }
        if item.speed > 0 { text += "  \(ByteCountFormatter.string(fromByteCount: Int64(item.speed), countStyle: .file))/s" }
        if let remaining = item.remaining { text += "  剩余 \(Duration.seconds(remaining).formatted(.units(allowed: [.hours, .minutes, .seconds], width: .narrow, maximumUnitCount: 2)))" }
        return text
    }
}
