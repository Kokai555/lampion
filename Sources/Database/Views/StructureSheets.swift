import SwiftUI
import AppKit

/// A text field for a column type with a menu of common types.
struct TypeField: View {
    @Binding var type: String
    var body: some View {
        HStack(spacing: 4) {
            TextField("Type", text: $type).font(.system(size: 12, design: .monospaced))
            Menu("") { ForEach(DBModel.typePresets, id: \.self) { p in Button(p) { type = p } } }
                .menuStyle(.borderlessButton).fixedSize().help("Common types")
        }
    }
}

/// Add a column, or change an existing one.
struct ColumnSheet: View {
    @EnvironmentObject var m: DBModel
    let editing: ColumnInfo?
    @State private var draft = ColumnDraft()
    @State private var position: ColumnPosition = .unchanged
    @State private var loaded = false

    var body: some View {
        SheetFrame(title: editing.map { "Edit Column – \($0.name)" } ?? "Add Column – \(m.currentTable ?? "")",
                   confirm: editing == nil ? "Add" : "Save",
                   canConfirm: !draft.name.trimmed.isEmpty && !draft.type.trimmed.isEmpty,
                   action: { m.saveColumn(draft, replacing: editing?.name, position: position) }, width: 480) {
            Form {
                TextField("Name", text: $draft.name)
                LabeledContent("Type") { TypeField(type: $draft.type) }
                Toggle("Allow NULL", isOn: $draft.nullable)
                TextField("Default", text: $draft.defaultText, prompt: Text("none"))
                    .disabled(draft.autoIncrement)
                Toggle("Auto increment", isOn: $draft.autoIncrement)
                TextField("Comment", text: $draft.comment, prompt: Text("optional"))
                Picker("Position", selection: $position) {
                    Text(editing == nil ? "At the end" : "Keep position").tag(ColumnPosition.unchanged)
                    Text("First").tag(ColumnPosition.first)
                    ForEach(m.columns.filter { $0.name != editing?.name }) { c in
                        Text("After \(c.name)").tag(ColumnPosition.after(c.name))
                    }
                }
            }
            Text("Default: leave empty for none. NULL, numbers and CURRENT_TIMESTAMP are used as written; other text is stored as a string.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let editing { draft = ColumnDraft(editing) }
        }
    }
}

/// Add an index or a primary key to the selected table.
struct IndexSheet: View {
    @EnvironmentObject var m: DBModel
    @State private var kind: IndexKind = .index
    @State private var name = ""
    @State private var chosen: [String] = []

