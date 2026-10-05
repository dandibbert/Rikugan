import SwiftUI
import UIKit

/// Rikugan's icon set. Call sites use SF Symbol names; when the asset catalog has a custom symbol
/// "rk.<name>" (Phosphor icons converted by scripts/gen_icons.py — rounder, softer line icons)
/// that is drawn instead, otherwise the system symbol. Custom symbols behave like SF Symbols:
/// they scale with the font, take the tint / foreground style and work in UIKit menus.
enum Icons {
    private static var cache: [String: Bool] = [:]
    private static let lock = NSLock()

    /// Asset name to use for `name` (the custom one when it exists).
    static func resolved(_ name: String) -> (name: String, custom: Bool) {
        let custom = "rk." + name
        lock.lock(); defer { lock.unlock() }
        if let hit = cache[name] { return hit ? (custom, true) : (name, false) }
        let exists = UIImage(named: custom) != nil
        cache[name] = exists
        return exists ? (custom, true) : (name, false)
    }

    static func uiImage(_ name: String, configuration: UIImage.SymbolConfiguration? = nil) -> UIImage? {
        let (asset, custom) = resolved(name)
        if custom { return UIImage(named: asset, in: nil, with: configuration) }
        return configuration.map { UIImage(systemName: name, withConfiguration: $0) } ?? UIImage(systemName: name)
    }
}

extension Image {
    /// An icon by SF Symbol name, drawn from Rikugan's icon set when it has one.
    init(icon name: String) {
        let (asset, custom) = Icons.resolved(name)
        if custom { self.init(asset) } else { self.init(systemName: name) }
    }
}

extension Label where Title == Text, Icon == Image {
    init<S: StringProtocol>(_ title: S, icon name: String) {
        self.init { Text(title) } icon: { Image(icon: name) }
    }

    init(_ titleKey: LocalizedStringKey, icon name: String) {
        self.init { Text(titleKey) } icon: { Image(icon: name) }
    }
}

extension UIImage {
    /// UIKit counterpart of `Image(icon:)`.
    static func icon(_ name: String) -> UIImage? { Icons.uiImage(name) }
}
