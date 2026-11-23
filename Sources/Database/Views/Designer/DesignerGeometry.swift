import SwiftUI
import AppKit

// Sizes of the table cards, where the relation lines run, and the automatic layout.
// Everything is in "world" points (the diagram at 100 %); the canvas scales and pans the world.

enum DesignerMetrics {
    static let headerHeight: CGFloat = 36
    static let rowHeight: CGFloat = 22
    static let bottomPadding: CGFloat = 6
    static let minWidth: CGFloat = 170
    static let maxWidth: CGFloat = 340
    /// Above this many columns a card shows the first ones and the key columns, then "+ N more".
    static let maxRows = 24
    static let firstRows = 16
    static let iconSlot: CGFloat = 30
    static let horizontalPadding: CGFloat = 10
    static let handleRadius: CGFloat = 5

    static let nameFont = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    static let chipFont = NSFont.monospacedSystemFont(ofSize: 10, weight: .medium)
    static let titleFont = NSFont.systemFont(ofSize: 12.5, weight: .semibold)

    static let nameCharWidth: CGFloat = ("0" as NSString).size(withAttributes: [.font: nameFont]).width
    static let chipCharWidth: CGFloat = ("0" as NSString).size(withAttributes: [.font: chipFont]).width
}

/// How one card is laid out: its size and which columns it shows.
struct DesignerCardLayout: Equatable {
    var width: CGFloat
    var height: CGFloat
    /// Indexes into the table's columns, in order.
    var rows: [Int]
    /// Columns not shown (0 when the card shows all of them).
    var hidden: Int

    var rowCount: Int { rows.count + (hidden > 0 ? 1 : 0) }

    init(table: DesignerTable, relationColumns: Set<String>) {
        let all = table.columns
        if all.count <= DesignerMetrics.maxRows {
            rows = Array(all.indices)
        } else {
            rows = all.indices.filter { i in
                i < DesignerMetrics.firstRows || all[i].isPrimary || relationColumns.contains(all[i].name)
            }
        }
        hidden = all.count - rows.count
        let name = rows.map { CGFloat(all[$0].name.count) }.max() ?? 4
        let chip = rows.map { CGFloat(DesignerType.compact(all[$0].type).count) }.max() ?? 3
        let rowWidth = DesignerMetrics.horizontalPadding * 2 + DesignerMetrics.iconSlot
            + name * DesignerMetrics.nameCharWidth + 14 + chip * DesignerMetrics.chipCharWidth + 12
        let title = (table.name as NSString).size(withAttributes: [.font: DesignerMetrics.titleFont]).width
        let headerWidth = DesignerMetrics.horizontalPadding * 2 + 20 + 8 + title + (table.isView ? 60 : 0) + 14
        width = min(DesignerMetrics.maxWidth, max(DesignerMetrics.minWidth, ceil(max(rowWidth, headerWidth))))
        height = DesignerMetrics.headerHeight + CGFloat(max(1, rows.count + (hidden > 0 ? 1 : 0))) * DesignerMetrics.rowHeight
            + DesignerMetrics.bottomPadding
    }

    /// Vertical centre of a column's row, from the top of the card. Hidden columns use the "+ N more" row.
    func rowCenter(of column: String, in table: DesignerTable) -> CGFloat {
        let index = table.columns.firstIndex { $0.name == column }
        let row = index.flatMap { rows.firstIndex(of: $0) } ?? (hidden > 0 ? rows.count : 0)
        return DesignerMetrics.headerHeight + (CGFloat(row) + 0.5) * DesignerMetrics.rowHeight
    }

    /// The column at a point inside the card (card coordinates), if the point is on a column row.
    func column(at y: CGFloat, in table: DesignerTable) -> String? {
        let row = Int(floor((y - DesignerMetrics.headerHeight) / DesignerMetrics.rowHeight))
        guard y >= DesignerMetrics.headerHeight, row >= 0, row < rows.count else { return nil }
        return table.columns[rows[row]].name
    }
}

