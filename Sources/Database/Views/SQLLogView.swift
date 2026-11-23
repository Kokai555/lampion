import SwiftUI
import AppKit

/// The SQL console at the bottom of the window. Collapsed it is a single line showing the last statement;
/// expanded it adds a scrolling list of everything the app sent to the server. Sizes itself.
///
/// The statements live in `DBActivity`, which the bar and the list observe on their own: a new statement
/// redraws only the console, not the rest of the window.
struct SQLLogView: View {
    @EnvironmentObject var m: DBModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let barHeight: CGFloat = 28
    static let listHeight: CGFloat = 180

    var body: some View {
        VStack(spacing: 0) {
            ConsoleBar(activity: m.activity, expanded: m.consoleExpanded, toggle: toggle)
            if m.consoleExpanded {
                VStack(spacing: 0) {
                    Divider()
                    ConsoleList(activity: m.activity)
                        .frame(height: Self.listHeight)
                }
                // Slides up from under the window edge like a drawer while the content above shrinks.
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .clipped()
    }

    private func toggle() {
        withAnimation(DBMotion.spring(reduceMotion)) { m.consoleExpanded.toggle() }
    }

    /// Errors are shown with an icon, so the "/* ERROR */" marker is left out of the visible text.
    static func display(_ line: SQLLogLine) -> String {
        let marker = "/* ERROR */ "
        if line.isError, line.text.hasPrefix(marker) { return String(line.text.dropFirst(marker.count)) }
        return line.text
    }
}

// MARK: - Bar

private struct ConsoleBar: View {
    @ObservedObject var activity: DBActivity
    let expanded: Bool
    let toggle: () -> Void

    private var statementCount: Int { activity.sqlLog.reduce(0) { $1.isError ? $0 : $0 + 1 } }

    var body: some View {
        HStack(spacing: 8) {
            Button(action: toggle) {
                HStack(spacing: 8) {
                    Image(systemName: "terminal")
                        .foregroundStyle(.secondary)
                    Text("Console")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    if !expanded {
                        lastLine.transition(.opacity)
                    }
                    Spacer(minLength: 8)
                    Text(statementCount == 1 ? "1 statement" : "\(statementCount.formatted()) statements")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .fixedSize()
                }
                .frame(maxHeight: .infinity)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(expanded ? "Hide the SQL console" : "Show every statement sent to the server")
            .accessibilityLabel("Console, \(statementCount) statements")
            .accessibilityHint(expanded ? "Collapses the console" : "Expands the console")

            if expanded {
                Group {
                    Button(action: copyAll) { Label("Copy All", systemImage: "doc.on.doc") }
                        .help("Copy all statements")
                    Button { activity.sqlLog.removeAll() } label: { Label("Clear", systemImage: "trash") }
                        .help("Clear the console")
                }
                .labelStyle(.iconOnly)
                .disabled(activity.sqlLog.isEmpty)
                .transition(.opacity)
            }

            Button(action: toggle) {
                Image(systemName: "chevron.up")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 180 : 0))
                    .frame(width: 16, height: 16)
                    .contentShape(Rectangle())
            }
            .help(expanded ? "Collapse" : "Expand")
            .accessibilityLabel(expanded ? "Collapse console" : "Expand console")
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .frame(height: SQLLogView.barHeight)
        .frame(maxWidth: .infinity)
        .background(.bar)
    }

    @ViewBuilder private var lastLine: some View {
        if let last = activity.sqlLog.last {
            HStack(spacing: 4) {
                if last.isError {
                    Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 10)).foregroundStyle(.red)
                }
                Text(SQLLogView.display(last))
                    .font(DBStyle.monoSmall)
                    .foregroundStyle(last.isError ? Color.red : Color.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            .padding(.leading, 4)
        } else {
            Text("No statements yet")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 4)
        }
    }

    private func copyAll() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(activity.sqlLog.map(\.text).joined(separator: "\n"), forType: .string)
    }
}

// MARK: - List

private struct ConsoleList: View {
    @ObservedObject var activity: DBActivity

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 3) {
                    ForEach(activity.sqlLog) { line in
                        HStack(alignment: .firstTextBaseline, spacing: 6) {
                            Image(systemName: line.isError ? "exclamationmark.triangle.fill" : "chevron.right")
                                .font(.system(size: line.isError ? 9.5 : 8, weight: .semibold))
                                .foregroundStyle(line.isError ? AnyShapeStyle(Color.red) : AnyShapeStyle(.tertiary))
                                .frame(width: 12)
                                .accessibilityLabel("Error")
                                .accessibilityHidden(!line.isError)
                            Text(SQLLogView.display(line))
                                .foregroundStyle(line.isError ? Color.red : Color.secondary)
                                .lineLimit(4)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .id(line.id)
                    }
                }
                .font(DBStyle.monoSmall)
                .textSelection(.enabled)
                .padding(.horizontal, 12).padding(.vertical, 8)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(nsColor: .textBackgroundColor))
            .overlay {
                if activity.sqlLog.isEmpty {
                    Text("Statements sent to the server will appear here.")
                        .font(.callout).foregroundStyle(.tertiary)
                }
            }
            .onAppear {
                if let last = activity.sqlLog.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
            .onChange(of: activity.sqlLog.last?.id) {
                // New lines arrive while the console may be animating; jump, don't animate the scroll.
                if let last = activity.sqlLog.last { proxy.scrollTo(last.id, anchor: .bottom) }
            }
        }
    }
}
