import SwiftUI
import AppKit

// MARK: - Sheet frame

/// The shared look of every database sheet: an icon header, the content as a grouped form,
/// and a footer with an optional note on the left and Cancel / confirm on the right.
/// `content` is form content (sections and rows); the frame wraps it in the `Form`.
struct SheetFrame<Content: View>: View {
    let title: String
    let subtitle: String?
    let symbol: String
    let tint: Color
    let confirm: String
    let canConfirm: Bool
    let action: () -> Void
    let width: CGFloat
    let note: String?
    let noteIsCode: Bool
    let warning: String?
    let showsCancel: Bool
    let maxFormHeight: CGFloat
    /// Conditions that show or hide rows; when one changes, the form re-lays out with a short spring.
    let motionKey: [Bool]
    let content: Content
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(title: String, subtitle: String? = nil, symbol: String = "square.and.pencil", tint: Color = .accentColor,
         confirm: String, canConfirm: Bool = true, action: @escaping () -> Void, width: CGFloat = 460,
         note: String? = nil, noteIsCode: Bool = false, warning: String? = nil, showsCancel: Bool = true, maxFormHeight: CGFloat = 520,
         motionKey: [Bool] = [], @ViewBuilder content: () -> Content) {
        self.title = title; self.subtitle = subtitle; self.symbol = symbol; self.tint = tint
        self.confirm = confirm; self.canConfirm = canConfirm; self.action = action; self.width = width
        self.note = note; self.noteIsCode = noteIsCode; self.warning = warning; self.showsCancel = showsCancel; self.maxFormHeight = maxFormHeight
        self.motionKey = motionKey
        self.content = content()
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Form { content }
                .formStyle(.grouped)
                .textFieldStyle(.roundedBorder)
                .scrollContentBackground(.hidden)
                .scrollBounceBehavior(.basedOnSize)
                .contentMargins(.horizontal, 0, for: .scrollContent)
                .contentMargins(.top, 0, for: .scrollContent)
                .contentMargins(.bottom, 8, for: .scrollContent)
                .frame(maxHeight: maxFormHeight)
                .fixedSize(horizontal: false, vertical: true)
            Divider()
            footer
        }
        .frame(width: width)
        .animation(DBMotion.spring(reduceMotion), value: motionKey)
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, tint: tint, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.title3.weight(.semibold))
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle).font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.top, 18)
        .padding(.bottom, 2)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if let warning {
                SheetNote(text: warning, symbol: "exclamationmark.triangle.fill", color: .orange)
                    .transition(.opacity)
            } else if let note {
                SheetNote(text: note, symbol: noteIsCode ? "chevron.left.forwardslash.chevron.right" : "info.circle",
                          color: .secondary, code: noteIsCode)
                    .transition(.opacity)
            }
            Spacer(minLength: 12)
            if showsCancel {
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Button(confirm, action: action)
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(!canConfirm)
        }
        .controlSize(.large)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        // The warning and the note swap with a fade (keyed to which one shows, not to every keystroke).
        .animation(DBMotion.fade(reduceMotion), value: warning == nil)
        .animation(DBMotion.fade(reduceMotion), value: note == nil)
    }
}

/// The leading note in a sheet footer.
private struct SheetNote: View {
    let text: String
    let symbol: String
    let color: Color
    var code = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: symbol).foregroundStyle(color).font(.callout)
            Text(text).foregroundStyle(.secondary)
                .font(code ? DBStyle.monoSmall : .callout)
                .lineLimit(3).truncationMode(.middle).fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        .help(code ? "The SQL that will be sent" : "")
    }
}

/// A labelled text field for sheets: the label in the system font, the value left-aligned and
/// (by default) monospaced, since names and values are data.
struct SheetTextField: View {
    let title: String
    @Binding var text: String
    var prompt: String? = nil
    var mono = true
    var width: CGFloat = 260

    var body: some View {
        LabeledContent(title) {
            TextField(title, text: $text, prompt: prompt.map { Text($0) })
                .labelsHidden()
                .font(mono ? DBStyle.mono : .body)
                .multilineTextAlignment(.leading)
                .frame(width: width)
        }
    }
}

