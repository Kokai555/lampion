import SwiftUI
import AppKit

/// A relation the user is about to create by dragging between two columns (shown in the confirm sheet).
struct DesignerNewRelation: Identifiable, Equatable {
    let id = UUID()
    let database: String
    var table: String
    var column: String
    var refTable: String
    var refColumn: String

    func swapped() -> DesignerNewRelation {
        DesignerNewRelation(database: database, table: refTable, column: refColumn, refTable: table, refColumn: column)
    }
}

/// A column-to-column drag in progress.
struct DesignerLinkDrag: Equatable {
    let table: String
    let column: String
    /// The pointer, in world coordinates.
    var point: CGPoint
    /// The column under the pointer that would become the other end.
    var target: DesignerColumnRef?
}

struct DesignerColumnRef: Equatable, Hashable {
    let table: String
    let column: String
}

/// State of the Designer tab for the selected database: what is drawn, where, and what the pointer is over.
final class DesignerStore: ObservableObject {
    @Published private(set) var schema: DesignerSchema?
    @Published private(set) var loadError: String?
    @Published private(set) var positions: [String: CGPoint] = [:] {
        didSet { curvesDirty = true }
    }
    @Published var hoveredTable: String?
    @Published var hoveredRelation: String?
    /// Where the pointer was (canvas coordinates) when the hovered relation was entered; the tooltip sits there.
    var hoverAnchor: CGPoint = .zero
    @Published var link: DesignerLinkDrag?
    @Published var draggingTable: String?
    @Published var pendingRelation: DesignerNewRelation?
    @Published var relationsOnly = UserDefaults.standard.bool(forKey: "db.designer.relationsOnly") {
        didSet { UserDefaults.standard.set(relationsOnly, forKey: "db.designer.relationsOnly") }
    }

    private(set) var layouts: [String: DesignerCardLayout] = [:]
    private(set) var database: String?
    /// Set when a new database (or the first schema) arrived; the view fits the diagram into the window once.
    @Published var needsFit = false
    private var generation = 0
    private var pendingReload: DispatchWorkItem?
    /// Schemas already read, per database, kept while the app runs: switching back (or leaving the tab and
    /// returning) shows the diagram at once, and a fresh read only updates it if something changed.
    private static var cache: [String: DesignerSchema] = [:]
    /// The table list last seen per database, to tell real changes from the reload that comes with every selection.
    private var tableSignatures: [String: [String]] = [:]

    // MARK: Loading

    /// Called when the sidebar's table lists change. Reloads only when this database's tables really changed:
    /// selecting a database reloads its list too, and that must not restart the read already under way.
    func tablesChanged(_ m: DBModel, db: String) {
        let signature = (m.tables[db] ?? []).map { "\($0.name)\u{1}\($0.type)\u{1}\($0.engine)" }
        let previous = tableSignatures[db]
        tableSignatures[db] = signature
        guard let previous, previous != signature else { return }
        requestReload(m, db: db)
    }

