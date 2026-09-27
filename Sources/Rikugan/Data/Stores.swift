import Foundation
import Combine

struct HistoryEntry: Codable, Identifiable, Hashable {
    var id = UUID()
    var url: String
    var title: String
    var visitedAt: Date
    var visitCount: Int = 1
}

/// Browsing history (per profile). Private tabs never write here.
@MainActor final class HistoryStore: ObservableObject {
    @Published private(set) var entries: [HistoryEntry] = []
    @Published private(set) var searchHistory: [String] = []
    private let file: JSONFile<[HistoryEntry]>
    private let searchFile: JSONFile<[String]>
    static let limit = 5000

    init(directory: URL) {
        file = JSONFile(directory.appendingPathComponent("history.json"))
        searchFile = JSONFile(directory.appendingPathComponent("search-history.json"))
        entries = file.load() ?? []
        searchHistory = searchFile.load() ?? []
    }

    func record(url: URL, title: String) {
        guard ["http", "https"].contains(url.scheme ?? "") else { return }
        let key = url.absoluteString
        var count = 1
        if let index = entries.firstIndex(where: { $0.url == key && Calendar.current.isDateInToday($0.visitedAt) }) {
            count = entries[index].visitCount + 1
            entries.remove(at: index)
        } else if let previous = entries.first(where: { $0.url == key }) {
            count = previous.visitCount + 1
        }
        entries.insert(HistoryEntry(url: key, title: title.isEmpty ? (url.host ?? key) : title, visitedAt: Date(), visitCount: count), at: 0)
        if entries.count > Self.limit { entries.removeLast(entries.count - Self.limit) }
        file.save(entries)
    }

    func updateTitle(url: URL, title: String) {
        guard !title.isEmpty, let index = entries.firstIndex(where: { $0.url == url.absoluteString }), entries[index].title != title else { return }
        entries[index].title = title
        file.save(entries)
    }

    func recordSearch(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        searchHistory.removeAll { $0 == q }
        searchHistory.insert(q, at: 0)
        searchHistory = Array(searchHistory.prefix(200))
        searchFile.save(searchHistory)
    }

    func delete(_ entry: HistoryEntry) { entries.removeAll { $0.id == entry.id }; file.save(entries) }

    func delete(day: Date) {
        entries.removeAll { Calendar.current.isDate($0.visitedAt, inSameDayAs: day) }
        file.save(entries)
    }

    func clearAll() {
        entries.removeAll(); searchHistory.removeAll()
        file.save(entries, immediately: true); searchFile.save(searchHistory, immediately: true)
    }

    func search(_ text: String, limit: Int = 8) -> [HistoryEntry] {
        let q = text.lowercased()
        guard !q.isEmpty else { return [] }
        var seen = Set<String>()
        return entries.filter { entry in
            guard entry.url.lowercased().contains(q) || entry.title.lowercased().contains(q) else { return false }
            return seen.insert(entry.url).inserted
        }.sorted { $0.visitCount > $1.visitCount }.prefix(limit).map { $0 }
    }

    /// Frequently visited sites for the homepage (grouped by host).
    func frequentlyVisited(limit: Int = 8) -> [HistoryEntry] {
        var byHost: [String: (HistoryEntry, Int)] = [:]
        for entry in entries.prefix(2000) {
            guard let host = URL(string: entry.url)?.host else { continue }
            let current = byHost[host]
            byHost[host] = (current?.0 ?? entry, (current?.1 ?? 0) + entry.visitCount)
        }
        return byHost.values.sorted { $0.1 > $1.1 }.prefix(limit).map { $0.0 }
    }

    struct Day: Identifiable {
        let day: Date
        let entries: [HistoryEntry]
        var id: Date { day }
    }

    var groupedByDay: [Day] {
        let groups = Dictionary(grouping: entries) { Calendar.current.startOfDay(for: $0.visitedAt) }
        return groups.keys.sorted(by: >).map { Day(day: $0, entries: groups[$0]!.sorted { $0.visitedAt > $1.visitedAt }) }
    }
}

