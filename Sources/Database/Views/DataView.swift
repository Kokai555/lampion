import SwiftUI
import AppKit

struct DataView: View {
    @EnvironmentObject var m: DBModel

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Image(systemName: "line.3.horizontal.decrease.circle").foregroundStyle(.secondary)
                TextField("Filter – WHERE condition, e.g. id > 10 AND name LIKE 'a%'", text: $m.filter)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { m.offset = 0; m.loadData() }
                Button { m.loadData() } label: { Image(systemName: "arrow.clockwise") }.help("Reload data")
                Divider().frame(height: 16)
                Button { m.sheet = .insertRow } label: { Label("New Row", systemImage: "plus") }
                    .disabled(m.currentTableInfo?.isView == true)
                Button {
                    let n = m.selectedRows.count
                    m.confirm = ConfirmRequest(title: "Delete the \(n) selected rows?", message: "This can't be undone.",
                                               button: "Delete") { m.deleteSelectedRows() }
                } label: { Label("Delete", systemImage: "minus") }
                .disabled(m.selectedRows.isEmpty || m.currentTableInfo?.isView == true)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()

            if let e = m.dataError {
                Text(e).foregroundStyle(.red).textSelection(.enabled).padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                GridView(columns: m.data.columns, rows: m.data.rows, version: m.dataVersion,
                         editable: m.currentTableInfo?.isView != true,
                         sortColumn: m.orderBy, ascending: m.ascending, selection: $m.selectedRows,
                         onEdit: { r, c, v in m.updateCell(row: r, column: c, value: v) },
                         onSort: { m.sort(by: $0) })
            }

            Divider()
            HStack(spacing: 10) {
                Text(rangeText).font(.callout).foregroundStyle(.secondary).monospacedDigit()
                Spacer()
                Text("Double-click to edit · right-click for NULL / copy").font(.caption).foregroundStyle(.secondary)
                Button { m.page(-1) } label: { Image(systemName: "chevron.left") }.disabled(m.offset == 0)
                Button { m.page(1) } label: { Image(systemName: "chevron.right") }
                    .disabled(m.offset + m.data.rows.count >= (m.totalRows ?? 0))
            }
            .padding(.horizontal, 12).padding(.vertical, 6)
        }
    }

    private var rangeText: String {
        let count = m.data.rows.count
        guard count > 0 else { return "0 rows" }
        let total = m.totalRows.map { " / \($0)" } ?? ""
        return "\(m.offset + 1)–\(m.offset + count)\(total) rows"
    }
}
