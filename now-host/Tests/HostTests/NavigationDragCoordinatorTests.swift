import XCTest
@testable import Host

@MainActor
final class NavigationDragCoordinatorTests: XCTestCase {
    private let shelfUUID = UUID(
        uuidString: "8D5B6B80-6522-4CE9-A123-A2DA410D8488")!

    func testLooseModuleMovesAcrossZones() throws {
        let layout = NavigationLayout.standard(for: .standard)
        let command = try XCTUnwrap(NavigationDragCoordinator.command(
            for: .module("chat"),
            droppingOn: .zone(.lower, index: 1),
            in: layout,
            makeShelfID: { self.shelfUUID }))

        let changed = try layout.applying(command)

        XCTAssertFalse(changed.upper.contains(.module("chat")))
        XCTAssertEqual(changed.lower[1], .module("chat"))
    }

    func testDroppingLooseModuleOnLooseModuleCombinesThem() throws {
        let layout = NavigationLayout.standard(for: .standard)
        let command = try XCTUnwrap(NavigationDragCoordinator.command(
            for: .module("development"),
            droppingOn: .module("chat"),
            in: layout,
            makeShelfID: { self.shelfUUID }))

        let changed = try layout.applying(command)
        let shelf = try XCTUnwrap(changed.shelf(id: .user(shelfUUID)))

        XCTAssertEqual(shelf.moduleIDs, ["chat", "development"])
        XCTAssertEqual(shelf.title, "New Shelf")
        XCTAssertFalse(changed.upper.contains(.module("chat")))
        XCTAssertFalse(changed.upper.contains(.module("development")))
    }

    func testNewShelfNamesAdvancePastExistingDefaults() throws {
        var layout = NavigationLayout.standard(for: .standard)
        let existingID = UUID(
            uuidString: "16186E4B-5F6D-42F6-BAE6-C62C7405E492")!
        layout.lower.removeAll {
            $0.id == NavigationShelfID.debug.rawValue
        }
        layout.lower.insert(.shelf(NavigationShelf(
            id: .user(existingID), title: "New Shelf",
            moduleIDs: ["console", "logs"])), at: 0)

        let command = try XCTUnwrap(NavigationDragCoordinator.command(
            for: .module("development"),
            droppingOn: .module("chat"),
            in: layout,
            makeShelfID: { self.shelfUUID }))
        let changed = try layout.applying(command)

        XCTAssertEqual(changed.shelf(id: .user(shelfUUID))?.title,
                       "New Shelf 2")
    }

    func testWholeSidebarDropResolverSnapsToTheNearestStack() {
        XCTAssertEqual(
            NavigationSidebarDropResolver.target(
                distanceFromTop: 40, height: 400,
                upperItemCount: 5, lowerItemCount: 3),
            .zone(.upper, index: 5))
        XCTAssertEqual(
            NavigationSidebarDropResolver.target(
                distanceFromTop: 360, height: 400,
                upperItemCount: 5, lowerItemCount: 3),
            .zone(.lower, index: 0))
    }

    func testModuleCanBeExtractedFromShelfAndShelfModuleCanBeReordered() throws {
        let layout = NavigationLayout.standard(for: .standard)
        let extracted = try layout.applying(try XCTUnwrap(
            NavigationDragCoordinator.command(
                for: .module("mirror"),
                droppingOn: .zone(.lower, index: 0),
                in: layout,
                makeShelfID: { self.shelfUUID })))

        XCTAssertEqual(extracted.lower.first, .module("mirror"))
        XCTAssertEqual(extracted.shelf(id: .screen)?.moduleIDs,
                       ["screen", "continuity"])

        let reordered = try layout.applying(try XCTUnwrap(
            NavigationDragCoordinator.command(
                for: .module("mcp"),
                droppingOn: .shelf(.network, beforeModuleID: "settings"),
                in: layout,
                makeShelfID: { self.shelfUUID })))
        XCTAssertEqual(reordered.shelf(id: .network)?.moduleIDs,
                       ["mcp", "settings", "networking", "web"])
    }

