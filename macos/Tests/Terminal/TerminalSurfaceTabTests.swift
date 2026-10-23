import AppKit
import Testing
@testable import Ghostty

@MainActor
@Suite(.serialized)
struct TerminalSurfaceTabTests {
    @Test(arguments: [(false, false), (false, true), (true, true)])
    func movePreservesSurfaceAndSupportsUndo(sameWindow: Bool, splitSource: Bool) throws {
        let fixture = try Fixture()
        defer { fixture.close() }
        let source = try fixture.makeTerminal()
        let remaining = try #require(source.surfaceTree.first)
        let moved = try splitSource
            ? #require(source.newSplit(at: remaining, direction: .right, baseConfig: fixture.baseConfig))
            : remaining
        let destination = try sameWindow ? source : fixture.makeTerminal()
        let sourceWindow = try #require(source.window)
        let destinationWindow = try #require(destination.window)
        let originalSurface = try #require(moved.surface)
        fixture.undoManager.removeAllActions()

        #expect(destination.moveSurfaceToTab(moved))

        let newOwner = try #require(BaseTerminalController.controller(owning: moved) as? TerminalController)
        #expect(newOwner !== source)
        #expect(newOwner !== destination)
        #expect(newOwner.window?.tabGroup === destinationWindow.tabGroup)
        #expect(destinationWindow.tabGroup?.windows.count == 2)
        #expect(moved.surface == originalSurface)
        if splitSource {
            #expect(source.surfaceTree.contains(remaining))
            #expect(!source.surfaceTree.contains(moved))
        } else {
            #expect(sourceWindow.contentView == nil)
        }

        fixture.undoManager.undo()
        let restoredOwner = try #require(BaseTerminalController.controller(owning: moved))
        #expect(restoredOwner !== newOwner)
        #expect(moved.surface == originalSurface)
        if splitSource {
            #expect(restoredOwner === source)
            #expect(source.surfaceTree.contains(remaining))
            #expect(source.surfaceTree.contains(moved))
        }

        fixture.undoManager.redo()
        let redoneOwner = try #require(BaseTerminalController.controller(owning: moved))
        #expect(redoneOwner !== restoredOwner)
        #expect(redoneOwner.window?.tabGroup === destinationWindow.tabGroup)
        #expect(moved.surface == originalSurface)
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

        func close() {
            undoManager.removeAllActions()
            for window in NSApp.windows where !originalWindows.contains(window) {
                window.close()
            }
        }
    }
}
