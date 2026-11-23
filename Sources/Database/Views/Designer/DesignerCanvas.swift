import SwiftUI
import AppKit

/// The pannable, zoomable diagram. Cards live in a scaled "world" layer; lines, the background grid and the
/// relation being dragged are drawn in canvas coordinates, so they stay crisp and cheap at any zoom.
/// All pointer handling (hover, drag, double-click, context menu) is done here with hit tests against the
/// store's geometry, so cards need no gestures of their own.
struct DesignerCanvas: View {
    @EnvironmentObject var m: DBModel
    @ObservedObject var store: DesignerStore
    @ObservedObject var viewport: DesignerViewport
    let db: String

    @State private var mode: DragMode?
    @State private var pointer: CGPoint?

    static let space = "designerCanvas"

    private enum DragMode {
        case pan(start: CGPoint)
        case move(table: String, start: CGPoint)
        case link
    }

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                DesignerLinesLayer(store: store, viewport: viewport)
                DesignerWorld(store: store)
                    .scaleEffect(viewport.zoom, anchor: .topLeading)
                    .offset(x: viewport.pan.x, y: viewport.pan.y)
                DesignerLinkLayer(store: store, viewport: viewport)
                tooltip(in: geo.size)
            }
            .frame(width: geo.size.width, height: geo.size.height, alignment: .topLeading)
            .clipped()
            .contentShape(Rectangle())
            .coordinateSpace(name: Self.space)
            .gesture(drag)
            .simultaneousGesture(doubleClick)
            .onContinuousHover(coordinateSpace: .named(Self.space)) { phase in
                switch phase {
                case .active(let p):
                    pointer = p
                    if mode == nil { store.hover(world: viewport.world(p), screen: p, zoom: viewport.zoom) }
                case .ended:
                    pointer = nil
                    if mode == nil { store.clearHover() }
                }
            }
            .contextMenu { contextMenu }
            .background(DesignerEventCatcher(onScroll: scroll, onMagnify: magnify, onSmartMagnify: smartMagnify))
            .onAppear { resize(geo.size) }
            .onChange(of: geo.size) { _, s in resize(s) }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .onChange(of: store.positions) { viewport.content = store.contentBounds }
        .onChange(of: store.relationsOnly) { viewport.content = store.contentBounds }
        .onChange(of: store.needsFit, initial: true) { fitIfNeeded() }
    }

    private func resize(_ size: CGSize) {
        viewport.size = size
        if viewport.followsFit && !store.needsFit { viewport.fit(store.contentBounds) }
        fitIfNeeded()
    }

    private func fitIfNeeded() {
        guard store.needsFit, store.schema != nil, viewport.size.width > 40 else { return }
        viewport.content = store.contentBounds
        viewport.fit(store.contentBounds)
        store.needsFit = false
    }

    // MARK: Pointer

    private var drag: some Gesture {
        DragGesture(minimumDistance: 2, coordinateSpace: .named(Self.space))
            .onChanged { v in
                if mode == nil { begin(at: v.startLocation) }
                let world = viewport.world(v.location)
                switch mode {
                case .pan(let start):
                    viewport.setPan(CGPoint(x: start.x + v.translation.width, y: start.y + v.translation.height))
                case .move(let table, let start):
                    store.move(table, to: CGPoint(x: start.x + v.translation.width / viewport.zoom,
                                                  y: start.y + v.translation.height / viewport.zoom))
                case .link:
                    store.updateLink(to: world)
                case nil:
                    break
                }
            }
            .onEnded { v in
                switch mode {
                case .pan:
                    NSCursor.pop()
                case .move:
                    store.draggingTable = nil
                    store.savePositions()
                case .link:
                    store.updateLink(to: viewport.world(v.location))
                    store.endLink()
                default:
                    break
                }
                mode = nil
                store.hover(world: viewport.world(v.location), screen: v.location, zoom: viewport.zoom)
            }
    }

    /// Decides what a drag does from where it starts: a row's handle links, a card moves, empty space pans.
    private func begin(at screen: CGPoint) {
        let p = viewport.world(screen)
        guard let name = store.table(at: p), let f = store.frame(name) else {
            mode = .pan(start: viewport.pan)
            NSCursor.closedHand.push()
            return
        }
        let reach = max(7, 7 / viewport.zoom)
        if store.canLink(name), abs(p.x - f.maxX) <= reach, let c = store.column(at: p), c.table == name {
            store.clearHover()
            store.beginLink(table: name, column: c.column, at: p)
            mode = .link
            return
        }
        store.draggingTable = name
        mode = .move(table: name, start: f.origin)
    }

    private var doubleClick: some Gesture {
        SpatialTapGesture(count: 2, coordinateSpace: .named(Self.space))
            .onEnded { v in
                if let t = store.table(at: viewport.world(v.location)) { open(t, tab: .structure) }
            }
    }

    private func open(_ table: String, tab: DBTab) {
        m.tab = tab
        m.selection = .table(db, table)
    }

    // MARK: Scroll and zoom

    private func scroll(_ e: NSEvent, at p: CGPoint) {
        if e.modifierFlags.contains(.command) {
            let dy = e.hasPreciseScrollingDeltas ? e.scrollingDeltaY : e.scrollingDeltaY * 8
            viewport.zoom(to: viewport.zoom * exp(dy * 0.01), around: p)
        } else {
            let k: CGFloat = e.hasPreciseScrollingDeltas ? 1 : 10
            viewport.scroll(by: CGSize(width: e.scrollingDeltaX * k, height: e.scrollingDeltaY * k))
        }
        if mode == nil { store.hover(world: viewport.world(p), screen: p, zoom: viewport.zoom) }
    }

    private func magnify(_ e: NSEvent, at p: CGPoint) {
        viewport.zoom(to: viewport.zoom * (1 + e.magnification), around: p)
    }

    private func smartMagnify(_ e: NSEvent, at p: CGPoint) {
        if abs(viewport.zoom - 1) < 0.01 {
            viewport.fit(store.contentBounds)
        } else {
            viewport.zoom(to: 1, around: p)
        }
    }

    // MARK: Overlays

    @ViewBuilder
    private func tooltip(in size: CGSize) -> some View {
        if mode == nil, store.link == nil, let r = store.relation(store.hoveredRelation) {
            let a = store.hoverAnchor
            Text(r.summary)
                .font(.system(size: 11.5, weight: .medium, design: .monospaced))
                .lineLimit(1)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(Color.primary.opacity(0.1)))
                .shadow(color: .black.opacity(0.12), radius: 6, y: 2)
                .fixedSize()
                .alignmentGuide(.leading) { d in -min(a.x + 14, max(8, size.width - d.width - 8)) }
                .alignmentGuide(.top) { d in -(a.y + 18 + d.height > size.height ? a.y - d.height - 10 : a.y + 18) }
                .allowsHitTesting(false)
                .transition(.opacity)
        }
    }

    // MARK: Context menu

    @ViewBuilder
    private var contextMenu: some View {
        if let r = store.relation(store.hoveredRelation) {
            Text(r.summary)
            Divider()
            Button("Delete Relation…") { confirmDelete(r) }
            Button("Open “\(r.table)” Structure") { open(r.table, tab: .structure) }
        } else if let t = store.hoveredTable {
            Button("Open Structure") { open(t, tab: .structure) }
            Button("Open Data") { open(t, tab: .data) }
            Divider()
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(t, forType: .string)
            }
        } else {
            Button("Fit to Window") { viewport.fit(store.contentBounds) }
            Button("Auto Arrange") { arrange() }
            Toggle("Relations Only", isOn: $store.relationsOnly)
        }
    }

    private func arrange() {
        store.autoArrange()
        viewport.content = store.contentBounds
        viewport.fit(store.contentBounds)
    }

    private func confirmDelete(_ r: DesignerRelation) {
        store.confirmDelete(r, m: m)
    }
}

