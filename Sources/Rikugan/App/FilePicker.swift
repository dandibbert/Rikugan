import UIKit
import UniformTypeIdentifiers

/// The system document picker, presented over whatever is on screen (browser or a sheet).
///
/// Files are picked as copies: the picker copies them into the app's container itself, so the
/// app needs no access grant to the original. That works on every install, including re-signed
/// ones whose application-identifier does not match the bundle (there a grant to open the
/// original in place is not honoured and the picker's "Open" did nothing). Folders cannot be
/// copied; a folder is opened in place, which needs that grant.
@MainActor enum FilePicker {
    static func pick(_ types: [UTType], folder: Bool = false, completion: @escaping (Result<[URL], Error>) -> Void) {
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: !folder)
        picker.allowsMultipleSelection = false
        let delegate = Delegate(completion)
        picker.delegate = delegate
        objc_setAssociatedObject(picker, &Delegate.key, delegate, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        Presenter.present(picker)
    }

    private final class Delegate: NSObject, UIDocumentPickerDelegate {
        static var key = 0
        private var completion: ((Result<[URL], Error>) -> Void)?
        init(_ completion: @escaping (Result<[URL], Error>) -> Void) { self.completion = completion }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            completion?(.success(urls)); completion = nil
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            completion?(.failure(CocoaError(.userCancelled))); completion = nil
        }
    }
}
