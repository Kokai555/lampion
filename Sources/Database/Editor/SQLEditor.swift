import SwiftUI
import AppKit

struct SQLEditor: NSViewRepresentable {
    @Binding var text: String
    /// Az utolsó futtatás hibaüzenete; a szerkesztő megjelöli a hibás részt.
    var error: String? = nil
    var errorVersion = 0
    var completions: (_ prefix: String, _ qualifier: String?) -> [String]

    /// A szerkesztőben pirossal megjelölt szövegrészek (önteszthez).
    static var markedErrors: [String] = []

    static let completeTest = Notification.Name("lampion.completeTest")
    /// Az éppen látható javaslatok (önteszthez).
    static var shownSuggestions: [String] = []

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = SQLTextView(frame: NSRect(x: 0, y: 0, width: 400, height: 120))
        tv.delegate = context.coordinator
        tv.string = text
        tv.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        tv.textColor = .labelColor
        tv.drawsBackground = false
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isContinuousSpellCheckingEnabled = false
        tv.isGrammarCheckingEnabled = false
        tv.textContainerInset = NSSize(width: 6, height: 8)
        tv.minSize = .zero
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.drawsBackground = false
        sv.borderType = .noBorder
        context.coordinator.textView = tv
        context.coordinator.highlight()
        NotificationCenter.default.addObserver(context.coordinator, selector: #selector(Coordinator.runCompleteTest(_:)),
                                               name: SQLEditor.completeTest, object: nil)
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.textView else { return }
        var changed = false
        if tv.string != text { tv.string = text; changed = true }
        if c.seenErrorVersion != errorVersion {
            c.seenErrorVersion = errorVersion
            c.errorMessage = error
            c.errorText = tv.string
            changed = true
        }
        if changed { c.highlight() }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SQLEditor
        weak var textView: SQLTextView?
        private let suggestions = SuggestionPanel()
        private var range = NSRange(location: 0, length: 0)
        private var suppressNext = false
        var seenErrorVersion = -1
        var errorMessage: String?
        var errorText = ""

        /// Szintaxisszínezés és hibajelölés. A futtatási hiba jelölése az első szerkesztésig marad.
        func highlight() {
            guard let tv = textView, let storage = tv.textStorage, let layout = tv.layoutManager, !tv.hasMarkedText() else { return }
            let ns = tv.string as NSString
            let full = NSRange(location: 0, length: ns.length)
            let font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
            let tokens = SQLSyntax.tokenize(tv.string)

            storage.beginEditing()
            storage.setAttributes([.font: font, .foregroundColor: NSColor.labelColor], range: full)
            for t in tokens where t.kind != .error {
                storage.addAttribute(.foregroundColor, value: SQLSyntax.color(t.kind), range: t.range)
            }
            storage.endEditing()
            tv.typingAttributes = [.font: font, .foregroundColor: NSColor.labelColor]

            layout.removeTemporaryAttribute(.spellingState, forCharacterRange: full)
            layout.removeTemporaryAttribute(.backgroundColor, forCharacterRange: full)
            var marks = tokens.filter { $0.kind == .error }.map(\.range)
            if let message = errorMessage, tv.string == errorText {
                marks += SQLSyntax.errorRanges(message: message, in: tv.string)
            }
            for r in marks where r.location + r.length <= ns.length {
                layout.addTemporaryAttribute(.spellingState, value: NSAttributedString.SpellingState.spelling.rawValue, forCharacterRange: r)
                layout.addTemporaryAttribute(.backgroundColor, value: NSColor.systemRed.withAlphaComponent(0.25), forCharacterRange: r)
            }
            SQLEditor.markedErrors = marks.filter { $0.location + $0.length <= ns.length }.map { ns.substring(with: $0) }
        }

        init(_ parent: SQLEditor) {
            self.parent = parent
            super.init()
            suggestions.onPick = { [weak self] word in self?.accept(word) }
        }

