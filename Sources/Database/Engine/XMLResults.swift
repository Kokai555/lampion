import SwiftUI
import AppKit

/// A `mariadb --xml` kimenetének feldolgozása (utasításonként egy <resultset>).
final class XMLResults: NSObject, XMLParserDelegate {
    private var sets: [ResultSet] = []
    private var current = ResultSet()
    private var row: [String?] = []
    private var names: [String] = []
    private var text = ""
    private var isNil = false
    private var inField = false

    static func parse(_ data: Data) -> (sets: [ResultSet], ok: Bool) {
        if data.isEmpty { return ([], true) }
        let body = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<?xml version=\"1.0\"?>", with: "")
        let wrapped = "<root xmlns:xsi=\"http://www.w3.org/2001/XMLSchema-instance\">" + body + "</root>"
        let parser = XMLParser(data: Data(wrapped.utf8))
        let delegate = XMLResults()
        parser.delegate = delegate
        let ok = parser.parse()
        return (delegate.sets, ok)
    }

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?,
                attributes: [String: String] = [:]) {
        switch name {
        case "resultset": current = ResultSet()
        case "row": row = []; names = []
        case "field":
            inField = true; text = ""
            isNil = attributes["xsi:nil"] == "true"
            names.append(attributes["name"] ?? "")
        default: break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) { if inField { text += string } }

    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "field": row.append(isNil ? nil : text); inField = false
        case "row":
            if current.columns.isEmpty { current.columns = names }
            current.rows.append(row)
        case "resultset": sets.append(current)
        default: break
        }
    }
}
