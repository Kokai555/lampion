import SwiftUI
import AppKit

struct StructureView: View {
    @EnvironmentObject var m: DBModel

    var body: some View {
        VSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 8) {
                    Text("Columns").font(.headline)
                    Spacer()
                    Button { m.sheet = .addColumn } label: { Label("Add Column", systemImage: "plus") }
                        .disabled(m.currentTableInfo?.isView == true)
                    Button {
                        guard let i = m.selectedColumns.first, i < m.columns.count else { return }
                        let name = m.columns[i].name
                        m.confirm = ConfirmRequest(title: "Delete the column “\(name)”?",
                                                   message: "All data in the column will be permanently deleted.",
                                                   button: "Delete") { m.dropColumn(name) }
                    } label: { Label("Delete Column", systemImage: "minus") }
                    .disabled(m.selectedColumns.count != 1 || m.currentTableInfo?.isView == true)
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
                Divider()
                GridView(columns: ["Name", "Type", "NULL", "Key", "Default", "Extra", "Collation", "Comment"],
                         rows: m.columns.map { [$0.name, $0.type, $0.null, $0.key, $0.def, $0.extra, $0.collation, $0.comment] },
                         version: m.dataVersion &+ m.columns.count, selection: $m.selectedColumns)
            }
            .frame(minHeight: 150)

            VStack(spacing: 0) {
                HStack { Text("Indexes").font(.headline); Spacer() }.padding(.horizontal, 12).padding(.vertical, 6)
                Divider()
                GridView(columns: ["Index", "Column", "Unique", "Type"],
                         rows: m.indexes.rows.indices.map { i in
                             [m.indexes.value(i, "Key_name"), m.indexes.value(i, "Column_name"),
                              m.indexes.value(i, "Non_unique") == "0" ? "yes" : "no", m.indexes.value(i, "Index_type")]
                         },
                         version: m.dataVersion &+ m.indexes.rows.count)
            }
            .frame(minHeight: 90)

            ScrollView {
                Text(m.createSQL)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .frame(minHeight: 90)
        }
    }
}
