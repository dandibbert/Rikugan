import XCTest
@testable import Rikugan

final class BackupMigrationTests: XCTestCase {
    func testV2MigrationRetainsTabsGroupsAndSettings() throws {
        var backup = PortableBackup()
        let group = TabGroup(name: "研究")
        backup.tabGroups = [group]
        backup.tabs = [SavedTab(url: "https://example.com", groupID: group.id)]
        backup.selectedTabID = backup.tabs[0].id
        backup.settings.webFontFamily = "Custom Font"
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(backup)) as! [String: Any]
        object["version"] = 2; object.removeValue(forKey: "format")
        let migrated = try BackupImporter.decode(JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(migrated.version, 3)
        XCTAssertEqual(migrated.tabs, backup.tabs)
        XCTAssertEqual(migrated.tabGroups, backup.tabGroups)
        XCTAssertEqual(migrated.settings, backup.settings)
    }

    func testReferenceGraphsAndNumericLimitsFailClosed() throws {
        var backup = PortableBackup()
        let a = UUID(), b = UUID()
        backup.bookmarkFolders = [BookmarkFolder(id: a, name: "A", parentID: b), BookmarkFolder(id: b, name: "B", parentID: a)]
        XCTAssertThrowsError(try BackupImporter.validate(backup))
        backup.bookmarkFolders = [BookmarkFolder(name: "Orphan", parentID: UUID())]
        XCTAssertThrowsError(try BackupImporter.validate(backup))
        backup.bookmarkFolders = []
        backup.tabs = [SavedTab(url: "https://example.com", autoRefreshSeconds: Int.max)]
        XCTAssertThrowsError(try BackupImporter.validate(backup))
        backup.tabs[0].autoRefreshSeconds = 60
        backup.selectedTabID = UUID()
        XCTAssertThrowsError(try BackupImporter.validate(backup))
        backup.selectedTabID = backup.tabs[0].id
        XCTAssertNoThrow(try BackupImporter.validate(backup))
        backup.settings.reader.fontSize = .infinity
        XCTAssertThrowsError(try BackupImporter.validate(backup))
    }

    func testUnknownVersionsAndDuplicateSettingsAreRejected() throws {
        var backup = PortableBackup()
        backup.version = 999
        XCTAssertThrowsError(try BackupImporter.decode(JSONEncoder().encode(backup)))
        backup.version = 3; backup.format = "another-app"
        XCTAssertThrowsError(try BackupImporter.decode(JSONEncoder().encode(backup)))
        backup.format = "com.dandibbert.rikugan.backup"
        backup.siteSettings = [SiteSettings(host: "example.com"), SiteSettings(host: "EXAMPLE.com")]
        XCTAssertThrowsError(try BackupImporter.validate(backup))
        backup.siteSettings = []
        let rule = CustomBlockRule(text: "||example.com^")
        backup.settings.customRules = [rule, rule]
        XCTAssertThrowsError(try BackupImporter.validate(backup))
    }
}
