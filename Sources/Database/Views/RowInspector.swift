import SwiftUI
import AppKit

/// Panel beside the data grid showing every field of the selected row, editable as a form.
struct RowInspector: View {
    @EnvironmentObject var m: DBModel

    var body: some View {
        let selected = m.selectedRows
        Group {
            if selected.count > 1 {
                ContentUnavailableView {
                    Label("\(selected.count) Rows Selected", systemImage: "rectangle.stack")
                } description: {
                    Text("Select a single row to see and edit its fields.")
                }
            } else if let row = selected.first, row < m.data.rows.count {
                RowEditor(row: row, values: m.data.rows[row])
                    .id("\(m.dataVersion)-\(row)")
            } else {
                ContentUnavailableView {
                    Label("No Row Selected", systemImage: "cursorarrow.click")
                } description: {
                    Text("Select a row to see all of its fields here.")
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }
}

private struct RowEditor: View {
    @EnvironmentObject var m: DBModel
    let row: Int
    let original: [String?]
    @State private var draft: [String?]

    init(row: Int, values: [String?]) {
        self.row = row
        self.original = values
        _draft = State(initialValue: values)
    }

    private var readOnlyTable: Bool { m.currentTable == nil || m.currentTableInfo?.isView == true }

    private var changed: [Int] {
        draft.indices.filter { $0 < original.count && draft[$0] != original[$0] }
    }

    var body: some View {
        VStack(spacing: 0) {
            DBBar {
                VStack(alignment: .leading, spacing: 1) {
                    Text("Row \(m.offset + row + 1)").font(.headline)
                    Text(keyText).font(DBStyle.monoSmall).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
                Spacer(minLength: 4)
                if readOnlyTable {
                    Label("Read-only", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
                        .help(m.currentTableInfo?.isView == true ? "Views can't be edited here." : "Read-only")
                }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(m.data.columns.indices, id: \.self) { i in
                        if i < draft.count { field(i) }
                    }
                }
                .padding(14)
            }

            if !readOnlyTable {
                DBBar(edge: .bottom) {
                    Text(changed.isEmpty ? "No changes" : changed.count == 1 ? "1 field changed" : "\(changed.count) fields changed")
                        .font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Revert") { draft = original }
                        .disabled(changed.isEmpty)
                        .help("Discard your changes to this row")
                    Button("Save") { save() }
                        .buttonStyle(.borderedProminent)
                        .disabled(changed.isEmpty)
                        .help("Write the changed fields to the database")
                }
                .controlSize(.small)
            }
        }
    }

    // MARK: Header

    private var keyText: String {
        let pk = m.columns.filter(\.isPrimary).map(\.name)
        guard !pk.isEmpty else { return m.currentTable.map { "\($0) · no primary key" } ?? "" }
        return pk.map { name in
            let v = m.data.index(name).flatMap { $0 < original.count ? original[$0] : nil }
            return "\(name) = \(v ?? "NULL")"
        }.joined(separator: ", ")
    }

    // MARK: Fields

    @ViewBuilder
    private func field(_ i: Int) -> some View {
        let name = m.data.columns[i]
        let info = m.columns.first { $0.name == name }
        let editable = !readOnlyTable && info?.isBinary != true
        let isChanged = i < original.count && draft[i] != original[i]

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Text(name).font(.system(size: 12, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle)
                    .help(info.map { $0.comment.isEmpty ? name : "\(name)\n\($0.comment)" } ?? name)
                if isChanged {
                    Circle().fill(Color.accentColor).frame(width: 6, height: 6).help("Changed")
                }
                Spacer(minLength: 4)
                ForEach(Array((info?.badges ?? []).filter { $0 != .notNull }.enumerated()), id: \.offset) { _, kind in
                    KeyBadge(kind: kind)
                }
            }
            HStack(spacing: 6) {
                if let info { TypeChip(type: info.type) }
                Spacer(minLength: 4)
                if editable && (info?.isNullable ?? true) {
                    Toggle("NULL", isOn: nullBinding(i))
                        .toggleStyle(.checkbox)
                        .controlSize(.small)
                        .font(.caption)
                        .help("Store NULL (no value) in this field")
                }
            }
            value(i, info: info, editable: editable, changed: isChanged)
        }
    }

    private func nullBinding(_ i: Int) -> Binding<Bool> {
        Binding(get: { draft[i] == nil },
                set: { isNull in
                    if isNull { draft[i] = nil }
                    else { draft[i] = (i < original.count ? original[i] : nil) ?? "" }
                })
    }

    private func textBinding(_ i: Int) -> Binding<String> {
        Binding(get: { draft[i] ?? "" }, set: { draft[i] = $0 })
    }

    private func isLong(_ i: Int, info: ColumnInfo?) -> Bool {
        let v = (i < original.count ? original[i] : nil) ?? ""
        let t = info?.type.lowercased() ?? ""
        return t.contains("text") || t.hasPrefix("json") || v.contains("\n") || v.count > 60
    }

    @ViewBuilder
    private func value(_ i: Int, info: ColumnInfo?, editable: Bool, changed: Bool) -> some View {
        let stroke = changed ? Color.accentColor.opacity(0.7) : Color.primary.opacity(0.1)
        if draft[i] == nil {
            HStack {
                NullLabel()
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 24)
            .background(box(stroke))
            .contentShape(Rectangle())
            .onTapGesture { if editable { draft[i] = "" } }
            .help(editable ? "NULL. Click to enter a value." : "NULL")
        } else if !editable {
            Text(String((draft[i] ?? "").prefix(4000)))
                .font(DBStyle.mono)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .lineLimit(12)
                .frame(maxWidth: .infinity, minHeight: 16, alignment: .leading)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(box(stroke))
                .help(info?.isBinary == true ? "Binary data can't be edited here." : "Read-only")
        } else if isLong(i, info: info) {
            TextEditor(text: textBinding(i))
                .font(DBStyle.mono)
                .scrollContentBackground(.hidden)
                .padding(4)
                .frame(height: 96)
                .background(box(stroke))
        } else {
            TextField("", text: textBinding(i), prompt: Text("Empty"))
                .textFieldStyle(.plain)
                .font(DBStyle.mono)
                .multilineTextAlignment(info?.family.isNumeric == true ? .trailing : .leading)
                .padding(.horizontal, 8)
                .frame(height: 24)
                .background(box(stroke))
        }
    }

    private func box(_ stroke: Color) -> some View {
        RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(Color(nsColor: .textBackgroundColor))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(stroke))
    }

    private func save() {
        var values: [Int: String?] = [:]
        for i in changed { values[i] = draft[i] }
        m.updateRow(row, values: values)
    }
}

// MARK: - Row updates

extension DBModel {
    /// Writes several fields of one data row in a single UPDATE, reloads, and keeps the row selected.
    func updateRow(_ row: Int, values: [Int: String?], then: (() -> Void)? = nil) {
        guard let fq, row < data.rows.count, !values.isEmpty else { return }
        let original = data.rows[row]
        var expected = original
        var sets: [String] = []
        for (c, v) in values.sorted(by: { $0.key < $1.key }) where c < data.columns.count {
            let name = data.columns[c]
            sets.append("\(SQL.id(name)) = \(rowEditLiteral(v, column: name))")
            if c < expected.count { expected[c] = v }
        }
        let match = rowEditMatch(original)
        guard !sets.isEmpty, !match.isEmpty else { return }
        _ = fq
        updateOneRow(set: sets.joined(separator: ", "), where: match) { _ in
            self.loadData {
                self.reselectRow(like: expected, fallback: row)
                then?()
            }
        }
    }

    /// After a reload, selects the row whose key values match `expected` (or the same position).
    func reselectRow(like expected: [String?], fallback: Int) {
        let keys = rowEditKeyIndexes
        let found = keys.isEmpty ? nil : data.rows.firstIndex { r in
            keys.allSatisfy { $0 < r.count && $0 < expected.count && r[$0] == expected[$0] }
        }
        if let found { selectedRows = [found] }
        else if fallback < data.rows.count { selectedRows = [fallback] }
    }

    private var rowEditKeyIndexes: [Int] { rowKeyColumns.compactMap { data.index($0) } }

    private func rowEditMatch(_ r: [String?]) -> String {
        rowEditKeyIndexes.filter { $0 < r.count }.map {
            "\(SQL.id(data.columns[$0])) <=> \(rowEditLiteral(r[$0], column: data.columns[$0]))"
        }.joined(separator: " AND ")
    }

    private func rowEditLiteral(_ value: String?, column: String) -> String {
        guard let value else { return "NULL" }
        if value.hasPrefix("0x"), columns.first(where: { $0.name == column })?.isBinary == true { return value }
        return SQL.val(value)
    }
}
