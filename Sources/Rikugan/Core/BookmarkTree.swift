import Foundation

/// Structural rules of the bookmark graph, shared by the store, the move UI and archive import:
/// unique IDs, every parent exists and is a folder, no cycles, the Favorites folder is a
/// top-level folder.
public enum BookmarkTree {
    /// Whether `candidate` is `ancestor` itself or lies below it.
    public static func isDescendant(_ candidate: UUID?, of ancestor: UUID, in nodes: [BookmarkNode]) -> Bool {
        let parents = Dictionary(nodes.map { ($0.id, $0.parentID) }, uniquingKeysWith: { a, _ in a })
        var cursor = candidate
        var steps = 0
        while let current = cursor, steps <= nodes.count {
            if current == ancestor { return true }
            cursor = parents[current] ?? nil
            steps += 1
        }
        return false
    }

    public static func problems(_ nodes: [BookmarkNode]) -> [String] {
        var problems: [String] = []
        let byID = Dictionary(nodes.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        if byID.count != nodes.count { problems.append("书签 ID 重复") }
        for node in nodes {
            guard let parent = node.parentID else { continue }
            guard let parentNode = byID[parent] else { problems.append("书签「\(node.title)」的父文件夹不存在"); continue }
            if !parentNode.isFolder { problems.append("书签「\(node.title)」的父项不是文件夹") }
        }
        // Cycle check: walking up from every node must reach the root within `count` steps.
        for node in nodes {
            var cursor = node.parentID
            var steps = 0
            while let current = cursor {
                steps += 1
                if current == node.id || steps > nodes.count { problems.append("书签文件夹「\(node.title)」形成了循环"); break }
                cursor = byID[current]?.parentID
            }
        }
        if let favorites = byID[BookmarkNode.favoritesID], !favorites.isFolder || favorites.parentID != nil {
            problems.append("“个人收藏”必须是顶层文件夹")
        }
        return Array(NSOrderedSet(array: problems).array as? [String] ?? problems)
    }

    /// Folders ordered so that every folder comes after its parent (roots first).
    public static func foldersParentFirst(_ nodes: [BookmarkNode]) -> [BookmarkNode] {
        let folders = nodes.filter(\.isFolder)
        let ids = Set(folders.map(\.id))
        var children: [UUID: [BookmarkNode]] = [:]
        var queue: [BookmarkNode] = []
        for folder in folders {
            if let parent = folder.parentID, ids.contains(parent) { children[parent, default: []].append(folder) } else { queue.append(folder) }
        }
        var ordered: [BookmarkNode] = []
        var index = 0
        while index < queue.count {
            let folder = queue[index]; index += 1
            ordered.append(folder)
            queue += children[folder.id] ?? []
        }
        return ordered
    }
}