/// One drawn line of a relation (a composite key draws one line per column pair).
struct RelationCurve {
    let relationID: String
    let start: CGPoint
    let c1: CGPoint
    let c2: CGPoint
    let end: CGPoint
    /// +1 when the line leaves the FK card to the right, −1 to the left.
    let startSide: CGFloat
    /// +1 when the line enters the referenced card from the right (the arrow points left), −1 from the left.
    let endSide: CGFloat

    func point(_ t: CGFloat) -> CGPoint {
        let u = 1 - t
        let a = u * u * u, b = 3 * u * u * t, c = 3 * u * t * t, d = t * t * t
        return CGPoint(x: a * start.x + b * c1.x + c * c2.x + d * end.x,
                       y: a * start.y + b * c1.y + c * c2.y + d * end.y)
    }

    var bounds: CGRect {
        let xs = [start.x, c1.x, c2.x, end.x], ys = [start.y, c1.y, c2.y, end.y]
        return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
    }

    /// Distance from `p` to the curve (approximated with straight pieces).
    func distance(to p: CGPoint) -> CGFloat {
        var best = CGFloat.infinity
        var previous = start
        let steps = 24
        for i in 1...steps {
            let next = point(CGFloat(i) / CGFloat(steps))
            best = min(best, DesignerGeometry.segmentDistance(p, previous, next))
            previous = next
        }
        return best
    }
}

enum DesignerGeometry {
    static let arrowLength: CGFloat = 8

    static func segmentDistance(_ p: CGPoint, _ a: CGPoint, _ b: CGPoint) -> CGFloat {
        let dx = b.x - a.x, dy = b.y - a.y
        let len = dx * dx + dy * dy
        var t: CGFloat = len > 0 ? ((p.x - a.x) * dx + (p.y - a.y) * dy) / len : 0
        t = max(0, min(1, t))
        let x = a.x + t * dx - p.x, y = a.y + t * dy - p.y
        return (x * x + y * y).squareRoot()
    }

    /// The lines for a relation between two placed cards.
    static func curves(for r: DesignerRelation, schema: DesignerSchema,
                       frames: [String: CGRect], layouts: [String: DesignerCardLayout]) -> [RelationCurve] {
        guard let child = schema.table(r.table), let parent = schema.table(r.refTable),
              let a = frames[r.table], let b = frames[r.refTable],
              let la = layouts[r.table], let lb = layouts[r.refTable] else { return [] }
        return zip(r.columns, r.refColumns).enumerated().map { i, pair in
            let y1 = a.minY + la.rowCenter(of: pair.0, in: child)
            let y2 = b.minY + lb.rowCenter(of: pair.1, in: parent)
            let spread = CGFloat(i) * 6
            if r.isSelf {
                // A loop on the right side of the card.
                let x = a.maxX
                let reach: CGFloat = 46 + spread + min(40, abs(y2 - y1) * 0.25)
                let y2b = y1 == y2 ? y2 + DesignerMetrics.rowHeight * 0.35 : y2
                return RelationCurve(relationID: r.id, start: CGPoint(x: x, y: y1), c1: CGPoint(x: x + reach, y: y1),
                                     c2: CGPoint(x: x + reach, y: y2b), end: CGPoint(x: x + arrowLength, y: y2b),
                                     startSide: 1, endSide: 1)
            }
            let gap: CGFloat = 24
            if b.minX >= a.maxX + gap {
                // Parent to the right: leave right, enter left.
                let k = max(40, (b.minX - a.maxX) * 0.5)
                let s = CGPoint(x: a.maxX, y: y1), e = CGPoint(x: b.minX - arrowLength, y: y2)
                return RelationCurve(relationID: r.id, start: s, c1: CGPoint(x: s.x + k, y: s.y),
                                     c2: CGPoint(x: e.x - k, y: e.y), end: e, startSide: 1, endSide: -1)
            } else if b.maxX <= a.minX - gap {
                // Parent to the left: leave left, enter right.
                let k = max(40, (a.minX - b.maxX) * 0.5)
                let s = CGPoint(x: a.minX, y: y1), e = CGPoint(x: b.maxX + arrowLength, y: y2)
                return RelationCurve(relationID: r.id, start: s, c1: CGPoint(x: s.x - k, y: s.y),
                                     c2: CGPoint(x: e.x + k, y: e.y), end: e, startSide: -1, endSide: 1)
            } else {
                // Above or below each other: a C-shaped curve on the right.
                let x = max(a.maxX, b.maxX) + 50 + spread + min(60, abs(y2 - y1) * 0.08)
                let s = CGPoint(x: a.maxX, y: y1), e = CGPoint(x: b.maxX + arrowLength, y: y2)
                return RelationCurve(relationID: r.id, start: s, c1: CGPoint(x: x, y: s.y), c2: CGPoint(x: x, y: e.y),
                                     end: e, startSide: 1, endSide: 1)
            }
        }
    }

