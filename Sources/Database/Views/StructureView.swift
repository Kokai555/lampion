import SwiftUI
import AppKit

/// The Structure tab: columns, indexes, foreign keys and the CREATE statement of the selected table.
struct StructureView: View {
    @EnvironmentObject var m: DBModel

    private var isView: Bool { m.currentTableInfo?.isView == true }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("", selection: $m.structureSection) {
                    ForEach(StructureSection.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden().fixedSize()
                Spacer()
                actions
                Divider().frame(height: 16)
                Button("Table Options…") { m.sheet = .tableOptions }.disabled(isView)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
            Divider()
            content
        }
        .alert("Done", isPresented: Binding(get: { m.infoMessage != nil }, set: { if !$0 { m.infoMessage = nil } })) {
            Button("OK") {}
        } message: { Text(m.infoMessage ?? "") }
    }

    @ViewBuilder
    private var actions: some View {
        switch m.structureSection {
        case .columns:
            Button { m.sheet = .addColumn } label: { Label("Add Column", systemImage: "plus") }.disabled(isView)
            Button { m.sheet = .editColumn } label: { Label("Edit", systemImage: "pencil") }
                .disabled(m.selectedColumns.count != 1 || isView)
            Button {
                guard let i = m.selectedColumns.first, i < m.columns.count else { return }
                let name = m.columns[i].name
                m.confirm = ConfirmRequest(title: "Delete the column “\(name)”?",
                                           message: "All data in the column will be permanently deleted.",
                                           button: "Delete") { m.dropColumn(name) }
            } label: { Label("Delete", systemImage: "minus") }
            .disabled(m.selectedColumns.count != 1 || isView)
        case .indexes:
            Button { m.sheet = .addIndex } label: { Label("Add Index", systemImage: "plus") }.disabled(isView)
            Button {
                guard let i = m.selectedIndexes.first, i < m.indexList.count else { return }
                let name = m.indexList[i].name
                m.confirm = ConfirmRequest(title: name == "PRIMARY" ? "Delete the primary key?" : "Delete the index “\(name)”?",
                                           message: "The data stays; only the index is removed.",
                                           button: "Delete") { m.dropIndex(name) }
            } label: { Label("Delete", systemImage: "minus") }
            .disabled(m.selectedIndexes.count != 1 || isView)
        case .foreignKeys:
            Button { m.sheet = .addForeignKey } label: { Label("Add Foreign Key", systemImage: "plus") }.disabled(isView)
            Button {
                guard let i = m.selectedForeignKeys.first, i < m.foreignKeys.count else { return }
                let name = m.foreignKeys[i].name
                m.confirm = ConfirmRequest(title: "Delete the foreign key “\(name)”?",
                                           message: "The data stays; only the relationship is removed.",
                                           button: "Delete") { m.dropForeignKey(name) }
            } label: { Label("Delete", systemImage: "minus") }
            .disabled(m.selectedForeignKeys.count != 1 || isView)
        case .sql:
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(m.createSQL, forType: .string)
            } label: { Label("Copy", systemImage: "doc.on.doc") }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch m.structureSection {
        case .columns:
            GridView(columns: ["Name", "Type", "NULL", "Key", "Default", "Extra", "Collation", "Comment"],
                     rows: m.columns.map { [$0.name, $0.type, $0.null, $0.key, $0.def, $0.extra, $0.collation, $0.comment] },
                     version: m.dataVersion &+ m.columns.map(\.type).joined().hashValue, selection: $m.selectedColumns)
        case .indexes:
            if m.indexList.isEmpty {
                empty("This table has no indexes.")
            } else {
                GridView(columns: ["Name", "Columns", "Unique", "Type"],
                         rows: m.indexList.map { [$0.name, $0.columns.joined(separator: ", "), $0.unique ? "yes" : "no", $0.type] },
                         version: m.dataVersion &+ m.indexList.map(\.name).joined().hashValue, selection: $m.selectedIndexes)
            }
        case .foreignKeys:
            if m.foreignKeys.isEmpty {
                empty("This table has no foreign keys.")
            } else {
                GridView(columns: ["Name", "Column", "References", "On Update", "On Delete"],
                         rows: m.foreignKeys.map { [$0.name, $0.column, "\($0.refTable).\($0.refColumn)", $0.updateRule, $0.deleteRule] },
                         version: m.dataVersion &+ m.foreignKeys.map(\.id).joined().hashValue, selection: $m.selectedForeignKeys)
            }
        case .sql:
            ScrollView {
                Text(m.createSQL)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
        }
    }

    private func empty(_ text: String) -> some View {
        Text(text).foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
