import AppKit
import Testing
@testable import Ghostty

@MainActor
@Suite(.serialized)
struct TerminalSurfaceTabTests {
    @Test(arguments: [false, true])
    func moveSplitPreservesSurfaceAndSupportsUndo(sameWindow: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let source = try fixture.makeTerminal()
        let remaining = try #require(source.surfaceTree.first)
        let moved = try #require(source.newSplit(at: remaining, direction: .right, baseConfig: fixture.baseConfig))
        let destination = try sameWindow ? source : fixture.makeTerminal()
        let destinationWindow = try #require(destination.window)
        let originalSurface = try #require(moved.surface)
        fixture.undoManager.removeAllActions()

        #expect(destination.moveSurfaceToTab(moved))

        let newOwner = try #require(BaseTerminalController.controller(owning: moved) as? TerminalController)
        #expect(newOwner !== source)
        #expect(newOwner.window?.tabGroup === destinationWindow.tabGroup)
        #expect(destinationWindow.tabGroup?.windows.count == 2)
        #expect(source.surfaceTree.contains(remaining))
        #expect(!source.surfaceTree.contains(moved))
        #expect(moved.surface == originalSurface)

        fixture.undoManager.undo()
        #expect(BaseTerminalController.controller(owning: moved) === source)
        #expect(source.surfaceTree.contains(remaining))
        #expect(source.surfaceTree.contains(moved))
        #expect(newOwner.window?.contentView == nil)
        #expect(moved.surface == originalSurface)

        fixture.undoManager.redo()
        let redoneOwner = try #require(BaseTerminalController.controller(owning: moved))
        #expect(redoneOwner !== source)
        #expect(redoneOwner.window?.tabGroup === destinationWindow.tabGroup)
        #expect(!source.surfaceTree.contains(moved))
        #expect(moved.surface == originalSurface)

        // Redo registers the undo again.
        fixture.undoManager.undo()
        #expect(BaseTerminalController.controller(owning: moved) === source)
        #expect(source.surfaceTree.contains(moved))
    }

    @Test(arguments: [1, 2])
    func moveUnsplitTerminalMergesItsWholeWindow(sourceTabs: Int) throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let sources = try fixture.makeTabbedTerminals(count: sourceTabs)
        let sourceWindows = try sources.map { try #require($0.window) }
        let dragged = try #require(sources.last)
        let surface = try #require(dragged.surfaceTree.first)
        let destination = try fixture.makeTerminal()
        let destinationWindow = try #require(destination.window)
        fixture.undoManager.removeAllActions()

        // The source window's own tabs don't offer to take the whole window.
        for source in sources {
            #expect(!source.canMoveSurfaceToTab(surface))
        }

        // The windows themselves move, so their controllers and surfaces stay.
        #expect(destination.moveSurfaceToTab(surface))
        #expect(fixture.tabs(of: destinationWindow) == [destinationWindow] + sourceWindows)
        #expect(destinationWindow.tabGroup?.selectedWindow === sourceWindows.last)
        #expect(BaseTerminalController.controller(owning: surface) === dragged)

        fixture.undoManager.undo()
        #expect(fixture.tabs(of: destinationWindow) == [destinationWindow])
        #expect(fixture.tabs(of: sourceWindows[0]) == sourceWindows)
        #expect(sourceWindows[0].tabGroup?.selectedWindow === sourceWindows.last)
        #expect(BaseTerminalController.controller(owning: surface) === dragged)

        fixture.undoManager.redo()
        #expect(fixture.tabs(of: destinationWindow) == [destinationWindow] + sourceWindows)

        // Redo registers the undo again.
        fixture.undoManager.undo()
        #expect(fixture.tabs(of: sourceWindows[0]) == sourceWindows)
    }

    @Test func moveSplitFromTabbedWindowLeavesOtherTabs() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let sources = try fixture.makeTabbedTerminals(count: 2)
        let first = sources[0], second = sources[1]
        let firstWindow = try #require(first.window)
        let remaining = try #require(second.surfaceTree.first)
        let moved = try #require(second.newSplit(at: remaining, direction: .right, baseConfig: fixture.baseConfig))
        let destination = try fixture.makeTerminal()
        let destinationWindow = try #require(destination.window)

        // A split can still become its own tab next to a sibling tab.
        #expect(first.canMoveSurfaceToTab(moved))