        private func candidates(_ tv: SQLTextView, _ range: NSRange) -> [String] {
            let prefix = (tv.string as NSString).substring(with: range)
            return parent.completions(prefix, tv.qualifier(before: range))
        }

        /// Javaslatok megjelenítése a kurzor alatt; `force`: Tabra, akkor is, ha még nincs begépelt betű.
        private func refresh(_ tv: SQLTextView, force: Bool = false) {
            guard tv.selectedRange().length == 0 else { hide(); return }
            let r = tv.rangeForUserCompletion
            let hasQualifier = tv.qualifier(before: r) != nil
            guard r.length > 0 || hasQualifier || force else { hide(); return }
            let list = candidates(tv, r)
            guard !list.isEmpty, let window = tv.window else { hide(); return }
            range = r
            let caret = tv.firstRect(forCharacterRange: NSRange(location: r.location, length: 0), actualRange: nil)
            suggestions.show(list, below: NSPoint(x: caret.minX - 6, y: caret.minY - 3), parent: window)
            SQLEditor.shownSuggestions = suggestions.items
        }

        private func hide() {
            suggestions.hide()
            SQLEditor.shownSuggestions = []
        }

        private func accept(_ word: String) {
            guard let tv = textView else { return }
            suppressNext = true
            tv.insertText(word, replacementRange: range)
            hide()
        }

        func textDidChange(_ note: Notification) {
            guard let tv = textView else { return }
            if parent.text != tv.string { parent.text = tv.string }
            highlight()
            if suppressNext { suppressNext = false; hide() } else { refresh(tv) }
        }

        /// Ha a kurzor gépelés nélkül mozdul el (kattintás, nyilak), a javaslatok eltűnnek.
        func textViewDidChangeSelection(_ note: Notification) {
            DispatchQueue.main.async {
                guard self.suggestions.isVisible, let tv = self.textView else { return }
                if tv.selectedRange().length != 0 || tv.rangeForUserCompletion.location != self.range.location {
                    self.hide()
                } else {
                    self.refresh(tv)
                }
            }
        }

        func textDidEndEditing(_ note: Notification) { hide() }

        func textView(_ textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            guard let tv = textView as? SQLTextView else { return false }
            if suggestions.isVisible {
                switch selector {
                case #selector(NSResponder.moveDown(_:)): suggestions.move(1); return true
                case #selector(NSResponder.moveUp(_:)): suggestions.move(-1); return true
                case #selector(NSResponder.cancelOperation(_:)): hide(); return true
                case #selector(NSResponder.insertTab(_:)):
                    if let word = suggestions.selected { accept(word) }
                    return true
                case #selector(NSResponder.insertNewline(_:)):
                    // Enter csak akkor fogad el, ha a nyilakkal kiválasztottál valamit.
                    if suggestions.navigated, let word = suggestions.selected { accept(word); return true }
                    hide()
                    return false
                default: return false
                }
            }
            // Zárt listánál a Tab megnyitja a javaslatokat; egyetlen találatot azonnal beír.
            if selector == #selector(NSResponder.insertTab(_:)), tv.selectedRange().length == 0 {
                let r = tv.rangeForUserCompletion
                if r.length == 0 && tv.qualifier(before: r) == nil { return false }
                let list = candidates(tv, r)
                if list.count == 1 {
                    range = r
                    accept(list[0])
                } else if list.isEmpty {
                    NSSound.beep()
                } else {
                    refresh(tv, force: true)
                }
                return true
            }
            return false
        }

        /// Csak önteszthez. Szöveg érkezik: „begépeli”; különben a kurzort a végére teszi, és Tabot „nyom”.
        @objc func runCompleteTest(_ note: Notification) {
            guard let tv = textView else { return }
            tv.window?.makeFirstResponder(tv)
            tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
            if let typed = note.object as? String {
                tv.insertText(typed, replacementRange: tv.selectedRange())
            } else {
                tv.doCommand(by: #selector(NSResponder.insertTab(_:)))
            }
        }
    }
}
