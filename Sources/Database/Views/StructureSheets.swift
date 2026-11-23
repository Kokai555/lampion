import SwiftUI
import AppKit

// MARK: - Type field

/// A text field for a column type, tinted by its family, with a menu of common types.
struct TypeField: View {
    @Binding var type: String
    var compact = false

    private static let groups: [(title: String, types: [String])] = {
        func family(_ t: String) -> String {
            switch SQLTypeFamily(type: t) {
            case .integer, .decimal, .boolean: return "Numbers"
            case .text, .enumSet: return "Text"
            case .temporal: return "Date & Time"
            default: return "Other"
            }
        }
        return ["Numbers", "Text", "Date & Time", "Other"].map { g in (g, DBModel.typePresets.filter { family($0) == g }) }
            .filter { !$0.types.isEmpty }
    }()

    var body: some View {
        let family = SQLTypeFamily(type: type)
        HStack(spacing: 6) {
            Image(systemName: family.symbol)
                .contentTransition(.symbolEffect(.replace))
                .font(.system(size: compact ? 9.5 : 10.5, weight: .semibold))
                .foregroundStyle(family.color)
                .frame(width: compact ? 18 : 22, height: compact ? 18 : 22)
                .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(family.color.opacity(0.13)))
                .help("Type family")
            TextField("Type", text: $type, prompt: Text("VARCHAR(255)"))
                .labelsHidden()
                .textFieldStyle(.roundedBorder)
                .font(DBStyle.mono)
                .multilineTextAlignment(.leading)
            Menu {
                ForEach(Self.groups, id: \.title) { g in
                    Section(g.title) {
                        ForEach(g.types, id: \.self) { p in Button(p) { type = p } }
                    }
                }
            } label: {
                Image(systemName: "chevron.up.chevron.down")
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("Common types")
        }
        .animation(.easeOut(duration: 0.15), value: family.symbol)
    }
}

/// A type split into its name, the part in brackets and what follows: `DECIMAL`, `10,2`, `UNSIGNED`.
struct TypeParts {
    var base = ""
    var args = ""
    var modifiers = ""

    init(_ type: String) {
        let t = type.trimmed
        if let open = t.firstIndex(of: "("), let close = t.lastIndex(of: ")"), open < close {
            base = String(t[..<open]).trimmed
            args = String(t[t.index(after: open)..<close])
            modifiers = String(t[t.index(after: close)...]).trimmed
        } else if let space = t.firstIndex(of: " ") {
            base = String(t[..<space])
            modifiers = String(t[space...]).trimmed
        } else {
            base = t
        }
    }

    var type: String {
        base + (args.isEmpty ? "" : "(\(args))") + (modifiers.isEmpty ? "" : " " + modifiers)
    }

    var unsigned: Bool {
        get { modifiers.split(separator: " ").contains { $0.uppercased() == "UNSIGNED" } }
        set {
            var words = modifiers.split(separator: " ").map(String.init).filter { $0.uppercased() != "UNSIGNED" }
            if newValue { words.insert(base == base.lowercased() ? "unsigned" : "UNSIGNED", at: 0) }
            modifiers = words.joined(separator: " ")
        }
    }
}

// MARK: - Column

/// Add a column, or change an existing one.
struct ColumnSheet: View {
    @EnvironmentObject var m: DBModel
    let editing: ColumnInfo?
    @State private var draft = ColumnDraft()
    @State private var position: ColumnPosition = .unchanged
    @State private var loaded = false

    private var family: SQLTypeFamily { SQLTypeFamily(type: draft.type) }

    private var parts: Binding<TypeParts> {
        Binding(get: { TypeParts(draft.type) }, set: { draft.type = $0.type })
    }