    func testTwoMemberUserShelfCanReorderWithoutDecomposing() throws {
        var layout = NavigationLayout.standard(for: .standard)
        layout.upper.removeAll {
            $0 == .module("chat") || $0 == .module("development")
        }
        layout.upper.append(.shelf(NavigationShelf(
            id: .user(shelfUUID), moduleIDs: ["chat", "development"])))

        let changed = try layout.applying(try XCTUnwrap(
            NavigationDragCoordinator.command(
                for: .module("development"),
                droppingOn: .shelf(.user(shelfUUID), beforeModuleID: "chat"),
                in: layout,
                makeShelfID: { self.shelfUUID })))

        XCTAssertEqual(changed.shelf(id: .user(shelfUUID))?.moduleIDs,
                       ["development", "chat"])
    }

    func testPreviewReflowsTopLevelItemsWithoutMutatingTheBaseline() throws {
        let baseline = NavigationLayout.standard(for: .standard)

        let preview = try XCTUnwrap(NavigationDragPreview(
            dragged: .shelf(.screen),
            target: .zone(.upper, index: 0),
            baseline: baseline,
            makeShelfID: { self.shelfUUID }))

        XCTAssertEqual(preview.layout.upper.first?.id,
                       NavigationShelfID.screen.rawValue)
        XCTAssertEqual(baseline.upper.first?.id,
                       NavigationShelfID.machine.rawValue)
    }

    func testPreviewReflowsShelfTabsBeforeDrop() throws {
        let baseline = NavigationLayout.standard(for: .standard)

        let preview = try XCTUnwrap(NavigationDragPreview(
            dragged: .module("mcp"),
            target: .shelf(.network, beforeModuleID: "settings"),
            baseline: baseline,
            makeShelfID: { self.shelfUUID }))

        XCTAssertEqual(preview.layout.shelf(id: .network)?.moduleIDs,
                       ["mcp", "settings", "networking", "web"])
        XCTAssertEqual(baseline.shelf(id: .network)?.moduleIDs,
                       ["settings", "networking", "mcp", "web"])
    }

    /// Hovering a shelf must not lift the dragged row out of the stack.
    ///
    /// This is H7 at its root, and it is a mechanism no band width reaches:
    /// the whole sidebar renders the preview layout, so an insert that takes
    /// a module out of the top level closes its row up and raises every row
    /// below — the shelf the pointer is resting on included. The drag then
    /// leaves the row it was aimed at, which both reads as "the connections
    /// shelf gets out of the way" and restarts the spring-load dwell.
    /// `testPreviewReflowsShelfTabsBeforeDrop` is the other half: a module
    /// already inside the shelf displaces nothing, and still previews live.
    func testHoveringAShelfDoesNotLiftTheDraggedRowOutOfTheStack() throws {
        let baseline = NavigationLayout.standard(for: .standard)
        XCTAssertTrue(baseline.upper.contains(.module("chat")),
                      "the fixture wants a module that is its own row")

        let preview = try XCTUnwrap(NavigationDragPreview(
            dragged: .module("chat"),
            target: .shelf(.network, beforeModuleID: nil),
            baseline: baseline,
            makeShelfID: { self.shelfUUID }))

        XCTAssertEqual(preview.layout, baseline,
                       "the stack must stand still until the drop")
        XCTAssertEqual(preview.target, .shelf(.network, beforeModuleID: nil))
    }

    func testCombiningModulesWaitsForDropInsteadOfCollapsingTheDragTarget() throws {
        let baseline = NavigationLayout.standard(for: .standard)

        let preview = try XCTUnwrap(NavigationDragPreview(
            dragged: .module("development"),
            target: .module("chat"),
            baseline: baseline,
            makeShelfID: { self.shelfUUID }))

        XCTAssertEqual(preview.layout, baseline)
        XCTAssertEqual(preview.target, .module("chat"))
    }

    func testFixedModuleHeroesCannotProduceDragCommands() {
        let layout = NavigationLayout.standard(for: .standard)

        for moduleID in ["screen", "files", "settings"] {
            XCTAssertNil(NavigationDragCoordinator.command(
                for: .module(moduleID),
                droppingOn: .zone(.lower, index: 0),
                in: layout,
                makeShelfID: { shelfUUID }))
        }
    }

