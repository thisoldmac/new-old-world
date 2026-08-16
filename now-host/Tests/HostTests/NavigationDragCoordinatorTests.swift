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
            for: .module("projects"),
            droppingOn: .module("chat"),
            in: layout,
            makeShelfID: { self.shelfUUID }))

        let changed = try layout.applying(command)
        let shelf = try XCTUnwrap(changed.shelf(id: .user(shelfUUID)))

        XCTAssertEqual(shelf.moduleIDs, ["chat", "projects"])
        XCTAssertEqual(shelf.title, "New Shelf")
        XCTAssertFalse(changed.upper.contains(.module("chat")))
        XCTAssertFalse(changed.upper.contains(.module("projects")))
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
            for: .module("projects"),
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
                upperItemCount: 5, lowerItemCount: 3,
                pinnedStackHeight: 96),
            .zone(.upper, index: 5))
        XCTAssertEqual(
            NavigationSidebarDropResolver.target(
                distanceFromTop: 310, height: 400,
                upperItemCount: 5, lowerItemCount: 3,
                pinnedStackHeight: 96),
            .zone(.lower, index: 0))
    }

    /// The footer's chrome must append below the stack, not prepend above it.
    ///
    /// The canvas fallback used to split the whole canvas in half: the top
    /// appended to `upper`, the bottom prepended at `.zone(.lower, index: 0)`.
    /// The footer is entirely inside that bottom half, and it is mostly
    /// chrome — a divider, 8/5pt padding, the gaps around two rows — none of
    /// which any row's own drop view covers. Connections is the LAST row of
    /// that stack, so every one of those points pushed it down a full row
    /// before the pointer had reached it. Widening the row's centre band
    /// could not help: the displacement happens above the row.
    func testFooterChromeAppendsBelowTheStackRatherThanPrependingAboveIt() {
        func target(_ y: CGFloat) -> NavigationDropTarget {
            NavigationSidebarDropResolver.target(
                distanceFromTop: y, height: 400,
                upperItemCount: 5, lowerItemCount: 2,
                pinnedStackHeight: 96)          // stack occupies 304...400
        }

        XCTAssertEqual(target(300), .zone(.upper, index: 5),
                       "above the pinned stack still appends to the list")
        XCTAssertEqual(target(310), .zone(.lower, index: 0),
                       "the stack's top padding means before its first row")
        XCTAssertEqual(target(394), .zone(.lower, index: 2),
                       "below the last footer row is an APPEND — the same "
                         + "answer the upper half gives, mirrored")
    }

    func testFooterDropGeometryDegradesHonestlyBeforeItIsMeasured() {
        // A stack of no height cannot own any point; nothing may resolve to
        // a prepend that would displace the row a drag is aimed at.
        XCTAssertEqual(
            NavigationSidebarDropResolver.target(
                distanceFromTop: 399, height: 400,
                upperItemCount: 5, lowerItemCount: 2,
                pinnedStackHeight: 0),
            .zone(.upper, index: 5))
        // An empty footer takes the whole drop, which is the one case the
        // old prepend was right about.
        XCTAssertEqual(
            NavigationSidebarDropResolver.target(
                distanceFromTop: 396, height: 400,
                upperItemCount: 5, lowerItemCount: 0,
                pinnedStackHeight: 20),
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
                for: .module("web"),
                droppingOn: .shelf(.network, beforeModuleID: "mcp"),
                in: layout,
                makeShelfID: { self.shelfUUID })))
        XCTAssertEqual(reordered.shelf(id: .network)?.moduleIDs,
                       ["settings", "web", "mcp"])
    }

    /// A drop in front of a shelf's first tab is accepted AND survives saving.
    ///
    /// This asserted the opposite until heroes became movable: `sanitised`
    /// ran `enforceSpecialHeroes`, which re-prepended each fixed hero, and
    /// `SidebarPreferences.replaceLayout` returned early because the
    /// canonical result equalled what was already stored — so a drop in
    /// front of the Settings pill (the Connections shelf's leftmost tab, and
    /// the natural aim point for "put it first") was accepted by
    /// `performDragOperation`, animated by AppKit, and reverted with no state
    /// change at all. The interim fix refused it up front; the decision was
    /// to let the person decide tab order instead.
    ///
    /// The suite could not see any of this: every other case asserts
    /// `applying(command)` and stops there. This one goes through the save,
    /// which is the half where the reorder used to die.
    func testDroppingBeforeAShelfHeroSurvivesTheSave() throws {
        let layout = NavigationLayout.standard(for: .standard)

        let command = try XCTUnwrap(NavigationDragCoordinator.command(
            for: .module("mcp"),
            droppingOn: .shelf(.network, beforeModuleID: "settings"),
            in: layout,
            makeShelfID: { self.shelfUUID }),
                                    "displacing a shelf's first tab is a "
                                      + "valid drop")

        let applied = try layout.applying(command)
        XCTAssertEqual(applied.shelf(id: .network)?.moduleIDs,
                       ["mcp", "settings", "web"])
        XCTAssertEqual(applied.sanitised(for: .standard)
                        .shelf(id: .network)?.moduleIDs,
                       ["mcp", "settings", "web"],
                       "the save must not re-prepend a hero over the order "
                         + "the person arranged")

        // And the shelf now opens on the tab they put first.
        XCTAssertEqual(applied.sanitised(for: .standard)
                        .shelf(id: .network)?.hero,
                       .module("mcp"))

        // A drop that displaces nothing still survives, unchanged.
        let later = try XCTUnwrap(NavigationDragCoordinator.command(
            for: .module("web"),
            droppingOn: .shelf(.network, beforeModuleID: "mcp"),
            in: layout,
            makeShelfID: { self.shelfUUID }))
        let saved = try layout.applying(later).sanitised(for: .standard)
        XCTAssertEqual(saved.shelf(id: .network)?.moduleIDs,
                       ["settings", "web", "mcp"])
    }

    /// The same round trip for the other two shelves that had a fixed hero,
    /// because the rule they shared was per-shelf and deleting it must not
    /// have been half-deleted.
    func testScreenAndFilesHeroesAlsoSurviveBeingDisplaced() throws {
        let layout = NavigationLayout.standard(for: .standard)

        let screen = try layout.applying(try XCTUnwrap(
            NavigationDragCoordinator.command(
                for: .module("mirror"),
                droppingOn: .shelf(.screen, beforeModuleID: "screen"),
                in: layout,
                makeShelfID: { self.shelfUUID }))).sanitised(for: .standard)
        XCTAssertEqual(screen.shelf(id: .screen)?.moduleIDs,
                       ["mirror", "screen", "continuity"])
        XCTAssertEqual(screen.shelf(id: .screen)?.hero, .module("mirror"))

        let files = try layout.applying(try XCTUnwrap(
            NavigationDragCoordinator.command(
                for: .module("icloud"),
                droppingOn: .shelf(.files, beforeModuleID: "files"),
                in: layout,
                makeShelfID: { self.shelfUUID }))).sanitised(for: .standard)
        XCTAssertEqual(files.shelf(id: .files)?.moduleIDs,
                       ["icloud", "files"])
        XCTAssertEqual(files.shelf(id: .files)?.hero, .module("icloud"))
    }

    /// The machine shelf's hero is not a module and does not move.
    ///
    /// It is different in KIND, not by policy: Overview is a page the shelf
    /// owns, so there is no module for a person to put in front of it. The
    /// fixed-hero rule that just went away never applied here, and a sweep
    /// that deleted this distinction too would leak a pseudo module id into
    /// selection.
    func testTheMachineShelfHeroIsStillTheOverviewPage() throws {
        let layout = NavigationLayout.standard(for: .standard)
        XCTAssertEqual(layout.shelf(id: .machine)?.hero, .overview)

        let reordered = try layout.applying(try XCTUnwrap(
            NavigationDragCoordinator.command(
                for: .module("software"),
                droppingOn: .shelf(.machine, beforeModuleID: "census"),
                in: layout,
                makeShelfID: { self.shelfUUID }))).sanitised(for: .standard)
        XCTAssertEqual(reordered.shelf(id: .machine)?.moduleIDs.first,
                       "software")
        XCTAssertEqual(reordered.shelf(id: .machine)?.hero, .overview)
    }

    func testTwoMemberUserShelfCanReorderWithoutDecomposing() throws {
        var layout = NavigationLayout.standard(for: .standard)
        layout.upper.removeAll {
            $0 == .module("chat") || $0 == .module("projects")
        }
        layout.upper.append(.shelf(NavigationShelf(
            id: .user(shelfUUID), moduleIDs: ["chat", "projects"])))

        let changed = try layout.applying(try XCTUnwrap(
            NavigationDragCoordinator.command(
                for: .module("projects"),
                droppingOn: .shelf(.user(shelfUUID), beforeModuleID: "chat"),
                in: layout,
                makeShelfID: { self.shelfUUID })))

        XCTAssertEqual(changed.shelf(id: .user(shelfUUID))?.moduleIDs,
                       ["projects", "chat"])
    }

    /// A top-level move previews the baseline and still refuses a target the
    /// layout cannot accept.
    ///
    /// This test used to assert the opposite — that the preview reflowed the
    /// upper stack — which is the behaviour
    /// `testHoveringAnInsertionBandDoesNotReflowTheStack` removed. What
    /// survives from it is the half worth keeping: previewing never mutates
    /// the baseline, and a preview is nil exactly when the drop would be.
    func testPreviewOfATopLevelMoveShowsTheBaselineAndValidatesTheTarget()
        throws {
        let baseline = NavigationLayout.standard(for: .standard)

        let preview = try XCTUnwrap(NavigationDragPreview(
            dragged: .shelf(.screen),
            target: .zone(.upper, index: 0),
            baseline: baseline,
            makeShelfID: { self.shelfUUID }))

        XCTAssertEqual(preview.layout, baseline)
        XCTAssertEqual(baseline.upper.first?.id,
                       NavigationShelfID.machine.rawValue)

        XCTAssertNil(NavigationDragPreview(
            dragged: .shelf(.machine),
            target: .zone(.drawer, index: 0),
            baseline: baseline,
            makeShelfID: { self.shelfUUID }),
                     "a move the layout refuses must not preview either")
    }

    func testPreviewReflowsShelfTabsBeforeDrop() throws {
        let baseline = NavigationLayout.standard(for: .standard)

        let preview = try XCTUnwrap(NavigationDragPreview(
            dragged: .module("web"),
            target: .shelf(.network, beforeModuleID: "mcp"),
            baseline: baseline,
            makeShelfID: { self.shelfUUID }))

        XCTAssertEqual(preview.layout.shelf(id: .network)?.moduleIDs,
                       ["settings", "web", "mcp"])
        XCTAssertEqual(baseline.shelf(id: .network)?.moduleIDs,
                       ["settings", "mcp", "web"])

        // The first pill previews like any other. It used to preview nothing
        // because a drop in front of a fixed hero was refused.
        let beforeTheFirstTab = try XCTUnwrap(NavigationDragPreview(
            dragged: .module("web"),
            target: .shelf(.network, beforeModuleID: "settings"),
            baseline: baseline,
            makeShelfID: { self.shelfUUID }))
        XCTAssertEqual(beforeTheFirstTab.layout.shelf(id: .network)?.moduleIDs,
                       ["web", "settings", "mcp"])
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

    /// Hovering an insertion band must not reflow the stack either.
    ///
    /// Wave 1 suppressed the eager preview for `.insert` only. Every
    /// insertion band on every row resolves a `.zone` target, and every
    /// `.zone` target is a `.move` — so the mechanism the `.insert` guard
    /// exists to prevent stayed fully live through the top and bottom bands
    /// of every row and through the whole canvas fallback. The insertion
    /// line already says where the row lands; moving the rows as well takes
    /// the destination out from under a pointer that has not moved, which is
    /// a real `draggingExited` and restarts AppKit's spring-load dwell.
    func testHoveringAnInsertionBandDoesNotReflowTheStack() throws {
        let baseline = NavigationLayout.standard(for: .standard)

        let preview = try XCTUnwrap(NavigationDragPreview(
            dragged: .shelf(.network),
            target: .zone(.upper, index: 1),
            baseline: baseline,
            makeShelfID: { self.shelfUUID }))

        XCTAssertEqual(preview.layout, baseline,
                       "an insertion line says where it lands; "
                         + "it does not move rows")
        XCTAssertEqual(preview.target, .zone(.upper, index: 1))
    }

    /// The rows' targets and the commands' indices must name the same rows.
    ///
    /// `HostRootView` renders `dragPreview?.layout ?? sidebar.layout`, so
    /// every `beforeTarget: .zone(zone, index: index)` a row builds is an
    /// index into the PREVIEW — while `canDrop`, `previewDrop` and
    /// `performDrop` all resolve against `sidebar.layout`, the baseline. Any
    /// preview that reorders a stack makes those two index spaces differ,
    /// and the resolved target then feeds the next preview. Freezing the
    /// presentation at the baseline for the whole drag makes them one space
    /// by construction, which is why the `.move` guard is not cosmetic.
    func testFooterRowTargetsAndCommandsShareOneIndexSpace() throws {
        let baseline = NavigationLayout.standard(for: .standard)
        let preview = try XCTUnwrap(NavigationDragPreview(
            dragged: .module("chat"),
            target: .zone(.lower, index: 0),
            baseline: baseline,
            makeShelfID: { self.shelfUUID }))

        let previewIndex = try XCTUnwrap(preview.layout.lower.firstIndex {
            $0.id == NavigationShelfID.network.rawValue
        })
        let baselineIndex = try XCTUnwrap(baseline.lower.firstIndex {
            $0.id == NavigationShelfID.network.rawValue
        })

        XCTAssertEqual(previewIndex, baselineIndex,
                       "a target the pointer aimed at in the preview must "
                         + "mean the same row in the layout the command is "
                         + "applied to")
    }

    func testCombiningModulesWaitsForDropInsteadOfCollapsingTheDragTarget() throws {
        let baseline = NavigationLayout.standard(for: .standard)

        let preview = try XCTUnwrap(NavigationDragPreview(
            dragged: .module("projects"),
            target: .module("chat"),
            baseline: baseline,
            makeShelfID: { self.shelfUUID }))

        XCTAssertEqual(preview.layout, baseline)
        XCTAssertEqual(preview.target, .module("chat"))
    }

    /// A former fixed hero drags like any other pill, out of its shelf and
    /// across zones, and the shelf it left opens on whatever is now first.
    ///
    /// The inverse of this used to be the assertion — these three modules
    /// could produce no drag command at all, which is what made Screen, Files
    /// and Connections partly immovable rather than merely awkward.
    func testAFormerFixedHeroDragsOutAndTheShelfPromotesTheNextTab() throws {
        let layout = NavigationLayout.standard(for: .standard)
        let cases: [(module: String, shelf: NavigationShelfID, next: String)] = [
            ("screen", .screen, "mirror"),
            ("files", .files, "icloud"),
            ("settings", .network, "mcp"),
        ]

        for (moduleID, shelfID, next) in cases {
            let command = try XCTUnwrap(NavigationDragCoordinator.command(
                for: .module(moduleID),
                droppingOn: .zone(.lower, index: 0),
                in: layout,
                makeShelfID: { shelfUUID }),
                                        "\(moduleID) must be draggable")
            let saved = try layout.applying(command).sanitised(for: .standard)

            XCTAssertEqual(saved.lower.first, .module(moduleID))
            XCTAssertFalse(
                saved.shelf(id: shelfID)?.moduleIDs.contains(moduleID) ?? true,
                "\(moduleID) must not be pulled back onto \(shelfID.rawValue)")
            XCTAssertEqual(saved.shelf(id: shelfID)?.hero, .module(next))
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
        layout.upper.removeAll { $0 == .module("chat") || $0 == .module("projects") }
        layout.upper.append(.shelf(NavigationShelf(
            id: .user(shelfUUID), moduleIDs: ["chat", "projects"])))

        let changed = try layout.applying(try XCTUnwrap(
            NavigationDragCoordinator.command(
                for: .module("projects"),
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
                       /* The Connections shelf carries three modules since
                          Networking moved to the Machine shelf, plus the
                          loose chat row. */
                       NavigationDrawerSummary(moduleCount: 4,
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
