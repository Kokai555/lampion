import SwiftUI
import AppKit

// Shared look for the database manager. Matches the main window (Servers/Views/Components.swift:
// Card, IconTile, StatusPill, Fact, Tint, Module.tint), which these views may use too.

enum DBStyle {
    static let databaseTint = Module.mysql.tint
    static let tableTint = Color.blue
    static let viewTint = Color.purple
    static let mono = Font.system(size: 12, design: .monospaced)
    static let monoSmall = Font.system(size: 11, design: .monospaced)
    /// Height of the bars above and below content (filter bar, query toolbar, footer).
    static let barHeight: CGFloat = 40
    static let systemDatabases: Set<String> = ["information_schema", "mysql", "performance_schema", "sys"]

    // One icon per thing, used everywhere. Filled for identity and status, outlined for actions.
    static let databaseSymbol = "cylinder.split.1x2.fill"
    static let tableSymbol = "tablecells.fill"
    static let viewSymbol = "eye.fill"
    static let columnsSymbol = "rectangle.split.3x1"
    static let rowsSymbol = "list.number"
    static let engineSymbol = "engine.combustion"
    static let collationSymbol = "textformat.abc"
    static let sizeSymbol = "internaldrive"
    static let exportSymbol = "arrow.up.doc"
    static let importSymbol = "arrow.down.doc"

    static func symbol(isView: Bool) -> String { isView ? viewSymbol : tableSymbol }
    static func tint(isView: Bool) -> Color { isView ? viewTint : tableTint }
}

/// The window's motion: short, interruptible, and none (or a plain fade) with Reduce Motion.
enum DBMotion {
    /// Panels that slide or resize (inspector, console, expanding sections).
    static func spring(_ reduceMotion: Bool) -> Animation? { reduceMotion ? nil : .snappy(duration: 0.3) }
    /// Content that swaps in place (tabs, empty states, status). Opacity only, so kept with Reduce Motion, just shorter.
    static func fade(_ reduceMotion: Bool) -> Animation { .easeOut(duration: reduceMotion ? 0.12 : 0.2) }
    /// Hover highlights.
    static let hover = Animation.easeOut(duration: 0.12)
}

/// Hands its content a "busy" flag that turns on only when statements run longer than a blink (0.25 s),
/// so a fast query doesn't flash a spinner. Watches only `DBActivity`, not the whole model.
struct DelayedBusy<Content: View>: View {
    @ObservedObject var activity: DBActivity
    @ViewBuilder var content: (_ busy: Bool) -> Content
    @State private var busy = false
    @State private var pending: DispatchWorkItem?

    var body: some View {
        content(busy)
            .onChange(of: activity.busyCount > 0, initial: true) { _, working in
                pending?.cancel()
                if working {
                    let show = DispatchWorkItem { busy = true }
                    pending = show
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.25, execute: show)
                } else {
                    busy = false
                }
            }
    }
}

/// A small spinner shown while statements run. It keeps its space, so the bar doesn't shift on every query.
struct BusyIndicator: View {
    @ObservedObject var activity: DBActivity

    var body: some View {
        DelayedBusy(activity: activity) { busy in
            ProgressView()
                .controlSize(.small)
                .opacity(busy ? 1 : 0)
                .animation(.easeOut(duration: 0.15), value: busy)
                .help("Working…")
                .accessibilityHidden(!busy)
        }
    }
}

/// What kind of value a column holds, from its SQL type. Drives colours, alignment and icons.
enum SQLTypeFamily {
    case integer, decimal, text, temporal, binary, enumSet, json, spatial, boolean, other

    init(type raw: String) {
        let t = raw.lowercased()
        if t.hasPrefix("tinyint(1)") || t == "bool" || t == "boolean" { self = .boolean }
        else if ["int", "tinyint", "smallint", "mediumint", "bigint", "integer", "bit", "serial"].contains(where: { t.hasPrefix($0) }) { self = .integer }
        else if ["decimal", "numeric", "float", "double", "real"].contains(where: { t.hasPrefix($0) }) { self = .decimal }
        else if ["date", "time", "year", "timestamp"].contains(where: { t.hasPrefix($0) }) { self = .temporal }
        else if t.hasPrefix("enum") || t.hasPrefix("set") { self = .enumSet }
        else if t.hasPrefix("json") { self = .json }
        else if ["blob", "binary", "varbinary", "tinyblob", "mediumblob", "longblob"].contains(where: { t.hasPrefix($0) }) { self = .binary }
        else if ["geometry", "point", "linestring", "polygon", "multi"].contains(where: { t.hasPrefix($0) }) { self = .spatial }
        else if ["char", "varchar", "text", "tinytext", "mediumtext", "longtext", "uuid", "inet"].contains(where: { t.hasPrefix($0) }) { self = .text }
        else { self = .other }
    }

    var isNumeric: Bool { self == .integer || self == .decimal }