    func testInvalidAndSelfDropsDoNotProduceCommands() {
        let layout = NavigationLayout.standard(for: .standard)

        XCTAssertNil(NavigationDragCoordinator.command(
            for: .module("missing"), droppingOn: .zone(.upper, index: 0),
            in: layout, makeShelfID: { shelfUUID }))
        XCTAssertNil(NavigationDragCoordinator.command(
            for: .module("chat"), droppingOn: .module("chat"),
            in: layout, makeShelfID: { shelfUUID }))
        XCTAssertNil(NavigationDragCoordinator.command(
            for: .shelf(.screen), droppingOn: .module("chat"),
            in: layout, makeShelfID: { shelfUUID }))
        XCTAssertNil(NavigationDragCoordinator.command(
            for: .module("chat"),
            droppingOn: .shelf(.user(shelfUUID), beforeModuleID: nil),
            in: layout, makeShelfID: { shelfUUID }))
    }

    func testUserShelfDecomposesAtOneButSpecialShelvesDoNot() throws {
        var layout = NavigationLayout.standard(for: .standard)
        layout.upper.removeAll { $0 == .module("chat") || $0 == .module("development") }
        layout.upper.append(.shelf(NavigationShelf(
            id: .user(shelfUUID), moduleIDs: ["chat", "development"])))

        let changed = try layout.applying(try XCTUnwrap(
            NavigationDragCoordinator.command(
                for: .module("development"),
                droppingOn: .zone(.lower, index: 0),
                in: layout,
                makeShelfID: { self.shelfUUID })))

        XCTAssertNil(changed.shelf(id: .user(shelfUUID)))
        XCTAssertTrue(changed.upper.contains(.module("chat")))
        XCTAssertNotNil(changed.shelf(id: .machine))
        XCTAssertNotNil(changed.shelf(id: .network))
    }

    func testMachineShelfCannotEnterDrawerAndNetworkShelfCan() throws {
        let layout = NavigationLayout.standard(for: .standard)

        XCTAssertNil(NavigationDragCoordinator.command(
            for: .shelf(.machine),
            droppingOn: .zone(.drawer, index: 0),
            in: layout, makeShelfID: { shelfUUID }))

        let command = try XCTUnwrap(NavigationDragCoordinator.command(
            for: .shelf(.network),
            droppingOn: .zone(.drawer, index: 0),
            in: layout, makeShelfID: { shelfUUID }))
        let changed = try layout.applying(command)
        XCTAssertEqual(changed.zone(of: .network), .drawer)
        XCTAssertNotNil(changed.shelf(id: .machine))
    }

    func testPermanentShelvesCanMoveBetweenMainAndFooterZones() throws {
        let layout = NavigationLayout.standard(for: .standard)

        let machineCommand = try XCTUnwrap(NavigationDragCoordinator.command(
            for: .shelf(.machine),
            droppingOn: .zone(.lower, index: 0),
            in: layout, makeShelfID: { shelfUUID }))
        let machineMoved = try layout.applying(machineCommand)
        XCTAssertEqual(machineMoved.zone(of: .machine), .lower)

        let networkCommand = try XCTUnwrap(NavigationDragCoordinator.command(
            for: .shelf(.network),
            droppingOn: .zone(.upper, index: 0),
            in: layout, makeShelfID: { shelfUUID }))
        let networkMoved = try layout.applying(networkCommand)
        XCTAssertEqual(networkMoved.zone(of: .network), .upper)
    }

    func testDrawerSummaryCountsContainedLeavesAndSurfacesNetworkStatus() {
        var layout = NavigationLayout.standard(for: .standard)
        let networkIndex = layout.lower.firstIndex {
            $0.id == NavigationShelfID.network.rawValue
        }!
        layout.drawer.append(layout.lower.remove(at: networkIndex))
        layout.drawer.append(.module("chat"))
        layout.upper.removeAll { $0 == .module("chat") }

        XCTAssertEqual(NavigationDrawerSummary(items: layout.drawer),
                       NavigationDrawerSummary(moduleCount: 5,
                                               containsNetworkShelf: true))
    }

