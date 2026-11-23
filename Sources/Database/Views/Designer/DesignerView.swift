import SwiftUI
import AppKit

/// The Designer tab: the database's tables as boxes and its foreign keys as lines, on one pannable, zoomable diagram.
/// Drag a column's handle onto another column to add a relation; right-click a line to delete one.
struct DesignerView: View {
    @EnvironmentObject var m: DBModel
    @StateObject private var store = DesignerStore()
    @StateObject private var viewport = DesignerViewport()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if let db = m.currentDB {
            content(db)
                .animation(DBMotion.fade(reduceMotion), value: store.schema?.database)
                .onChange(of: db, initial: true) { _, new in store.load(m, db: new) }
                // The table lists reload on Refresh, after queries and after structure changes: follow them.
                .onReceive(m.$tables) { _ in store.tablesChanged(m, db: db) }
                .sheet(item: $store.pendingRelation) { r in
                    DesignerRelationSheet(relation: r, store: store).environmentObject(m)
                }
        } else {
            ContentUnavailableView("No Database Selected", systemImage: "cylinder.split.1x2",
                                   description: Text("Choose a database in the sidebar."))
        }
    }

    @ViewBuilder
    private func content(_ db: String) -> some View {
        if let schema = store.schema {
            if schema.tables.isEmpty {
                ContentUnavailableView {
                    Label("No Tables", systemImage: "point.3.connected.trianglepath.dotted")
                } description: {
                    Text("“\(db)” has no tables yet. Once it has some, they appear here as boxes, with lines for their foreign keys.")
                } actions: {
                    Button("New Table…") { m.sheet = .newTable }.buttonStyle(.borderedProminent)
                }
            } else {
                VStack(spacing: 0) {
                    DesignerToolbar(store: store, viewport: viewport)
                    DesignerCanvas(store: store, viewport: viewport, db: db)
                        .overlay(alignment: .bottomLeading) { DesignerHint(store: store).padding(12) }
                        .overlay { noRelations(schema) }
                }
                // A newly shown database fades in instead of popping.
                .id(schema.database)
                .transition(.opacity)
            }
        } else if let e = store.loadError {
            ContentUnavailableView {
                Label("Can't Read the Database", systemImage: "exclamationmark.triangle")
            } description: {
                Text(e)
            } actions: {
                Button("Try Again") { store.load(m, db: db) }
            }
        } else {
            DesignerLoading()
        }
    }

    @ViewBuilder
    private func noRelations(_ schema: DesignerSchema) -> some View {
        if store.relationsOnly && schema.relations.isEmpty {
            ContentUnavailableView {
                Label("No Relations", systemImage: "link")
            } description: {
                Text("None of the tables in “\(schema.database)” are linked by foreign keys yet. Show all tables, then drag from a column’s handle onto another table’s column to link them.")
            } actions: {
                Button("Show All Tables") { store.relationsOnly = false }
            }
            .background(Color(nsColor: .windowBackgroundColor).opacity(0.9))
        }
    }
}

/// Zoom, fit, arrange and the relations filter, above the canvas.
private struct DesignerToolbar: View {
    @ObservedObject var store: DesignerStore
    @ObservedObject var viewport: DesignerViewport

    var body: some View {
        DBBar {
            HStack(spacing: 2) {
                Button { viewport.zoom(to: viewport.zoom / 1.25) } label: {
                    Image(systemName: "minus.magnifyingglass").frame(width: 22)
                }
                .help("Zoom out (⌘−)")
                .accessibilityLabel("Zoom out")
                .keyboardShortcut("-", modifiers: .command)
                .disabled(viewport.zoom <= DesignerViewport.minZoom + 0.001)

                Menu {
                    ForEach([50, 75, 100, 150, 200], id: \.self) { p in
                        Button("\(p) %") { viewport.zoom(to: CGFloat(p) / 100) }
                    }
                    Divider()
                    Button("Fit to Window") { viewport.fit(store.contentBounds) }
                } label: {
                    Text("\(Int((viewport.zoom * 100).rounded())) %")
                        .font(.callout.monospacedDigit())
                        .frame(width: 44)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Zoom level")

                Button { viewport.zoom(to: viewport.zoom * 1.25) } label: {
                    Image(systemName: "plus.magnifyingglass").frame(width: 22)
                }
                .help("Zoom in (⌘+)")
                .accessibilityLabel("Zoom in")
                .keyboardShortcut("+", modifiers: .command)
                .disabled(viewport.zoom >= DesignerViewport.maxZoom - 0.001)
            }
            .buttonStyle(.borderless)

            Button { viewport.zoom(to: 1) } label: { EmptyView() }
                .keyboardShortcut("0", modifiers: .command)
                .frame(width: 0, height: 0).opacity(0)
                .accessibilityHidden(true)

            Divider().frame(height: 18)

            Button { viewport.fit(store.contentBounds) } label: {
                Label("Fit", systemImage: "arrow.up.left.and.arrow.down.right")
            }
            .help("Show the whole diagram")

            Button {
                store.autoArrange()
                viewport.content = store.contentBounds
                viewport.fit(store.contentBounds)
            } label: {
                Label("Auto Arrange", systemImage: "rectangle.3.group")
            }
            .help("Forget the positions you dragged and lay the tables out again")

            Toggle("Relations only", isOn: $store.relationsOnly)
                .toggleStyle(.checkbox)
                .help("Hide the tables that have no foreign keys and are not referenced")
                .onChange(of: store.relationsOnly) {
                    viewport.content = store.contentBounds
                    viewport.fit(store.contentBounds)
                }

            Spacer(minLength: 12)

            Text(countText)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .accessibilityLabel(countText)
        }
        .controlSize(.small)
    }

    private var countText: String {
        guard let s = store.schema else { return "" }
        let views = s.tables.filter(\.isView).count
        let tables = s.tables.count - views
        var parts = ["\(tables) table\(tables == 1 ? "" : "s")"]
        if views > 0 { parts.append("\(views) view\(views == 1 ? "" : "s")") }
        parts.append("\(s.relations.count) relation\(s.relations.count == 1 ? "" : "s")")
        if store.relationsOnly {
            let hidden = s.tables.count - store.visibleTables.count
            if hidden > 0 { parts.append("\(hidden) hidden") }
        }
        return parts.joined(separator: " · ")
    }
}

/// A one-line hint in the corner of the canvas, which follows what the user is doing.
private struct DesignerHint: View {
    @ObservedObject var store: DesignerStore

    var body: some View {
        if let text {
            Label(text.0, systemImage: text.1)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
                .allowsHitTesting(false)
                .animation(DBMotion.hover, value: text.0)
        }
    }

    private var text: (String, String)? {
        guard let s = store.schema, !s.tables.isEmpty else { return nil }
        if let l = store.link {
            if let t = l.target { return ("\(l.table).\(l.column)  ↔  \(t.table).\(t.column)", "link") }
            return ("Release over a column of another table", "link")
        }
        if s.tables.allSatisfy(\.isView) { return nil }
        return ("Drag the ○ beside a column onto another table’s column to add a relation · Double-click a table to open it",
                "hand.point.up.left")
    }
}

/// While a database's diagram is read for the first time: a calm empty canvas, with a spinner only if it takes a while.
private struct DesignerLoading: View {
    @State private var showSpinner = false

    var body: some View {
        ZStack {
            Color(nsColor: .textBackgroundColor).opacity(0.35)
            if showSpinner {
                ProgressView().controlSize(.small).transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            try? await Task.sleep(nanoseconds: 450_000_000)
            withAnimation(.easeOut(duration: 0.2)) { showSpinner = true }
        }
    }
}
