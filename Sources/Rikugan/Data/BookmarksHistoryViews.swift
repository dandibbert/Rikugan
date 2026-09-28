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

    private var active: [DownloadItem] { downloads.items.filter { $0.state == .downloading || $0.state == .paused } }
    private var finished: [DownloadItem] { downloads.items.filter { $0.state != .downloading && $0.state != .paused } }

    var body: some View {
        List {
            if downloads.items.isEmpty {
                ContentUnavailableView("没有下载项", systemImage: "arrow.down.circle", description: Text("网页下载、长按链接下载和媒体面板下载会出现在这里。"))
            }
            if !active.isEmpty {
                Section("进行中") { ForEach(active) { DownloadRow(item: $0) } }
            }
            if !finished.isEmpty {
                Section("已完成") { ForEach(finished) { DownloadRow(item: $0) } }
            }
        }
        .navigationTitle("下载")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            ToolbarItem(placement: .topBarLeading) {
                Menu {
                    Button { openDownloadsFolder() } label: { Label("在“文件”中打开下载文件夹", systemImage: "folder") }
                    Button(role: .destructive) { downloads.clearFinished() } label: { Label("清除已完成的记录", systemImage: "trash") }
                } label: { Image(systemName: "ellipsis.circle") }
            }
        }
    }

    private func openDownloadsFolder() {
        // shareddocuments:// opens the Files app at a folder of this app's Documents.
        let path = AppPaths.downloads.path
        if let url = URL(string: "shareddocuments://" + (path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path)) {
            UIApplication.shared.open(url)
        }
    }
}

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    @EnvironmentObject private var downloads: DownloadManager

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous).fill(tint.opacity(0.15)).frame(width: 40, height: 40)
                Image(systemName: fileSymbol).foregroundStyle(tint).font(.system(size: 18))
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(item.fileName).font(.subheadline.weight(.medium)).lineLimit(2)
                switch item.state {
                case .downloading, .paused:
                    ProgressView(value: item.total > 0 ? item.fraction : nil).tint(tint)
                    Text(progressText).font(.caption2).foregroundStyle(.secondary).monospacedDigit()
                case .completed:
                    Text(subtitle(ByteCountFormatter.string(fromByteCount: item.total, countStyle: .file))).font(.caption2).foregroundStyle(.secondary)
                case .failed(let message):
                    Text("失败：\(message)").font(.caption2).foregroundStyle(.red).lineLimit(2)
                case .cancelled:
                    Text(subtitle("已取消")).font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            trailingButton
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .onTapGesture { if item.state == .completed { downloads.open(item) } }
        .contextMenu { menuItems }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) { downloads.remove(item, deleteFile: true) } label: { Label("删除", systemImage: "trash") }
        }
    }

    @ViewBuilder private var trailingButton: some View {
        switch item.state {
        case .downloading:
            Button { downloads.pause(item) } label: { Image(systemName: "pause.circle.fill").font(.title2) }.buttonStyle(.borderless)
        case .paused, .failed:
            Button { downloads.resume(item) } label: { Image(systemName: "arrow.clockwise.circle.fill").font(.title2) }.buttonStyle(.borderless)
        case .completed:
            Menu { menuItems } label: { Image(systemName: "ellipsis.circle").font(.title3) }
        case .cancelled:
            EmptyView()
        }
    }

    @ViewBuilder private var menuItems: some View {
        switch item.state {
        case .completed:
            Button { downloads.open(item) } label: { Label("打开", systemImage: "eye") }
            Button { downloads.share(item) } label: { Label("分享", systemImage: "square.and.arrow.up") }
            Button { downloads.saveToFiles(item) } label: { Label("存储到“文件”…", systemImage: "folder") }
        case .downloading:
            Button { downloads.pause(item) } label: { Label("暂停", systemImage: "pause") }
            Button(role: .destructive) { downloads.cancel(item) } label: { Label("取消", systemImage: "xmark") }
        case .paused, .failed:
            Button { downloads.resume(item) } label: { Label("继续", systemImage: "arrow.clockwise") }
        case .cancelled:
            EmptyView()
        }
        if let url = item.sourceURL {
            Button { UIPasteboard.general.url = url } label: { Label("拷贝下载地址", systemImage: "link") }
        }
        Button(role: .destructive) { downloads.remove(item, deleteFile: true) } label: { Label("删除", systemImage: "trash") }
    }

    private func subtitle(_ detail: String) -> String {
        var parts = [detail]
        if let host = item.sourceURL?.host { parts.append(host) }
        parts.append(item.startDate.formatted(date: .abbreviated, time: .shortened))
        return parts.joined(separator: " · ")
    }

    private var tint: Color {
        switch item.state {
        case .failed: return .red
        case .cancelled: return .gray
        default: return .accentColor
        }
    }

    private var fileSymbol: String {
        let ext = (item.fileName as NSString).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.richtext"
        case "zip", "rar", "7z", "gz", "tar", "crx": return "doc.zipper"
        case "jpg", "jpeg", "png", "gif", "webp", "heic", "svg": return "photo"
        case "mp4", "mov", "m4v", "webm", "mkv", "ts": return "film"
        case "mp3", "m4a", "aac", "wav", "flac", "ogg": return "music.note"
        case "md", "txt", "json", "js", "css", "html", "xml", "csv": return "doc.text"
        case "ttf", "otf", "woff", "woff2": return "textformat"
        default: return "doc"
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
