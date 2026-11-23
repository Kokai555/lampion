import SwiftUI
import AppKit

/// A fast, calm data grid (NSTableView) used for table data, query results and lists.
///
/// Pass `columnInfo` (matched to `columns` by name) to get two-line headers with the SQL type,
/// a key for primary-key columns and right-aligned numbers. Pass `tableName` to offer
/// "Copy Row as INSERT" in the context menu.
struct GridView: NSViewRepresentable {
    var columns: [String]
    var rows: [[String?]]
    var version: Int
    /// When this differs from the value at the previous reload, the reload scrolls back to the top left
    /// (a new page, sort or table). Reloads with the same key keep the scroll position.
    var scrollKey: String? = nil
    var editable = false
    var sortColumn: String? = nil
    var ascending = true
    var selection: Binding<IndexSet>? = nil
    var onEdit: ((Int, Int, String?) -> Void)? = nil
    var onSort: ((String) -> Void)? = nil
    /// Column details, matched to `columns` by name. Optional.
    var columnInfo: [ColumnInfo] = []
    /// The table the rows come from, for "Copy Row as INSERT". Optional.
    var tableName: String? = nil

    static let rowHeight: CGFloat = 24
    static let maxColumnWidth: CGFloat = 380
    static let cellPadding: CGFloat = 8

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = GridTableView()
        tv.gridCoordinator = context.coordinator
        tv.style = .fullWidth
        tv.usesAlternatingRowBackgroundColors = true
        tv.gridStyleMask = []
        tv.gridColor = NSColor.separatorColor.withAlphaComponent(0.5)
        tv.intercellSpacing = NSSize(width: 0, height: 0)
        tv.rowHeight = GridView.rowHeight
        tv.columnAutoresizingStyle = .noColumnAutoresizing
        tv.allowsMultipleSelection = true
        tv.allowsColumnReordering = false
        tv.headerView = NSTableHeaderView(frame: NSRect(x: 0, y: 0, width: 100, height: Coordinator.singleHeaderHeight))
        tv.dataSource = context.coordinator
        tv.delegate = context.coordinator

