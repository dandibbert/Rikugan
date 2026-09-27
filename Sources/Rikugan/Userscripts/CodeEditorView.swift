import SwiftUI
import UIKit

/// Monospaced code editor with line numbers and system find (spec §10).
struct CodeEditorView: UIViewRepresentable {
    @Binding var text: String
    var highlightLines: Set<Int> = []

    func makeUIView(context: Context) -> LineNumberedTextView {
        let view = LineNumberedTextView()
        view.textView.delegate = context.coordinator
        view.textView.text = text
        view.errorLines = highlightLines
        return view
    }

    func updateUIView(_ uiView: LineNumberedTextView, context: Context) {
        if uiView.textView.text != text { uiView.textView.text = text }
        uiView.errorLines = highlightLines
        uiView.gutter.setNeedsDisplay()
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: CodeEditorView
        init(_ parent: CodeEditorView) { self.parent = parent }
        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView.superview as? LineNumberedTextView)?.gutter.setNeedsDisplay()
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            (scrollView.superview as? LineNumberedTextView)?.gutter.setNeedsDisplay()
        }
    }
}

final class LineNumberedTextView: UIView {
    let textView = UITextView(usingTextLayoutManager: false)
    let gutter = GutterView()
    var errorLines: Set<Int> = [] { didSet { gutter.errorLines = errorLines } }
    private let gutterWidth: CGFloat = 44

    override init(frame: CGRect) {
        super.init(frame: frame)
        textView.font = UIFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.autocapitalizationType = .none
        textView.autocorrectionType = .no
        textView.smartQuotesType = .no
        textView.smartDashesType = .no
        textView.smartInsertDeleteType = .no
        textView.spellCheckingType = .no
        textView.keyboardType = .asciiCapable
        textView.isFindInteractionEnabled = true
        textView.alwaysBounceVertical = true
        textView.textContainerInset = UIEdgeInsets(top: 8, left: 4, bottom: 40, right: 8)
        textView.backgroundColor = .systemBackground
        gutter.textView = textView
        gutter.backgroundColor = .secondarySystemBackground
        addSubview(gutter)
        addSubview(textView)
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layoutSubviews() {
        super.layoutSubviews()
        gutter.frame = CGRect(x: 0, y: 0, width: gutterWidth, height: bounds.height)
        textView.frame = CGRect(x: gutterWidth, y: 0, width: bounds.width - gutterWidth, height: bounds.height)
        gutter.setNeedsDisplay()
    }
}

final class GutterView: UIView {
    weak var textView: UITextView?
    var errorLines: Set<Int> = []

    override func draw(_ rect: CGRect) {
        guard let textView else { return }
        let layout = textView.layoutManager
        let text = textView.text as NSString
        let offset = textView.contentOffset.y - textView.textContainerInset.top
        let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: UIColor.secondaryLabel]
        let errorAttributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .bold), .foregroundColor: UIColor.systemRed]
        let visible = CGRect(x: 0, y: offset, width: textView.bounds.width, height: bounds.height)
        let glyphRange = layout.glyphRange(forBoundingRect: visible, in: textView.textContainer)
        let charRange = layout.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        // Line number of the first visible character.
        var line = text.substring(to: min(charRange.location, text.length)).reduce(into: 1) { count, ch in if ch == "\n" { count += 1 } }
        var index = charRange.location
        // Move to start of the paragraph.
        index = text.lineRange(for: NSRange(location: min(index, max(0, text.length - 1)), length: 0)).location
        if text.length == 0 {
            ("1" as NSString).draw(at: CGPoint(x: 6, y: textView.textContainerInset.top - textView.contentOffset.y), withAttributes: attributes)
            return
        }
        while index < NSMaxRange(charRange) + 1 && index < text.length {
            let paragraph = text.lineRange(for: NSRange(location: index, length: 0))
            let glyph = layout.glyphIndexForCharacter(at: paragraph.location)
            let fragment = layout.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let y = fragment.minY + textView.textContainerInset.top - textView.contentOffset.y
            let label = "\(line)" as NSString
            let size = label.size(withAttributes: attributes)
            label.draw(at: CGPoint(x: bounds.width - size.width - 6, y: y + 1), withAttributes: errorLines.contains(line) ? errorAttributes : attributes)
            line += 1
            index = NSMaxRange(paragraph)
            if paragraph.length == 0 { break }
        }
    }
}