    private var lengthHint: String {
        switch family {
        case .text: return "VARCHAR(n) and CHAR(n) hold up to n characters. TEXT needs no length."
        case .decimal: return "DECIMAL(p,s): p digits in all, s of them after the point."
        case .enumSet: return "The allowed values, quoted and separated by commas: 'small','large'."
        case .integer, .boolean: return "The number in brackets is only a display width; it doesn't limit the value."
        case .temporal: return "DATETIME(3) and TIMESTAMP(6) keep fractions of a second."
        default: return "Leave the length empty when the type doesn't need one."
        }
    }

    var body: some View {
        SheetFrame(title: editing == nil ? "Add Column" : "Edit Column",
                   subtitle: editing.map { "\($0.name) in \(m.currentTable ?? "")" } ?? m.currentTable.map { "To \($0)" },
                   symbol: "rectangle.split.3x1.fill", tint: .indigo,
                   confirm: editing == nil ? "Add Column" : "Save",
                   canConfirm: !draft.name.trimmed.isEmpty && !draft.type.trimmed.isEmpty,
                   action: { m.saveColumn(draft, replacing: editing?.name, position: position) },
                   width: 540,
                   note: draft.name.trimmed.isEmpty || draft.type.trimmed.isEmpty ? nil
                       : SQL.id(draft.name.trimmed) + " " + draft.definition,
                   noteIsCode: true, maxFormHeight: 640,
                   motionKey: [family == .integer || parts.wrappedValue.unsigned, family == .temporal || draft.onUpdateTimestamp]) {
            Section {
                SheetTextField(title: "Name", text: $draft.name, prompt: "column_name")
                SheetTextField(title: "Comment", text: $draft.comment, prompt: "optional", mono: false)
            }

            Section {
                LabeledContent("Type") { TypeField(type: $draft.type).frame(width: 260) }
                SheetTextField(title: "Length / values", text: parts.args, prompt: "none")
                if family == .integer || parts.wrappedValue.unsigned {
                    Toggle("Unsigned", isOn: parts.unsigned)
                        .help("Only zero and positive numbers, with twice the upper range")
                }
            } header: {
                Text("Type & length")
            } footer: {
                SheetHint(text: lengthHint)
            }

            Section {
                Toggle("Allow NULL", isOn: $draft.nullable)
                LabeledContent("Default") {
                    HStack(spacing: 4) {
                        TextField("Default", text: $draft.defaultText, prompt: Text("none"))
                            .labelsHidden().font(DBStyle.mono).multilineTextAlignment(.leading)
                        Menu {
                            Button("No default") { draft.defaultText = "" }
                            Button("NULL") { draft.defaultText = "NULL" }
                            Button("Empty text ('')") { draft.defaultText = "''" }
                            if family == .temporal { Button("CURRENT_TIMESTAMP") { draft.defaultText = "CURRENT_TIMESTAMP" } }
                            if family.isNumeric || family == .boolean { Button("0") { draft.defaultText = "0" } }
                        } label: {
                            Image(systemName: "chevron.up.chevron.down")
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                        .help("Common defaults")
                    }
                    .frame(width: 260)
                }
                .disabled(draft.autoIncrement)
                Toggle("Auto increment", isOn: $draft.autoIncrement)
                if family == .temporal || draft.onUpdateTimestamp {
                    Toggle("Update on every change", isOn: $draft.onUpdateTimestamp)
                        .help("ON UPDATE CURRENT_TIMESTAMP: set to the current time whenever the row changes")
                }
            } header: {
                Text("Null & default")
            } footer: {
                SheetHint(text: "Empty means no default. NULL, numbers and CURRENT_TIMESTAMP are used as written; other text is quoted.")
            }

            Section {
                Picker("Position", selection: $position) {
                    Text(editing == nil ? "At the end" : "Keep position").tag(ColumnPosition.unchanged)
                    Text("First").tag(ColumnPosition.first)
                    ForEach(m.columns.filter { $0.name != editing?.name }) { c in
                        Text("After \(c.name)").tag(ColumnPosition.after(c.name))
                    }
                }
            }
        }
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let editing { draft = ColumnDraft(editing) }
        }
    }
}

// MARK: - Index

