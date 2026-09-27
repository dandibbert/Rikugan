import Foundation
import UIKit
import CoreText
import SwiftUI

/// Custom web fonts (spec §2 / §6): fonts installed system-wide through configuration profiles
/// (visible to WebKit by family name) plus font files imported into Rikugan (served to pages via
/// the FontFace API, so page CSP cannot block them).
@MainActor final class FontManager: ObservableObject {
    struct ImportedFont: Identifiable, Hashable {
        let id: String
        let fileURL: URL
        let family: String
        let postScriptName: String
    }

    @Published private(set) var imported: [ImportedFont] = []
    @Published private(set) var systemFamilies: [String] = []

    func reload() {
        systemFamilies = UIFont.familyNames.sorted()
        var list: [ImportedFont] = []
        let files = (try? FileManager.default.contentsOfDirectory(at: AppPaths.fonts, includingPropertiesForKeys: nil)) ?? []
        for file in files where ["ttf", "otf", "ttc", "woff", "woff2"].contains(file.pathExtension.lowercased()) {
            let descriptors = (CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor]) ?? []
            let family = descriptors.first.flatMap { CTFontDescriptorCopyAttribute($0, kCTFontFamilyNameAttribute) as? String }
                ?? file.deletingPathExtension().lastPathComponent
            let ps = descriptors.first.flatMap { CTFontDescriptorCopyAttribute($0, kCTFontNameAttribute) as? String } ?? family
            CTFontManagerRegisterFontURLs([file] as CFArray, .process, false, nil)
            list.append(ImportedFont(id: file.lastPathComponent, fileURL: file, family: family, postScriptName: ps))
        }
        imported = list.sorted { $0.family < $1.family }
    }

    func importFont(from url: URL) throws -> ImportedFont {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let destination = AppPaths.uniqueFile(in: AppPaths.fonts, name: url.lastPathComponent)
        try FileManager.default.copyItem(at: url, to: destination)
        let descriptors = (CTFontManagerCreateFontDescriptorsFromURL(destination as CFURL) as? [CTFontDescriptor]) ?? []
        guard !descriptors.isEmpty || ["woff", "woff2"].contains(destination.pathExtension.lowercased()) else {
            try? FileManager.default.removeItem(at: destination)
            throw RikuganError("无法识别的字体文件")
        }
        reload()
        guard let font = imported.first(where: { $0.fileURL == destination }) else { throw RikuganError("字体导入失败") }
        return font
    }

    func delete(_ font: ImportedFont) {
        CTFontManagerUnregisterFontURLs([font.fileURL] as CFArray, .process, nil)
        try? FileManager.default.removeItem(at: font.fileURL)
        reload()
    }

    func importedFont(family: String) -> ImportedFont? { imported.first { $0.family == family } }

    /// Families shown in pickers: imported first, then everything the system exposes (incl. profile fonts).
    var allFamilies: [String] { Array(NSOrderedSet(array: imported.map(\.family) + systemFamilies)) as? [String] ?? systemFamilies }
}

/// SwiftUI wrapper around UIFontPickerViewController (lists profile-installed fonts too).
struct SystemFontPicker: UIViewControllerRepresentable {
    let onPick: (String) -> Void

    func makeUIViewController(context: Context) -> UIFontPickerViewController {
        let configuration = UIFontPickerViewController.Configuration()
        configuration.includeFaces = false
        configuration.displayUsingSystemFont = false
        let picker = UIFontPickerViewController(configuration: configuration)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: UIFontPickerViewController, context: Context) {}
    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, UIFontPickerViewControllerDelegate {
        let onPick: (String) -> Void
        init(onPick: @escaping (String) -> Void) { self.onPick = onPick }
        func fontPickerViewControllerDidPickFont(_ viewController: UIFontPickerViewController) {
            guard let descriptor = viewController.selectedFontDescriptor else { return }
            let family = (descriptor.object(forKey: .family) as? String) ?? UIFont(descriptor: descriptor, size: 12).familyName
            onPick(family)
            viewController.dismiss(animated: true)
        }
    }
}