    func testSpringLoadingFeedbackArmsOnlyOncePerEntry() {
        var feedback = NavigationDragFeedbackState()
        let target = NavigationDropTarget.zone(.drawer, index: 0)

        feedback.enter(target)
        XCTAssertTrue(feedback.activateSpringLoading(for: target))
        XCTAssertFalse(feedback.activateSpringLoading(for: target))
        feedback.exit(target)
        XCTAssertNil(feedback.target)
    }

    func testSpringLoadingActivationRequiresAcceptedSupportedTargetOnce() {
        var feedback = NavigationDragFeedbackState()
        let target = NavigationDropTarget.zone(.drawer, index: 0)
        feedback.enter(target)

        XCTAssertFalse(NavigationSpringLoadActivation.shouldActivate(
            activated: false, acceptedTarget: target, feedback: &feedback))
        XCTAssertTrue(NavigationSpringLoadActivation.shouldActivate(
            activated: true, acceptedTarget: target, feedback: &feedback))
        XCTAssertFalse(NavigationSpringLoadActivation.shouldActivate(
            activated: true, acceptedTarget: target, feedback: &feedback))

        var shelfFeedback = NavigationDragFeedbackState()
        let shelf = NavigationDropTarget.shelf(
            .screen, beforeModuleID: nil)
        shelfFeedback.enter(shelf)
        XCTAssertTrue(NavigationSpringLoadActivation.shouldActivate(
            activated: true, acceptedTarget: shelf,
            feedback: &shelfFeedback))

        var unsupportedFeedback = NavigationDragFeedbackState()
        let unsupported = NavigationDropTarget.zone(.upper, index: 0)
        unsupportedFeedback.enter(unsupported)
        XCTAssertFalse(NavigationSpringLoadActivation.shouldActivate(
            activated: true, acceptedTarget: unsupported,
            feedback: &unsupportedFeedback))
    }

    func testSpringLoadingUsesTheDoubleFlashSpec() {
        XCTAssertEqual(NavigationSpringLoadFlash.count, 2)
        XCTAssertEqual(NavigationSpringLoadFlash.animationRepeatCount,
                       Float(NavigationSpringLoadFlash.count))
    }

    func testNavigationRowUsesContinuousTopCenterBottomDropRegions() {
        let targets = NavigationRowDropTargets(
            before: .zone(.upper, index: 1),
            center: .module("chat"),
            after: .zone(.upper, index: 2))
        // Neither the row's own targets nor nil: the settled bands apply
        // without any stickiness from a previous answer.
        let elsewhere = NavigationDropTarget.zone(.lower, index: 9)

        XCTAssertEqual(targets.target(at: 0, height: 90, previous: elsewhere),
                       targets.before)
        XCTAssertEqual(targets.target(at: 17, height: 90, previous: elsewhere),
                       targets.before)
        XCTAssertEqual(targets.target(at: 19, height: 90, previous: elsewhere),
                       targets.center)
        XCTAssertEqual(targets.target(at: 71, height: 90, previous: elsewhere),
                       targets.center)
        XCTAssertEqual(targets.target(at: 73, height: 90, previous: elsewhere),
                       targets.after)
        XCTAssertEqual(targets.target(at: 90, height: 90, previous: elsewhere),
                       targets.after)
    }

    /// The row must not reorder the stack on the frame the pointer arrives.
    ///
    /// `previewDrop` applies an insertion's move live, and the connections
    /// shelf is the row a drag is most likely to enter through its top edge
    /// — it is the last one before the window edge. Resolving an insertion
    /// on first contact moved the shelf out from under a pointer that had
    /// not moved, which is why it could not be spring-loaded into.
    func testFirstContactResolvesTheRowRatherThanDisplacingIt() {
        let targets = NavigationRowDropTargets(
            before: .zone(.upper, index: 1),
            center: .shelf(.network, beforeModuleID: nil),
            after: .zone(.upper, index: 2))

        // Under thirds these two were `before` and `after`.
        XCTAssertEqual(targets.target(at: 12, height: 90, previous: nil),
                       targets.center)
        XCTAssertEqual(targets.target(at: 78, height: 90, previous: nil),
                       targets.center)
        // Aiming deliberately at the gap either side still reaches it.
        XCTAssertEqual(targets.target(at: 4, height: 90, previous: nil),
                       targets.before)
        XCTAssertEqual(targets.target(at: 86, height: 90, previous: nil),
                       targets.after)
    }