        #expect(destination.moveSurfaceToTab(moved))
        #expect(destinationWindow.tabGroup?.windows.count == 2)
        #expect(firstWindow.tabGroup?.windows.count == 2)
        #expect(second.surfaceTree.contains(remaining))
        #expect(!second.surfaceTree.contains(moved))
    }

    @Test func splitMoveUndoKeepsTerminalWhenSourceClosed() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let source = try fixture.makeTerminal()
        let remaining = try #require(source.surfaceTree.first)
        let moved = try #require(source.newSplit(at: remaining, direction: .right, baseConfig: fixture.baseConfig))
        let destination = try fixture.makeTerminal()
        fixture.undoManager.removeAllActions()

        #expect(destination.moveSurfaceToTab(moved))
        let newOwner = try #require(BaseTerminalController.controller(owning: moved))
        fixture.undoManager.disableUndoRegistration { source.window?.close() }

        // There is nothing to put the terminal back into, so undo leaves it.
        fixture.undoManager.undo()
        #expect(BaseTerminalController.controller(owning: moved) === newOwner)
        #expect(newOwner.window?.contentView != nil)
    }

    @Test func splitMoveUndoDoesNotDuplicateRestoredTab() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let source = try fixture.makeTerminal()
        let remaining = try #require(source.surfaceTree.first)
        let moved = try #require(source.newSplit(at: remaining, direction: .right, baseConfig: fixture.baseConfig))
        let destination = try fixture.makeTerminal()
        fixture.undoManager.removeAllActions()

        #expect(destination.moveSurfaceToTab(moved))
        let newOwner = try #require(BaseTerminalController.controller(owning: moved) as? TerminalController)
        fixture.undoManager.beginUndoGrouping()
        newOwner.closeTabImmediately()
        fixture.undoManager.endUndoGrouping()

        // Undoing the close brings the tab back as a new window.
        fixture.undoManager.undo()
        let restoredOwner = try #require(BaseTerminalController.controller(owning: moved))
        #expect(restoredOwner !== newOwner)

        // The tab the move created is gone, so undoing the move does nothing.
        fixture.undoManager.undo()
        #expect(BaseTerminalController.controller(owning: moved) === restoredOwner)
        #expect(!source.surfaceTree.contains(moved))
    }

    @Test func redoRechecksTheDestination() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let sources = try fixture.makeTabbedTerminals(count: 2)
        let sourceWindows = try sources.map { try #require($0.window) }
        let surface = try #require(sources[1].surfaceTree.first)
        let destination = try fixture.makeTerminal()
        let destinationWindow = try #require(destination.window)
        fixture.undoManager.removeAllActions()

        #expect(destination.moveSurfaceToTab(surface))
        fixture.undoManager.undo()
        destinationWindow.tabbingMode = .disallowed

        fixture.undoManager.redo()
        #expect(fixture.tabs(of: sourceWindows[0]) == sourceWindows)
        #expect(fixture.tabs(of: destinationWindow) == [destinationWindow])
    }

    @Test func rejectsSelfDropAndDisabledTabsWithoutDetaching() throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let source = try fixture.makeTerminal()
        let surface = try #require(source.surfaceTree.first)
        #expect(!source.moveSurfaceToTab(surface))

        let destination = try fixture.makeTerminal()
        destination.window?.tabbingMode = .disallowed
        #expect(!destination.moveSurfaceToTab(surface))
        #expect(source.surfaceTree.contains(surface))
        #expect(BaseTerminalController.controller(owning: surface) === source)
    }

    @MainActor
    private final class Fixture {
        let ghostty: Ghostty.App
        let undoManager: ExpiringUndoManager
        let originalWindows: Set<NSWindow>
        var baseConfig: Ghostty.SurfaceConfiguration {
            var config = Ghostty.SurfaceConfiguration()
            config.command = "/bin/cat"
            return config
        }

        init() throws {
            let delegate = try #require(NSApp.delegate as? AppDelegate)
            ghostty = delegate.ghostty
            undoManager = delegate.undoManager
            originalWindows = Set(NSApp.windows)
        }

        func makeTerminal() throws -> TerminalController {
            let controller = TerminalController(ghostty, withBaseConfig: baseConfig)
            let window = try #require(controller.window)
            window.tabbingMode = .disallowed
            #expect(controller.showWindowSafely(nil))
            window.tabbingMode = .automatic
            return controller
        }

        func makeTabbedTerminals(count: Int) throws -> [TerminalController] {
            let terminals = try (0..<count).map { _ in try makeTerminal() }
            let windows = try terminals.map { try #require($0.window) }
            for (anchor, tab) in zip(windows, windows.dropFirst()) {
                #expect(anchor.addTabbedWindowSafely(tab, ordered: .above))
            }
            windows.first?.tabGroup?.selectedWindow = windows.last
            return terminals
        }

        func tabs(of window: NSWindow) -> [NSWindow] {
            window.tabGroup?.windows ?? [window]
        }

        func close() {
            undoManager.removeAllActions()
            for window in NSApp.windows where !originalWindows.contains(window) {
                window.close()
            }
        }
    }
}