    // MARK: - Automatic layout

    static let layerGap: CGFloat = 110
    static let rowGap: CGFloat = 34
    static let componentGap: CGFloat = 120
    static let margin: CGFloat = 40

    /// Places the cards: related tables in layers (referenced tables to the left of the tables that point to them),
    /// each group of connected tables as a block, and tables without relations in a grid to the right.
    static func autoLayout(schema: DesignerSchema, sizes: [String: CGSize]) -> [String: CGPoint] {
        let names = schema.tables.map(\.name)
        var parents: [String: Set<String>] = [:]   // child → referenced tables
        var neighbours: [String: Set<String>] = [:]
        for r in schema.relations where !r.isSelf {
            parents[r.table, default: []].insert(r.refTable)
            neighbours[r.table, default: []].insert(r.refTable)
            neighbours[r.refTable, default: []].insert(r.table)
        }

        // Connected groups, in name order.
        var seen = Set<String>()
        var groups: [[String]] = []
        var loners: [String] = []
        for n in names where !seen.contains(n) {
            guard neighbours[n] != nil else { seen.insert(n); loners.append(n); continue }
            var group: [String] = []
            var queue = [n]
            seen.insert(n)
            while let t = queue.popLast() {
                group.append(t)
                for x in (neighbours[t] ?? []).sorted() where !seen.contains(x) { seen.insert(x); queue.append(x) }
            }
            groups.append(group.sorted())
        }
        groups.sort { $0.count > $1.count }

        var result: [String: CGPoint] = [:]
        var blocks: [(size: CGSize, places: [String: CGPoint])] = []
        for g in groups {
            blocks.append(layoutGroup(g, parents: parents, neighbours: neighbours, sizes: sizes))
        }

        // Groups side by side, wrapping into rows when they get too wide.
        let totalArea = blocks.reduce(CGFloat(0)) { $0 + $1.size.width * $1.size.height }
        let rowLimit = max(1400, blocks.map(\.size.width).max() ?? 0, totalArea.squareRoot() * 1.6)
        var x = margin, y = margin, rowHeight: CGFloat = 0, maxX: CGFloat = margin
        for b in blocks {
            if x > margin && x + b.size.width > rowLimit {
                x = margin; y += rowHeight + componentGap; rowHeight = 0
            }
            for (name, p) in b.places { result[name] = CGPoint(x: x + p.x, y: y + p.y) }
            x += b.size.width + componentGap
            maxX = max(maxX, x - componentGap)
            rowHeight = max(rowHeight, b.size.height)
        }
        let connectedHeight = blocks.isEmpty ? 0 : y + rowHeight - margin

        // Tables without relations: columns of cards to the right (or a grid of their own when nothing is related).
        if !loners.isEmpty {
            let startX = blocks.isEmpty ? margin : maxX + componentGap
            let area = loners.reduce(CGFloat(0)) { a, n in
                let s = sizes[n] ?? CGSize(width: 200, height: 100)
                return a + (s.width + 40) * (s.height + rowGap)
            }
            let columnLimit = max(blocks.isEmpty ? 0 : connectedHeight, (area * 0.6).squareRoot(), 420)
            var cx = startX, cy = margin, columnWidth: CGFloat = 0
            for n in loners {
                let s = sizes[n] ?? CGSize(width: 200, height: 100)
                if cy > margin && cy + s.height > margin + columnLimit {
                    cx += columnWidth + 40; cy = margin; columnWidth = 0
                }
                result[n] = CGPoint(x: cx, y: cy)
                cy += s.height + rowGap
                columnWidth = max(columnWidth, s.width)
            }
        }
        return result
    }

