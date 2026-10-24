import Foundation
import Testing
@testable import Ghostty

@Suite
@MainActor
struct ExpiringUndoManagerTests {
    private final class Target {}

    private func register(_ manager: ExpiringUndoManager, _ target: Target) {
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: target, expiresAfter: .seconds(60)) { _ in }
        manager.endUndoGrouping()
    }

    /// Removing every action releases the expiring targets, and a target
    /// removes its own actions from the manager when it is released.
    @Test func removeAllActionsReleasesExpiringTargets() {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        let target = Target()
        register(manager, target)
        register(manager, target)
        #expect(manager.canUndo)

        manager.removeAllActions()
        #expect(!manager.canUndo)

        // The manager still works afterwards.
        register(manager, target)
        #expect(manager.canUndo)
    }

    @Test func removeAllActionsWithTargetRemovesItsActions() {
        let manager = ExpiringUndoManager()
        manager.groupsByEvent = false
        let target = Target()
        register(manager, target)
        #expect(manager.canUndo)

        manager.removeAllActions(withTarget: target)
        #expect(!manager.canUndo)
    }
}