    var color: Color { Color(nsColor: nsColor) }

    var nsColor: NSColor {
        switch self {
        case .integer, .decimal: return .systemBlue
        case .text: return .systemGreen
        case .temporal: return .systemOrange
        case .binary, .spatial: return .systemGray
        case .enumSet: return .systemPurple
        case .json: return .systemTeal
        case .boolean: return .systemPink
        case .other: return .secondaryLabelColor
        }
    }

    var symbol: String {
        switch self {
        case .integer, .decimal: return "number"
        case .text: return "textformat"
        case .temporal: return "calendar"
        case .binary: return "memorychip"
        case .enumSet: return "list.bullet"
        case .json: return "curlybraces"
        case .spatial: return "mappin.and.ellipse"
        case .boolean: return "checkmark.square"
        case .other: return "questionmark.square.dashed"
        }
    }
}

/// The SQL type as a small tinted capsule, e.g. `varchar(100)`.
struct TypeChip: View {
    let type: String

    var body: some View {
        let family = SQLTypeFamily(type: type)
        Text(type)
            .font(.system(size: 10.5, weight: .medium, design: .monospaced))
            .lineLimit(1)
            .padding(.horizontal, 6).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 4, style: .continuous).fill(family.color.opacity(0.13)))
            .foregroundStyle(family.color)
            .help(type)
    }
}

/// Key markers for columns and indexes.
enum KeyKind {
    case primary, unique, index, foreign, autoIncrement, notNull

    var title: String {
        switch self {
        case .primary: return "PK"
        case .unique: return "UNIQUE"
        case .index: return "INDEX"
        case .foreign: return "FK"
        case .autoIncrement: return "AUTO"
        case .notNull: return "NOT NULL"
        }
    }

    var symbol: String? {
        switch self {
        case .primary: return "key.fill"
        case .foreign: return "link"
        case .autoIncrement: return "arrow.up.forward"
        default: return nil
        }
    }

    var color: Color {
        switch self {
        case .primary: return .yellow
        case .unique: return .orange
        case .index: return .blue
        case .foreign: return .purple
        case .autoIncrement: return .teal
        case .notNull: return .secondary
        }
    }

    var help: String {
        switch self {
        case .primary: return "Primary key"
        case .unique: return "Unique: no two rows may have the same value"
        case .index: return "Indexed, for faster searching"
        case .foreign: return "Foreign key: refers to a row in another table"
        case .autoIncrement: return "Auto increment: filled in automatically"
        case .notNull: return "A value is required"
        }
    }
}

struct KeyBadge: View {
    let kind: KeyKind

    var body: some View {
        HStack(spacing: 3) {
            if let s = kind.symbol { Image(systemName: s).font(.system(size: 8.5, weight: .bold)) }
            Text(kind.title).font(.system(size: 9.5, weight: .semibold))
        }
        .padding(.horizontal, 5).padding(.vertical, 2)
        .background(Capsule().fill(kind.color.opacity(0.15)))
        .foregroundStyle(kind.color)
        .help(kind.help)
    }
}

extension ColumnInfo {
    var family: SQLTypeFamily { SQLTypeFamily(type: type) }
    var isPrimary: Bool { key == "PRI" }
    var isAutoIncrement: Bool { extra.lowercased().contains("auto_increment") }
    var isNullable: Bool { null.uppercased() == "YES" }

    /// Badges for the column, most important first.
    var badges: [KeyKind] {
        var b: [KeyKind] = []
        switch key {
        case "PRI": b.append(.primary)
        case "UNI": b.append(.unique)
        case "MUL": b.append(.index)
        default: break
        }
        if isAutoIncrement { b.append(.autoIncrement) }
        if !isNullable && !isPrimary { b.append(.notNull) }
        return b
    }
}

/// A 40-pt strip with the window's bar material, used above and below content.
struct DBBar<Content: View>: View {
    var edge: VerticalEdge = .top
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) {
            if edge == .bottom { Divider() }
            HStack(spacing: 8) { content }
                .padding(.horizontal, 12)
                .frame(height: DBStyle.barHeight)
                .frame(maxWidth: .infinity)
                .background(.bar)
            if edge == .top { Divider() }
        }
    }
}

/// Small grey icon + text, for table facts (engine, rows, size…).
struct MetaChip: View {
    let symbol: String
    let text: String

    var body: some View {
        Label(text, systemImage: symbol)
            .labelStyle(.titleAndIcon)
            .font(.caption)
            .foregroundStyle(.secondary)
            .lineLimit(1)
    }
}

/// How a NULL value looks everywhere: dim, italic.
struct NullLabel: View {
    var body: some View {
        Text("NULL").font(.system(size: 11, design: .monospaced).italic()).foregroundStyle(.tertiary)
    }
}

extension ByteCountFormatter {
    static let db: ByteCountFormatter = { let f = ByteCountFormatter(); f.countStyle = .binary; return f }()
}