    var body: some View {
        SheetFrame(title: "Add Index – \(m.currentTable ?? "")", confirm: "Add", canConfirm: !chosen.isEmpty,
                   action: { m.addIndex(name: name, kind: kind, columns: chosen) }) {
            Form {
                Picker("Kind", selection: $kind) { ForEach(IndexKind.allCases) { Text($0.rawValue).tag($0) } }
                TextField("Name", text: $name, prompt: Text(kind == .primary ? "PRIMARY" : "automatic"))
                    .disabled(kind == .primary)
            }
            Text("Columns, in the order you tick them:").font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(m.columns) { c in
                        Toggle(isOn: Binding(
                            get: { chosen.contains(c.name) },
                            set: { on in if on { chosen.append(c.name) } else { chosen.removeAll { $0 == c.name } } })) {
                            HStack {
                                Text(c.name)
                                Text(c.type).foregroundStyle(.secondary).font(.callout)
                                if let i = chosen.firstIndex(of: c.name), chosen.count > 1 {
                                    Text("#\(i + 1)").foregroundStyle(.secondary).font(.caption)
                                }
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 220)
        }
    }
}

/// Link a column of the selected table to a column of another table.
struct ForeignKeySheet: View {
    @EnvironmentObject var m: DBModel
    @State private var name = ""
    @State private var column = ""
    @State private var refTable = ""
    @State private var refColumn = ""
    @State private var onDelete = "RESTRICT"
    @State private var onUpdate = "RESTRICT"

    private var tables: [String] {
        (m.currentDB.flatMap { m.tables[$0] } ?? []).filter { !$0.isView }.map(\.name)
    }
    private var refColumns: [String] {
        m.currentDB.flatMap { m.completionColumns[$0]?[refTable] } ?? []
    }

    var body: some View {
        SheetFrame(title: "Add Foreign Key – \(m.currentTable ?? "")", confirm: "Add",
                   canConfirm: !column.isEmpty && !refTable.isEmpty && !refColumn.isEmpty,
                   action: { m.addForeignKey(name: name, column: column, refTable: refTable, refColumn: refColumn,
                                              onDelete: onDelete, onUpdate: onUpdate) }, width: 480) {
            Form {
                Picker("Column", selection: $column) {
                    Text("Choose…").tag("")
                    ForEach(m.columns) { Text("\($0.name)  (\($0.type))").tag($0.name) }
                }
                Picker("References table", selection: $refTable) {
                    Text("Choose…").tag("")
                    ForEach(tables, id: \.self) { Text($0).tag($0) }
                }
                Picker("References column", selection: $refColumn) {
                    Text("Choose…").tag("")
                    ForEach(refColumns, id: \.self) { Text($0).tag($0) }
                }
                .disabled(refTable.isEmpty)
                Picker("On delete", selection: $onDelete) { ForEach(DBModel.referenceRules, id: \.self) { Text($0).tag($0) } }
                Picker("On update", selection: $onUpdate) { ForEach(DBModel.referenceRules, id: \.self) { Text($0).tag($0) } }
                TextField("Name", text: $name, prompt: Text("automatic"))
            }
            Text("Both columns need the same type, and the referenced column needs an index (a primary key works).")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: refTable) { refColumn = refColumns.first ?? "" }
    }
}

/// Rename, move, copy, change engine or collation, and maintenance for the selected table.
struct TableOptionsSheet: View {
    @EnvironmentObject var m: DBModel
    @Environment(\.dismiss) private var dismiss
    @State private var newName = ""
    @State private var newDB = ""
    @State private var copyName = ""
    @State private var copyData = true
    @State private var engine = ""
    @State private var collation = ""

    private var info: TableInfo? { m.currentTableInfo }
    private var collations: [String] {
        let current = info?.collation ?? ""
        return current.isEmpty || DBModel.collations.contains(current) ? DBModel.collations : [current] + DBModel.collations
    }
    private var engines: [String] {
        let current = info?.engine ?? ""
        return current.isEmpty || DBModel.engines.contains(current) ? DBModel.engines : [current] + DBModel.engines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Table Options – \(m.currentTable ?? "")").font(.title3.weight(.semibold))

            GroupBox("Rename or move") {
                HStack {
                    TextField("Name", text: $newName)
                    Picker("", selection: $newDB) { ForEach(m.databases, id: \.self) { Text($0).tag($0) } }
                        .labelsHidden().frame(width: 170)
                    Button("Rename") { m.renameTable(to: newName, database: newDB) }
                        .disabled(newName.trimmed.isEmpty || (newName.trimmed == m.currentTable && newDB == m.currentDB))
                }
                .padding(4)
            }

            GroupBox("Copy") {
                HStack {
                    TextField("Name of the copy", text: $copyName)
                    Toggle("With data", isOn: $copyData)
                    Button("Copy") { m.copyTable(to: copyName, withData: copyData) }.disabled(copyName.trimmed.isEmpty)
                }
                .padding(4)
            }

            GroupBox("Storage") {
                HStack {
                    Picker("Engine", selection: $engine) { ForEach(engines, id: \.self) { Text($0).tag($0) } }.frame(width: 190)
                    Picker("Collation", selection: $collation) { ForEach(collations, id: \.self) { Text($0).tag($0) } }
                    Button("Apply") {
                        m.setTableOptions(engine: engine == info?.engine ? nil : engine,
                                          collation: collation == info?.collation ? nil : collation)
                    }
                    .disabled(engine == info?.engine && collation == info?.collation)
                }
                .padding(4)
            }

            GroupBox("Maintenance") {
                HStack {
                    ForEach(["OPTIMIZE", "REPAIR", "ANALYZE", "CHECK"], id: \.self) { op in
                        Button(op.capitalized) { m.maintenance(op) }
                    }
                    Spacer()
                }
                .padding(4)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 600)
        .onAppear {
            newName = m.currentTable ?? ""
            newDB = m.currentDB ?? ""
            copyName = (m.currentTable ?? "") + "_copy"
            engine = info?.engine ?? "InnoDB"
            collation = info?.collation ?? DBModel.collations[0]
        }
        .alert("Done", isPresented: Binding(get: { m.infoMessage != nil }, set: { if !$0 { m.infoMessage = nil } })) {
            Button("OK") {}
        } message: { Text(m.infoMessage ?? "") }
        .alert("Error", isPresented: Binding(get: { m.alertMessage != nil }, set: { if !$0 { m.alertMessage = nil } })) {
            Button("OK") {}
        } message: { Text(m.alertMessage ?? "") }
    }
}

/// Table designer: define all the columns of a new table at once.
struct NewTableSheet: View {
    @EnvironmentObject var m: DBModel
    @State private var name = ""
    @State private var engine = "InnoDB"
    @State private var collation = "utf8mb4_general_ci"
    @State private var columns: [ColumnDraft] = [
        ColumnDraft(name: "id", type: "INT UNSIGNED", nullable: false, autoIncrement: true, primaryKey: true),
        ColumnDraft(name: "", type: "VARCHAR(255)"),
    ]

    private var usable: [ColumnDraft] { columns.filter { !$0.name.trimmed.isEmpty && !$0.type.trimmed.isEmpty } }

    var body: some View {
        SheetFrame(title: "New Table – \(m.currentDB ?? "")", confirm: "Create",
                   canConfirm: !name.trimmed.isEmpty && !usable.isEmpty,
                   action: { if let d = m.currentDB { m.createTable(name: name, in: d, columns: usable, engine: engine, collation: collation) } },
                   width: 820) {
            HStack {
                TextField("Table name", text: $name).frame(width: 240)
                Spacer()
                Picker("Engine", selection: $engine) { ForEach(DBModel.engines, id: \.self) { Text($0).tag($0) } }.frame(width: 170)
                Picker("Collation", selection: $collation) { ForEach(DBModel.collations, id: \.self) { Text($0).tag($0) } }.frame(width: 260)
            }

            Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                GridRow {
                    Text("Name"); Text("Type"); Text("NULL"); Text("Default"); Text("Primary"); Text("Auto inc."); Text("")
                }
                .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                ForEach($columns) { $c in
                    GridRow {
                        TextField("name", text: $c.name).frame(width: 160)
                        TypeField(type: $c.type).frame(width: 190)
                        Toggle("", isOn: $c.nullable).labelsHidden().disabled(c.primaryKey)
                        TextField("none", text: $c.defaultText).frame(width: 120).disabled(c.autoIncrement)
                        Toggle("", isOn: $c.primaryKey).labelsHidden()
                            .onChange(of: c.primaryKey) { if c.primaryKey { c.nullable = false } }
                        Toggle("", isOn: $c.autoIncrement).labelsHidden()
                        Button { columns.removeAll { $0.id == c.id } } label: { Image(systemName: "minus.circle") }
                            .buttonStyle(.borderless).disabled(columns.count <= 1).help("Remove this column")
                    }
                }
            }
            Button { columns.append(ColumnDraft(name: "", type: "VARCHAR(255)")) } label: { Label("Add Column", systemImage: "plus") }
            Text("Rows without a name are ignored. Indexes and foreign keys can be added on the Structure tab afterwards.")
                .font(.callout).foregroundStyle(.secondary)
        }
    }
}
