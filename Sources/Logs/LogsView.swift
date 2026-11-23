import SwiftUI
import AppKit

/// The Logs pane: Lampion's own activity plus the server log files, followed live.
struct LogsView: View {
    @EnvironmentObject var panel: Panel
    @StateObject private var tailer = LogTailer()
    @State private var filter = LevelFilter.all
    @State private var search = ""
    @State private var follow = true
    @State private var confirmClear = false
    @State private var clearError: String?

    enum LevelFilter: String, CaseIterable, Identifiable {
        case all, warnings, errors
        var id: String { rawValue }
        var title: String { self == .all ? "All" : self == .warnings ? "Warnings" : "Errors" }
        func includes(_ l: LogEntry.Level) -> Bool {
            switch self {
            case .all: return true
            case .warnings: return l >= .warn
            case .errors: return l == .error
            }
        }
    }

    private var source: LogSource { panel.logSource }

    /// Derived rows, counts and filter results, worked out again only when the lines, the filter or the search change.
    /// (The body runs on every change of the panel, which publishes often; rebuilding 5000 rows each time made the pane stutter.)
    @State private var cache = LogCache()

    var body: some View {
        let feed = cache.feed(source: source, activity: panel.log, lines: tailer.lines, filter: filter, search: search)
        VStack(spacing: 0) {
            SourceBar(selected: source, selectedExists: tailer.exists) { panel.logSource = $0 }
                .equatable()
            Divider()
            controlBar(feed)
            Divider()
            content(feed)
            Divider()
            statusBar(feed)
        }
        .onAppear { select(source) }
        .onDisappear { tailer.stop() }
        .onChange(of: panel.logSource) { _, new in select(new) }
        .confirmationDialog("Clear \(source.title)?", isPresented: $confirmClear) {
            Button("Clear", role: .destructive, action: clear)
        } message: {
            Text(source == .activity ? "This empties the list in this window. The log file on disk is kept."
                 : "This empties \((source.path ?? "") as NSString).lastPathComponent on disk. It cannot be undone.")
        }
        .alert("The log could not be cleared", isPresented: Binding(get: { clearError != nil }, set: { if !$0 { clearError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(clearError ?? "") }
    }

    private func select(_ s: LogSource) {
        if s == .activity { tailer.stop() } else { tailer.follow(s) }
    }

    // MARK: Bars

    private func controlBar(_ feed: LogCache.Feed) -> some View {
        HStack(spacing: 10) {
            Picker("Show", selection: $filter) {
                ForEach(LevelFilter.allCases) { f in
                    Text(f == .all ? "All" : "\(f.title) \(f == .warnings ? feed.warnings + feed.errors : feed.errors)").tag(f)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            HStack(spacing: 5) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search", text: $search).textFieldStyle(.plain)
                if !search.isEmpty {
                    Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                        .buttonStyle(.plain).help("Clear the search")
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
            .frame(maxWidth: 280)

            Spacer(minLength: 8)

            Toggle(isOn: $follow) { Label("Follow", systemImage: "arrow.down.to.line") }
                .toggleStyle(.button)
                .help("Keep the newest lines in view")

            Menu {
                Button("Copy Shown Lines") { copy(feed.shown) }
                if let path = source.path {
                    Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)]) }
                        .disabled(!tailer.exists)
                    Button("Open in Console") { Shell.open(["-a", "Console", path]) }
                        .disabled(!tailer.exists)
                    Button("Reload") { tailer.reload() }
                } else {
                    Button("Show Lampion.log in Finder") {
                        let url = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/Lampion.log")
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                }
                Divider()
                Button(source == .activity ? "Clear List" : "Clear Log File…", role: .destructive) { confirmClear = true }
                    .disabled(feed.total == 0)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("More")
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
    }

    private func statusBar(_ feed: LogCache.Feed) -> some View {
        HStack(spacing: 14) {
            Text(feed.shown.count == feed.total ? "\(feed.total) lines" : "\(feed.shown.count) of \(feed.total) lines")
            if feed.errors > 0 { Label("\(feed.errors)", systemImage: "xmark.octagon.fill").foregroundStyle(.red).help("Errors") }
            if feed.warnings > 0 { Label("\(feed.warnings)", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange).help("Warnings") }
            Spacer()
            if let path = source.path {
                Text(path).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                if tailer.exists { Text(ByteCountFormatter.string(fromByteCount: Int64(tailer.size), countStyle: .file)) }
            }
            HStack(spacing: 4) {
                Circle().fill(Color.green).frame(width: 6, height: 6)
                Text("Live")
            }
            .help(source == .activity ? "New events appear as they happen" : "The file is checked every second")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16).padding(.vertical, 6)
        .background(.bar)
    }

    // MARK: Lines

    @ViewBuilder
    private func content(_ feed: LogCache.Feed) -> some View {
        if source.path != nil && !tailer.exists {
            ContentUnavailableView {
                Label("\(source.title): no log file yet", systemImage: source.icon)
            } description: {
                Text(source.missingHint)
            } actions: {
                if source == .php { Button("PHP Settings") { panel.pane = .php } }
                if source == .mariadbSlow || source == .mariadbGeneral { Button("MariaDB Settings") { panel.pane = .mariadb } }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if feed.shown.isEmpty {
            ContentUnavailableView {
                Label(feed.total == 0 ? "The log is empty" : "No matching lines",
                      systemImage: feed.total == 0 ? "tray" : search.isEmpty ? "line.3.horizontal.decrease.circle" : "magnifyingglass")
            } description: {
                Text(feed.total == 0 ? "New lines appear here as soon as they are written." : "Try another search or show all levels.")
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            LogLines(rows: feed.shown, version: feed.version, highlight: search, follow: follow) { search = $0 }
                .equatable()
        }
    }

    // MARK: Actions

    private func copy(_ rows: [LogRow]) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(rows.map(\.raw).joined(separator: "\n"), forType: .string)
    }

    private func clear() {
        if source == .activity { panel.clearLog(); return }
        do { try tailer.truncate() } catch { clearError = error.localizedDescription }
    }
}

struct LogRow: Identifiable {
    let id: String
    let time: String?
    let tag: String?
    let message: String
    let level: LogEntry.Level
    let raw: String
}

/// Turns the panel's activity log or a followed file into rows, filters them and counts levels,
/// redoing the work only when its inputs change. Held in @State and read from the body; it is not observed.
final class LogCache {
    struct Feed {
        var shown: [LogRow] = []
        var total = 0
        var warnings = 0
        var errors = 0
        /// Changes whenever `shown` does, so the list can skip updates that change nothing.
        var version = 0
    }

    /// Identifies the input lines cheaply: both logs only append, drop from the front or start over with new ids.
    private struct InputKey: Equatable {
        let source: LogSource
        let count: Int
        let first: AnyHashable?
        let last: AnyHashable?
    }

    private var inputKey: InputKey?
    private var filterKey: (filter: LogsView.LevelFilter, search: String)?
    private var all: [LogRow] = []
    private var activityRows: [UUID: LogRow] = [:]
    private var result = Feed()

    private static let timeFormat: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm:ss"; return f
    }()

    func feed(source: LogSource, activity: [LogEntry], lines: [LogLine],
              filter: LogsView.LevelFilter, search: String) -> Feed {
        let key = source == .activity
            ? InputKey(source: source, count: activity.count, first: activity.first?.id, last: activity.last?.id)
            : InputKey(source: source, count: lines.count, first: lines.first?.id, last: lines.last?.id)
        var changed = false
        if key != inputKey {
            inputKey = key
            all = source == .activity ? rows(activity) : lines.map {
                LogRow(id: String($0.id), time: $0.time, tag: $0.tag, message: $0.message ?? $0.text, level: $0.level, raw: $0.text)
            }
            if source != .activity { activityRows = [:] }
            var warnings = 0, errors = 0
            for r in all {
                if r.level == .error { errors += 1 } else if r.level == .warn { warnings += 1 }
            }
            result.total = all.count; result.warnings = warnings; result.errors = errors
            changed = true
        }
        if changed || filterKey?.filter != filter || filterKey?.search != search {
            filterKey = (filter, search)
            result.shown = filter == .all && search.isEmpty ? all : all.filter {
                filter.includes($0.level) && (search.isEmpty || $0.raw.localizedCaseInsensitiveContains(search))
            }
            result.version &+= 1
        }
        return result
    }

    /// Activity rows, reusing the ones already made (formatting dates for 2000 entries on every change is not free).
    private func rows(_ entries: [LogEntry]) -> [LogRow] {
        var kept: [UUID: LogRow] = [:]
        kept.reserveCapacity(entries.count)
        let rows = entries.map { e -> LogRow in
            let row = activityRows[e.id] ?? {
                let time = Self.timeFormat.string(from: e.time)
                return LogRow(id: e.id.uuidString, time: time, tag: e.module, message: e.text, level: e.level,
                              raw: "\(time) [\(e.module)] \(e.text)")
            }()
            kept[e.id] = row
            return row
        }
        activityRows = kept
        return rows
    }
}

/// The picker of log sources. Equatable, so it is only redrawn when the selection changes,
/// not on every update of the panel (it checks which files exist each time it draws).
private struct SourceBar: View, Equatable {
    let selected: LogSource
    let selectedExists: Bool
    let select: (LogSource) -> Void

    static func == (a: SourceBar, b: SourceBar) -> Bool {
        a.selected == b.selected && a.selectedExists == b.selectedExists
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(LogSource.allCases) { s in
                        SourceChip(source: s, selected: s == selected,
                                   exists: s.path.map { FileManager.default.fileExists(atPath: $0) } ?? true) { select(s) }
                            .id(s)
                        if s == .activity || s == .php {
                            Divider().frame(height: 16).padding(.horizontal, 2)
                        }
                    }
                }
                .padding(.horizontal, 16).padding(.vertical, 10)
            }
            // Narrow windows can't show every tab: keep the selected one in view, and fade the edges as a hint.
            .onAppear { proxy.scrollTo(selected, anchor: .center) }
            .onChange(of: selected) { _, new in withAnimation(.snappy(duration: 0.25)) { proxy.scrollTo(new, anchor: .center) } }
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0), .init(color: .black, location: 0.02),
                                         .init(color: .black, location: 0.97), .init(color: .clear, location: 1)],
                                 startPoint: .leading, endPoint: .trailing))
        }
    }
}

