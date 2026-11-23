import SwiftUI
import AppKit

final class SQLTextView: NSTextView {
    static func isIdentifier(_ c: unichar) -> Bool {
        guard let u = UnicodeScalar(c) else { return false }
        return CharacterSet.alphanumerics.contains(u) || c == 95 || c == 36   // _ és $
    }

    /// A kurzor előtti azonosító (ezt cseréli le a kiegészítés).
    override var rangeForUserCompletion: NSRange {
        let ns = string as NSString
        let caret = selectedRange().location
        var start = caret
        while start > 0, SQLTextView.isIdentifier(ns.character(at: start - 1)) { start -= 1 }
        return NSRange(location: start, length: caret - start)
    }

    /// A pont előtti név, pl. "users.na" esetén "users".
    func qualifier(before range: NSRange) -> String? {
        let ns = string as NSString
        guard range.location > 0, ns.character(at: range.location - 1) == 46 else { return nil }
        var end = range.location - 1
        if end > 0, ns.character(at: end - 1) == 96 { end -= 1 }             // záró `
        var start = end
        while start > 0, SQLTextView.isIdentifier(ns.character(at: start - 1)) { start -= 1 }
        return start < end ? ns.substring(with: NSRange(location: start, length: end - start)) : nil
    }
}

/// Line numbers beside the SQL editor. Redraws itself when the text, the caret or the scroll position changes;
/// the caret's line is drawn brighter. Clicking a number selects that line.
final class LineNumberRuler: NSRulerView {
    private weak var textView: NSTextView?
    private let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10.5, weight: .regular)

    init(textView: NSTextView, scrollView: NSScrollView) {
        self.textView = textView
        super.init(scrollView: scrollView, orientation: .verticalRuler)
        clientView = textView
        ruleThickness = 34
        let nc = NotificationCenter.default
        nc.addObserver(self, selector: #selector(refresh), name: NSText.didChangeNotification, object: textView)
        nc.addObserver(self, selector: #selector(refresh), name: NSTextView.didChangeSelectionNotification, object: textView)
        scrollView.contentView.postsBoundsChangedNotifications = true
        nc.addObserver(self, selector: #selector(refresh), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    required init(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override var isOpaque: Bool { true }

    @objc func refresh() {
        // Wider gutter once the document reaches 1000 lines and beyond.
        if let tv = textView {
            let lines = (tv.string as NSString).components(separatedBy: "\n").count
            let digits = max(2, String(lines).count)
            let width = CGFloat(digits) * 7 + 20
            if abs(ruleThickness - width) > 0.5 { ruleThickness = width }
        }
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        NSColor.textBackgroundColor.setFill()
        bounds.fill()
        drawHashMarksAndLabels(in: dirtyRect)
    }

    override func drawHashMarksAndLabels(in rect: NSRect) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let ns = tv.string as NSString
        let origin = tv.textContainerOrigin
        let caret = tv.selectedRange().location
        let dim: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.tertiaryLabelColor]
        let bright: [NSAttributedString.Key: Any] = [.font: numberFont, .foregroundColor: NSColor.secondaryLabelColor]

        func draw(_ number: Int, fragment: NSRect, current: Bool) {
            var r = fragment
            r.origin.x += origin.x
            r.origin.y += origin.y
            let local = convert(r, from: tv)
            let label = String(number) as NSString
            let attrs = current ? bright : dim
            let size = label.size(withAttributes: attrs)
            let point = NSPoint(x: bounds.width - size.width - 8, y: local.minY + (local.height - size.height) / 2)
            label.draw(at: point, withAttributes: attrs)
        }

        let visible = tv.visibleRect
        let glyphs = lm.glyphRange(forBoundingRect: visible, in: tc)
        let chars = lm.characterRange(forGlyphRange: glyphs, actualGlyphRange: nil)

        // Number of the first visible line.
        var line = 1
        var i = 0
        while i < chars.location {
            let r = ns.range(of: "\n", options: [], range: NSRange(location: i, length: chars.location - i))
            if r.location == NSNotFound { break }
            line += 1
            i = r.location + 1
        }

        var index = ns.length == 0 ? 0 : ns.lineRange(for: NSRange(location: min(chars.location, ns.length), length: 0)).location
        let end = NSMaxRange(chars)
        while index < ns.length && index <= end {
            let lineRange = ns.lineRange(for: NSRange(location: index, length: 0))
            let glyph = lm.glyphIndexForCharacter(at: index)
            let fragment = lm.lineFragmentRect(forGlyphAt: glyph, effectiveRange: nil)
            let current = caret >= lineRange.location && (caret < NSMaxRange(lineRange) || (caret == ns.length && NSMaxRange(lineRange) == ns.length && !ns.hasSuffix("\n")))
            draw(line, fragment: fragment, current: current)
            line += 1
            index = NSMaxRange(lineRange)
        }
        // The empty last line after a trailing newline (or an empty document).
        if ns.length == 0 || ns.hasSuffix("\n") {
            let extra = lm.extraLineFragmentRect
            if extra.height > 0 { draw(line, fragment: extra, current: caret == ns.length) }
        }
    }

    override func mouseDown(with event: NSEvent) {
        guard let tv = textView, let lm = tv.layoutManager, let tc = tv.textContainer else { return }
        let ns = tv.string as NSString
        var p = tv.convert(event.locationInWindow, from: nil)
        p.x = 0
        p.y -= tv.textContainerOrigin.y
        let glyph = lm.glyphIndex(for: p, in: tc)
        let char = min(lm.characterIndexForGlyph(at: glyph), ns.length)
        tv.window?.makeFirstResponder(tv)
        tv.setSelectedRange(ns.lineRange(for: NSRange(location: char, length: 0)))
    }
}