/// Add an index or a primary key to the selected table.
struct IndexSheet: View {
    @EnvironmentObject var m: DBModel
    @State private var kind: IndexKind = .index
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name = ""
    @State private var chosen: [String] = []

    private var kindHint: String {
        switch kind {
        case .index: return "Makes searching and sorting by these columns faster."
        case .unique: return "Faster searching, and no two rows may have the same values."
        case .primary: return "Identifies each row. A table has at most one, and its columns can't be NULL."
        case .fulltext: return "For word searches in text columns with MATCH … AGAINST."
        }
    }

    var body: some View {
        SheetFrame(title: "Add Index",
                   subtitle: m.currentTable.map { "To \($0)" },
                   symbol: "bolt.fill", tint: .orange,
                   confirm: "Add Index", canConfirm: !chosen.isEmpty,
                   action: { m.addIndex(name: name, kind: kind, columns: chosen) },
                   width: 500,
                   note: chosen.isEmpty ? "Choose at least one column." : nil,
                   maxFormHeight: 560) {
            Section {
                Picker("Kind", selection: $kind) { ForEach(IndexKind.allCases) { Text($0.rawValue).tag($0) } }
                SheetTextField(title: "Name", text: $name, prompt: kind == .primary ? "PRIMARY" : "automatic")
                    .disabled(kind == .primary)
            } footer: {
                SheetHint(text: kindHint)
            }

            Section {
                ForEach(m.columns) { c in
                    IndexColumnRow(column: c, order: chosen.firstIndex(of: c.name).map { $0 + 1 }) {
                        withAnimation(DBMotion.spring(reduceMotion)) {
                            if chosen.contains(c.name) { chosen.removeAll { $0 == c.name } } else { chosen.append(c.name) }
                        }
                    }
                }
            } header: {
                Text("Columns")
            } footer: {
                SheetHint(text: "The order you pick them in is the order of the index. Put the column you filter on most first.")
            }
        }
    }
}

private struct IndexColumnRow: View {
    let column: ColumnInfo
    let order: Int?
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 8) {
                Image(systemName: order == nil ? "circle" : "checkmark.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(order == nil ? Color.secondary : Color.accentColor)
                Text(column.name).lineLimit(1)
                TypeChip(type: column.type)
                ForEach(column.badges.filter { $0 != .notNull }, id: \.self) { KeyBadge(kind: $0) }
                Spacer(minLength: 8)
                if let order {
                    Text("\(order)")
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.white)
                        .frame(minWidth: 18, minHeight: 18)
                        .background(Circle().fill(Color.accentColor))
                        .help("Position in the index")
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(order == nil ? [] : .isSelected)
    }
}