        let menu = NSMenu()
        menu.autoenablesItems = false
        menu.delegate = context.coordinator
        tv.menu = menu

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.autohidesScrollers = true
        sv.borderType = .noBorder
        context.coordinator.table = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.table else { return }
        let infoKey = c.infoKey(for: self)
        // Only reload when the data actually changed (a new version or other columns): updateNSView
        // also runs for unrelated model changes, and a reload there would cost time and the scroll position.
        var reloaded = false, rebuilt = false
        if c.builtColumns != columns || c.builtInfoKey != infoKey {
            c.rebuildColumns()
            c.builtInfoKey = infoKey
            reloaded = true
            rebuilt = true
        } else if c.version != version {
            reloaded = true
        }
        if reloaded {
            c.version = version
            c.quietly {
                tv.deselectAll(nil)
                tv.reloadData()
            }
            if rebuilt || c.scrollKey != scrollKey {
                if tv.numberOfRows > 0 { tv.scrollRowToVisible(0) }
                if tv.numberOfColumns > 0 { tv.scrollColumnToVisible(0) }
            }
            c.scrollKey = scrollKey
        }
        c.updateSortIndicator()
        c.syncSelection(force: reloaded)
    }

    // MARK: - Coordinator

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate, NSMenuDelegate {
        static let singleHeaderHeight: CGFloat = 28
        static let doubleHeaderHeight: CGFloat = 38
        static let cellID = NSUserInterfaceItemIdentifier("gridCell")

        var parent: GridView
        weak var table: NSTableView?
        var builtColumns: [String] = []
        var builtInfoKey = ""
        var version = -1
        var scrollKey: String?
        private var infoByName: [String: ColumnInfo] = [:]
        private var headerInfos: [GridHeaderInfo] = []
        /// True while the grid changes its own selection, so those changes are not reported back.
        private var syncing = false

        static let cellFont = NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        static let nullFont: NSFont = {
            let base = NSFont.systemFont(ofSize: 11)
            return NSFontManager.shared.convert(base, toHaveTrait: .italicFontMask)
        }()

        init(_ parent: GridView) { self.parent = parent }

        func quietly(_ body: () -> Void) {
            syncing = true
            body()
            syncing = false
        }

        func infoKey(for grid: GridView) -> String {
            grid.columnInfo.map { "\($0.name)\u{1}\($0.type)\u{1}\($0.key)" }.joined(separator: "\u{2}")
        }

        // MARK: Columns

        func rebuildColumns() {
            guard let table else { return }
            infoByName = Dictionary(parent.columnInfo.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            for c in table.tableColumns { table.removeTableColumn(c) }
            headerInfos = []
            let anyInfo = parent.columns.contains { infoByName[$0] != nil }
            for (i, name) in parent.columns.enumerated() {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
                let info = infoByName[name]
                let header = GridHeaderInfo(name: name, type: info?.type, primary: info?.isPrimary == true,
                                            right: info?.family.isNumeric == true)
                headerInfos.append(header)
                let cell = GridHeaderCell(textCell: name)
                cell.representedObject = header
                col.headerCell = cell
                col.title = name
                col.headerToolTip = tooltip(name, info)
                col.width = width(for: i, header: header)
                col.minWidth = 40
                col.maxWidth = 4000
                table.addTableColumn(col)
            }
            setHeaderHeight(anyInfo ? Self.doubleHeaderHeight : Self.singleHeaderHeight)
            builtColumns = parent.columns
        }

        private func tooltip(_ name: String, _ info: ColumnInfo?) -> String {
            guard let info else { return name }
            var parts = [name, info.type]
            parts += info.badges.map(\.help)
            if !info.comment.isEmpty { parts.append(info.comment) }
            return parts.joined(separator: "\n")
        }

        private func width(for i: Int, header: GridHeaderInfo) -> CGFloat {
            let headerFont = GridHeaderCell.titleFont
            var w = measure(header.name, headerFont) + (header.primary ? 14 : 0) + 14
            if let t = header.type { w = max(w, measure(t, GridHeaderCell.typeFont)) }
            for row in parent.rows.prefix(60) where i < row.count {
                let v = row[i].map { String(GridView.flatten($0).prefix(80)) }
                w = max(w, v.map { measure($0, Self.cellFont) } ?? measure("NULL", Self.nullFont))
                if w >= GridView.maxColumnWidth { break }
            }
            return min(GridView.maxColumnWidth, max(56, ceil(w + 2 * GridView.cellPadding + 2)))
        }

        private func measure(_ s: String, _ font: NSFont) -> CGFloat {
            (s as NSString).size(withAttributes: [.font: font]).width
        }

        private func setHeaderHeight(_ h: CGFloat) {
            guard let table, let header = table.headerView, header.frame.height != h else { return }
            header.frame.size.height = h
            table.enclosingScrollView?.tile()
            header.needsDisplay = true
        }

        func updateSortIndicator() {
            guard let table else { return }
            var changed = false
            for (i, info) in headerInfos.enumerated() {
                let sort: Int = i < parent.columns.count && parent.columns[i] == parent.sortColumn
                    ? (parent.ascending ? 1 : -1) : 0
                if info.sort != sort { info.sort = sort; changed = true }
            }
            if changed { table.headerView?.needsDisplay = true }
        }

        // MARK: Selection

        /// Makes the table show the bound selection (the binding is the source of truth).
        func syncSelection(force: Bool) {
            guard let table, let binding = parent.selection else { return }
            let bound = binding.wrappedValue
            let valid = bound.filteredIndexSet { $0 < parent.rows.count }
            if valid != table.selectedRowIndexes || force {
                quietly { table.selectRowIndexes(valid, byExtendingSelection: false) }
            }
            if valid != bound {
                DispatchQueue.main.async { if binding.wrappedValue == bound { binding.wrappedValue = valid } }
            }
        }

        func tableViewSelectionDidChange(_ note: Notification) {
            guard !syncing, let table, let binding = parent.selection else { return }
            let sel = table.selectedRowIndexes
            if binding.wrappedValue != sel { binding.wrappedValue = sel }
        }

        // MARK: Data

        private func value(_ row: Int, _ col: Int) -> String?? {
            guard row >= 0, col >= 0, row < parent.rows.count, col < parent.rows[row].count else { return nil }
            return .some(parent.rows[row][col])
        }

        private func columnIndex(_ col: NSTableColumn?) -> Int? {
            col.flatMap { Int($0.identifier.rawValue.dropFirst()) }
        }

        private func info(_ col: Int) -> ColumnInfo? {
            col >= 0 && col < parent.columns.count ? infoByName[parent.columns[col]] : nil
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let ci = columnIndex(tableColumn), let cell = value(row, ci) else { return nil }
            let view = (tableView.makeView(withIdentifier: Self.cellID, owner: nil) as? NSTableCellView) ?? makeCellView()
            guard let tf = view.textField else { return view }
            let right = info(ci)?.family.isNumeric == true
            tf.alignment = right ? .right : .left
            if let text = cell {
                let simple = GridView.isSimple(text)
                tf.stringValue = simple ? text : String(GridView.flatten(text).prefix(300))
                tf.placeholderAttributedString = nil
                tf.isEditable = parent.editable && simple
                tf.toolTip = !simple || text.count > 60 ? String(text.prefix(1500)) : nil
            } else {
                tf.stringValue = ""
                tf.placeholderAttributedString = Self.nullPlaceholder(right: right)
                tf.isEditable = parent.editable
                tf.toolTip = nil
            }
            return view
        }

        private func makeCellView() -> NSTableCellView {
            let view = NSTableCellView()
            view.identifier = Self.cellID
            let field = NSTextField()
            field.isBordered = false
            field.drawsBackground = false
            field.focusRingType = .none
            field.font = Self.cellFont
            field.lineBreakMode = .byTruncatingTail
            field.cell?.usesSingleLineMode = true
            field.cell?.truncatesLastVisibleLine = true
            field.delegate = self
            field.translatesAutoresizingMaskIntoConstraints = false
            field.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            view.addSubview(field)
            view.textField = field
            NSLayoutConstraint.activate([
                field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: GridView.cellPadding),
                field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -GridView.cellPadding),
                field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
            ])
            return view
        }

        private static func nullPlaceholder(right: Bool) -> NSAttributedString {
            let p = NSMutableParagraphStyle()
            p.alignment = right ? .right : .left
            return NSAttributedString(string: "NULL", attributes: [
                .font: nullFont, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: p,
            ])
        }

        func controlTextDidEndEditing(_ note: Notification) {
            guard let tf = note.object as? NSTextField, let table else { return }
            let row = table.row(for: tf), col = table.column(for: tf)
            guard let old = value(row, col) else { return }
            let new = tf.stringValue
            if old == nil && new.isEmpty { return }
            if old == new { return }
            parent.onEdit?(row, col, new)
        }

        func tableView(_ tableView: NSTableView, didClick tableColumn: NSTableColumn) {
            guard let i = columnIndex(tableColumn), i < parent.columns.count else { return }
            parent.onSort?(parent.columns[i])
        }

        // MARK: Context menu

        /// The rows a menu command applies to: the selection when the clicked row is in it, else the clicked row.
        private func targetRows() -> IndexSet {
            guard let table, table.clickedRow >= 0 else { return table?.selectedRowIndexes ?? [] }
            let sel = table.selectedRowIndexes
            return sel.contains(table.clickedRow) ? sel : IndexSet(integer: table.clickedRow)
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            guard let table, table.clickedRow >= 0 else { return }
            let col = table.clickedColumn
            let n = targetRows().count
            func add(_ title: String, _ action: Selector, enabled: Bool = true) {
                let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
                item.target = self
                item.isEnabled = enabled
                menu.addItem(item)
            }
            if col >= 0 { add("Copy Cell", #selector(copyCell)) }
            add(n > 1 ? "Copy \(n) Rows" : "Copy Row", #selector(copyRows))
            if parent.tableName != nil {
                add(n > 1 ? "Copy \(n) Rows as INSERT" : "Copy Row as INSERT", #selector(copyInsert))
            }
            if col >= 0 { add("Copy Column Name", #selector(copyColumnName)) }
            if parent.editable, col >= 0 {
                menu.addItem(.separator())
                let isNull = value(table.clickedRow, col).map { $0 == nil } ?? true
                add("Set to NULL", #selector(setNull), enabled: !isNull)
            }
        }

        private func copy(_ s: String) {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(s, forType: .string)
        }

        private func tsv(_ rows: IndexSet) -> String {
            rows.filter { $0 < parent.rows.count }
                .map { parent.rows[$0].map { $0 ?? "NULL" }.joined(separator: "\t") }
                .joined(separator: "\n")
        }

        @objc func copyCell() {
            guard let table, let cell = value(table.clickedRow, table.clickedColumn) else { return }
            copy(cell ?? "NULL")
        }

        @objc func copyRows() { copy(tsv(targetRows())) }

        /// Cmd-C in the grid: the selected rows, tab-separated.
        func copySelection() {
            guard let table, !table.selectedRowIndexes.isEmpty else { return }
            copy(tsv(table.selectedRowIndexes))
        }

        @objc func copyColumnName() {
            guard let table, table.clickedColumn >= 0, table.clickedColumn < parent.columns.count else { return }
            copy(parent.columns[table.clickedColumn])
        }

        @objc func copyInsert() {
            guard let name = parent.tableName else { return }
            let cols = parent.columns.map(SQL.id).joined(separator: ", ")
            let sql = targetRows().filter { $0 < parent.rows.count }.map { r -> String in
                let values = parent.rows[r].enumerated().map { i, v in literal(v, column: i) }
                return "INSERT INTO \(SQL.id(name)) (\(cols)) VALUES (\(values.joined(separator: ", ")));"
            }
            copy(sql.joined(separator: "\n"))
        }

        private func literal(_ v: String?, column: Int) -> String {
            guard let v else { return "NULL" }
            let family = info(column)?.family
            if family?.isNumeric == true, Double(v) != nil { return v }
            if info(column)?.isBinary == true, v.hasPrefix("0x") { return v }
            return SQL.val(v)
        }

        @objc func setNull() {
            guard let table, parent.editable, value(table.clickedRow, table.clickedColumn) != nil else { return }
            parent.onEdit?(table.clickedRow, table.clickedColumn, nil)
        }
    }

    // MARK: - Helpers

    /// Short, single-line values can be edited in place; others are shown flattened.
    static func isSimple(_ text: String) -> Bool {
        text.count <= 2000 && !text.contains("\n") && !text.contains("\r")
    }

    static func flatten(_ text: String) -> String {
        guard !isSimple(text) else { return text }
        return String(text.prefix(300)).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ⏎ ")
    }
}

// MARK: - Table and header

/// NSTableView that copies the selected rows on Cmd-C.
final class GridTableView: NSTableView {
    weak var gridCoordinator: GridView.Coordinator?

    @objc func copy(_ sender: Any?) { gridCoordinator?.copySelection() }

    /// Stripes only behind real rows: below the last row the grid stays one calm colour, so a short result
    /// doesn't look like a full table.
    override func drawBackground(inClipRect clipRect: NSRect) {
        let rowsEnd = numberOfRows > 0 ? rect(ofRow: numberOfRows - 1).maxY : bounds.minY
        let rows = clipRect.intersection(NSRect(x: clipRect.minX, y: bounds.minY, width: clipRect.width, height: rowsEnd - bounds.minY))
        if !rows.isEmpty { super.drawBackground(inClipRect: rows) }
        let rest = clipRect.intersection(NSRect(x: clipRect.minX, y: rowsEnd, width: clipRect.width, height: max(0, clipRect.maxY - rowsEnd)))
        if !rest.isEmpty {
            (NSColor.alternatingContentBackgroundColors.first ?? .textBackgroundColor).setFill()
            rest.fill()
        }
    }

    /// Draws the faint column lines only where there are rows, not down the empty space below them.
    override func drawGrid(inClipRect clipRect: NSRect) {
        guard numberOfRows > 0 else { return }
        let rowsArea = NSRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: rect(ofRow: numberOfRows - 1).maxY)
        let clip = clipRect.intersection(rowsArea)
        if !clip.isEmpty { super.drawGrid(inClipRect: clip) }
    }
}

/// What a header shows. Kept in the cell's `representedObject` (NSCell copies are bitwise, so the
/// cell subclass itself holds no Swift stored properties).
final class GridHeaderInfo: NSObject {
    let name: String
    let type: String?
    let primary: Bool
    let right: Bool
    /// 1 ascending, -1 descending, 0 not sorted.
    var sort = 0

    init(name: String, type: String?, primary: Bool, right: Bool) {
        self.name = name
        self.type = type
        self.primary = primary
        self.right = right
    }
}

/// Header cell: column name, optional key symbol, optional type line below, sort chevron.
final class GridHeaderCell: NSTableHeaderCell {
    static let titleFont = NSFont.systemFont(ofSize: 11.5, weight: .semibold)
    static let typeFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .regular)

    override func drawInterior(withFrame frame: NSRect, in view: NSView) {
        guard let info = representedObject as? GridHeaderInfo else {
            super.drawInterior(withFrame: frame, in: view)
            return
        }
        let flipped = view.isFlipped
        var box = frame.insetBy(dx: GridView.cellPadding, dy: 0)
        let titleH = ceil(Self.titleFont.ascender - Self.titleFont.descender + Self.titleFont.leading)
        let typeH = ceil(Self.typeFont.ascender - Self.typeFont.descender + Self.typeFont.leading)
        let total = info.type == nil ? titleH : titleH + 1 + typeH
        let top = (frame.height - total) / 2
        func y(_ offset: CGFloat, _ h: CGFloat) -> CGFloat {
            flipped ? frame.minY + offset : frame.maxY - offset - h
        }

        if info.sort != 0, let img = Self.symbol(info.sort > 0 ? "chevron.up" : "chevron.down",
                                                  size: 8, color: .secondaryLabelColor) {
            let s = img.size
            img.draw(in: NSRect(x: box.maxX - s.width, y: y(top + (titleH - s.height) / 2, s.height),
                                width: s.width, height: s.height))
            box.size.width -= s.width + 5
        }

        let key = info.primary ? Self.symbol("key.fill", size: 8.5, color: .systemYellow) : nil
        let keyW = key.map { $0.size.width + 4 } ?? 0
        let nameW = min(ceil((info.name as NSString).size(withAttributes: [.font: Self.titleFont]).width),
                        max(0, box.width - keyW))
        let nameX = info.right ? box.maxX - nameW : box.minX + keyW
        if let key {
            let s = key.size
            key.draw(in: NSRect(x: nameX - keyW, y: y(top + (titleH - s.height) / 2, s.height),
                                width: s.width, height: s.height))
        }
        (info.name as NSString).draw(in: NSRect(x: nameX, y: y(top, titleH), width: nameW, height: titleH),
                                     withAttributes: Self.attributes(Self.titleFont, .headerTextColor, right: info.right))
        if let type = info.type {
            (type as NSString).draw(in: NSRect(x: box.minX, y: y(top + titleH + 1, typeH), width: box.width, height: typeH),
                                    withAttributes: Self.attributes(Self.typeFont, .secondaryLabelColor, right: info.right))
        }
    }

    private static func attributes(_ font: NSFont, _ color: NSColor, right: Bool) -> [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.alignment = right ? .right : .left
        p.lineBreakMode = .byTruncatingTail
        return [.font: font, .foregroundColor: color, .paragraphStyle: p]
    }

    /// An SF Symbol tinted with a (dynamic) colour at draw time.
    private static func symbol(_ name: String, size: CGFloat, color: NSColor) -> NSImage? {
        guard let base = NSImage(systemSymbolName: name, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: size, weight: .bold)) else { return nil }
        return NSImage(size: base.size, flipped: false) { r in
            base.draw(in: r)
            color.set()
            r.fill(using: .sourceAtop)
            return true
        }
    }
}