/// The cards, at world coordinates. Observes only the store, so panning and zooming don't rebuild it.
private struct DesignerWorld: View {
    @ObservedObject var store: DesignerStore

    var body: some View {
        let emphasis = store.emphasis
        let link = store.link
        let schema = store.schema
        var foreign: [String: Set<String>] = [:]
        var external: [String: [String: String]] = [:]
        for r in schema?.relations ?? [] { foreign[r.table, default: []].formUnion(r.columns) }
        for r in schema?.external ?? [] {
            for (c, rc) in zip(r.columns, r.refColumns) { external[r.table, default: [:]][c] = "\(r.refSchema).\(r.refTable).\(rc)" }
        }
        return ZStack(alignment: .topLeading) {
            ForEach(store.visibleTables) { t in
                if let layout = store.layouts[t.name], let p = store.positions[t.name] {
                    DesignerCard(
                        table: t, layout: layout,
                        state: state(t.name, emphasis),
                        foreignColumns: foreign[t.name] ?? [],
                        externalTargets: external[t.name] ?? [:],
                        highlighted: store.highlightedColumns(t.name),
                        dropTarget: link?.target?.table == t.name ? link?.target?.column : nil,
                        dragSource: link?.table == t.name ? link?.column : nil,
                        hovered: store.hoveredTable == t.name && link == nil
                    )
                    .equatable()
                    .offset(x: p.x, y: p.y)
                    .zIndex(store.draggingTable == t.name ? 1 : 0)
                }
            }
        }
    }

