import SwiftUI

struct ShareQueueView: View {
    @EnvironmentObject private var model: AppModel
    @State private var items: [SharedItem] = []
    @State private var error: String?
    var body: some View {
        List {
            if let error { Text(error).foregroundStyle(.red) }
            if items.isEmpty { Text("没有待处理分享").foregroundStyle(.secondary) }
            ForEach(items) { item in
                VStack(alignment: .leading) {
                    Label(item.kind == .script ? "待确认用户脚本" : item.kind == .search ? "搜索文本" : "网页链接", systemImage: item.kind == .script ? "curlybraces" : "link")
                    Text(item.name.isEmpty ? String(item.value.prefix(150)) : item.name).font(.caption).lineLimit(3)
                }.swipeActions {
                    Button("移除", role: .destructive) { do { try model.discardShare(item.id); reload() } catch { self.error = error.localizedDescription } }
                }
            }
            if !items.isEmpty {
                Button("继续按顺序处理") { model.resumeShareQueue() }
                Text("脚本仅进入源码/权限确认，不会自动安装。取消确认会移除该项，再处理下一项。").font(.footnote)
            }
        }.navigationTitle("待处理分享").onAppear(perform: reload)
            .onChange(of: model.pendingShareCount) { _, _ in reload() }
    }
    private func reload() {
        do { items = try model.shareInbox.items(); error = nil }
        catch { self.error = error.localizedDescription }
    }
}