/// Bookmarks with folders (per profile).
@MainActor final class BookmarkStore: ObservableObject {
    @Published private(set) var nodes: [BookmarkNode] = []
    private let file: JSONFile<[BookmarkNode]>

    init(directory: URL) {
        file = JSONFile(directory.appendingPathComponent("bookmarks.json"))
        nodes = file.load() ?? []
        if !nodes.contains(where: { $0.id == BookmarkNode.favoritesID }) {
            nodes.insert(BookmarkNode(id: BookmarkNode.favoritesID, title: "个人收藏", url: nil, parentID: nil, isFolder: true), at: 0)
            save()
        }
    }

    func children(of parent: UUID?) -> [BookmarkNode] {
        nodes.filter { $0.parentID == parent }.sorted { ($0.isFolder ? 0 : 1, $0.order) < ($1.isFolder ? 0 : 1, $1.order) }
    }

    var favorites: [BookmarkNode] { children(of: BookmarkNode.favoritesID).filter { !$0.isFolder } }
    var folders: [BookmarkNode] { nodes.filter(\.isFolder) }

    func contains(url: URL) -> Bool { nodes.contains { $0.url == url.absoluteString } }

    @discardableResult
    func add(title: String, url: String?, parent: UUID?, isFolder: Bool = false) -> BookmarkNode {
        let order = (children(of: parent).map(\.order).max() ?? -1) + 1
        let node = BookmarkNode(title: title, url: url, parentID: parent, isFolder: isFolder, order: order)
        nodes.append(node)
        save()
        return node
    }

    func update(_ node: BookmarkNode) {
        guard let index = nodes.firstIndex(where: { $0.id == node.id }) else { return }
        nodes[index] = node
        save()
    }

    func move(_ node: BookmarkNode, to parent: UUID?) {
        guard node.id != parent else { return }
        var copy = node
        copy.parentID = parent
        copy.order = (children(of: parent).map(\.order).max() ?? -1) + 1
        update(copy)
    }

    func reorder(parent: UUID?, from source: IndexSet, to destination: Int) {
        var list = children(of: parent)
        list.move(fromOffsets: source, toOffset: destination)
        for (i, var node) in list.enumerated() { node.order = i; if let idx = nodes.firstIndex(where: { $0.id == node.id }) { nodes[idx] = node } }
        save()
    }

    func delete(_ node: BookmarkNode) {
        guard node.id != BookmarkNode.favoritesID else { return }
        var remove: Set<UUID> = [node.id]
        var changed = true
        while changed {
            changed = false
            for n in nodes where n.parentID.map(remove.contains) == true && !remove.contains(n.id) { remove.insert(n.id); changed = true }
        }
        nodes.removeAll { remove.contains($0.id) }
        save()
    }

    func search(_ text: String, limit: Int = 6) -> [BookmarkNode] {
        let q = text.lowercased()
        guard !q.isEmpty else { return [] }
        return nodes.filter { !$0.isFolder && ($0.title.lowercased().contains(q) || ($0.url ?? "").lowercased().contains(q)) }.prefix(limit).map { $0 }
    }

    func replaceAll(_ newNodes: [BookmarkNode]) {
        nodes = newNodes
        if !nodes.contains(where: { $0.id == BookmarkNode.favoritesID }) {
            nodes.insert(BookmarkNode(id: BookmarkNode.favoritesID, title: "个人收藏", url: nil, parentID: nil, isFolder: true), at: 0)
        }
        save()
    }

    private func save() { file.save(nodes) }
}

/// Per-host settings store.
@MainActor final class SiteSettingsStore: ObservableObject {
    @Published private(set) var sites: [String: SiteSettings] = [:]
    private let file: JSONFile<[String: SiteSettings]>