    /// Layers one connected group: tables that reference nothing on the left, each other table one layer to the
    /// right of the furthest table it references. Order inside a layer follows the neighbours (barycentre sweeps).
    private static func layoutGroup(_ group: [String], parents: [String: Set<String>], neighbours: [String: Set<String>],
                                    sizes: [String: CGSize]) -> (size: CGSize, places: [String: CGPoint]) {
        let members = Set(group)
        var rank: [String: Int] = [:]
        var visiting = Set<String>()
        func depth(_ t: String) -> Int {
            if let r = rank[t] { return r }
            visiting.insert(t)
            var d = 0
            for p in (parents[t] ?? []) where members.contains(p) && !visiting.contains(p) {
                d = max(d, depth(p) + 1)
            }
            visiting.remove(t)
            rank[t] = d
            return d
        }
        for t in group { _ = depth(t) }

        let layerCount = (rank.values.max() ?? 0) + 1
        var layers = Array(repeating: [String](), count: layerCount)
        for t in group { layers[rank[t]!].append(t) }

        // Barycentre ordering, a few sweeps in both directions.
        func position() -> [String: CGFloat] {
            var p: [String: CGFloat] = [:]
            for layer in layers {
                for (i, t) in layer.enumerated() { p[t] = (CGFloat(i) + 0.5) / CGFloat(layer.count) }
            }
            return p
        }
        for sweep in 0..<6 {
            let order = sweep % 2 == 0 ? Array(0..<layerCount) : Array((0..<layerCount).reversed())
            for li in order {
                let p = position()
                layers[li].sort { a, b in
                    func bary(_ t: String) -> CGFloat {
                        let ns = (neighbours[t] ?? []).filter { members.contains($0) && rank[$0] != li }
                        guard !ns.isEmpty else { return p[t] ?? 0.5 }
                        return ns.reduce(0) { $0 + (p[$1] ?? 0.5) } / CGFloat(ns.count)
                    }
                    let ba = bary(a), bb = bary(b)
                    return ba == bb ? a < b : ba < bb
                }
            }
        }

        // Tall layers wrap into several columns.
        let maxColumnHeight: CGFloat = 1500
        var columns: [[String]] = []
        for layer in layers {
            var column: [String] = []
            var h: CGFloat = 0
            for t in layer {
                let s = sizes[t]?.height ?? 100
                if !column.isEmpty && h + s > maxColumnHeight {
                    columns.append(column); column = []; h = 0
                }
                column.append(t)
                h += s + rowGap
            }
            if !column.isEmpty { columns.append(column) }
        }
        let heights = columns.map { c in c.reduce(CGFloat(0)) { $0 + (sizes[$1]?.height ?? 100) } + CGFloat(max(0, c.count - 1)) * rowGap }
        let tallest = heights.max() ?? 0
        var places: [String: CGPoint] = [:]
        var x: CGFloat = 0
        for (ci, column) in columns.enumerated() {
            let width = column.map { sizes[$0]?.width ?? 200 }.max() ?? 200
            var y = (tallest - heights[ci]) / 2
            for t in column {
                places[t] = CGPoint(x: x, y: y)
                y += (sizes[t]?.height ?? 100) + rowGap
            }
            x += width + layerGap
        }
        return (CGSize(width: x - layerGap, height: tallest), places)
    }
}