// MARK: - Foreign key

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
        SheetFrame(title: "Add Foreign Key",
                   subtitle: m.currentTable.map { "From \($0)" },
                   symbol: "link", tint: KeyKind.foreign.color,
                   confirm: "Add Foreign Key",
                   canConfirm: !column.isEmpty && !refTable.isEmpty && !refColumn.isEmpty,
                   action: { m.addForeignKey(name: name, column: column, refTable: refTable, refColumn: refColumn,
                                              onDelete: onDelete, onUpdate: onUpdate) },
                   width: 540,
                   note: "The columns need the same type, and the referenced one needs an index (a primary key works).") {
            Section {
                relation
            }

            Section("This table") {
                Picker("Column", selection: $column) {
                    Text("Choose…").tag("")
                    ForEach(m.columns) { c in Text("\(c.name)   \(c.type)").tag(c.name) }
                }
            }

            Section("Refers to") {
                Picker("Table", selection: $refTable) {
                    Text("Choose…").tag("")
                    ForEach(tables, id: \.self) { Text($0).tag($0) }
                }
                Picker("Column", selection: $refColumn) {
                    Text("Choose…").tag("")
                    ForEach(refColumns, id: \.self) { Text($0).tag($0) }
                }
                .disabled(refTable.isEmpty)
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
        }
        .onChange(of: refTable) { refColumn = refColumns.first ?? "" }
    }

    /// `orders.customer_id → customers.id`, with placeholders for what is not chosen yet.
    private var relation: some View {
        HStack(spacing: 10) {
            endpoint(table: m.currentTable ?? "", column: column)
            Image(systemName: "arrow.right").foregroundStyle(KeyKind.foreign.color).fontWeight(.semibold)
            endpoint(table: refTable, column: refColumn)
            Spacer(minLength: 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func endpoint(table: String, column: String) -> some View {
        HStack(spacing: 0) {
            Text(table.isEmpty ? "table" : table).foregroundStyle(table.isEmpty ? .tertiary : .primary)
            Text(".").foregroundStyle(.secondary)
            Text(column.isEmpty ? "column" : column).foregroundStyle(column.isEmpty ? .tertiary : .primary)
                .fontWeight(.semibold)
        }
        .font(DBStyle.mono)
        .lineLimit(1).truncationMode(.middle)
    }
}

// MARK: - Table options

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
        let list = SheetCollations.names(for: m)
        let current = info?.collation ?? ""
        return current.isEmpty || list.contains(current) ? list : [current] + list
    }
    private var engines: [String] {
        let current = info?.engine ?? ""
        return current.isEmpty || DBModel.engines.contains(current) ? DBModel.engines : [current] + DBModel.engines
    }
    private var renamed: Bool { newName.trimmed != m.currentTable || newDB != m.currentDB }
    private var storageChanged: Bool { engine != info?.engine || collation != info?.collation }

    private var subtitle: String {
        var parts = [[m.currentTable, m.currentDB.map { "in \($0)" }].compactMap { $0 }.joined(separator: " ")]
        if let info, !info.rows.isEmpty { parts.append("\(info.rows) rows") }
        if let info, info.bytes > 0 { parts.append(ByteCountFormatter.db.string(fromByteCount: info.bytes)) }
        return parts.joined(separator: " · ")
    }

    var body: some View {
        SheetFrame(title: "Table Options", subtitle: subtitle,
                   symbol: "slider.horizontal.3", tint: .gray,
                   confirm: "Done", canConfirm: true, action: { dismiss() },
                   width: 560, showsCancel: false, maxFormHeight: 660) {
            Section {
                SheetTextField(title: "Name", text: $newName)
                Picker("Database", selection: $newDB) { ForEach(m.databases, id: \.self) { Text($0).tag($0) } }
            } header: {
                Text("Rename or move")
            } footer: {
                actionRow(renamed && !newName.trimmed.isEmpty ? "Becomes \(newDB).\(newName.trimmed)" : nil) {
                    Button("Rename") { m.renameTable(to: newName, database: newDB) }
                        .disabled(newName.trimmed.isEmpty || !renamed)
                }
            }

            Section {
                SheetTextField(title: "Name of the copy", text: $copyName)
                Toggle("Copy the rows too", isOn: $copyData)
            } header: {
                Text("Copy")
            } footer: {
                actionRow(copyData ? "Structure, indexes and rows." : "Structure and indexes only.") {
                    Button("Copy") { m.copyTable(to: copyName, withData: copyData) }.disabled(copyName.trimmed.isEmpty)
                }
            }

            Section {
                Picker("Engine", selection: $engine) { ForEach(engines, id: \.self) { Text($0).tag($0) } }
                Picker("Collation", selection: $collation) { ForEach(collations, id: \.self) { Text($0).tag($0) } }
            } header: {
                Text("Storage")
            } footer: {
                actionRow(storageChanged ? "Rewrites the table; large tables take a while." : SheetCollations.detail(collation)) {
                    Button("Apply") {
                        m.setTableOptions(engine: engine == info?.engine ? nil : engine,
                                          collation: collation == info?.collation ? nil : collation)
                    }
                    .disabled(!storageChanged)
                }
            }

            Section {
                HStack(spacing: 8) {
                    maintenanceButton("OPTIMIZE", symbol: "wand.and.stars", help: "Reclaims unused space and defragments the table")
                    maintenanceButton("ANALYZE", symbol: "chart.bar", help: "Updates the statistics the server uses to pick indexes")
                    maintenanceButton("CHECK", symbol: "checkmark.shield", help: "Looks for errors in the table")
                    maintenanceButton("REPAIR", symbol: "wrench.and.screwdriver", help: "Fixes a damaged table (MyISAM and Aria)")
                }
            } header: {
                Text("Maintenance")
            }
        }
        .onAppear {
            newName = m.currentTable ?? ""
            newDB = m.currentDB ?? ""
            copyName = (m.currentTable ?? "") + "_copy"
            engine = info?.engine ?? "InnoDB"
            collation = info?.collation ?? SheetCollations.defaultName(for: m)
        }
        .alert("Done", isPresented: Binding(get: { m.infoMessage != nil }, set: { if !$0 { m.infoMessage = nil } })) {
            Button("OK") {}
        } message: { Text(m.infoMessage ?? "") }
        .alert("Error", isPresented: Binding(get: { m.alertMessage != nil }, set: { if !$0 { m.alertMessage = nil } })) {
            Button("OK") {}
        } message: { Text(m.alertMessage ?? "") }
    }

    private func actionRow<B: View>(_ caption: String?, @ViewBuilder button: () -> B) -> some View {
        HStack(alignment: .firstTextBaseline) {
            if let caption {
                Text(caption).font(.callout).foregroundStyle(.secondary)
                    .lineLimit(2).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            button()
        }
    }

    private func maintenanceButton(_ op: String, symbol: String, help: String) -> some View {
        Button { m.maintenance(op) } label: {
            Label(op.capitalized, systemImage: symbol).frame(maxWidth: .infinity)
        }
        .help(help)
    }
}

// MARK: - New table

/// Table designer: define all the columns of a new table at once.
struct NewTableSheet: View {
    @EnvironmentObject var m: DBModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var name = ""
    @State private var engine = "InnoDB"
    @State private var collation = ""
    @State private var columns: [ColumnDraft] = [
        ColumnDraft(name: "id", type: "INT UNSIGNED", nullable: false, autoIncrement: true, primaryKey: true),
        ColumnDraft(name: "", type: "VARCHAR(255)"),
    ]

    private var usable: [ColumnDraft] { columns.filter { !$0.name.trimmed.isEmpty && !$0.type.trimmed.isEmpty } }
    private var problem: String? {
        NameCheck.problem(name, kind: "Table", existing: m.currentDB.flatMap { m.tables[$0] }?.map(\.name) ?? [])
    }
    private var duplicate: String? {
        let names = usable.map { $0.name.trimmed.lowercased() }
        return names.first { n in names.filter { $0 == n }.count > 1 }
    }

    var body: some View {
        SheetFrame(title: "New Table",
                   subtitle: m.currentDB.map { "In \($0)" },
                   symbol: DBStyle.tableSymbol, tint: DBStyle.tableTint,
                   confirm: "Create Table",
                   canConfirm: !name.trimmed.isEmpty && problem == nil && !usable.isEmpty && duplicate == nil && !collation.isEmpty,
                   action: { if let d = m.currentDB { m.createTable(name: name, in: d, columns: usable, engine: engine, collation: collation) } },
                   width: 700,
                   note: "Rows without a name are ignored. Add indexes and foreign keys on the Structure tab afterwards.",
                   warning: duplicate.map { "Two columns are named “\($0)”." },
                   maxFormHeight: 580,
                   motionKey: [problem == nil]) {
            Section {
                SheetTextField(title: "Name", text: $name, prompt: "table_name")
                Picker("Engine", selection: $engine) { ForEach(DBModel.engines, id: \.self) { Text($0).tag($0) } }
                Picker("Collation", selection: $collation) {
                    ForEach(SheetCollations.names(for: m), id: \.self) { Text($0).tag($0) }
                }
            } footer: {
                if let problem { SheetHint(text: problem, problem: true) }
            }

            Section {
                DesignerHeader()
                ForEach($columns) { $c in
                    DesignerRow(column: $c, canRemove: columns.count > 1) {
                        withAnimation(DBMotion.spring(reduceMotion)) { columns.removeAll { $0.id == c.id } }
                    }
                }
                HStack {
                    Button {
                        withAnimation(DBMotion.spring(reduceMotion)) { columns.append(ColumnDraft(name: "", type: "VARCHAR(255)")) }
                    } label: {
                        Label("Add Column", systemImage: "plus.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    Spacer()
                    Text("\(usable.count) column\(usable.count == 1 ? "" : "s")")
                        .font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Columns")
            }
        }
        .onAppear { if collation.isEmpty { collation = SheetCollations.defaultName(for: m) } }
    }
}

private enum DesignerWidth {
    static let name: CGFloat = 140
    static let type: CGFloat = 190
    static let def: CGFloat = 96
}

private struct DesignerHeader: View {
    var body: some View {
        HStack(spacing: 8) {
            Text("Name").frame(width: DesignerWidth.name, alignment: .leading)
            Text("Type").padding(.leading, 24).frame(width: DesignerWidth.type, alignment: .leading)
            Text("Default").frame(width: DesignerWidth.def, alignment: .leading)
            Text("Flags")
            Spacer(minLength: 0)
        }
        .font(.caption.weight(.medium))
        .foregroundStyle(.secondary)
    }
}

/// One column of the table designer: name, type, default, flags and a remove button.
private struct DesignerRow: View {
    @Binding var column: ColumnDraft
    let canRemove: Bool
    let remove: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            TextField("Name", text: $column.name, prompt: Text("name"))
                .labelsHidden().font(DBStyle.mono).multilineTextAlignment(.leading)
                .frame(width: DesignerWidth.name)
            TypeField(type: $column.type, compact: true)
                .frame(width: DesignerWidth.type)
            TextField("Default", text: $column.defaultText, prompt: Text("none"))
                .labelsHidden().font(DBStyle.mono).multilineTextAlignment(.leading)
                .frame(width: DesignerWidth.def)
                .disabled(column.autoIncrement)
            HStack(spacing: 4) {
                FlagToggle(title: "PK", color: KeyKind.primary.color, isOn: $column.primaryKey,
                           help: "Primary key: identifies each row")
                FlagToggle(title: "AUTO", color: KeyKind.autoIncrement.color, isOn: $column.autoIncrement,
                           help: "Auto increment: numbered automatically")
                FlagToggle(title: "NULL", color: .gray, isOn: $column.nullable,
                           help: "Allow NULL: the value may be missing")
                    .disabled(column.primaryKey)
            }
            Spacer(minLength: 0)
            Button(action: remove) {
                Image(systemName: "minus.circle.fill").foregroundStyle(canRemove ? Color.red.opacity(0.8) : Color.secondary)
            }
            .buttonStyle(.borderless)
            .disabled(!canRemove)
            .help("Remove this column")
        }
        .onChange(of: column.primaryKey) { if column.primaryKey { column.nullable = false } }
    }
}

/// A small capsule that switches a column flag on and off, styled like `KeyBadge`.
private struct FlagToggle: View {
    let title: String
    let color: Color
    @Binding var isOn: Bool
    let help: String
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button { isOn.toggle() } label: {
            Text(title)
                .font(.system(size: 9.5, weight: .semibold))
                .lineLimit(1).fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 3)
                .background(Capsule().fill(isOn ? color.opacity(0.18) : Color.clear))
                .overlay(Capsule().strokeBorder(isOn ? Color.clear : Color.primary.opacity(0.15)))
                .foregroundStyle(isOn ? color : Color.secondary)
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isEnabled ? 1 : 0.45)
        .help(help)
        .accessibilityLabel(help)
        .accessibilityAddTraits(isOn ? .isSelected : [])
    }
}