private struct SourceChip: View {
    let source: LogSource
    let selected: Bool
    let exists: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Label(source.title, systemImage: source.icon)
                .symbolVariant(selected ? .fill : .none)
                .font(.callout.weight(selected ? .semibold : .regular))
                .padding(.horizontal, 10).padding(.vertical, 5)
                .background(Capsule().fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(hovering ? 0.09 : 0.05)))
                .foregroundStyle(selected ? Color.accentColor : (exists ? Color.primary : Color.secondary))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .help(source.path ?? "Everything Lampion does: starting, stopping, setup and errors.")
        .onHover { hovering = $0 }
        .animation(Motion.fade, value: hovering)
        .animation(Motion.fade, value: selected)
    }
}

/// The lines themselves. Equatable on the feed version, so it is skipped when the parent redraws for other reasons;
/// rows are Equatable too, so appending lines only draws the new ones.
private struct LogLines: View, Equatable {
    let rows: [LogRow]
    let version: Int
    let highlight: String
    let follow: Bool
    let onSearch: (String) -> Void

    static func == (a: LogLines, b: LogLines) -> Bool {
        a.version == b.version && a.highlight == b.highlight && a.follow == b.follow
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(rows) { row in
                        LogRowView(row: row, highlight: highlight)
                            .equatable()
                            .id(row.id)
                            .contextMenu {
                                Button("Copy Line") {
                                    NSPasteboard.general.clearContents()
                                    NSPasteboard.general.setString(row.raw, forType: .string)
                                }
                                Button("Search for “\(row.tag ?? "")”") { onSearch(row.tag ?? "") }.disabled(row.tag == nil)
                            }
                    }
                }
                .padding(.vertical, 6)
            }
            .background(Color(nsColor: .textBackgroundColor))
            // Jumps, never animated: an animated scroll through thousands of lazy rows stutters.
            .onAppear { if follow, let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) } }
            .onChange(of: rows.last?.id) { _, last in
                if follow, let last { proxy.scrollTo(last, anchor: .bottom) }
            }
            .onChange(of: follow) { _, on in
                if on, let last = rows.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}