    init(directory: URL) {
        file = JSONFile(directory.appendingPathComponent("site-settings.json"))
        sites = file.load() ?? [:]
    }

    /// Settings for a host, falling back to parent domains (e.g. m.example.com → example.com).
    func settings(for host: String?) -> SiteSettings {
        guard let host = host?.lowercased(), !host.isEmpty else { return SiteSettings(host: "") }
        for suffix in DomainTools.suffixes(of: host) {
            if let s = sites[suffix] { return s }
        }
        return SiteSettings(host: host)
    }

    func update(_ host: String, _ change: (inout SiteSettings) -> Void) {
        let key = host.lowercased()
        var value = sites[key] ?? SiteSettings(host: key)
        change(&value)
        if value.isEmpty { sites.removeValue(forKey: key) } else { sites[key] = value }
        file.save(sites)
    }

    func remove(_ host: String) { sites.removeValue(forKey: host); file.save(sites) }

    func replaceAll(_ list: [SiteSettings]) {
        sites = Dictionary(list.map { ($0.host, $0) }, uniquingKeysWith: { a, _ in a })
        file.save(sites)
    }
}

// MARK: - Autofill (Keychain backed)

struct SavedCredential: Codable, Identifiable, Hashable {
    var id = UUID()
    var host: String
    var username: String
    var password: String
    var updatedAt = Date()
}

struct AutofillProfile: Codable, Hashable {
    var name = "", givenName = "", familyName = "", email = "", phone = "", organization = ""
    var street = "", city = "", region = "", postalCode = "", country = ""
    var dictionary: [String: String] {
        ["name": name, "givenName": givenName, "familyName": familyName, "email": email, "phone": phone, "organization": organization,
         "street": street, "city": city, "region": region, "postalCode": postalCode, "country": country]
    }
}

struct PaymentCard: Codable, Identifiable, Hashable {
    var id = UUID()
    var cardName = "", cardNumber = "", expMonth = "", expYear = "", nickname = ""
    var masked: String { "•••• " + String(cardNumber.filter(\.isNumber).suffix(4)) }
    var dictionary: [String: String] { ["cardName": cardName, "cardNumber": cardNumber, "expMonth": expMonth, "expYear": expYear] }
}

/// Stores credentials, personal info and cards in the Keychain (spec §40).
@MainActor final class AutofillStore: ObservableObject {
    @Published private(set) var credentials: [SavedCredential] = []
    @Published var profile = AutofillProfile()
    @Published private(set) var cards: [PaymentCard] = []

    init() {
        credentials = Self.read("credentials") ?? []
        profile = Self.read("profile") ?? AutofillProfile()
        cards = Self.read("cards") ?? []
    }

    private static func read<T: Decodable>(_ account: String) -> T? {
        guard let data = Keychain.get(account: account) else { return nil }
        return try? JSONDecoder().decode(T.self, from: data)
    }

    private func write<T: Encodable>(_ value: T, _ account: String) {
        guard let data = try? JSONEncoder().encode(value) else { return }
        try? Keychain.set(data, account: account)
    }

    func credentials(for host: String) -> [SavedCredential] {
        let domain = DomainTools.registrableDomain(host)
        return credentials.filter { DomainTools.registrableDomain($0.host) == domain }
    }

    func save(_ credential: SavedCredential) {
        credentials.removeAll { $0.host == credential.host && $0.username == credential.username }
        credentials.insert(credential, at: 0)
        write(credentials, "credentials")
    }

    func delete(_ credential: SavedCredential) { credentials.removeAll { $0.id == credential.id }; write(credentials, "credentials") }
    func saveProfile() { write(profile, "profile") }
    func save(_ card: PaymentCard) { cards.removeAll { $0.id == card.id }; cards.append(card); write(cards, "cards") }
    func delete(_ card: PaymentCard) { cards.removeAll { $0.id == card.id }; write(cards, "cards") }
}
