import CoreGraphics
import Foundation

/// A grid of windows that fills an area, used by the `tile_windows` action.
///
/// The grid leaves as few cells empty as it can while keeping each cell about
/// as wide as it is tall, so six windows on a 16:9 screen are arranged in 3
/// columns and 2 rows, and on a portrait screen in 2 columns and 3 rows. When
/// the windows don't fill every cell, the last row has fewer windows and they
/// are made wider to fill it.
struct WindowGrid: Equatable {
    let count: Int
    let columns: Int
    let rows: Int

    /// How much an empty cell weighs against a cell that is not square. An
    /// empty cell makes the windows in the last row wider than the others,
    /// so it is accepted only when it makes the cells much closer to square.
    /// At 0.3, nine windows on a 16:9 screen are 3x3 rather than 5x2 (with a
    /// last row of 4), while five are 3x2 rather than a row of tall columns.
    private static let emptyCellPenalty = 0.3

    /// The grid for `count` windows in an area of `size`, with `gap` between
    /// the windows and around the edges of the area.
    init(count: Int, size: CGSize, gap: CGFloat = 0) {
        precondition(count > 0)
        self.count = count

        var best: (score: Double, columns: Int)?
        for columns in 1...count {
            let rows = Self.rows(count: count, columns: columns)
            let cell = Self.cellSize(columns: columns, rows: rows, size: size, gap: gap)
            let empty = columns * rows - count
            let score = abs(log(Double(cell.width / cell.height)))
                + Self.emptyCellPenalty * Double(empty)
            if best.map({ score < $0.score }) ?? true {
                best = (score, columns)
            }
        }

        self.columns = best?.columns ?? 1
        self.rows = Self.rows(count: count, columns: self.columns)
    }

    /// The number of windows in each row from the top. Every row is full
    /// except possibly the last.
    var rowCounts: [Int] {
        (0..<rows).map { row in min(columns, count - row * columns) }
    }

    /// The frames of the windows in `area`, row by row from the top left.
    /// The area and frames use AppKit coordinates, where y grows upward.
    /// Frames are rounded to whole points, and windows next to each other
    /// share an edge when `gap` is 0.
    func frames(in area: CGRect, gap: CGFloat = 0) -> [CGRect] {
        let inner = Self.inset(area, by: gap)
        let rowHeight = Self.length(inner.height, parts: rows, gap: gap)

        var result: [CGRect] = []
        for (row, rowCount) in rowCounts.enumerated() {
            let top = inner.maxY - CGFloat(row) * (rowHeight + gap)
            let maxY = top.rounded()
            let minY = (top - rowHeight).rounded()
            let width = Self.length(inner.width, parts: rowCount, gap: gap)
            for column in 0..<rowCount {
                let left = inner.minX + CGFloat(column) * (width + gap)
                let minX = left.rounded()
                let maxX = (left + width).rounded()
                result.append(CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY))
            }
        }

        return result
    }

    /// Sorts `items` into the order of `frames(in:gap:)` by where they are
    /// now: top to bottom into rows, then left to right within each row. This
    /// moves windows as little as possible, and tiling windows that are
    /// already tiled leaves them where they are.
    func order<T>(_ items: [T], by frame: (T) -> CGRect) -> [T] {
        precondition(items.count == count)
        let byRow = items.sorted { a, b in
            let fa = frame(a), fb = frame(b)
            if fa.midY != fb.midY { return fa.midY > fb.midY }
            return fa.midX < fb.midX
        }

        var result: [T] = []
        var start = 0
        for rowCount in rowCounts {
            result += byRow[start..<start + rowCount].sorted { frame($0).midX < frame($1).midX }
            start += rowCount
        }

        return result
    }

    private static func rows(count: Int, columns: Int) -> Int {
        (count + columns - 1) / columns
    }

    private static func cellSize(columns: Int, rows: Int, size: CGSize, gap: CGFloat) -> CGSize {
        let inner = inset(CGRect(origin: .zero, size: size), by: gap)
        return CGSize(
            width: length(inner.width, parts: columns, gap: gap),
            height: length(inner.height, parts: rows, gap: gap))
    }

    /// The length of each of `parts` that fill `total` with `gap` between
    /// them, kept positive so a gap too large for the area still gives
    /// usable frames.
    private static func length(_ total: CGFloat, parts: Int, gap: CGFloat) -> CGFloat {
        max(1, (total - CGFloat(parts - 1) * gap) / CGFloat(parts))
    }

    /// `area` without `gap` on every side, or a 1x1 rect at its center if
    /// the gap is larger than the area.
    private static func inset(_ area: CGRect, by gap: CGFloat) -> CGRect {
        let inner = area.insetBy(dx: gap, dy: gap)
        if inner.isNull || inner.width < 1 || inner.height < 1 {
            return CGRect(x: area.midX, y: area.midY, width: 1, height: 1)
        }
        return inner
    }
}
