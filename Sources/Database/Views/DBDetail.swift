import SwiftUI
import AppKit

struct DBDetail: View {
    @EnvironmentObject var m: DBModel

    var body: some View {
        VStack(spacing: 0) {
            Picker("", selection: $m.tab) {
                ForEach(m.availableTabs, id: \.self) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).labelsHidden().fixedSize()
            .padding(.vertical, 8)
            Divider()
            switch m.tab {
            case .tables: TablesView()
            case .data: DataView()
            case .structure: StructureView()
            case .query: QueryView()
            }
        }
    }
}

struct TablesView: View {
    @EnvironmentObject var m: DBModel
    private static let sizeFmt: ByteCountFormatter = {
        let f = ByteCountFormatter(); f.countStyle = .binary; return f
    }()

    var body: some View {
        let list = m.currentDB.flatMap { m.tables[$0] } ?? []
        if list.isEmpty {
            VStack(spacing: 10) {
                Text("This database has no tables yet.").foregroundStyle(.secondary)
                Button("New Table…") { m.sheet = .newTable }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            GridView(columns: ["Table", "Type", "Engine", "Rows (approx.)", "Size", "Collation"],
                     rows: list.map { [$0.name, $0.isView ? "view" : "table", $0.engine, $0.rows,
                                       TablesView.sizeFmt.string(fromByteCount: $0.bytes), $0.collation] },
                     version: list.hashValue)
        }
    }
}
