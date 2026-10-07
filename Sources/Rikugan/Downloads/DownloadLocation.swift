import Foundation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// Where downloads go: Rikugan's own Downloads folder (always, so the list can open them) and,
/// when the user picked one, a copy in a folder of their choice in Files. The chosen folder is
/// remembered (security-scoped bookmark) and used for every later download until changed.
@MainActor enum DownloadLocation {
    enum Destination: Equatable { case rikugan, custom }

    private static let bookmarkKey = "rikugan.downloadFolderBookmark"
    private static let destinationKey = "rikugan.downloadDestination"

    /// The remembered destination for new downloads.
    static var destination: Destination {
        get { UserDefaults.standard.string(forKey: destinationKey) == "custom" && customFolder != nil ? .custom : .rikugan }
        set { UserDefaults.standard.set(newValue == .custom ? "custom" : "rikugan", forKey: destinationKey) }
    }

    /// The folder picked in Files, if any (resolved from its bookmark).
    static var customFolder: URL? {
        guard let data = UserDefaults.standard.data(forKey: bookmarkKey) else { return nil }
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if stale { try? remember(url) }
        return url
    }

    static var customFolderName: String? { customFolder?.lastPathComponent }

    static func displayName(_ destination: Destination) -> String {
        destination == .custom ? (customFolderName ?? "所选文件夹") : "Rikugan 下载"
    }

    private static func remember(_ folder: URL) throws {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let data = try folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(data, forKey: bookmarkKey)
    }

    /// Takes the result of the folder picker (`.fileImporter` with `.folder`, see
    /// `downloadFolderPicker`). On success the folder becomes the remembered destination; a failure
    /// is shown, never swallowed.
    @discardableResult
    static func adopt(_ result: Result<[URL], Error>) -> Bool {
        do {
            guard let folder = try result.get().first else { return false }
            try remember(folder)
            guard customFolder != nil else { throw RikuganError("无法重新打开所选文件夹") }
            destination = .custom
            ToastCenter.shared.show("下载将保存到“\(folder.lastPathComponent)”", symbol: "folder")
            return true
        } catch {
            if (error as NSError).code == NSUserCancelledError { return false }
            ErrorLog.shared.record(error.localizedDescription, source: "下载文件夹")
            ToastCenter.shared.show("无法使用这个文件夹：\(error.localizedDescription)", symbol: "exclamationmark.triangle", duration: 5)
            return false
        }
    }

    /// Copies a finished download into the chosen folder. Returns the copy's URL.
    static func copyToCustomFolder(_ file: URL) throws -> URL {
        guard let folder = customFolder else { throw RikuganError("没有选择保存文件夹") }
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let target = AppPaths.uniqueFile(in: folder, name: file.lastPathComponent)
        var coordinationError: NSError?
        var copyError: Error?
        NSFileCoordinator().coordinate(writingItemAt: target, options: .forReplacing, error: &coordinationError) { url in
            do { try FileManager.default.copyItem(at: file, to: url) } catch { copyError = error }
        }
        if let error = coordinationError ?? copyError { throw error }
        return target
    }
}

extension View {
    /// The system folder picker for the download destination, presented by SwiftUI itself.
    func downloadFolderPicker(isPresented: Binding<Bool>, picked: @escaping () -> Void) -> some View {
        fileImporter(isPresented: isPresented, allowedContentTypes: [.folder], allowsMultipleSelection: false) { result in
            if DownloadLocation.adopt(result) { picked() }
        }
    }
}
