import SwiftUI
import AppKit

/// Lebegő javaslatlista a kurzor alatt. Nem veszi el a fókuszt, így a gépelés folytatható.
final class SuggestionPanel: NSObject, NSTableViewDataSource, NSTableViewDelegate {
    private final class RowView: NSTableRowView {
        override var isEmphasized: Bool { get { true } set {} }
    }

    private let panel: NSPanel
    private let table = NSTableView()
    private(set) var items: [String] = []
    private(set) var navigated = false
    var onPick: ((String) -> Void)?
    var isVisible: Bool { panel.isVisible }
    var selected: String? {
        let r = table.selectedRow
        return r >= 0 && r < items.count ? items[r] : nil
    }

    override init() {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 120),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        super.init()
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.hasShadow = true
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hidesOnDeactivate = false

        let effect = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 220, height: 120))
        effect.material = .menu
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 8
        effect.layer?.masksToBounds = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("word"))
        column.resizingMask = .autoresizingMask
        table.addTableColumn(column)
        table.headerView = nil
        table.backgroundColor = .clear
        table.rowHeight = 20
        table.style = .plain
        table.intercellSpacing = NSSize(width: 0, height: 0)
        table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
        table.refusesFirstResponder = true
        table.dataSource = self
        table.delegate = self
        table.target = self
        table.action = #selector(clicked)

        let scroll = NSScrollView(frame: effect.bounds.insetBy(dx: 0, dy: 4))
        scroll.autoresizingMask = [.width, .height]
        scroll.documentView = table
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.scrollerStyle = .overlay
        effect.addSubview(scroll)
        panel.contentView = effect
    }

    /// `below`: a lista bal felső sarka képernyő-koordinátában.
    func show(_ list: [String], below point: NSPoint, parent: NSWindow) {
        items = Array(list.prefix(40))
        navigated = false
        let height = CGFloat(min(items.count, 8)) * 20 + 8
        let width = min(460, max(180, CGFloat(items.map(\.count).max() ?? 10) * 7.3 + 40))
        panel.setFrame(NSRect(x: point.x, y: point.y - height, width: width, height: height), display: true)
        table.reloadData()
        table.sizeLastColumnToFit()
        table.selectRowIndexes([0], byExtendingSelection: false)
        table.scrollRowToVisible(0)
        if panel.parent !== parent {
            panel.parent?.removeChildWindow(panel)
            parent.addChildWindow(panel, ordered: .above)
        }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
        items = []
    }

    func move(_ delta: Int) {
        guard !items.isEmpty else { return }
        let row = max(0, min(items.count - 1, table.selectedRow + delta))
        table.selectRowIndexes([row], byExtendingSelection: false)
        table.scrollRowToVisible(row)
        navigated = true
    }

    @objc private func clicked() {
        let row = table.clickedRow
        if row >= 0, row < items.count { onPick?(items[row]) }
    }

    func numberOfRows(in tableView: NSTableView) -> Int { items.count }

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? { RowView() }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        let ident = NSUserInterfaceItemIdentifier("suggestion")
        let cell: NSTableCellView
        if let reused = tableView.makeView(withIdentifier: ident, owner: nil) as? NSTableCellView {
            cell = reused
        } else {
            cell = NSTableCellView()
            cell.identifier = ident
            let label = NSTextField(labelWithString: "")
            label.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
            label.lineBreakMode = .byTruncatingTail
            label.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(label)
            cell.textField = label
            NSLayoutConstraint.activate([
                label.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 10),
                label.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
                label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            ])
        }
        cell.textField?.stringValue = row < items.count ? items[row] : ""
        return cell
    }
}