    /// Reloads soon; several requests in a row (refresh reloads every table list) make one query.
    func requestReload(_ m: DBModel, db: String, delay: Double = 0.08) {
        pendingReload?.cancel()
        let work = DispatchWorkItem { [weak self, weak m] in
            guard let self, let m else { return }
            self.load(m, db: db)
        }
        pendingReload = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    func load(_ m: DBModel, db: String, then: (() -> Void)? = nil) {
        if database != db {
            database = db
            schema = nil
            loadError = nil
            positions = [:]
            layouts = [:]
            clearHover()
            link = nil
            if let cached = Self.cache[db] { apply(cached) }
        }
        generation += 1
        let ticket = generation
        m.loadDesignerSchema(db) { [weak self] result in
            guard let self, ticket == self.generation, self.database == db else { return }
            switch result {
            case .failure(let e):
                self.loadError = e.message
            case .success(let s):
                self.loadError = nil
                Self.cache[db] = s
                self.apply(s)
            }
            then?()
        }
    }

    private func apply(_ s: DesignerSchema) {
        let first = schema == nil
        if s == schema { return }
        var relationColumns: [String: Set<String>] = [:]
        for r in s.relations {
            relationColumns[r.table, default: []].formUnion(r.columns)
            relationColumns[r.refTable, default: []].formUnion(r.refColumns)
        }
        var newLayouts: [String: DesignerCardLayout] = [:]
        for t in s.tables { newLayouts[t.name] = DesignerCardLayout(table: t, relationColumns: relationColumns[t.name] ?? []) }
        layouts = newLayouts
        schema = s
        if hoveredTable.map({ s.table($0) == nil }) == true { hoveredTable = nil }
        if hoveredRelation.map({ id in !s.relations.contains { $0.id == id } }) == true { hoveredRelation = nil }
        positions = placed(s)
        if first { needsFit = true }
    }

    /// Saved positions where there are any; new tables are placed by the automatic layout, beside the saved ones.
    private func placed(_ s: DesignerSchema) -> [String: CGPoint] {
        let sizes = cardSizes
        let auto = DesignerGeometry.autoLayout(schema: s, sizes: sizes)
        let current = positions.isEmpty ? savedPositions(s.database) : positions
        let known = current.filter { name, _ in s.table(name) != nil }
        guard !known.isEmpty else { return auto }
        var result = known
        let missing = s.tables.map(\.name).filter { known[$0] == nil }
        guard !missing.isEmpty else { return result }
        let right = known.map { name, p in p.x + (sizes[name]?.width ?? 200) }.max() ?? 0
        let top = known.values.map(\.y).min() ?? DesignerGeometry.margin
        let minX = missing.compactMap { auto[$0]?.x }.min() ?? 0
        let minY = missing.compactMap { auto[$0]?.y }.min() ?? 0
        for name in missing {
            let p = auto[name] ?? .zero
            result[name] = CGPoint(x: right + DesignerGeometry.componentGap + p.x - minX, y: top + p.y - minY)
        }
        return result
    }

    var cardSizes: [String: CGSize] {
        layouts.mapValues { CGSize(width: $0.width, height: $0.height) }
    }

    // MARK: Positions

    private func key(_ db: String) -> String { "db.designer.positions." + db }

    private func savedPositions(_ db: String) -> [String: CGPoint] {
        guard let raw = UserDefaults.standard.dictionary(forKey: key(db)) as? [String: [Double]] else { return [:] }
        return raw.compactMapValues { v in v.count == 2 ? CGPoint(x: v[0], y: v[1]) : nil }
    }

    func savePositions() {
        guard let db = database else { return }
        let raw = positions.mapValues { [Double($0.x.rounded()), Double($0.y.rounded())] }
        UserDefaults.standard.set(raw, forKey: key(db))
    }

    func move(_ table: String, to p: CGPoint) {
        positions[table] = CGPoint(x: max(0, p.x), y: max(0, p.y))
    }

    /// Forgets the saved positions and lays the diagram out again.
    func autoArrange() {
        guard let s = schema, let db = database else { return }
        UserDefaults.standard.removeObject(forKey: key(db))
        positions = DesignerGeometry.autoLayout(schema: s, sizes: cardSizes)
    }

    // MARK: Derived

    var visibleTables: [DesignerTable] {
        guard let s = schema else { return [] }
        guard relationsOnly else { return s.tables }
        let c = s.connected
        return s.tables.filter { c.contains($0.name) }
    }

    func frame(_ table: String) -> CGRect? {
        guard let p = positions[table], let l = layouts[table] else { return nil }
        return CGRect(x: p.x, y: p.y, width: l.width, height: l.height)
    }

    var frames: [String: CGRect] {
        var f: [String: CGRect] = [:]
        for (name, p) in positions {
            if let l = layouts[name] { f[name] = CGRect(x: p.x, y: p.y, width: l.width, height: l.height) }
        }
        return f
    }

    /// The area the visible cards and lines cover.
    var contentBounds: CGRect? {
        let rects = visibleTables.compactMap { frame($0.name) } + curves.map(\.bounds)
        guard var r = rects.first else { return nil }
        for x in rects.dropFirst() { r = r.union(x) }
        return r
    }

    private var curvesDirty = true
    private var cachedCurves: [RelationCurve] = []

    var curves: [RelationCurve] {
        if curvesDirty {
            curvesDirty = false
            guard let s = schema else { cachedCurves = []; return [] }
            let f = frames
            cachedCurves = s.relations.flatMap { DesignerGeometry.curves(for: $0, schema: s, frames: f, layouts: layouts) }
        }
        return cachedCurves
    }

    func relation(_ id: String?) -> DesignerRelation? {
        guard let id else { return nil }
        return schema?.relations.first { $0.id == id }
    }

    /// The tables and relations to keep bright while something is hovered; nil when nothing is dimmed.
    var emphasis: (tables: Set<String>, relations: Set<String>)? {
        guard link == nil, let s = schema else { return nil }
        if let r = relation(hoveredRelation) {
            return ([r.table, r.refTable], [r.id])
        }
        if let t = hoveredTable ?? draggingTable {
            var tables: Set<String> = [t]
            var rels = Set<String>()
            for r in s.relations where r.table == t || r.refTable == t {
                rels.insert(r.id)
                tables.insert(r.table)
                tables.insert(r.refTable)
            }
            return (tables, rels)
        }
        return nil
    }

    /// Columns of a table that take part in the hovered relation (highlighted rows).
    func highlightedColumns(_ table: String) -> Set<String> {
        guard link == nil, let r = relation(hoveredRelation) else { return [] }
        var s = Set<String>()
        if r.table == table { s.formUnion(r.columns) }
        if r.refTable == table { s.formUnion(r.refColumns) }
        return s
    }

    // MARK: Hit testing (world coordinates)

    func table(at p: CGPoint) -> String? {
        // Last drawn is on top.
        for t in visibleTables.reversed() where frame(t.name)?.insetBy(dx: -DesignerMetrics.handleRadius, dy: 0).contains(p) == true {
            return t.name
        }
        return nil
    }

    func column(at p: CGPoint) -> DesignerColumnRef? {
        guard let name = table(at: p), let f = frame(name), let t = schema?.table(name), let l = layouts[name],
              let c = l.column(at: p.y - f.minY, in: t) else { return nil }
        return DesignerColumnRef(table: name, column: c)
    }

    func relation(at p: CGPoint, tolerance: CGFloat) -> String? {
        let visible = Set(visibleTables.map(\.name))
        var best: (id: String, d: CGFloat)?
        for c in curves where c.bounds.insetBy(dx: -tolerance, dy: -tolerance).contains(p) {
            guard let r = relation(c.relationID), visible.contains(r.table), visible.contains(r.refTable) else { continue }
            let d = c.distance(to: p)
            if d <= tolerance && d < (best?.d ?? .infinity) { best = (c.relationID, d) }
        }
        return best?.id
    }

    /// Updates the hover state for a pointer position; publishes only when something changed.
    func hover(world p: CGPoint, screen: CGPoint, zoom: CGFloat) {
        let t = table(at: p)
        let r = t == nil ? relation(at: p, tolerance: 6 / max(zoom, 0.2)) : nil
        if r != hoveredRelation {
            hoverAnchor = screen
            hoveredRelation = r
        }
        if t != hoveredTable { hoveredTable = t }
    }

    func clearHover() {
        if hoveredTable != nil { hoveredTable = nil }
        if hoveredRelation != nil { hoveredRelation = nil }
    }

    // MARK: Creating relations by dragging

    func canLink(_ table: String) -> Bool { schema?.table(table)?.isView == false }

    func beginLink(table: String, column: String, at p: CGPoint) {
        link = DesignerLinkDrag(table: table, column: column, point: p, target: nil)
    }

    func updateLink(to p: CGPoint) {
        guard var l = link else { return }
        l.point = p
        if let c = column(at: p), canLink(c.table), !(c.table == l.table && c.column == l.column) {
            l.target = c
        } else {
            l.target = nil
        }
        if l != link { link = l }
    }

    /// Ends the drag; when it ended on a column, the confirm sheet opens. Dragging from a key onto a plain column
    /// is read as "this column refers to that key" the other way round.
    func endLink() {
        defer { link = nil }
        guard let l = link, let target = l.target, let db = database, let s = schema,
              let from = s.table(l.table)?.column(l.column), let to = s.table(target.table)?.column(target.column) else { return }
        var r = DesignerNewRelation(database: db, table: l.table, column: l.column, refTable: target.table, refColumn: target.column)
        func isKey(_ c: DesignerColumn) -> Bool { c.isPrimary || c.key == "UNI" }
        if (isKey(from) && !isKey(to)) || (!isKey(to) && from.isIndexed && !to.isIndexed) { r = r.swapped() }
        pendingRelation = r
    }

    /// Asks, then drops the foreign key and reloads the diagram.
    func confirmDelete(_ r: DesignerRelation, m: DBModel) {
        guard let db = database else { return }
        let sql = "ALTER TABLE \(SQL.id(db)).\(SQL.id(r.table)) DROP FOREIGN KEY \(SQL.id(r.name));"
        m.confirm = ConfirmRequest(
            title: "Delete the relation “\(r.name)”?",
            message: "\(r.summary)\n\nThe columns and their data stay; only the foreign key is removed.\n\n\(sql)",
            button: "Delete Relation"
        ) { [weak self, weak m] in
            guard let m else { return }
            m.change(sql, db: db) { _ in self?.load(m, db: db) }
        }
    }

    /// A free constraint name such as `fk_orders_customer_id`.
    func suggestedName(table: String, column: String) -> String {
        let base = String(("fk_" + table + "_" + column).prefix(60))
        let used = schema?.constraintNames ?? []
        var name = base, n = 2
        while used.contains(name.lowercased()) { name = base + "_\(n)"; n += 1 }
        return name
    }
}

/// Zoom and scroll position of the canvas. Kept apart from `DesignerStore`, so panning redraws only the transform.
final class DesignerViewport: ObservableObject {
    static let minZoom: CGFloat = 0.05
    static let maxZoom: CGFloat = 2.5

