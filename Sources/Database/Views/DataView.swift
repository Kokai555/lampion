import SwiftUI
import AppKit

/// The Data tab: a filter bar, the rows of the selected table, paging, and an optional row inspector.
struct DataView: View {
    @EnvironmentObject var m: DBModel
    @FocusState private var filterFocused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isView: Bool { m.currentTableInfo?.isView == true }

    var body: some View {
        HStack(spacing: 0) {
            VStack(spacing: 0) {
                topBar
                content
                bottomBar
            }
            .frame(minWidth: 320)
            if m.showInspector {
                // Divider and panel move as one piece, so the edge doesn't pop in ahead of the panel.
                HStack(spacing: 0) {
                    Divider()
                    RowInspector()
                        .frame(width: 300)
                }
                .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .clipped()
    }

    private func toggleInspector() {
        withAnimation(DBMotion.spring(reduceMotion)) { m.showInspector.toggle() }
    }

    // MARK: Top bar

    private var topBar: some View {
        DBBar {
            filterField
            Button { m.loadData() } label: { Image(systemName: "arrow.clockwise") }
                .help("Reload rows")
            Divider().frame(height: 18)
            Button { m.sheet = .insertRow } label: { Image(systemName: "plus") }
                .disabled(isView)
                .help(isView ? "Views can't be edited" : "Add a new row")
            Button(role: .destructive) {
                let n = m.selectedRows.count
                m.confirm = ConfirmRequest(title: n == 1 ? "Delete the selected row?" : "Delete the \(n) selected rows?",
                                           message: "This can't be undone.", button: "Delete") { m.deleteSelectedRows() }
            } label: { Image(systemName: "trash") }
                .disabled(m.selectedRows.isEmpty || isView)
                .help(m.selectedRows.count > 1 ? "Delete the \(m.selectedRows.count) selected rows" : "Delete the selected row")
            Divider().frame(height: 18)
            Toggle(isOn: Binding(get: { m.showInspector }, set: { if $0 != m.showInspector { toggleInspector() } })) {
                Image(systemName: "sidebar.right")
            }
            .toggleStyle(.button)
            .help(m.showInspector ? "Hide row details" : "Show row details")
        }
        .buttonStyle(.borderless)
        .imageScale(.large)
    }

    private var filterField: some View {
        HStack(spacing: 6) {
            Text("WHERE")
                .font(.system(size: 9.5, weight: .bold, design: .monospaced))
                .foregroundStyle(DBStyle.databaseTint)
                .padding(.horizontal, 5).padding(.vertical, 2)
                .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(DBStyle.databaseTint.opacity(0.14)))
            TextField("", text: $m.filter, prompt: Text("e.g. id > 10 AND name LIKE 'a%'").foregroundStyle(.tertiary))
                .textFieldStyle(.plain)
                .font(DBStyle.mono)
                .focused($filterFocused)
                .onSubmit(applyFilter)
            if !m.filter.isEmpty {
                Button {
                    m.filter = ""
                    applyFilter()
                } label: {
                    Image(systemName: "xmark.circle.fill").imageScale(.medium).foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
                .help("Clear the filter")
            }
        }
        .padding(.leading, 5).padding(.trailing, 7)
        .frame(height: 26)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Color(nsColor: .textBackgroundColor)))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .strokeBorder(filterFocused ? Color.accentColor.opacity(0.8) : Color.primary.opacity(0.12),
                          lineWidth: filterFocused ? 1.5 : 1))
        .help("Filter rows with a WHERE condition. Press Return to apply.")
        .frame(maxWidth: .infinity)
    }

    private func applyFilter() {
        m.offset = 0
        m.loadData()
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if let e = m.dataError {
            ContentUnavailableView {
                Label("Couldn't Load Rows", systemImage: "exclamationmark.triangle.fill")
            } description: {
                Text(e).font(DBStyle.monoSmall).textSelection(.enabled)
            } actions: {
                HStack {
                    if !m.filter.trimmed.isEmpty {
                        Button("Clear Filter") { m.filter = ""; applyFilter() }
                    }
                    Button("Try Again") { m.loadData() }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GridView(columns: m.data.columns, rows: m.data.rows, version: m.dataVersion,
                     scrollKey: scrollKey,
                     editable: !isView,
                     sortColumn: m.orderBy, ascending: m.ascending, selection: $m.selectedRows,
                     onEdit: { r, c, v in edit(row: r, column: c, value: v) },
                     onSort: { m.sort(by: $0) },
                     columnInfo: m.columns, tableName: m.currentTable)
                // The table's rows arrive after its columns: fade the grid in once instead of popping.
                .opacity(m.data.columns.isEmpty ? 0 : 1)
                .overlay {
                    // Data is replaced only when a load finishes, so this can't flash while loading.
                    if m.data.rows.isEmpty && !m.data.columns.isEmpty {
                        emptyState
                            .allowsHitTesting(false)
                            .transition(.opacity)
                    }
                }
                .animation(DBMotion.fade(reduceMotion), value: m.data.columns.isEmpty)
                .animation(DBMotion.fade(reduceMotion), value: m.data.rows.isEmpty)
        }
    }

    /// Changes when the rows shown are a different slice (table, page, sort, filter): the grid then
    /// scrolls back to the top. Edits and reloads keep the scroll position.
    private var scrollKey: String {
        "\(m.currentDB ?? "")\u{1}\(m.currentTable ?? "")\u{1}\(m.offset)\u{1}\(m.orderBy ?? "")\u{1}\(m.ascending)"
    }

    private var emptyState: some View {
        VStack(spacing: 6) {
            Image(systemName: m.filter.trimmed.isEmpty ? "tray" : "line.3.horizontal.decrease.circle")
                .font(.system(size: 26)).foregroundStyle(.tertiary)
            Text(m.filter.trimmed.isEmpty ? "No rows yet" : "No rows match the filter")
                .font(.callout).foregroundStyle(.secondary)
        }
        .padding(.top, 40)
    }

    /// Inline edit from the grid; keeps the edited row selected after the reload.
    private func edit(row: Int, column: Int, value: String?) {
        guard row < m.data.rows.count else { return }
        var expected = m.data.rows[row]
        if column < expected.count { expected[column] = value }
        m.updateCell(row: row, column: column, value: value) { m.reselectRow(like: expected, fallback: row) }
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        DBBar(edge: .bottom) {
            Text(rangeText)
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .help("Double-click a cell to edit it. Right-click a cell to copy it or set it to NULL.")
            if m.selectedRows.count > 0 {
                Text("·").foregroundStyle(.tertiary)
                Text("\(m.selectedRows.count) selected")
                    .font(.callout).monospacedDigit().foregroundStyle(.secondary)
            }
            if let sort = m.orderBy {
                sortChip(sort)
            }
            Spacer()
            Button { m.page(-1) } label: { Image(systemName: "chevron.left") }
                .disabled(m.offset == 0)
                .help("Previous \(DBModel.pageSize) rows")
            Button { m.page(1) } label: { Image(systemName: "chevron.right") }
                .disabled(m.offset + m.data.rows.count >= (m.totalRows ?? 0))
                .help("Next \(DBModel.pageSize) rows")
        }
        .buttonStyle(.borderless)
    }

    private func sortChip(_ column: String) -> some View {
        Button {
            m.orderBy = nil
            m.loadData()
        } label: {
            HStack(spacing: 4) {
                Image(systemName: m.ascending ? "arrow.up" : "arrow.down").font(.system(size: 9, weight: .bold))
                Text(column).font(.system(size: 11, weight: .medium, design: .monospaced)).lineLimit(1)
                Image(systemName: "xmark").font(.system(size: 8, weight: .bold)).foregroundStyle(.secondary)
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(Capsule().fill(Color.accentColor.opacity(0.12)))
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .help("Sorted by \(column), \(m.ascending ? "ascending" : "descending"). Click to remove the sort.")
    }

    private var rangeText: String {
        let count = m.data.rows.count
        guard count > 0 else { return m.offset > 0 ? "No more rows" : "0 rows" }
        let range = "\(m.offset + 1)–\(m.offset + count)"
        guard let total = m.totalRows else { return "\(range) rows" }
        return "\(range) of \(total) \(total == 1 ? "row" : "rows")"
    }
}
