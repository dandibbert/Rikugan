import Foundation
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
        if stale { remember(url) }
        return url
    }

    static var customFolderName: String? { customFolder?.lastPathComponent }

    static func displayName(_ destination: Destination) -> String {
        destination == .custom ? (customFolderName ?? "所选文件夹") : "Rikugan 下载"
    }

    private static func remember(_ folder: URL) {
        let accessing = folder.startAccessingSecurityScopedResource()
        defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        if let data = try? folder.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil) {
            UserDefaults.standard.set(data, forKey: bookmarkKey)
        }
    }

    /// Lets the user pick a folder in Files; on success it becomes the remembered destination.
    static func pickFolder() async -> Bool {
        await withCheckedContinuation { continuation in
            let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.folder])
            let delegate = PickerDelegate { url in
                if let url {
                    remember(url)
                    destination = .custom
                }
                continuation.resume(returning: url != nil)
            }
            picker.delegate = delegate
            objc_setAssociatedObject(picker, &PickerDelegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            Presenter.present(picker)
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

    private final class PickerDelegate: NSObject, UIDocumentPickerDelegate {
        static var key = 0
        private var done: ((URL?) -> Void)?
        init(_ done: @escaping (URL?) -> Void) { self.done = done }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            done?(urls.first); done = nil
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            done?(nil); done = nil
        }
    }
}
