import SwiftUI
import AppKit

struct QueryView: View {
    @EnvironmentObject var m: DBModel
    /// The result area can be folded away completely; the choice is remembered.
    @AppStorage("db.queryResultsOpen") private var resultsOpen = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            QueryToolbar()
            if resultsOpen {
                VSplitView {
                    editor.frame(minHeight: 110, idealHeight: 220)
                    VStack(spacing: 0) {
                        ResultsBar(open: $resultsOpen)
                        QueryResultsPane()
                    }
                    .frame(minHeight: 150)
                }
            } else {
                editor.frame(maxHeight: .infinity)
                ResultsBar(open: $resultsOpen)
            }
        }
        .animation(DBMotion.fade(reduceMotion), value: resultsOpen)
    }

    private var editor: some View {
        SQLEditor(text: $m.queryText, error: m.queryError, errorVersion: m.queryVersion,
                  completions: { m.completions(prefix: $0, qualifier: $1) })
            .background(Color(nsColor: .textBackgroundColor))
    }
}

/// The strip above the results: what the last run returned, and a chevron to fold the results away or open them.
private struct ResultsBar: View {
    @EnvironmentObject var m: DBModel
    @Binding var open: Bool

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            Button { open.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(open ? 0 : -90))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                    Text("Result").font(.callout.weight(.semibold))
                    summary
                    Spacer()
                    Text(open ? "Hide" : "Show").font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .frame(height: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .background(.bar)
            .help(open ? "Fold the results away" : "Show the results")
        }
    }

    @ViewBuilder private var summary: some View {
        if m.queryError != nil {
            Label("Error", systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
        } else if m.shownResult < m.queryResults.count {
            let set = m.queryResults[m.shownResult]
            let rows = set.rows.count == 1 ? "1 row" : "\(set.rows.count.formatted()) rows"
            let cols = set.columns.count == 1 ? "1 column" : "\(set.columns.count.formatted()) columns"
            Text(m.queryResults.count > 1 ? "\(m.queryResults.count) results · \(rows)" : "\(rows) · \(cols)")
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
        } else if m.queryVersion > 0 && !m.queryMessage.isEmpty {
            Text(m.queryMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        } else {
            Text("Nothing run yet").font(.caption).foregroundStyle(.tertiary)
        }
    }
}

// MARK: - Toolbar

/// Run, target database, history and clear on the left; the last run's status on the right.
private struct QueryToolbar: View {
    @EnvironmentObject var m: DBModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        DBBar {
            Button { m.runQuery() } label: { Label("Run", systemImage: "play.fill") }
                .buttonStyle(.borderedProminent)
                .disabled(m.queryText.trimmed.isEmpty)
                .help("Run the SQL in the editor (⌘R)")

            databaseMenu
            historyMenu

            Button { m.queryText = "" } label: { Label("Clear Editor", systemImage: "eraser") }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .disabled(m.queryText.isEmpty)
                .help("Clear Editor")

            Spacer(minLength: 12)

            BusyIndicator(activity: m.activity)
            status
        }
    }

    // Database picker

    private var targetDatabase: String? { m.queryDatabase ?? m.currentDB }

    private var databaseMenu: some View {
        let user = m.databases.filter { !DBStyle.systemDatabases.contains($0) }
        let system = m.databases.filter { DBStyle.systemDatabases.contains($0) }
        return Menu {
            Toggle(isOn: Binding(get: { m.queryDatabase == nil }, set: { if $0 { m.queryDatabase = nil } })) {
                Text("Selected in sidebar (\(m.currentDB ?? "none"))")
            }
            Divider()
            ForEach(user, id: \.self) { databaseItem($0) }
            if !system.isEmpty {
                Divider()
                ForEach(system, id: \.self) { databaseItem($0) }
            }
        } label: {
            Label(targetDatabase ?? "No database", systemImage: DBStyle.databaseSymbol)
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help(m.queryDatabase == nil
              ? "The query runs in the database selected in the sidebar. Choose one to always use it."
              : "The query runs in \(m.queryDatabase ?? "")")
    }

    private func databaseItem(_ name: String) -> some View {
        Toggle(isOn: Binding(get: { m.queryDatabase == name }, set: { if $0 { m.queryDatabase = name } })) {
            Text(name)
        }
    }

    // History

    private var historyMenu: some View {
        Menu {
            if m.queryHistory.isEmpty {
                Text("No queries yet")
            } else {
                ForEach(Array(m.queryHistory.enumerated()), id: \.offset) { _, query in
                    Button(Self.summary(of: query)) { m.queryText = query }
                }
            }
            Divider()
            Button("Clear History", role: .destructive) { m.queryHistory.removeAll() }
                .disabled(m.queryHistory.isEmpty)
        } label: {
            Label("History", systemImage: "clock.arrow.circlepath")
                .labelStyle(.titleAndIcon)
        }
        .fixedSize()
        .help("Recently run queries")
    }

    /// The first non-empty line of a query, shortened for a menu item.
    static func summary(of query: String) -> String {
        let line = query.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .first { !$0.isEmpty } ?? query
        let more = line != query.trimmed
        let limit = 70
        if line.count > limit { return String(line.prefix(limit)) + "…" }
        return more ? line + " …" : line
    }

    // Status

    /// Each run's result fades in over the previous one.
    private var status: some View {
        ZStack(alignment: .trailing) {
            if !m.queryMessage.isEmpty {
                statusLabel
                    .id(m.queryVersion)
                    .transition(.opacity)
            }
        }
        .animation(DBMotion.fade(reduceMotion), value: m.queryVersion)
    }

    private var statusLabel: some View {
        Group {
            HStack(spacing: 5) {
                if m.queryError != nil {
                    Image(systemName: "xmark.octagon.fill").foregroundStyle(.red)
                    Text("Failed · " + m.queryMessage)
                } else {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(m.queryMessage)
                }
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .lineLimit(1)
            .truncationMode(.middle)
            .textSelection(.enabled)
            .help("Result of the last run")
        }
    }
}

// MARK: - Results

private struct QueryResultsPane: View {
    @EnvironmentObject var m: DBModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            if let e = m.queryError {
                QueryErrorCard(message: e)
                    .transition(.opacity)
            } else if m.shownResult < m.queryResults.count {
                if m.queryResults.count > 1 { resultHeader }
                let set = m.queryResults[m.shownResult]
                let version = m.queryVersion &* 100 &+ m.shownResult
                GridView(columns: set.columns, rows: set.rows, version: version, scrollKey: String(version))
            } else if m.queryVersion > 0 && !m.queryMessage.isEmpty {
                ContentUnavailableView {
                    Label("Query Finished", systemImage: "checkmark.circle")
                } description: {
                    Text(m.queryMessage).monospacedDigit()
                }
                .transition(.opacity)
            } else {
                ContentUnavailableView {
                    Label("Run a query", systemImage: "play.rectangle")
                } description: {
                    Text("Type SQL above and press ⌘R.\nPress Tab to complete table and column names.")
                }
                .transition(.opacity)
            }
        }
        // A run swaps the pane's content (results, error, message) with a short fade.
        .animation(DBMotion.fade(reduceMotion), value: m.queryVersion)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }

    @ViewBuilder private var resultHeader: some View {
        DBBar {
            if m.queryResults.count > 1 {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(m.queryResults.indices, id: \.self) { i in
                            ResultChip(index: i, rows: m.queryResults[i].rows.count,
                                       selected: i == m.shownResult) { m.shownResult = i }
                        }
                    }
                }
            } else {
                let set = m.queryResults[m.shownResult]
                Text("Result").font(.callout.weight(.semibold))
                MetaChip(symbol: DBStyle.rowsSymbol, text: Self.rows(set.rows.count))
                MetaChip(symbol: DBStyle.columnsSymbol, text: set.columns.count == 1 ? "1 column" : "\(set.columns.count.formatted()) columns")
                Spacer()
            }
        }
    }

    static func rows(_ n: Int) -> String { n == 1 ? "1 row" : "\(n.formatted()) rows" }
}

/// "Result 2 · 10 rows", selectable.
private struct ResultChip: View {
    let index: Int
    let rows: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 4) {
                Text("Result \(index + 1)").fontWeight(.medium)
                Text("·").foregroundStyle(.tertiary)
                Text(QueryResultsPane.rows(rows)).monospacedDigit()
                    .foregroundStyle(selected ? Color.accentColor : .secondary)
            }
            .font(.callout)
            .padding(.horizontal, 10).padding(.vertical, 4)
            .background(Capsule().fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.05)))
            .overlay(Capsule().strokeBorder(selected ? Color.accentColor.opacity(0.35) : Color.primary.opacity(0.08)))
            .foregroundStyle(selected ? Color.accentColor : .primary)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// The server's error message in a red-tinted card.
private struct QueryErrorCard: View {
    let message: String

    var body: some View {
        ScrollView {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 18))
                    .foregroundStyle(.red)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("The query failed").font(.headline)
                    Text(message)
                        .font(DBStyle.mono)
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("When the server names the location, it is marked in the editor.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message, forType: .string)
                } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .help("Copy the error message")
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color.red.opacity(0.08)))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.red.opacity(0.25)))
            .padding(16)
        }
    }
}
