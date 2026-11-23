import SwiftUI
import AppKit

struct GridView: NSViewRepresentable {
    var columns: [String]
    var rows: [[String?]]
    var version: Int
    var editable = false
    var sortColumn: String? = nil
    var ascending = true
    var selection: Binding<IndexSet>? = nil
    var onEdit: ((Int, Int, String?) -> Void)? = nil
    var onSort: ((String) -> Void)? = nil

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = NSTableView()
        tv.usesAlternatingRowBackgroundColors = true
        tv.gridStyleMask = [.solidVerticalGridLineMask]
        tv.columnAutoresizingStyle = .noColumnAutoresizing
        tv.allowsMultipleSelection = true
        tv.allowsColumnReordering = false
        tv.rowHeight = 22
        tv.style = .fullWidth
        tv.dataSource = context.coordinator
        tv.delegate = context.coordinator

        let menu = NSMenu()
        let copy = NSMenuItem(title: "Copy Cell", action: #selector(Coordinator.copyCell), keyEquivalent: "")
        copy.target = context.coordinator
        menu.addItem(copy)
        if editable {
            let null = NSMenuItem(title: "Set to NULL", action: #selector(Coordinator.setNull), keyEquivalent: "")
            null.target = context.coordinator
            menu.addItem(null)
        }
        tv.menu = menu

        let sv = NSScrollView()
        sv.documentView = tv
        sv.hasVerticalScroller = true
        sv.hasHorizontalScroller = true
        sv.borderType = .noBorder
        context.coordinator.table = tv
        return sv
    }

    func updateNSView(_ sv: NSScrollView, context: Context) {
        let c = context.coordinator
        c.parent = self
        guard let tv = c.table else { return }
        if c.builtColumns != columns {
            c.rebuildColumns()
            c.version = version
            tv.deselectAll(nil)
            tv.reloadData()
        } else if c.version != version {
            c.version = version
            tv.deselectAll(nil)
            tv.reloadData()
        }
        c.updateSortIndicator()
    }

    final class Coordinator: NSObject, NSTableViewDataSource, NSTableViewDelegate, NSTextFieldDelegate {
        var parent: GridView
        weak var table: NSTableView?
        var builtColumns: [String] = []
        var version = -1

        init(_ parent: GridView) { self.parent = parent }

        func rebuildColumns() {
            guard let table else { return }
            for c in table.tableColumns { table.removeTableColumn(c) }
            for (i, name) in parent.columns.enumerated() {
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("c\(i)"))
                col.title = name
                let sample = parent.rows.prefix(40).map { $0.count > i ? min($0[i]?.count ?? 6, 60) : 0 }.max() ?? 0
                col.width = min(380, max(64, CGFloat(max(name.count + 2, sample)) * 7.4 + 20))
                col.minWidth = 40
                table.addTableColumn(col)
            }
            builtColumns = parent.columns
        }

        func updateSortIndicator() {
            guard let table else { return }
            for (i, col) in table.tableColumns.enumerated() {
                let active = i < parent.columns.count && parent.columns[i] == parent.sortColumn
                table.setIndicatorImage(active ? NSImage(named: parent.ascending ? "NSAscendingSortIndicator"
                                                                                  : "NSDescendingSortIndicator") : nil,
                                        in: col)
            }
        }

        private func value(_ row: Int, _ col: Int) -> String?? {
            guard row >= 0, col >= 0, row < parent.rows.count, col < parent.rows[row].count else { return nil }
            return .some(parent.rows[row][col])
        }

        private func columnIndex(_ col: NSTableColumn?) -> Int? {
            col.flatMap { Int($0.identifier.rawValue.dropFirst()) }
        }

        func numberOfRows(in tableView: NSTableView) -> Int { parent.rows.count }

        func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
            guard let ci = columnIndex(tableColumn), let cell = value(row, ci) else { return nil }
            let ident = NSUserInterfaceItemIdentifier("cell")
            let view: NSTableCellView
            if let reused = tableView.makeView(withIdentifier: ident, owner: nil) as? NSTableCellView {
                view = reused
            } else {
                view = NSTableCellView()
                view.identifier = ident
                let field = NSTextField()
                field.isBordered = false
                field.drawsBackground = false
                field.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
                field.lineBreakMode = .byTruncatingTail
                field.cell?.usesSingleLineMode = true
                field.delegate = self
                field.translatesAutoresizingMaskIntoConstraints = false
                view.addSubview(field)
                view.textField = field
                NSLayoutConstraint.activate([
                    field.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 2),
                    field.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -2),
                    field.centerYAnchor.constraint(equalTo: view.centerYAnchor),
                ])
            }
            guard let tf = view.textField else { return view }
            if let text = cell {
                let simple = text.count <= 2000 && !text.contains("\n") && !text.contains("\r")
                tf.stringValue = simple ? text
                    : String(text.prefix(300)).replacingOccurrences(of: "\r", with: "").replacingOccurrences(of: "\n", with: " ⏎ ")
                tf.placeholderString = nil
                tf.isEditable = parent.editable && simple
            } else {
                tf.stringValue = ""
                tf.placeholderString = "(NULL)"
                tf.isEditable = parent.editable
            }
            return view
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

        func tableViewSelectionDidChange(_ note: Notification) {
            guard let table, let binding = parent.selection else { return }
            let sel = table.selectedRowIndexes
            DispatchQueue.main.async { if binding.wrappedValue != sel { binding.wrappedValue = sel } }
        }

        @objc func copyCell() {
            guard let table, let cell = value(table.clickedRow, table.clickedColumn) else { return }
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(cell ?? "NULL", forType: .string)
        }

        @objc func setNull() {
            guard let table, parent.editable, value(table.clickedRow, table.clickedColumn) != nil else { return }
            parent.onEdit?(table.clickedRow, table.clickedColumn, nil)
        }
    }
}
