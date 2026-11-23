import SwiftUI
import AppKit

/// Confirms a relation drawn on the diagram: shows both ends, the rules and the exact SQL, then runs it.
/// MariaDB's error (type mismatch, missing index, rows without a match…) is shown here, so the user can adjust and retry.
struct DesignerRelationSheet: View {
    @EnvironmentObject var m: DBModel
    @ObservedObject var store: DesignerStore
    @Environment(\.dismiss) private var dismiss

    @State private var relation: DesignerNewRelation
    @State private var name: String
    @State private var onDelete = "RESTRICT"
    @State private var onUpdate = "RESTRICT"
    @State private var error: String?
    @State private var running = false

    init(relation: DesignerNewRelation, store: DesignerStore) {
        self.store = store
        _relation = State(initialValue: relation)
        _name = State(initialValue: store.suggestedName(table: relation.table, column: relation.column))
    }

    private var child: DesignerTable? { store.schema?.table(relation.table) }
    private var parent: DesignerTable? { store.schema?.table(relation.refTable) }
    private var fkColumn: DesignerColumn? { child?.column(relation.column) }
    private var refColumn: DesignerColumn? { parent?.column(relation.refColumn) }

    private var sql: String {
        let constraint = name.trimmed.isEmpty ? "" : "\n  ADD CONSTRAINT \(SQL.id(name.trimmed))"
        return "ALTER TABLE \(SQL.id(relation.table))" + (constraint.isEmpty ? "\n  ADD" : constraint)
            + " FOREIGN KEY (\(SQL.id(relation.column)))\n  REFERENCES \(SQL.id(relation.refTable)) (\(SQL.id(relation.refColumn)))"
            + "\n  ON DELETE \(onDelete) ON UPDATE \(onUpdate);"
    }

    /// Problems MariaDB will most likely refuse, found before sending anything.
    private var warnings: [String] {
        var w: [String] = []
        if let a = fkColumn, let b = refColumn, DesignerType.fkComparable(a.type) != DesignerType.fkComparable(b.type) {
            w.append("The column types differ (\(a.type) and \(b.type)). MariaDB will most likely refuse.")
        }
        if let b = refColumn, !b.isIndexed {
            w.append("“\(relation.refTable).\(relation.refColumn)” has no index. The referenced column needs one (a primary key works).")
        }
        if let a = fkColumn, !a.nullable, onDelete == "SET NULL" || onUpdate == "SET NULL" {
            w.append("SET NULL needs “\(relation.column)” to allow NULL, and it is NOT NULL.")
        }
        for t in [child, parent].compactMap({ $0 }) where !t.engine.isEmpty && t.engine.lowercased() != "innodb" {
            w.append("“\(t.name)” uses \(t.engine), which ignores foreign keys. Change it to InnoDB in Table Options first.")
            break
        }
        if let existing = store.schema?.relations.first(where: {
            $0.table == relation.table && $0.columns == [relation.column] && $0.refTable == relation.refTable && $0.refColumns == [relation.refColumn]
        }) {
            w.append("This relation already exists as “\(existing.name)”.")
        }
        return w
    }

    var body: some View {
        SheetFrame(title: "New Relation",
                   subtitle: relation.database,
                   symbol: "link", tint: KeyKind.foreign.color,
                   confirm: running ? "Creating…" : "Create Relation",
                   canConfirm: !running,
                   action: create,
                   width: 560,
                   note: "Every value in “\(relation.column)” must then exist in “\(relation.refTable).\(relation.refColumn)”.",
                   warning: warnings.first,
                   motionKey: [error == nil]) {
            Section {
                HStack(spacing: 10) {
                    endpoint(relation.table, relation.column, fkColumn)
                    Image(systemName: "arrow.right").foregroundStyle(KeyKind.foreign.color).fontWeight(.semibold)
                    endpoint(relation.refTable, relation.refColumn, refColumn)
                    Spacer(minLength: 8)
                    Button {
                        let swapped = relation.swapped()
                        relation = swapped
                        name = store.suggestedName(table: swapped.table, column: swapped.column)
                        error = nil
                    } label: {
                        Label("Swap", systemImage: "arrow.left.arrow.right")
                    }
                    .controlSize(.small)
                    .disabled(store.schema?.table(relation.refTable)?.isView != false)
                    .help("Make “\(relation.refTable).\(relation.refColumn)” the foreign key instead")
                }
                .padding(.vertical, 2)
            } footer: {
                SheetHint(text: "“\(relation.table).\(relation.column)” becomes a foreign key that refers to “\(relation.refTable).\(relation.refColumn)”.")
            }

            if let error {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Label {
                            Text(error).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        } icon: {
                            Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                        .font(.callout)
                        if let hint = Self.explain(error) {
                            Text(hint).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                } header: {
                    Text("MariaDB refused the relation")
                }
                .transition(.opacity)
            }

            Section {
                Picker("On delete", selection: $onDelete) { ForEach(DBModel.referenceRules, id: \.self) { Text($0).tag($0) } }
                Picker("On update", selection: $onUpdate) { ForEach(DBModel.referenceRules, id: \.self) { Text($0).tag($0) } }
                SheetTextField(title: "Name", text: $name, prompt: "automatic")
            } header: {
                Text("When the referenced row changes")
            } footer: {
                SheetHint(text: "RESTRICT refuses the change, CASCADE deletes or updates these rows too, SET NULL clears the column.")
            }

            Section("SQL") {
                ScrollView(.horizontal, showsIndicators: false) {
                    HighlightedSQL(sql: sql)
                        .padding(-10)
                        .padding(.vertical, 4)
                }
            }

        }
        .onChange(of: onDelete) { error = nil }
        .onChange(of: onUpdate) { error = nil }
    }

    private func endpoint(_ table: String, _ column: String, _ info: DesignerColumn?) -> some View {
        HStack(spacing: 6) {
            HStack(spacing: 0) {
                Text(table)
                Text(".").foregroundStyle(.secondary)
                Text(column).fontWeight(.semibold)
            }
            .font(DBStyle.mono)
            .lineLimit(1).truncationMode(.middle)
            if let info { DesignerTypeChip(type: info.type) }
        }
    }

    private func create() {
        running = true
        error = nil
        let db = relation.database
        let expected = relation
        m.exec(sql, db: db) { r in
            if let e = r.error {
                running = false
                error = e
                return
            }
            store.load(m, db: db) {
                running = false
                let made = store.schema?.relations.contains {
                    $0.table == expected.table && $0.columns.contains(expected.column) && $0.refTable == expected.refTable
                } ?? false
                if made {
                    dismiss()
                } else {
                    error = "MariaDB accepted the statement, but no foreign key was created. "
                        + "This happens when a table does not use the InnoDB engine (for example MyISAM)."
                }
            }
        }
    }

    /// A plain-language hint for the usual refusals.
    static func explain(_ error: String) -> String? {
        let e = error.lowercased()
        if e.contains("errno: 150") || e.contains("incorrectly formed") {
            return "The two columns usually differ in type, signedness or collation, or the referenced column has no index."
        }
        if e.contains("1452") || e.contains("child row") {
            return "Some rows have a value that does not exist in the referenced table. Fix or remove those rows first, or allow NULL and clear them."
        }
        if e.contains("1215") || e.contains("cannot add foreign key") {
            return "Check that both columns have the same type and that the referenced column is indexed."
        }
        if e.contains("1826") || e.contains("duplicate") {
            return "A constraint with this name already exists in the database. Choose another name."
        }
        if e.contains("1830") || e.contains("set null") {
            return "SET NULL needs a column that allows NULL."
        }
        return nil
    }
}
