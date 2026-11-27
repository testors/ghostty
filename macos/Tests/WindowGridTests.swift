import CoreGraphics
import Testing
@testable import Ghostty

struct WindowGridTests {
    private func shape(_ count: Int, _ width: CGFloat, _ height: CGFloat) -> String {
        let grid = WindowGrid(count: count, size: CGSize(width: width, height: height))
        return "\(grid.columns)x\(grid.rows)"
    }

    @Test func landscapeScreen() {
        // 1920x1080 without the menu bar.
        let shapes = (1...12).map { shape($0, 1920, 1050) }
        #expect(shapes == [
            "1x1", "2x1", "3x1", "2x2", "3x2", "3x2",
            "4x2", "4x2", "3x3", "5x2", "4x3", "4x3",
        ])
    }

    @Test func portraitScreen() {
        #expect(shape(2, 1080, 1890) == "1x2")
        #expect(shape(6, 1080, 1890) == "2x3")
    }

    @Test func ultrawideScreen() {
        #expect(shape(4, 3440, 1415) == "4x1")
        #expect(shape(6, 3440, 1415) == "3x2")
    }

    @Test func sixFramesFillTheArea() {
        let area = CGRect(x: 0, y: 30, width: 1920, height: 1050)
        let grid = WindowGrid(count: 6, size: area.size)
        let frames = grid.frames(in: area)
        #expect(frames == [
            CGRect(x: 0, y: 555, width: 640, height: 525),
            CGRect(x: 640, y: 555, width: 640, height: 525),
            CGRect(x: 1280, y: 555, width: 640, height: 525),
            CGRect(x: 0, y: 30, width: 640, height: 525),
            CGRect(x: 640, y: 30, width: 640, height: 525),
            CGRect(x: 1280, y: 30, width: 640, height: 525),
        ])
    }

    @Test func lastRowIsWider() {
        let area = CGRect(x: 0, y: 0, width: 1920, height: 1080)
        let grid = WindowGrid(count: 5, size: area.size)
        #expect(grid.rowCounts == [3, 2])
        let frames = grid.frames(in: area)
        #expect(frames[3] == CGRect(x: 0, y: 0, width: 960, height: 540))
        #expect(frames[4] == CGRect(x: 960, y: 0, width: 960, height: 540))
    }

    @Test func gapIsBetweenWindowsAndAtEdges() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 500)
        let grid = WindowGrid(count: 2, size: area.size, gap: 10)
        #expect(grid.frames(in: area, gap: 10) == [
            CGRect(x: 10, y: 10, width: 485, height: 480),
            CGRect(x: 505, y: 10, width: 485, height: 480),
        ])
    }

    @Test func framesAreWholePointsAndShareEdges() {
        let area = CGRect(x: 0, y: 0, width: 1000, height: 400)
        let grid = WindowGrid(count: 3, size: area.size)
        let frames = grid.frames(in: area)
        #expect(frames.allSatisfy { $0 == $0.integral })
        #expect(frames[0].maxX == frames[1].minX)
        #expect(frames[1].maxX == frames[2].minX)
        #expect(frames[2].maxX == area.maxX)
    }

    @Test func hugeGapStillGivesFrames() {
        let area = CGRect(x: 0, y: 0, width: 100, height: 100)
        let grid = WindowGrid(count: 4, size: area.size, gap: 1000)
        let frames = grid.frames(in: area, gap: 1000)
        #expect(frames.count == 4)
        #expect(frames.allSatisfy { $0.width.isFinite && $0.height.isFinite })
    }

    @Test func orderIsTopToBottomThenLeftToRight() {
        // A cascade: each window lower and to the right of the one before.
        let cascade = (0..<6).map { i in
            CGRect(x: CGFloat(i) * 30, y: 500 - CGFloat(i) * 30, width: 800, height: 500)
        }
        let grid = WindowGrid(count: 6, size: CGSize(width: 1920, height: 1050))
        #expect(grid.order(Array(cascade.indices.reversed()), by: { cascade[$0] }) == [0, 1, 2, 3, 4, 5])
    }

    @Test func tilingTiledWindowsKeepsThem() {
        let area = CGRect(x: 0, y: 0, width: 1920, height: 1050)
        for count in 1...9 {
            let grid = WindowGrid(count: count, size: area.size)
            let frames = grid.frames(in: area)
            let shuffled = Array(frames.indices.shuffled())
            #expect(grid.order(shuffled, by: { frames[$0] }) == Array(frames.indices))
        }
    }
}
