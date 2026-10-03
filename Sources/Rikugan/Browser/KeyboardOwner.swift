import SwiftUI
import UIKit
import WebKit

/// Tracks whether the on-screen keyboard belongs to web content.
///
/// WKWebView handles the keyboard itself (like Safari, it keeps its frame and moves the page's
/// visual viewport). If SwiftUI's keyboard avoidance also shrinks the browser layout, the web view
/// is resized when the keyboard appears and again when it hides — and the hide starts with the
/// tap on a page button (e.g. a chat "send" button): the page moves under the finger mid-tap and
/// WebKit drops the click, so it takes a second tap. While a page field has the keyboard, the
/// browser layout therefore ignores the keyboard; native fields (address bar, find bar) keep the
/// normal avoidance so they stay visible above it.
@MainActor final class KeyboardOwner: ObservableObject {
    static let shared = KeyboardOwner()
    @Published private(set) var webContentHasKeyboard = false
    private var observers: [NSObjectProtocol] = []

    private init() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
        observers.append(center.addObserver(forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.update() }
        })
        // Only after the keyboard is fully gone: switching back while it is still on screen would
        // shrink the layout for the rest of the hide animation.
        observers.append(center.addObserver(forName: UIResponder.keyboardDidHideNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.set(false) }
        })
    }

    private func update() {
        guard let responder = FirstResponder.current() else { return }
        var view = responder as? UIView
        var inWebView = false
        while let current = view {
            if current is WKWebView { inWebView = true; break }
            view = current.superview
        }
        set(inWebView)
    }

    private func set(_ value: Bool) {
        if webContentHasKeyboard != value { webContentHasKeyboard = value }
    }
}

/// Finds the current first responder (the view that owns the keyboard).
@MainActor enum FirstResponder {
    fileprivate static weak var found: UIResponder?

    static func current() -> UIResponder? {
        found = nil
        UIApplication.shared.sendAction(#selector(UIResponder.rikuganCaptureFirstResponder), to: nil, from: nil, for: nil)
        return found
    }
}

extension UIResponder {
    @objc fileprivate func rikuganCaptureFirstResponder() {
        MainActor.assumeIsolated { FirstResponder.found = self }
    }
}