    private func state(_ name: String, _ e: (tables: Set<String>, relations: Set<String>)?) -> DesignerCardState {
        guard let e else { return .normal }
        if !e.tables.contains(name) { return .dimmed }
        return (store.hoveredTable == name || store.draggingTable == name || store.hoveredRelation != nil) ? .highlighted : .normal
    }
}

/// Dot grid and relation lines, drawn in canvas coordinates.
private struct DesignerLinesLayer: View {
    @ObservedObject var store: DesignerStore
    @ObservedObject var viewport: DesignerViewport
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        let z = viewport.zoom, pan = viewport.pan
        let curves = store.curves
        let emphasis = store.emphasis
        let hovered = store.hoveredRelation
        let visible = Set(store.visibleTables.map(\.name))
        let relations = Dictionary(uniqueKeysWithValues: (store.schema?.relations ?? []).map { ($0.id, $0) })
        let lineColor = NSColor.systemPurple
        let dotColor = Color.primary.opacity(scheme == .dark ? 0.10 : 0.09)
        Canvas { ctx, size in
            // Background dots, every 24 pt of the world (fewer when zoomed far out).
            var step = 24 * z
            while step < 12 { step *= 2 }
            let ox = pan.x.truncatingRemainder(dividingBy: step), oy = pan.y.truncatingRemainder(dividingBy: step)
            var dots = Path()
            let r: CGFloat = 0.9
            var y = oy - step
            while y < size.height + step {
                var x = ox - step
                while x < size.width + step {
                    dots.addEllipse(in: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2))
                    x += step
                }
                y += step
            }
            ctx.fill(dots, with: .color(dotColor))