struct LogRowView: View, Equatable {
    let row: LogRow
    let highlight: String

    static func == (a: LogRowView, b: LogRowView) -> Bool {
        a.row.id == b.row.id && a.highlight == b.highlight
    }

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            if let time = row.time {
                Text(time).foregroundStyle(.secondary).frame(width: 62, alignment: .leading)
            }
            if let tag = row.tag {
                Text(tag)
                    .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                    .lineLimit(1)
                    .padding(.horizontal, 6).padding(.vertical, 1)
                    .background(RoundedRectangle(cornerRadius: 4).fill(tagColor.opacity(0.14)))
                    .foregroundStyle(tagColor)
                    .frame(width: 96, alignment: .leading)
            }
            message
                .foregroundStyle(textColor)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.system(size: 12, design: .monospaced))
        .textSelection(.enabled)
        .padding(.leading, 13).padding(.trailing, 16).padding(.vertical, 3)
        .background(background)
        .overlay(alignment: .leading) { Rectangle().fill(barColor).frame(width: 3) }
    }

    private var barColor: Color {
        switch row.level {
        case .error: return .red
        case .warn: return .orange
        case .ok: return .green.opacity(0.7)
        case .info: return .clear
        }
    }

    private var background: Color {
        switch row.level {
        case .error: return Color.red.opacity(0.07)
        case .warn: return Color.orange.opacity(0.06)
        default: return .clear
        }
    }

    private var textColor: Color {
        switch row.level {
        case .error: return Color(nsColor: .systemRed)
        case .ok: return Color(nsColor: .systemGreen)
        default: return .primary
        }
    }

    /// Colour for the tag: HTTP status class, a known module, or a stable colour from the text.
    private var tagColor: Color {
        guard let tag = row.tag else { return .secondary }
        if let code = Int(tag), (100...599).contains(code) {
            return code >= 500 ? .red : code >= 400 ? .orange : code >= 300 ? .blue : .green
        }
        switch tag.lowercased() {
        case "apache": return Module.apache.tint
        case "mysql", "mariadb": return Module.mysql.tint
        case "php": return Tint.php
        case "setup": return .purple
        case "test": return .pink
        case "error", "fatal error", "parse error": return .red
        case "warning", "warn", "deprecated", "notice": return .orange
        default:
            let palette: [Color] = [.blue, .teal, .indigo, .brown, .cyan, .mint]
            return palette[abs(tag.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }) % palette.count]
        }
    }

    /// Plain text unless there is a search to highlight.
    private var message: Text {
        guard !highlight.isEmpty else { return Text(row.message) }
        var s = AttributedString(row.message)
        var start = s.startIndex
        while start < s.endIndex, let r = s[start...].range(of: highlight, options: .caseInsensitive) {
            s[r].backgroundColor = Color.yellow.opacity(0.45)
            start = r.upperBound
        }
        return Text(s)
    }
}
