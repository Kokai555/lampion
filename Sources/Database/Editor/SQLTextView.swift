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