/// A section footer: a hint, or a problem in red.
struct SheetHint: View {
    let text: String
    var problem = false

    var body: some View {
        if problem {
            Label(text, systemImage: "exclamationmark.circle.fill")
                .font(.callout).foregroundStyle(.red)
        } else {
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Collations and names

/// The collations the sheets offer, with a one-line explanation each.
enum SheetCollations {
    static let modern = "utf8mb4_uca1400_ai_ci"
    static let all: [(name: String, detail: String)] = [
        (modern, "Modern Unicode sorting, ignores case and accents. The MariaDB 11 default."),
        ("utf8mb4_unicode_ci", "Unicode sorting by an older standard. Also works on MySQL."),
        ("utf8mb4_general_ci", "Fast, simplified sorting. The classic default."),
        ("utf8mb4_hungarian_ci", "Hungarian alphabet: á, é, ő, ű and cs, sz, zs sort correctly."),
        ("utf8mb4_bin", "Compares bytes: case- and accent-sensitive."),
    ]

    static func names(for m: DBModel) -> [String] {
        all.map(\.name).filter { $0 != modern || m.supportsUCA1400 }
    }

    static func defaultName(for m: DBModel) -> String {
        m.supportsUCA1400 ? modern : "utf8mb4_general_ci"
    }

    static func detail(_ name: String) -> String? { all.first { $0.name == name }?.detail }
}

extension DBModel {
    /// uca1400 collations exist from MariaDB 10.10. Unknown version: assume a current MariaDB.
    var supportsUCA1400: Bool {
        let digits = serverVersion.drop { !$0.isNumber }
        let parts = digits.split(separator: ".").prefix(2).compactMap { Int($0.prefix { $0.isNumber }) }
        guard parts.count == 2 else { return true }
        return parts[0] > 10 || (parts[0] == 10 && parts[1] >= 10)
    }
}

/// Checks a database or table name before it is sent to the server.
enum NameCheck {
    static func problem(_ raw: String, kind: String, existing: [String]) -> String? {
        let name = raw.trimmed
        if name.isEmpty { return nil }
        if name.count > 64 { return "\(kind) names can be at most 64 characters long." }
        if name.contains(where: { "/\\.".contains($0) }) { return "The name can't contain / \\ or a dot." }
        if existing.contains(where: { $0.caseInsensitiveCompare(name) == .orderedSame }) {
            return "A \(kind.lowercased()) named “\(name)” already exists."
        }
        return nil
    }

    /// True for names that need no quoting: lowercase-friendly letters, digits and underscores.
    static func isPlain(_ raw: String) -> Bool {
        raw.trimmed.range(of: "^[A-Za-z0-9_]+$", options: .regularExpression) != nil
    }
}

// MARK: - New database

struct NewDatabaseSheet: View {
    @EnvironmentObject var m: DBModel
    @State private var name = ""
    @State private var collation = ""

    private var problem: String? { NameCheck.problem(name, kind: "Database", existing: m.databases) }

    var body: some View {
        SheetFrame(title: "New Database",
                   subtitle: m.serverVersion.isEmpty ? "On the local MariaDB server" : "On \(m.serverVersion)",
                   symbol: DBStyle.databaseSymbol, tint: DBStyle.databaseTint,
                   confirm: "Create", canConfirm: !name.trimmed.isEmpty && problem == nil && !collation.isEmpty,
                   action: { m.createDatabase(name.trimmed, collation: collation) },
                   note: "Character set utf8mb4: full Unicode, emoji included.",
                   motionKey: [problem == nil, name.trimmed.isEmpty || NameCheck.isPlain(name)]) {
            Section {
                SheetTextField(title: "Name", text: $name, prompt: "my_project")
            } footer: {
                if let problem {
                    SheetHint(text: problem, problem: true)
                } else if !name.trimmed.isEmpty && !NameCheck.isPlain(name) {
                    SheetHint(text: "Works, but letters, digits and underscores are easier to use in SQL and PHP.")
                }
            }

            Section {
                Picker("Collation", selection: $collation) {
                    ForEach(SheetCollations.names(for: m), id: \.self) { c in
                        Text(c).tag(c)
                    }
                }
                if let detail = SheetCollations.detail(collation) {
                    Text(detail).font(.callout).foregroundStyle(.secondary)
                }
            } header: {
                Text("Sorting and comparing")
            } footer: {
                SheetHint(text: "For Hungarian text pick utf8mb4_hungarian_ci, so á, ő and ű sort in the right place. Otherwise the default is a good choice.")
            }
        }
        .onAppear { if collation.isEmpty { collation = SheetCollations.defaultName(for: m) } }
    }
}

// MARK: - Insert row

struct InsertRowSheet: View {
    @EnvironmentObject var m: DBModel
    @State private var values: [String: String] = [:]

    private var missing: Int {
        m.columns.filter { $0.isRequired && (values[$0.name] ?? "").isEmpty }.count
    }

    var body: some View {
        SheetFrame(title: "New Row",
                   subtitle: [m.currentTable, m.currentDB.map { "in \($0)" }].compactMap { $0 }.joined(separator: " "),
                   symbol: "plus.rectangle.fill", tint: .green,
                   confirm: "Insert", canConfirm: true,
                   action: { m.insertRow(values.filter { !$0.value.isEmpty }) },
                   width: 580,
                   note: "Empty fields get their default value.",
                   warning: missing > 0 ? "\(missing) required field\(missing == 1 ? " is" : "s are") still empty." : nil,
                   maxFormHeight: 540) {
            Section {
                ForEach(m.columns) { c in
                    InsertField(column: c, text: Binding(get: { values[c.name] ?? "" }, set: { values[c.name] = $0 }))
                }
            }
        }
    }
}

extension ColumnInfo {
    /// NOT NULL, no default and not filled in automatically: the insert needs a value.
    var isRequired: Bool { !isNullable && def == nil && !isAutoIncrement }

    /// The values of an ENUM or SET column, in order.
    var enumValues: [String] {
        let t = type.lowercased()
        guard t.hasPrefix("enum(") || t.hasPrefix("set(") else { return [] }
        guard let re = try? NSRegularExpression(pattern: "'((?:[^']|'')*)'") else { return [] }
        let ns = type as NSString
        return re.matches(in: type, range: NSRange(location: 0, length: ns.length)).map {
            ns.substring(with: $0.range(at: 1)).replacingOccurrences(of: "''", with: "'")
        }
    }
}

private struct InsertField: View {
    let column: ColumnInfo
    @Binding var text: String

    private var prompt: String {
        if column.isAutoIncrement { return "automatic" }
        if let def = column.def { return def.isEmpty ? "empty text" : def }
        if column.isNullable { return "NULL" }
        return column.type.lowercased()
    }

    var body: some View {
        LabeledContent {
            HStack(spacing: 4) {
                TextField("", text: $text, prompt: Text(prompt))
                    .labelsHidden()
                    .font(DBStyle.mono)
                    .multilineTextAlignment(.leading)
                if !column.enumValues.isEmpty {
                    Menu {
                        ForEach(column.enumValues, id: \.self) { v in Button(v) { text = v } }
                        Divider()
                        Button("Clear") { text = "" }
                    } label: {
                        Image(systemName: "chevron.up.chevron.down")
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .help("Choose one of the allowed values")
                }
            }
            .frame(width: 250)
        } label: {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 5) {
                    Text(column.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle)
                    if column.isRequired {
                        Text("Required").font(.caption2.weight(.semibold)).foregroundStyle(.red)
                            .help("NOT NULL without a default value: fill this in")
                    }
                }
                HStack(spacing: 4) {
                    TypeChip(type: column.type)
                    ForEach(column.badges.filter { !(column.isRequired && $0 == .notNull) }, id: \.self) { KeyBadge(kind: $0) }
                }
            }
        }
        .padding(.vertical, 1)
    }
}