            func s(_ p: CGPoint) -> CGPoint { CGPoint(x: p.x * z + pan.x, y: p.y * z + pan.y) }
            let screen = CGRect(origin: .zero, size: size).insetBy(dx: -40, dy: -40)
            let width = max(0.8, 1.4 * z)
            // Dimmed lines first, highlighted ones on top.
            let ordered = curves.sorted { a, b in
                let ea = emphasis?.relations.contains(a.relationID) ?? false
                let eb = emphasis?.relations.contains(b.relationID) ?? false
                return !ea && eb
            }
            for c in ordered {
                guard let rel = relations[c.relationID], visible.contains(rel.table), visible.contains(rel.refTable) else { continue }
                let b = c.bounds
                let sb = CGRect(x: b.minX * z + pan.x, y: b.minY * z + pan.y, width: b.width * z, height: b.height * z)
                guard sb.intersects(screen) else { continue }
                let isHovered = hovered == c.relationID
                let bright = emphasis == nil || emphasis!.relations.contains(c.relationID)
                let alpha: CGFloat = emphasis == nil ? 0.62 : (bright ? 0.95 : 0.1)
                let color = Color(nsColor: lineColor.withAlphaComponent(alpha))
                let w = isHovered || (bright && emphasis != nil) ? width * 1.7 : width

                var path = Path()
                path.move(to: s(c.start))
                path.addCurve(to: s(c.end), control1: s(c.c1), control2: s(c.c2))
                ctx.stroke(path, with: .color(color), style: StrokeStyle(lineWidth: w, lineCap: .round))

                // Arrow into the referenced column.
                let tip = s(CGPoint(x: c.end.x - c.endSide * DesignerGeometry.arrowLength, y: c.end.y))
                let base = s(c.end)
                let half = max(2.5, 4.2 * z) * (isHovered ? 1.15 : 1)
                var arrow = Path()
                arrow.move(to: tip)
                arrow.addLine(to: CGPoint(x: base.x, y: base.y - half))
                arrow.addLine(to: CGPoint(x: base.x, y: base.y + half))
                arrow.closeSubpath()
                ctx.fill(arrow, with: .color(color))

                // A dot where the line leaves the foreign key column.
                let start = s(c.start)
                let dr = max(1.6, 2.6 * z)
                ctx.fill(Path(ellipseIn: CGRect(x: start.x - dr, y: start.y - dr, width: dr * 2, height: dr * 2)), with: .color(color))
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The dashed line while a relation is being dragged from a column handle.
private struct DesignerLinkLayer: View {
    @ObservedObject var store: DesignerStore
    @ObservedObject var viewport: DesignerViewport

    var body: some View {
        if let (from, end) = endpoints {
            Canvas { ctx, _ in
                var p = Path()
                let k = max(30, abs(end.x - from.x) * 0.45)
                p.move(to: from)
                p.addCurve(to: end, control1: CGPoint(x: from.x + k, y: from.y),
                           control2: CGPoint(x: end.x + (end.x < from.x ? k : -k), y: end.y))
                ctx.stroke(p, with: .color(.accentColor), style: StrokeStyle(lineWidth: 2, lineCap: .round, dash: [6, 4]))
                let r: CGFloat = 4
                ctx.fill(Path(ellipseIn: CGRect(x: end.x - r, y: end.y - r, width: r * 2, height: r * 2)), with: .color(.accentColor))
            }
            .allowsHitTesting(false)
        }
    }

    /// From the source handle to the pointer, or to the edge of the target row when over one (canvas coordinates).
    private var endpoints: (CGPoint, CGPoint)? {
        guard let link = store.link, let f = store.frame(link.table), let t = store.schema?.table(link.table),
              let l = store.layouts[link.table] else { return nil }
        let z = viewport.zoom, pan = viewport.pan
        let from = CGPoint(x: f.maxX * z + pan.x, y: (f.minY + l.rowCenter(of: link.column, in: t)) * z + pan.y)
        var to = CGPoint(x: link.point.x * z + pan.x, y: link.point.y * z + pan.y)
        if let target = link.target, let tf = store.frame(target.table), let tt = store.schema?.table(target.table),
           let tl = store.layouts[target.table] {
            let y = (tf.minY + tl.rowCenter(of: target.column, in: tt)) * z + pan.y
            let left = tf.minX * z + pan.x, right = tf.maxX * z + pan.x
            to = CGPoint(x: abs(left - from.x) < abs(right - from.x) ? left : right, y: y)
        }
        return (from, to)
    }
}

/// Catches scroll-wheel, pinch and smart-zoom events over the canvas (SwiftUI has no scroll-wheel events on macOS 14).
/// Uses a local event monitor and never takes part in hit testing, so clicks reach the SwiftUI views above.
struct DesignerEventCatcher: NSViewRepresentable {
    var onScroll: (NSEvent, CGPoint) -> Void
    var onMagnify: (NSEvent, CGPoint) -> Void
    var onSmartMagnify: (NSEvent, CGPoint) -> Void

    func makeNSView(context: Context) -> CatcherView {
        let v = CatcherView()
        v.handlers = self
        return v
    }

    func updateNSView(_ v: CatcherView, context: Context) { v.handlers = self }

    final class CatcherView: NSView {
        var handlers: DesignerEventCatcher?
        private var monitor: Any?

        override var isFlipped: Bool { true }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify, .smartMagnify]) { [weak self] e in
                guard let self, let h = self.handlers, let w = self.window, e.window === w, w.attachedSheet == nil,
                      !self.isHiddenOrHasHiddenAncestor else { return e }
                let p = self.convert(e.locationInWindow, from: nil)
                guard self.bounds.contains(p) else { return e }
                switch e.type {
                case .scrollWheel: h.onScroll(e, p)
                case .magnify: h.onMagnify(e, p)
                case .smartMagnify: h.onSmartMagnify(e, p)
                default: return e
                }
                return nil
            }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