    @Published var zoom: CGFloat = 1
    /// Where the world's origin sits in the canvas.
    @Published var pan: CGPoint = CGPoint(x: 0, y: 0)
    /// The canvas size, kept up to date by the canvas.
    var size: CGSize = .zero
    /// The diagram's extent, for keeping some of it on screen while panning.
    var content: CGRect?
    /// True after "Fit" until the user pans or zooms: resizing the window then fits again.
    var followsFit = false

    func world(_ screen: CGPoint) -> CGPoint {
        CGPoint(x: (screen.x - pan.x) / zoom, y: (screen.y - pan.y) / zoom)
    }

    func screen(_ world: CGPoint) -> CGPoint {
        CGPoint(x: world.x * zoom + pan.x, y: world.y * zoom + pan.y)
    }

    func scroll(by d: CGSize) {
        followsFit = false
        pan = clamped(CGPoint(x: pan.x + d.width, y: pan.y + d.height), zoom: zoom)
    }

    func setPan(_ p: CGPoint) {
        followsFit = false
        pan = clamped(p, zoom: zoom)
    }

    /// Zooms keeping the world point under `anchor` (canvas coordinates) in place; the centre when nil.
    func zoom(to value: CGFloat, around anchor: CGPoint? = nil) {
        followsFit = false
        let z = min(Self.maxZoom, max(Self.minZoom, value))
        let a = anchor ?? CGPoint(x: size.width / 2, y: size.height / 2)
        let w = world(a)
        let p = CGPoint(x: a.x - w.x * z, y: a.y - w.y * z)
        zoom = z
        pan = clamped(p, zoom: z)
    }

    /// Shows all of `rect`, at most at 100 %.
    func fit(_ rect: CGRect?) {
        guard let rect, size.width > 40, size.height > 40 else { return }
        // A margin of 28 pt on screen, whatever the zoom.
        let r = rect
        let m: CGFloat = 28
        let z = min(1, max(Self.minZoom, min((size.width - 2 * m) / max(1, r.width), (size.height - 2 * m) / max(1, r.height))))
        followsFit = true
        zoom = z
        pan = CGPoint(x: (size.width - r.width * z) / 2 - r.minX * z, y: (size.height - r.height * z) / 2 - r.minY * z)
    }

    /// Keeps at least a strip of the diagram visible, so it can't be scrolled away for good.
    private func clamped(_ p: CGPoint, zoom z: CGFloat) -> CGPoint {
        guard let c = content, size.width > 0 else { return p }
        let keep: CGFloat = 120
        let minX = keep - c.maxX * z, maxX = size.width - keep - c.minX * z
        let minY = keep - c.maxY * z, maxY = size.height - keep - c.minY * z
        return CGPoint(x: minX <= maxX ? min(maxX, max(minX, p.x)) : p.x,
                       y: minY <= maxY ? min(maxY, max(minY, p.y)) : p.y)
    }
}