    func testNavigationRowDropRegionHysteresisPreventsBoundaryFlicker() {
        let targets = NavigationRowDropTargets(
            before: .zone(.upper, index: 1),
            center: .module("chat"),
            after: .zone(.upper, index: 2))

        XCTAssertEqual(targets.target(at: 15, height: 90,
                                      previous: targets.center),
                       targets.center)
        XCTAssertEqual(targets.target(at: 13, height: 90,
                                      previous: targets.center),
                       targets.before)
        XCTAssertEqual(targets.target(at: 21, height: 90,
                                      previous: targets.before),
                       targets.before)
        XCTAssertEqual(targets.target(at: 23, height: 90,
                                      previous: targets.before),
                       targets.center)
        XCTAssertEqual(targets.target(at: 69, height: 90,
                                      previous: targets.after),
                       targets.after)
        XCTAssertEqual(targets.target(at: 67, height: 90,
                                      previous: targets.after),
                       targets.center)
    }

    /// Spring loading is armed against the ROW, not the band under the
    /// pointer.
    ///
    /// `springLoadingEntered` used to resolve the band and refuse to arm
    /// unless that band supported spring loading — and two of a row's three
    /// bands are `.zone` insertions, which never do. A drag resting anywhere
    /// but the middle answered AppKit with "no spring loading here", so the
    /// double flash had nothing to fire from.
    func testSpringLoadingArmsFromTheRowNotTheBandUnderThePointer() {
        let shelfRow = NavigationRowDropTargets(
            before: .zone(.upper, index: 1),
            center: .shelf(.network, beforeModuleID: nil),
            after: .zone(.upper, index: 2))

        XCTAssertFalse(shelfRow.before.supportsSpringLoading)
        XCTAssertFalse(shelfRow.after.supportsSpringLoading)
        XCTAssertEqual(shelfRow.springLoadingTarget { _ in true },
                       shelfRow.center)
        XCTAssertNil(shelfRow.springLoadingTarget { $0 != shelfRow.center })

        // The drawer is the one insertion target that does spring-load, so
        // asking the row still has to find it when the centre is refused.
        let drawerRow = NavigationRowDropTargets(
            before: .zone(.drawer, index: 0),
            center: .module("chat"),
            after: .zone(.drawer, index: 1))
        XCTAssertEqual(drawerRow.springLoadingTarget { $0 != drawerRow.center },
                       drawerRow.before)
    }

    func testNavigationRowFeedbackDistinguishesInsertionFromAttachment() {
        let targets = NavigationRowDropTargets(
            before: .zone(.upper, index: 1),
            center: .shelf(.files, beforeModuleID: nil),
            after: .zone(.upper, index: 2))

        XCTAssertEqual(targets.feedback(for: targets.before),
                       .insertionBefore)
        XCTAssertEqual(targets.feedback(for: targets.center), .center)
        XCTAssertEqual(targets.feedback(for: targets.after),
                       .insertionAfter)
    }

    func testNavigationRowFallsBackToNearestInsertionWhenCenterCannotAttach() {
        let targets = NavigationRowDropTargets(
            before: .zone(.upper, index: 1),
            center: .module("chat"),
            after: .zone(.upper, index: 2))

        XCTAssertEqual(targets.candidates(at: 40, height: 90,
                                          previous: nil),
                       [targets.center, targets.before, targets.after])
        XCTAssertEqual(targets.candidates(at: 50, height: 90,
                                          previous: nil),
                       [targets.center, targets.after, targets.before])
        XCTAssertEqual(targets.acceptedTarget(
            at: 40, height: 90, previous: nil,
            accepting: { $0 != targets.center }), targets.before)
        XCTAssertEqual(targets.acceptedTarget(
            at: 50, height: 90, previous: nil,
            accepting: { $0 != targets.center }), targets.after)
    }
}
