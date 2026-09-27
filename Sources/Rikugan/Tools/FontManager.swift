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

    /// Imports .ttf / .otf / .ttc (/ .woff / .woff2). Collections are split into one standalone
    /// font per face because WebKit's FontFace loader expects single-face sfnt data.
    @discardableResult
    func importFont(from url: URL) throws -> ImportedFont {
        guard let first = try importFonts(from: url).first else { throw RikuganError("字体导入失败") }
        return first
    }

    func importFonts(from url: URL) throws -> [ImportedFont] {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let data = try Data(contentsOf: url)
        let ext = url.pathExtension.lowercased()
        guard ["ttf", "otf", "ttc", "woff", "woff2"].contains(ext) || FontCollection.isCollection(data) else {
            throw RikuganError("不支持的字体格式：.\(ext)（支持 TTF / OTF / TTC / WOFF / WOFF2）")
        }
        var written: [URL] = []
        if FontCollection.isCollection(data) {
            let faces = try FontCollection.split(data)
            let base = url.deletingPathExtension().lastPathComponent
            for (index, face) in faces.enumerated() {
                let destination = AppPaths.uniqueFile(in: AppPaths.fonts, name: "\(base)-\(index + 1).ttf")
                try face.write(to: destination)
                written.append(destination)
            }
        } else {
            let destination = AppPaths.uniqueFile(in: AppPaths.fonts, name: url.lastPathComponent)
            try data.write(to: destination)
            written.append(destination)
        }
        for file in written where !["woff", "woff2"].contains(file.pathExtension.lowercased()) {
            let descriptors = (CTFontManagerCreateFontDescriptorsFromURL(file as CFURL) as? [CTFontDescriptor]) ?? []
            if descriptors.isEmpty {
                for w in written { try? FileManager.default.removeItem(at: w) }
                throw RikuganError("无法识别的字体文件：\(url.lastPathComponent)")
            }
        }
        reload()
        let fonts = imported.filter { written.contains($0.fileURL) }
        guard !fonts.isEmpty else { throw RikuganError("字体导入失败") }
        return fonts
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
