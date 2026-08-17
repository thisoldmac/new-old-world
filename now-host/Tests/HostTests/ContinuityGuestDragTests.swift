import AppKit
import MirrorKit
import MirrorKitUI
import XCTest
@testable import Host

/// The guest→host half of cross-edge file drag: what a press binds to, the
/// order the cross happens in, and what a grab does when the Mac says no.
///
/// Every assertion here exists because v1 failed attended metal testing with
/// no per-direction symptom at all — each of these paths was a silent nil.
@MainActor
final class ContinuityGuestDragTests: XCTestCase {

    // MARK: - The stub cache

    func testSelectionIsCachedUnderItsOwnGenerationAndAudited() {
        var audits: [(HostLog.LogLevel, String)] = []
        let cache = ContinuitySelectionCache { audits.append(($0, $1)) }
        cache.apply(Self.selection(epoch: 7, generation: 3,
                                   item: Self.file(name: "Read Me")),
                    activeEpoch: 7)

        let bound = try? cache.bindable(activeEpoch: 7).get()
        XCTAssertEqual(bound?.generation, 3)
        XCTAssertEqual(bound?.item.name, "Read Me")
        XCTAssertTrue(audits.contains { $0.1.contains("selection cached")
            && $0.1.contains("generation=3") },
            "a cache update nobody can see is how v1 produced no symptom")
    }

    /// An absent item is an INSTRUCTION, not a poll that found nothing.
    func testEmptySelectionClearsTheCacheAndSaysSo() {
        var audits: [(HostLog.LogLevel, String)] = []
        let cache = ContinuitySelectionCache { audits.append(($0, $1)) }
        cache.apply(Self.selection(epoch: 7, generation: 3,
                                   item: Self.file(name: "Read Me")),
                    activeEpoch: 7)
        cache.apply(Self.selection(epoch: 7, generation: 4, item: nil),
                    activeEpoch: 7)

        XCTAssertNil(cache.stub)
        XCTAssertEqual(cache.bindable(activeEpoch: 7), .failure(.noSelection))
        XCTAssertTrue(audits.contains { $0.1.contains("selection cleared") })
    }

    /// A grab expires with its epoch by contract. A stub cached under
    /// another one would be exactly that grant outliving its consent.
    func testSelectionFromAnotherEpochIsNeverCached() {
        var audits: [(HostLog.LogLevel, String)] = []
        let cache = ContinuitySelectionCache { audits.append(($0, $1)) }
        cache.apply(Self.selection(epoch: 6, generation: 1,
                                   item: Self.file(name: "Read Me")),
                    activeEpoch: 7)

        XCTAssertNil(cache.stub)
        XCTAssertTrue(audits.contains {
            $0.0 == .warn && $0.1.contains("epoch 6")
                && $0.1.contains("epoch 7")
        }, "the refusal must name both epochs, not merely decline")
    }

    func testFolderIsRefusedByTheNameTheContractUses() {
        let cache = ContinuitySelectionCache { _, _ in }
        cache.apply(Self.selection(epoch: 7, generation: 2,
                                   item: Self.folder(name: "System Folder")),
                    activeEpoch: 7)

        XCTAssertEqual(cache.bindable(activeEpoch: 7),
                       .failure(.folderNotYet("System Folder")))
        XCTAssertTrue(ContinuitySelectionCache.Unusable
            .folderNotYet("System Folder").message
            .contains("folder-not-yet"))
    }

    func testWrongContinuityVersionIsIgnoredOutLoud() {
        var audits: [(HostLog.LogLevel, String)] = []
        let cache = ContinuitySelectionCache { audits.append(($0, $1)) }
        var selection = Self.selection(epoch: 7, generation: 1,
                                       item: Self.file(name: "Read Me"))
        selection.version = ContinuityContract.version + 1
        cache.apply(selection, activeEpoch: 7)

        XCTAssertNil(cache.stub)
        XCTAssertTrue(audits.contains { $0.1.contains("Continuity version") })
    }

    /// A classic file has no extension to read a type from; four bytes is
    /// all the guest sends, so that is what the promise is built on.
    func testStubNamesATypeAndAFilenameFromClassicMetadata() {
        var item = Self.file(name: "Read Me")
        item.fileType = "TEXT"
        let text = ContinuityDragStub(epoch: 1, generation: 1, item: item)
        XCTAssertEqual(text.utType, .plainText)
        XCTAssertEqual(text.localName, "Read Me")
        XCTAssertNil(text.wireContainer)

        var appItem = Self.file(name: "SimpleText")
        appItem.fileType = "APPL"
        let app = ContinuityDragStub(epoch: 1, generation: 1, item: appItem)
        XCTAssertEqual(app.localName, "SimpleText.bin",
                       "an application without its resource fork is nothing")
        XCTAssertEqual(app.wireContainer, "macbinary")
    }

    // MARK: - The press binding

    func testPressBindsToTheSelectionStubRatherThanAScene() {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()

        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("press bound to the guest selection")
                && $0.1.contains("generation=3")
        })
        XCTAssertEqual(rig.sceneLookups, 0,
                       "the stub is the truth for this lane; a scene lookup "
                        + "here would reintroduce the Mirror dependency")
    }

    func testPressOnAFolderIsAnOrdinaryClickAndSaysWhy() {
        let rig = Rig()
        rig.select(Self.folder(name: "System Folder"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()

        XCTAssertTrue(rig.environment.fileDrags.isEmpty)
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("folder-not-yet")
        }, "an unusable stub must be named, not silently dropped")
    }

    func testPressWithNoSelectionIsAnOrdinaryClickAndSaysWhy() {
        let rig = Rig()
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()

        XCTAssertTrue(rig.environment.fileDrags.isEmpty)
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("has published no Finder selection")
        })
    }

    // MARK: - The selection that changed under the press

    /// **THE WRONG FILE, AS IT HAPPENED.** Metal, 2026-08-15 17:19:
    /// `hello.txt` was the published generation, Michelle pressed on
    /// `main.c` and dragged it across the edge, and this Mac transferred
    /// `hello.txt`. Every rule the binding had was satisfied throughout —
    /// the press bound the only generation that existed.
    ///
    /// Here the guest's press probe publishes `main.c` while the button is
    /// held, which is the only thing that can have caused it, and the cross
    /// binds THAT.
    func testACrossBindsTheSelectionThePressItselfCreated() throws {
        let rig = Rig()
        rig.select(Self.file(name: "hello.txt"), generation: 2)
        rig.enterGuest()
        rig.press()
        // The guest's press probe, mid-gesture: this press selected main.c.
        rig.select(Self.file(name: "main.c"), generation: 3)
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        let item = try XCTUnwrap(rig.environment.fileDrags.first?.item)
        let provider = try XCTUnwrap(item.writer as? NSFilePromiseProvider)
        let stub = try XCTUnwrap(provider.userInfo as? ContinuityDragStub)
        XCTAssertEqual(stub.item.name, "main.c",
                       "the file the person dragged is the file that crosses")
        XCTAssertEqual(stub.generation, 3)
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("binding this press to the selection it made")
                && $0.1.contains("generation=3")
                && $0.1.contains("replacing generation 2")
        }, "the bind must name both generations: the 17:19 report could not "
            + "be diagnosed from any single line")
    }

    /// The same shape with nothing cached at all — the press that selects
    /// AND drags, which bound `boundFile=none` on metal at 15:37.
    func testACrossBindsASelectionThatDidNotExistAtThePress() throws {
        let rig = Rig()
        rig.enterGuest()
        rig.press()
        rig.select(Self.file(name: "main.c"), generation: 1)
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        let item = try XCTUnwrap(rig.environment.fileDrags.first?.item)
        let provider = try XCTUnwrap(item.writer as? NSFilePromiseProvider)
        let stub = try XCTUnwrap(provider.userInfo as? ContinuityDragStub)
        XCTAssertEqual(stub.item.name, "main.c")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("replacing nothing")
        })
    }

    /// A change this press cannot claim REFUSES, and says so at warn.
    ///
    /// The distinguishing fact is the clock: this generation was applied
    /// before the press went out, so it is not this press's own doing and
    /// nothing on this Mac knows which of the two the hand chose. A
    /// snap-back is not the same kind of failure as a wrong file arriving.
    func testASelectionThatMovedBeforeThePressRefusesRatherThanGuesses()
    throws {
        let rig = Rig()
        rig.select(Self.file(name: "hello.txt"), generation: 2)
        rig.enterGuest()
        rig.press()
        /* Applied a second before the press went out, which is the shape of
           a publish that crossed the press on the wire: real, arriving
           late, and not attributable to this gesture. */
        rig.selectAsOf(rig.now() - 1, Self.file(name: "main.c"),
                       generation: 3)
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        XCTAssertTrue(rig.environment.fileDrags.isEmpty,
                      "nothing may cross when this Mac cannot say which "
                        + "file is in the person's hand")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.0 == .warn
                && $0.1.contains("the selection changed under this press")
                && $0.1.contains("not binding generation 2")
                && $0.1.contains("publishes generation 3")
        })
    }

    /// And the ritual that works today keeps working: select, release,
    /// press again, drag. Nothing changes under that press, so nothing
    /// here may interfere with it.
    func testTheTwoStepRitualIsUntouched() throws {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"), generation: 3)
        rig.enterGuest()
        rig.press()
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        let item = try XCTUnwrap(rig.environment.fileDrags.first?.item)
        let provider = try XCTUnwrap(item.writer as? NSFilePromiseProvider)
        let stub = try XCTUnwrap(provider.userInfo as? ContinuityDragStub)
        XCTAssertEqual(stub.item.name, "Read Me")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("this cross carries the selection its press was "
                + "made under")
        })
    }

    /// **THE RITUAL IS DEAD.** One gesture, on a file that was never
    /// selected: press, drag, cross. Nothing selected it first, nothing
    /// polled it, and the Finder's selection throughout is something else
    /// entirely — which is exactly what dragging an unselected icon looks
    /// like on a Macintosh.
    ///
    /// Every rule that existed before this slice refuses this drag, and
    /// none of them was wrong: they were all reasoning about a cache of the
    /// selection, and the selection genuinely does not name this file. The
    /// drag plane is what makes the file knowable at all.
    func testASingleGestureDragOfANeverSelectedFileBindsThatFile() throws {
        let rig = Rig()
        // What the Finder actually has selected, and keeps having.
        rig.select(Self.file(name: "hello.txt"), generation: 2)
        rig.enterGuest()
        rig.press()
        /* The person picked up a DIFFERENT icon. The Drag Manager says so —
           and the mark is stamped before the press instant so that no clock
           heuristic can rescue this test: what binds it is the source. */
        rig.dragBeginsAsOf(rig.now() - 1, Self.file(name: "main.c"),
                           generation: 3)
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        let item = try XCTUnwrap(rig.environment.fileDrags.first?.item)
        let provider = try XCTUnwrap(item.writer as? NSFilePromiseProvider)
        let stub = try XCTUnwrap(provider.userInfo as? ContinuityDragStub)
        XCTAssertEqual(stub.item.name, "main.c",
                       "the file in the hand crosses, not the file in the "
                         + "selection")
        XCTAssertEqual(stub.generation, 3)
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("binding this cross to the drag itself")
                && $0.1.contains("generation=3")
                && $0.1.contains("replacing generation 2")
        }, "the bind must name what it replaced: a drag and a cache "
            + "disagreeing is the ordinary case here, not a fault, and the "
            + "line is how anyone sees which one was taken")
    }

    /// **THE WRONG-FILE CASE, INVERTED.** A stale cache and a fresh drag
    /// naming different files used to be `superseded` — a refusal, and the
    /// right answer while a cache was all there was. It is now a bind, and
    /// the file it binds is the dragged one.
    ///
    /// The cache here is stale in the way that produced the 17:19 report:
    /// applied BEFORE the press, so the clock cannot attribute it to this
    /// gesture and `adopted` cannot rescue it either.
    func testAStaleCacheAndAFreshDragBindTheDrag() throws {
        let rig = Rig()
        rig.select(Self.file(name: "hello.txt"), generation: 2)
        rig.enterGuest()
        rig.press()
        rig.selectAsOf(rig.now() - 1, Self.file(name: "notes.txt"),
                       generation: 3)
        /* STAMPED BEFORE THE PRESS INSTANT, which is what makes this the
           case only the source can answer. The clock cannot attribute this
           generation to this gesture, so `adopted` does not fire and the
           old ladder reached `superseded` and refused. Nothing about the
           timing changed; what changed is that the Mac now says WHAT the
           generation is, and a drag needs no alibi. */
        rig.dragBeginsAsOf(rig.now() - 1, Self.file(name: "main.c"),
                           generation: 4)
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        let item = try XCTUnwrap(rig.environment.fileDrags.first?.item)
        let provider = try XCTUnwrap(item.writer as? NSFilePromiseProvider)
        let stub = try XCTUnwrap(provider.userInfo as? ContinuityDragStub)
        XCTAssertEqual(stub.item.name, "main.c")
        XCTAssertFalse(rig.recorder.lines.contains {
            $0.1.contains("the selection changed under this press")
        }, "a cache disagreeing with a drag is not an ambiguity: the drag "
            + "is the gesture, and refusing here would refuse every "
            + "never-selected file")
    }

    // MARK: - Late bind: the generation that arrives AFTER the cross
    //
    // Measured 2026-08-16 (build `cfc5c1a1`): the drag-sourced generation is
    // published 14 ticks — about 230 ms — after the drag ENDS, and the
    // crossing is what ends it, because the handback releases the guest
    // press. So on a single-gesture drag of a never-selected icon the fact
    // that names the file cannot exist on this side until after the cross has
    // already decided. `ContinuitySelectionBind` says a drag-sourced
    // generation "needs no clock comparison" and "wins first"; these say WHEN
    // that verdict may still be applied — up to the drop, and not past it.

    /// **THE SINGLE GESTURE, WITH NOTHING SELECTED AND NOTHING CACHED.**
    /// Nothing at all is bindable at the cross, which used to end the drag.
    /// The session starts anyway, carrying a promise nobody has filled in,
    /// and the Mac names the file a fifth of a second later.
    func testACrossWithNothingBoundIsFilledInByTheLateDragGeneration() throws {
        let rig = Rig()
        rig.enterGuest()
        rig.press()
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        let item = try XCTUnwrap(rig.environment.fileDrags.first?.item,
                                 "a cross with nothing bound must still start "
                                   + "a session: the fact that names the file "
                                   + "cannot arrive before the crossing that "
                                   + "releases the press")
        let provider = try XCTUnwrap(item.writer as? NSFilePromiseProvider)
        XCTAssertNil(provider.userInfo,
                     "nothing may be guessed at: the promise crosses unfilled")

        rig.dragBegins(Self.file(name: "main.c"), generation: 5)

        let stub = try XCTUnwrap(provider.userInfo as? ContinuityDragStub)
        XCTAssertEqual(stub.item.name, "main.c")
        XCTAssertEqual(stub.generation, 5)
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("late bind: this crossing now carries main.c")
                && $0.1.contains("generation 5")
                && $0.1.contains("source=drag")
                && $0.1.contains("replacing nothing at all")
        }, "the revision names old, new, source and gesture or the next "
            + "wrong-file report is unanswerable from the log")
    }

    /// And the drop redeems what the LATE generation named, not the empty
    /// seed the crossing started with.
    func testTheDropRedeemsTheLateBoundFile() throws {
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let asked = Asked()
        let rig = Rig(grabRequest: { epoch, generation, _, _, completion in
            asked.epoch = epoch
            asked.generation = generation
            completion(.failure(.init(code: "grant-expired",
                                      message: "too late")))
        })
        rig.select(Self.file(name: "hello.txt"), generation: 2)
        rig.enterGuest()
        rig.press()
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()
        rig.dragBegins(Self.file(name: "main.c"), generation: 5)

        let item = try XCTUnwrap(rig.environment.fileDrags.first?.item)
        let provider = try XCTUnwrap(item.writer as? NSFilePromiseProvider)
        _ = fulfill(rig.grab, to: staging.appendingPathComponent("main.c"),
                    provider: provider)

        XCTAssertEqual(asked.generation, 5,
                       "the wire is asked for the file in the hand, not the "
                         + "stale selection the crossing was seeded from")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("grab redeems a LATE bind")
                && $0.1.contains("name=main.c")
        })
    }

    /// A stale SELECTION candidate is replaced, exactly as
    /// `ContinuitySelectionBind.decide` would have replaced it had the fact
    /// arrived in time — "a stale cache and a fresh drag disagreeing is the
    /// ORDINARY case for a file nobody selected first".
    func testALateDragGenerationReplacesTheStaleSelectionItCrossedWith()
        throws {
        let rig = Rig()
        rig.select(Self.file(name: "hello.txt"), generation: 2)
        rig.enterGuest()
        rig.press()
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        let item = try XCTUnwrap(rig.environment.fileDrags.first?.item)
        let provider = try XCTUnwrap(item.writer as? NSFilePromiseProvider)
        XCTAssertEqual(
            (provider.userInfo as? ContinuityDragStub)?.item.name,
            "hello.txt", "the crossing is seeded from the cache, as before")

        rig.dragBegins(Self.file(name: "main.c"), generation: 5)

        XCTAssertEqual(
            (provider.userInfo as? ContinuityDragStub)?.item.name, "main.c")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("late bind: this crossing now carries main.c")
                && $0.1.contains("replacing hello.txt (generation 2)")
        })
    }

    /// **ONLY THE DRAG PLANE MAY REVISE.** Every other source is a cache of
    /// what was selected, and one arriving after the crossing has no claim
    /// on a gesture already in flight — the decision table ranks it below a
    /// drag even when it is fresh, and after the cross it is simply late
    /// news.
    func testALateSelectionGenerationNeverRevisesACrossing() throws {
        let rig = Rig()
        rig.select(Self.file(name: "hello.txt"), generation: 2)
        rig.enterGuest()
        rig.press()
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        rig.select(Self.file(name: "notes.txt"), generation: 6)

        let item = try XCTUnwrap(rig.environment.fileDrags.first?.item)
        let provider = try XCTUnwrap(item.writer as? NSFilePromiseProvider)
        XCTAssertEqual(
            (provider.userInfo as? ContinuityDragStub)?.item.name,
            "hello.txt")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("not revising this crossing")
                && $0.1.contains("generation 6 is a selection")
        }, "the refusal is said out loud: a silent one reads exactly like a "
            + "revision that worked")
    }

    /// **THE WINDOW SHUTS AT REDEMPTION.** The drop has asked the Mac for a
    /// specific generation; swapping the identity while those bytes are
    /// being fetched is the wrong-file bug in a new hat.
    func testAGenerationArrivingAfterTheDropIsRefusedByName() throws {
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let rig = Rig()
        rig.select(Self.file(name: "hello.txt"), generation: 2)
        rig.enterGuest()
        rig.press()
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        let item = try XCTUnwrap(rig.environment.fileDrags.first?.item)
        let provider = try XCTUnwrap(item.writer as? NSFilePromiseProvider)
        _ = fulfill(rig.grab, to: staging.appendingPathComponent("hello.txt"),
                    provider: provider)

        rig.dragBegins(Self.file(name: "main.c"), generation: 5)

        XCTAssertEqual(
            (provider.userInfo as? ContinuityDragStub)?.item.name,
            "hello.txt", "a redeemed drag keeps the identity it was redeemed "
                + "under")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.0 == .warn && $0.1.contains("late bind refused")
                && $0.1.contains("generation 5")
                && $0.1.contains("after the drop redeemed")
        })
    }

    /// **A CROSSING UNDER A HOST DRAG BINDS NOTHING, AND LATE BIND IS NOT A
    /// WAY AROUND THAT** (`37241007`). Widening the window in which a bind
    /// may be revised must not widen the window in which a refused one can
    /// come back.
    func testACrossUnderAHostDragBindsNothingEvenIfADragGenerationFollows() {
        let rig = Rig()
        rig.controller.physicalPrimaryButtonHeld = { true }
        rig.enterGuest()
        rig.hostDragReachesTheEdge()
        rig.press()
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        rig.dragBegins(Self.file(name: "main.c"), generation: 5)

        XCTAssertTrue(rig.environment.fileDrags.isEmpty,
                      "the gesture belongs to this Mac's own drag; nothing "
                        + "of the guest's crosses under it")
        XCTAssertFalse(rig.recorder.lines.contains {
            $0.1.contains("late bind: this crossing now carries")
        })
    }

    /// The box itself, where the two rules live: one revision at a time is
    /// fine, and none at all after the drop has taken its answer.
    func testTheRevisionWindowClosesAtRedemptionAndNotBefore() {
        let first = ContinuityDragStub(epoch: 7, generation: 2,
                                       item: Self.file(name: "hello.txt"))
        let second = ContinuityDragStub(epoch: 7, generation: 5,
                                        item: Self.file(name: "main.c"))
        let binding = ContinuityDragBinding(gesture: 1, stub: first)

        XCTAssertEqual(binding.revise(to: second),
                       .revised(gesture: 1,
                                from: "hello.txt (generation 2)",
                                to: "main.c (generation 5)"))
        XCTAssertEqual(binding.revise(to: second),
                       .unchanged(gesture: 1, generation: 5))
        XCTAssertEqual(binding.redeem()?.item.name, "main.c")
        XCTAssertEqual(binding.revise(to: first),
                       .refusedRedeemed(gesture: 1, generation: 2))
        XCTAssertEqual(binding.stub?.item.name, "main.c")

        /* And an empty one is honest about being empty: a crossing nothing
           ever named has no file, and refusing is what it must do. */
        let pending = ContinuityDragBinding(gesture: 2, stub: nil)
        XCTAssertNil(pending.redeem())
    }

    /// **BYTES ON THE PASTEBOARD END THE WINDOW EARLY, AND SAY SO.** An
    /// eager fetch that wins its race hands AppKit a real `file://` URL,
    /// because a promise-only pasteboard reads as nothing-droppable to every
    /// application that never adopted `NSFilePromiseReceiver` (metal,
    /// 2026-08-15) — that head start is kept. What it costs is revisability:
    /// a pasteboard cannot be changed once a session exists, so a drag that
    /// took the bytes refuses a late bind by name rather than accepting one
    /// that would be cosmetic.
    func testADragCarryingFetchedBytesRefusesALateBindOutLoud() throws {
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let delivery = try Self.delivery(name: "Read Me",
                                         bytes: Data("hello".utf8),
                                         in: staging)
        let fetched = expectation(description: "eager fetch completed")
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in completion(.success(delivery)) },
            audit: { if $1.contains("eager fetch completed") {
                fetched.fulfill()
            } })
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: Self.file(name: "Read Me"))
        let item = transfer.dragItem(for: stub)
        wait(for: [fetched], timeout: 5)
        XCTAssertTrue(item.finalized().writer is NSURL)

        let later = ContinuityDragStub(epoch: 7, generation: 5,
                                       item: Self.file(name: "main.c"))
        guard case .unusable(let reason) =
            transfer.reviseLiveBinding(to: later) else {
            return XCTFail("a pinned drag must refuse, not revise")
        }
        XCTAssertTrue(reason.contains("bytes"))
    }

    /// The pure decision, including the two cases the rig cannot stage
    /// without a real epoch ending underneath it.
    func testTheBindDecisionInEveryShape() {
        let press: TimeInterval = 1_000
        let before = ContinuitySelectionMark(epoch: 7, generation: 2,
                                             appliedAt: press - 1)
        let same = ContinuitySelectionMark(epoch: 7, generation: 2,
                                           appliedAt: press - 1)
        let after = ContinuitySelectionMark(epoch: 7, generation: 3,
                                            appliedAt: press + 0.4)
        let crossed = ContinuitySelectionMark(epoch: 7, generation: 3,
                                              appliedAt: press - 0.001)

        XCTAssertEqual(ContinuitySelectionBind.decide(
            pressed: before, current: same, downSentAt: press), .bound(same))
        XCTAssertEqual(ContinuitySelectionBind.decide(
            pressed: before, current: after, downSentAt: press),
            .adopted(after))
        XCTAssertEqual(ContinuitySelectionBind.decide(
            pressed: nil, current: after, downSentAt: press),
            .adopted(after))
        XCTAssertEqual(ContinuitySelectionBind.decide(
            pressed: before, current: crossed, downSentAt: press),
            .superseded(pressed: before, current: crossed))
        /* An arrival exactly ON the press instant is not this press's own
           doing either: the guest cannot have applied a down this Mac has
           only just sent. */
        XCTAssertEqual(ContinuitySelectionBind.decide(
            pressed: before,
            current: .init(epoch: 7, generation: 3, appliedAt: press),
            downSentAt: press),
            .superseded(pressed: before,
                        current: .init(epoch: 7, generation: 3,
                                       appliedAt: press)))
        /* The epoch ended with the cross, which is the ordinary case and
           must not read as a refusal. */
        XCTAssertEqual(ContinuitySelectionBind.decide(
            pressed: before, current: nil, downSentAt: press),
            .unchallenged(before))
        XCTAssertEqual(ContinuitySelectionBind.decide(
            pressed: nil, current: nil, downSentAt: press), .nothing)
        XCTAssertEqual(ContinuitySelectionBind.decide(
            pressed: nil, current: crossed, downSentAt: press), .nothing)

        /* --- and the drag source, which outranks all of it -------------
           Every case above argues about a CACHE; a drag-sourced mark is a
           report of the gesture, so it wins on kind rather than on
           freshness and needs no clock comparison to do it. */
        let dragged = ContinuitySelectionMark(epoch: 7, generation: 4,
                                              appliedAt: press + 0.4,
                                              source: .drag)
        /* THE ONE THAT MATTERS: applied BEFORE the press instant, so the
           clock cannot attribute it and `adopted` would not fire — and it
           binds anyway, because the Drag Manager named it. */
        let draggedEarly = ContinuitySelectionMark(epoch: 7, generation: 4,
                                                   appliedAt: press - 5,
                                                   source: .drag)

        XCTAssertEqual(ContinuitySelectionBind.decide(
            pressed: before, current: dragged, downSentAt: press),
            .dragged(dragged))
        XCTAssertEqual(ContinuitySelectionBind.decide(
            pressed: nil, current: dragged, downSentAt: press),
            .dragged(dragged))
        /* Where the old ladder said `superseded` and refused. */
        XCTAssertEqual(ContinuitySelectionBind.decide(
            pressed: before, current: draggedEarly, downSentAt: press),
            .dragged(draggedEarly))
        /* And where it said `bound` — still a drag, and still said so, so
           one line can tell the ritual working from it being unnecessary. */
        let sameGeneration = ContinuitySelectionMark(epoch: 7, generation: 2,
                                                     appliedAt: press - 1,
                                                     source: .drag)
        XCTAssertEqual(ContinuitySelectionBind.decide(
            pressed: before, current: sameGeneration, downSentAt: press),
            .dragged(sameGeneration))
        /* A cleared cache is still a cleared cache: there is no drag mark
           to prefer, and the guest's own grant hold redeems it. */
        XCTAssertEqual(ContinuitySelectionBind.decide(
            pressed: draggedEarly, current: nil, downSentAt: press),
            .unchallenged(draggedEarly))
    }

    /// The contract's default, applied where a host actually reads it.
    ///
    /// An absent `source` is `selection` — a guest built before the field
    /// existed had only the poll. An UNKNOWN value is not: it decodes as a
    /// failure rather than being demoted, because a future third source
    /// bound as if it were a poll is the quiet wrong-file bug this whole
    /// field exists to close.
    func testAnAbsentSourceIsASelectionAndAnUnknownOneIsNotDecodable()
    throws {
        let absent = try JSONDecoder().decode(
            ContinuitySelection.self,
            from: Data(#"{"version":4,"epoch":7,"generation":2}"#.utf8))
        XCTAssertNil(absent.source)
        XCTAssertEqual(absent.resolvedSource, .selection)

        let drag = try JSONDecoder().decode(
            ContinuitySelection.self,
            from: Data(#"{"version":4,"epoch":7,"generation":2,"source":"drag"}"#.utf8))
        XCTAssertEqual(drag.resolvedSource, .drag)

        XCTAssertThrowsError(try JSONDecoder().decode(
            ContinuitySelection.self,
            from: Data(#"{"version":4,"epoch":7,"generation":2,"source":"telepathy"}"#.utf8)))
    }

    // MARK: - The cross

    /// **An UNBOUND held cross releases at the press origin too.**
    ///
    /// Metal, 2026-08-15 01:16: the Mac had published no selection for the
    /// epoch, so nothing was bound, so the origin-return below was skipped —
    /// the press crossed with the button still down, stayed down for six
    /// seconds, and the guest Finder offered to replace `main.c` at wherever
    /// the pointer ended up. Returning to the origin is about not moving the
    /// person's files; it was never a detail of the file-transfer feature,
    /// and gating it on a bound item made a missing selection into a
    /// destructive one.
    func testAnUnboundHeldCrossReleasesAtThePressOriginNotTheCrossPoint()
        throws {
        let rig = Rig()                     /* nothing published, nothing bound */
        rig.enterGuest()
        rig.press()
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()

        let settle = try XCTUnwrap(
            rig.ledger.steps.firstIndex(
                of: .guestReturnedToPressOrigin(Rig.pressOrigin)),
            "the guest pointer was never returned to the press origin, so "
                + "the Finder completes its move wherever the release lands")
        let release = try XCTUnwrap(
            rig.ledger.steps.firstIndex(of: .guestPrimaryUp(Rig.pressOrigin)),
            "the held press was never released, or not at the origin")
        let left = try XCTUnwrap(
            rig.ledger.steps.firstIndex(of: .guestPointerLeft))
        XCTAssertLessThan(settle, release,
                          "the origin must be its own wire fact ahead of the "
                            + "release, not ride the same packet")
        XCTAssertLessThan(release, left,
                          "the press must end before this app stops driving "
                            + "the guest at all")
        /* THE LINE CHANGED WITH THE CONTRACT, THE ORDER DID NOT. An unbound
           cross no longer ends the gesture — it starts a drag pending a late
           bind, because the fact that names an unselected icon cannot reach
           this Mac until this very release ends the Finder's drag loop. The
           safety property above is untouched and is why it is asserted
           first: the guest pointer goes home before the button comes up
           whichever path the crossing takes. */
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("no file is bound to this cross")
                && $0.1.contains("pending a late bind")
        }, "an unbound cross must say what it is waiting for; silence here "
            + "reads as a drag that simply vanished")
    }

    /// **THE UNBOUND PATH IS NOW A HANDOFF, NOT AN ENDING.** It used to
    /// start nothing, on the reasoning that a press carrying no file is a
    /// drag of nothing — sound while the cross was the last moment this Mac
    /// could learn the file's name, and false since the drag plane: the
    /// generation that names a never-selected icon is published ~230 ms
    /// AFTER the crossing, because the crossing's own release is what ends
    /// the Finder's drag loop. So the session is started and left unfilled,
    /// and the drop refuses by name if nothing ever arrives.
    func testAnUnboundHeldCrossStartsADragPendingALateBind() throws {
        let rig = Rig()
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        let item = try XCTUnwrap(rig.environment.fileDrags.first?.item)
        let provider = try XCTUnwrap(item.writer as? NSFilePromiseProvider)
        XCTAssertNil(provider.userInfo,
                     "nothing may be guessed at: the promise is unfilled "
                       + "until the Mac itself names a file")
        XCTAssertEqual(rig.environment.catchChanges, [true],
                       "the catch surface is armed for the handoff, exactly "
                         + "as it is for a bound one")
    }

    /// A press the guest never took is not a press to release: sending an
    /// unpaired button-up would be this app inventing a click on the Mac.
    func testACrossWithNoGuestPressSendsNoRelease() {
        let rig = Rig()
        rig.enterGuest()
        rig.driver.acceptPresses = false
        rig.press()
        rig.crossBackHolding()

        XCTAssertFalse(rig.ledger.steps.contains {
            if case .guestPrimaryUp = $0 { return true }
            return false
        }, "nothing was pressed on the Mac, so nothing may be released")
    }

    /// **The release comes first.** v1 never released the guest button, so
    /// the dragged icon stayed stuck to the Finder's cursor on the other
    /// machine. Order is the whole mechanism, so the order is what is
    /// asserted — not merely that both things happened.
    func testGuestPressIsReleasedBeforeTheHostDragSessionStarts() throws {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        XCTAssertEqual(rig.environment.fileDrags.count, 1,
                       "the held file must reach AppKit")
        let release = try XCTUnwrap(
            rig.ledger.steps.firstIndex(of: .guestPrimaryUp(Rig.pressOrigin)),
            "the guest press was never released")
        let session = try XCTUnwrap(
            rig.ledger.steps.firstIndex(of: .hostDragBegan))
        XCTAssertLessThan(release, session,
                          "the drag started while the guest still held the "
                            + "press; the icon cannot snap back")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("guest press released before the cross")
        })
    }

    /// **The release lands where the press began, and lands there FIRST.**
    ///
    /// Metal, 2026-08-14: the guest dropped its icon at the screen edge.
    /// The Finder completes a move to wherever the pointer is when the
    /// button comes up, so releasing at the cross point is a real file
    /// relocation when the drag started inside a Finder window — the
    /// desktop case merely looked untidy and hid it.
    ///
    /// Three facts, and the order is one of them: the position packet goes
    /// out on its own, before the release, and both name the press origin
    /// rather than the point where the pointer left the guest.
    func testTheGuestPointerIsReturnedToThePressOriginBeforeTheRelease()
        throws {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        let settle = try XCTUnwrap(
            rig.ledger.steps.firstIndex(
                of: .guestReturnedToPressOrigin(Rig.pressOrigin)),
            "the guest pointer was never returned to the press origin; the "
                + "Finder completes its move wherever the release lands")
        let release = try XCTUnwrap(
            rig.ledger.steps.firstIndex(of: .guestPrimaryUp(Rig.pressOrigin)),
            "the release did not name the press origin")
        let session = try XCTUnwrap(
            rig.ledger.steps.firstIndex(of: .hostDragBegan))
        XCTAssertLessThan(settle, release,
                          "the origin must be on the wire before the button "
                            + "comes up, not beside it")
        XCTAssertLessThan(release, session)
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("returned to the press origin")
                && $0.1.contains("origin=\(Rig.pressOrigin.x)")
        }, "the log must carry both points, or a wrong one reads as right")
    }

    /// **The session's button state is re-armed before AppKit owns the
    /// gesture.**
    ///
    /// Metal, 2026-08-15 04:18–04:20: the abandon was gone and the sessions
    /// still failed, in two shapes from one cause. The consuming tap
    /// swallowed the physical `leftMouseDown`, so the window server believed
    /// no button was held for the whole handoff — and an `NSDraggingSession`
    /// is driven by session-level events, not the HID state our own readers
    /// were taught to ask. Five sessions completed instantly wherever the
    /// cursor stood (`operation=1`, "ended with the button still held") and
    /// one tracked nothing for three seconds, pinned at its seed point,
    /// ending `operation=nobody`. The synthetic down corrects the session's
    /// belief while the tap is already down (nothing of ours can swallow it)
    /// and the catch surface is wide and key (our own window receives it).
    func testTheSessionButtonStateIsRearmedBeforeTheDragSessionBegins()
        throws {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        let rearm = try XCTUnwrap(
            rig.ledger.steps.firstIndex(of: .sessionButtonRearmed),
            "the session state was never corrected; AppKit will drive the "
                + "drag from a state that believes the button is up")
        let session = try XCTUnwrap(
            rig.ledger.steps.firstIndex(of: .hostDragBegan))
        XCTAssertLessThan(rearm, session,
                          "posted after the session starts, the down arrives "
                            + "into a gesture AppKit already ended")
        let post = try XCTUnwrap(rig.environment.syntheticButtonPosts.first)
        XCTAssertTrue(post.down)
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("session button state re-armed")
        })
    }

    /// A failed post is an ERROR naming the consequence, not a silence —
    /// the 04:17 log took three rounds to diagnose because every layer of
    /// this defect degraded quietly.
    func testAFailedSessionRearmIsNamedOutLoud() {
        let rig = Rig()
        rig.environment.syntheticPostsSucceed = false
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()

        XCTAssertTrue(rig.recorder.lines.contains {
            $0.0 == .error
                && $0.1.contains("could not re-arm the session button state")
        })
    }

    /// **The synthetic down waits for the WINDOW SERVER, not for the widen.**
    ///
    /// Metal, 2026-08-15 13:43: the transfer worked and the presentation did
    /// not — a rubber-band selection dragged across the Finder desktop for
    /// the length of the handoff, and the drag image stuck at the screen edge
    /// while the session tracked 240 px and dropped correctly. The seed line
    /// named the cause without anyone reading it that way: `type=1,
    /// windowNumber=30, ourWindow=no` is a **`leftMouseDown`** — this app's
    /// own synthetic one, handed back by the global monitor after the window
    /// server delivered it to the Finder.
    ///
    /// Measured here the same day: a widened panel takes 15–25 ms and several
    /// runloop turns to reach the window server, and no synchronous flush
    /// brings it forward — while `panel.frame.contains(point)` is true the
    /// instant `setFrame` returns. The old code widened and posted in one
    /// synchronous block and read the second fact as the first.
    func testNoSyntheticDownIsPostedUntilTheServerOwnsTheSeedPoint() {
        let rig = Rig()
        rig.environment.catchSurfaceOwnsSeedPoint = false
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()

        XCTAssertTrue(rig.environment.syntheticButtonPosts.isEmpty,
                      "posted while the server still gives that point to "
                        + "another application, the down presses a button in "
                        + "somebody else's window")
        XCTAssertEqual(rig.environment.catchChanges, [true],
                       "the surface is still widened; it is the POST that "
                        + "waits")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("holding the synthetic primary down until the "
                + "window server")
        })

        rig.deliverRealDragEvent()
        XCTAssertTrue(rig.environment.syntheticButtonPosts.isEmpty,
                      "a real event is not the thing that was missing")
        XCTAssertTrue(rig.environment.fileDrags.isEmpty,
                      "and no session may begin before the button is re-armed")
    }

    /// The other half: once the server takes the surface the handoff
    /// proceeds, in the pinned order, from the real event that arrived while
    /// it was still catching up. That event is KEPT rather than dropped — it
    /// is the scarce thing on this path.
    func testTheHeldEventStartsTheDragOnceTheServerTakesTheSurface() throws {
        let rig = Rig()
        rig.environment.catchSurfaceOwnsSeedPoint = false
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent(eventNumber: 9182)

        rig.environment.catchSurfaceOwnsSeedPoint = true
        rig.deliverHeldSampleWithoutEvent()

        XCTAssertEqual(rig.environment.fileDrags.first?.event.eventNumber,
                       9182,
                       "the drag must start from the real event held back "
                        + "while the server caught up, not wait for another")
        let rearm = try XCTUnwrap(
            rig.ledger.steps.firstIndex(of: .sessionButtonRearmed))
        let session = try XCTUnwrap(
            rig.ledger.steps.firstIndex(of: .hostDragBegan))
        XCTAssertLessThan(rearm, session,
                          "the order this whole path exists to hold")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("the catch surface owns the seed point")
                && $0.1.contains("ownsPoint=yes")
        })
    }

    /// A surface the server never takes is an ERROR naming the consequence.
    /// It keeps trying — the release ends it either way — but a silence here
    /// reads exactly like a drag that never happened.
    func testACatchSurfaceTheServerNeverTakesIsNamedOutLoud() {
        let rig = Rig()
        rig.environment.catchSurfaceOwnsSeedPoint = false
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        for _ in 0..<40 { rig.deliverHeldSampleWithoutEvent() }

        XCTAssertTrue(rig.recorder.lines.contains {
            $0.0 == .error
                && $0.1.contains("still does not own the seed point")
                && $0.1.contains("will not press a button into another "
                    + "application")
        })
        XCTAssertEqual(
            rig.recorder.lines.filter {
                $0.1.contains("still does not own the seed point")
            }.count, 1,
            "once, not per sample: a burst would bury the line that matters")
        XCTAssertTrue(rig.environment.syntheticButtonPosts.isEmpty)
    }

    /// **`ourWindow=yes` and `serverOwnsPoint=no` is the shape that shipped**,
    /// and the two must stay separable in the log. The seed this app
    /// CONSTRUCTS can carry our own panel while the window server still hands
    /// every real event at that point to somebody else — which is a tracking
    /// session with a frozen image, exactly what 13:43 produced.
    func testASeedTheServerDoesNotOwnIsNamedEvenWhenItIsOurWindow() {
        let rig = Rig()
        rig.environment.dragSeed = ContinuityDragSeed(
            eventType: 6, serverTopWindowNumber: 30, appActive: false,
            windowNumber: 77, panelWindowNumber: 77,
            resolvedToPanel: true, clickCount: 1, panelKey: true,
            panelCoversPoint: true)
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        XCTAssertFalse(rig.recorder.lines.contains {
            $0.1.contains("window this app does not own")
        }, "the anchor was ours; naming the wrong half sends the next round "
            + "after the wrong defect")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.0 == .error
                && $0.1.contains("the window server does not put the catch "
                    + "surface under the seed point")
        })
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.0 == .error && $0.1.contains("host drag session seed")
                && $0.1.contains("ourWindow=yes")
                && $0.1.contains("serverOwnsPoint=no")
                && $0.1.contains("appActive=no")
        })
    }

    /// The pending handoff is a real handoff, so it re-arms the session
    /// button state exactly as a bound one does — and for the same reason:
    /// this app's own tap swallowed the physical down, and an
    /// `NSDraggingSession` is driven by session state rather than the HID's.
    /// A cross that refuses outright (`superseded`) still posts nothing.
    func testAPendingHandoffArmsTheSessionAndARefusedCrossDoesNot() {
        let pending = Rig()
        pending.enterGuest()
        pending.press()
        pending.crossBackHolding()
        XCTAssertEqual(pending.environment.syntheticButtonPosts.count, 1)

        let refused = Rig()
        refused.select(Self.file(name: "hello.txt"), generation: 2)
        refused.enterGuest()
        refused.press()
        refused.selectAsOf(refused.now() - 1, Self.file(name: "main.c"),
                           generation: 3)
        refused.crossBackHolding()
        XCTAssertTrue(refused.environment.syntheticButtonPosts.isEmpty,
                      "an ambiguous cross refuses; late bind is not a way "
                        + "to reopen a refusal")
    }

    /// The tap has no NSEvent by construction, and the physical button is
    /// still held — so the crossing WAITS rather than synthesizing one.
    func testTheDragWaitsForARealEventInsteadOfInventingOne() {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()

        XCTAssertTrue(rig.environment.fileDrags.isEmpty,
                      "no real event yet means no drag session at all")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("waiting for the catch surface and the first real "
                + "host mouse event")
        })
        XCTAssertEqual(rig.environment.catchChanges.first, true,
                       "two pixels cannot catch a moving pointer")

        rig.deliverRealDragEvent(eventNumber: 9182)
        XCTAssertEqual(rig.environment.fileDrags.first?.event.eventNumber,
                       9182)
        XCTAssertEqual(rig.environment.catchChanges, [true],
                       "the surface stays wide for the length of the session: "
                        + "narrowing it here moves the drag source's own "
                        + "window out from under a live drag")

        rig.endHostDragSession(operation: .copy)
        XCTAssertEqual(rig.environment.catchChanges, [true, false],
                       "the wide surface belongs to one handoff only")
    }

    /// **WIDE and HIT-TESTABLE are two different questions**, and the fix
    /// for the felt drop dead zone answers only the second one.
    ///
    /// The strip stays WIDE for the length of the session — asserted above
    /// — because narrowing it moves the drag source's own window out from
    /// under a live drag. But `EdgeView.isOwnSession` refuses the strip's
    /// own drag rather than passing it through, and a refusal still
    /// answers the drag: no `+` badge, and nothing else is asked. Michelle
    /// felt that refusal, at the shipped 160 px, as a drop dead zone the
    /// width of the whole strip. This asserts the controller turns the
    /// strip drop-transparent to ITS OWN session the instant that session
    /// actually starts, and restores it the instant the session ends — the
    /// two calls a real Mac needs so the badge is decided by whatever is
    /// really beneath the strip, not by the strip's own refusal.
    func testTheCatchSurfaceDropsThroughItsOwnLiveSessionOnly() {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()

        XCTAssertTrue(rig.environment.dropsThroughChanges.isEmpty,
                      "no session has started yet — nothing should be "
                        + "drop-transparent before there is a session to "
                        + "protect")

        rig.deliverRealDragEvent()
        XCTAssertEqual(rig.environment.dropsThroughChanges, [true],
                       "the session just started; the strip must stop "
                        + "intercepting its own drag from this instant")

        rig.endHostDragSession(operation: .copy)
        XCTAssertEqual(rig.environment.dropsThroughChanges, [true, false],
                       "drop-through belongs to one live session only — an "
                        + "ordinary foreign drag afterwards must still be "
                        + "caught and refused by identity")
    }

    /// A drag AppKit refuses to start never became drop-through in the
    /// first place, so there is nothing to undo — asserting the array
    /// stays empty is the same shape of guard as `catchChanges` staying at
    /// `[true, false]` above rather than growing a spurious third entry.
    func testARefusedDragNeverTogglesDropThrough() {
        let rig = Rig()
        rig.environment.dragSeed = nil
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        XCTAssertTrue(rig.environment.dropsThroughChanges.isEmpty,
                      "AppKit never started a session, so there was never a "
                        + "session's own refusal to fix")
    }

    /// **The strip must not catch the drag it just started.**
    ///
    /// Metal, 2026-08-14: the drag image appeared with a `.copy` badge and
    /// then went nowhere. That badge is this app's own answer — the widened
    /// catch surface is a registered destination for exactly the types the
    /// new session carries, so the first thing the session crossed was a
    /// destination of ours, which armed a host→guest pass and offered to
    /// copy the file straight back to the machine it was leaving.
    func testTheEdgeRefusesTheDragThisAppItselfStarted() throws {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()
        let callbacks = try XCTUnwrap(rig.environment.fileCallbacks)

        XCTAssertFalse(callbacks.entered(CGPoint(x: 1439, y: 450), .init(name: .drag)),
                       "the strip answered .copy to our own session and armed "
                        + "a pass back to the guest")
        XCTAssertFalse(callbacks.dropped(.init(name: .drag)),
                       "our own file must not land back on the guest")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("taking one FROM the guest")
        }, "the refusal must be named; silence here is the original symptom")
    }

    /// Nothing of ours reacts to the pointer once AppKit owns the gesture,
    /// and the end of the session is a fact in the log — the metal round had
    /// no line at all for a drag that started and then stalled.
    func testEverythingStandsDownWhileTheHostDragSessionIsLive() {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("stands down until the session ends")
        })

        /* Motion back toward the guest during the drag would otherwise
           re-enter and start steering the guest under the live session. The
           sample says the button is up because that is the shape that would
           re-enter: with the gate gone this is a fresh outward crossing. */
        rig.environment.emit(.init(kind: .moved,
                                   location: CGPoint(x: 1439, y: 450),
                                   delta: CGPoint(x: 30, y: 0),
                                   buttonsDown: false))
        XCTAssertEqual(rig.controller.state, .ready,
                       "a live drag session must not be able to re-enter the "
                        + "guest under itself")

        rig.endHostDragSession(operation: [])
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.0 == .warn && $0.1.contains("nothing accepted the file")
                && $0.1.contains("standDownSamples=1")
        }, "a drop that went nowhere and a promise that failed must not read "
            + "as the same silence")
    }

    /// `standDownSamples` counts what THIS APP saw, and on metal it read 0
    /// or 1 for every session in the 2026-08-15 15:27 build — over two to
    /// four seconds of hand motion. A count taken from a blind observer
    /// cannot say what ended a session, so the session's own stream is
    /// witnessed beside it.
    func testTheEndOfSessionLineNamesWhatEndedIt() {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()
        XCTAssertEqual(rig.environment.dragWitnessStarts, 1,
                       "the witness must be armed with the session, not "
                        + "after it")

        var witness = ContinuityDragWitness(installed: true)
        witness.record(Self.witnessed(type: 6, at: rig.now() - 0.5))
        witness.record(Self.witnessed(type: 2, at: rig.now(), pid: 77))
        rig.environment.dragWitness = witness
        rig.controller.hostProcessIdentifier = { 77 }
        rig.endHostDragSession(operation: [])

        XCTAssertEqual(rig.environment.dragWitnessStops, 1,
                       "a witness left running outlives the session it "
                        + "describes")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("host drag session end witness")
                && $0.1.contains("ended by a session leftMouseUp")
                && $0.1.contains("(this app)")
        }, rig.recorder.lines.map(\.1).joined(separator: "\n"))
    }

    /// The shape the 2026-08-15 rounds actually produced — a session that
    /// ended while the button was still physically held — must not be
    /// reported at the same level as an ordinary release.
    func testASessionEndingUnderAHeldButtonIsAnError() {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        var witness = ContinuityDragWitness(installed: true)
        witness.record(Self.witnessed(type: 6, at: rig.now() - 0.2))
        rig.environment.dragWitness = witness
        /* Set only now: the same reader decides whether a held handback is
           an echo, and this test is about the END of the session. */
        rig.controller.physicalPrimaryButtonHeld = { true }
        rig.controller.sessionPrimaryButtonHeld = { false }
        rig.endHostDragSession(operation: [])

        XCTAssertTrue(rig.recorder.lines.contains {
            $0.0 == .error && $0.1.contains("host drag session end witness")
                && $0.1.contains(
                    "NO session-level leftMouseUp was seen at all")
        }, rig.recorder.lines.map(\.1).joined(separator: "\n"))
    }

    /// Said before the session as well as after it. A witness that could not
    /// arm is a fact about the next four seconds, and learning it only
    /// afterwards is learning it too late to move the mouse differently.
    func testARefusedWitnessIsAnnouncedBeforeTheSessionAndNotOnlyAfter() {
        let rig = Rig()
        rig.environment.dragWitnessAvailable = false
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        XCTAssertTrue(rig.recorder.lines.contains {
            $0.0 == .warn && $0.1.contains("no drag-session witness")
        }, "the refusal has to be on the record while the drag is still in "
            + "flight")
        rig.endHostDragSession(operation: [])
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("host drag session end witness")
                && $0.1.contains("no witness was installed")
        }, rig.recorder.lines.map(\.1).joined(separator: "\n"))
    }

    /// Beside whose WINDOW the seed arrived at, whose PROCESS put it in the
    /// stream. Without it the log cannot distinguish a real host event from
    /// this app's own synthetic re-arm, which is the candidate the current
    /// build hands to `beginDraggingSession` every single time.
    func testTheSeedEventSaysWhetherThisAppPostedIt() {
        let rig = Rig()
        rig.controller.hostProcessIdentifier = { 90210 }
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("host drag seed event")
                && $0.1.contains("postedByThisApp=no")
        }, rig.recorder.lines.map(\.1).joined(separator: "\n"))
    }

    private static func witnessed(type: UInt32, at uptime: TimeInterval,
                                  pid: Int64 = 0)
        -> ContinuityWitnessedEvent {
        ContinuityWitnessedEvent(
            type: type, location: CGPoint(x: 1520, y: 379), sourcePID: pid,
            sourceStateID: pid == 0 ? 1 : 0, uptime: uptime,
            hidPrimaryHeld: true, sessionPrimaryHeld: false)
    }

    /// The seed's provenance, because a global monitor hands over events
    /// belonging to OTHER applications and that is the first thing to rule
    /// out when a session starts and then does nothing.
    func testTheSeedEventProvenanceIsRecorded() {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("host drag seed event")
                && $0.1.contains("ourWindow=no")
        }, "the log must say whose window the gesture came from")
    }

    /// The line round 2 did not have. The trigger event is foreign by
    /// construction, so `ourWindow=no` on it is ordinary; the question that
    /// mattered — and went unasked while the drag image froze for 101
    /// stand-down samples — is whose window the SESSION was anchored to.
    func testTheConstructedSeedIsAuditedAsOurOwnWindow() {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("host drag session seed")
                && $0.1.contains("ourWindow=yes")
        }, "the seed's own provenance must be recorded, not inferred from "
            + "the trigger event's")
    }

    /// And when it is not ours, it is an ERROR that names the consequence —
    /// the exact metal symptom, so the next audit log reads as a diagnosis
    /// rather than as three unexplained facts.
    func testAForeignAnchoredSessionIsNamedAsAnError() {
        let rig = Rig()
        rig.environment.dragSeed = ContinuityDragSeed(
            eventType: 6, windowNumber: 14932, panelWindowNumber: 77,
            resolvedToPanel: false, clickCount: 1, panelKey: false,
            panelCoversPoint: false)
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        XCTAssertTrue(rig.recorder.lines.contains {
            $0.0 == .error && $0.1.contains("window this app does not own")
        })
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("host drag session seed")
                && $0.1.contains("ourWindow=no")
        })
    }

    /// FIX A against real AppKit rather than against a fake: the seed is
    /// built from the real event's location, timestamp and flags but
    /// carries the CATCH PANEL's window number. Measured on metal (round 2)
    /// as `windowNumber=14932, ourWindow=no` — a window belonging to
    /// whatever the returning pointer was above.
    ///
    /// It asserts the seed rather than a live session on purpose: starting
    /// one in a test process would hand the run to a drag loop with no
    /// mouse behind it.
    func testTheSeedCarriesThePanelsWindowAndNotTheEventsOwn() throws {
        let host = HostDisplayDescriptor(
            id: 41, name: "Studio Display",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            pixelSize: CGSize(width: 5120, height: 2880), isPrimary: true)
        let fileEdge = ContinuityFileEdge(
            edge: .init(host: host, guestSide: .left, overlap: 0...900),
            callbacks: .init(entered: { _, _ in false }, exited: {},
                             dropped: { _ in false }))
        defer { fileEdge.close() }
        let foreign = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 10, y: 10),
            modifierFlags: [.shift], timestamp: 12, windowNumber: 14932,
            context: nil, eventNumber: 4242, clickCount: 1, pressure: 1))

        let seed = try XCTUnwrap(
            fileEdge.makeDragSeed(at: CGPoint(x: 1380, y: 450),
                                  from: foreign))

        XCTAssertTrue(seed.ownWindow,
                      "AppKit anchors the session to the seed's window; a "
                        + "foreign one freezes the drag image where it stood")
        XCTAssertNotEqual(seed.windowNumber, foreign.windowNumber)
        XCTAssertEqual(seed.eventType,
                       NSEvent.EventType.leftMouseDragged.rawValue)
        XCTAssertTrue(seed.panelCoversPoint,
                      "a seed anchored to our window at a point outside it "
                        + "is the next shape of the same defect")
        XCTAssertTrue(seed.summary.contains("ourWindow=yes"))
    }

    /// `catchThickness` is now configurable, and this is the geometry math
    /// against a real AppKit panel: the same seed point covered at the
    /// shipped 160 px default must NOT be covered at zero, because zero
    /// means the strip never widens past the ordinary two-pixel sentinel
    /// at all — cursor-at-the-very-edge handoff, exactly as asked for.
    func testConfiguredCatchThicknessChangesWhatThePanelCovers() throws {
        let host = HostDisplayDescriptor(
            id: 41, name: "Studio Display",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            pixelSize: CGSize(width: 5120, height: 2880), isPrimary: true)
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 10, y: 10),
            modifierFlags: [], timestamp: 12, windowNumber: 14932,
            context: nil, eventNumber: 4242, clickCount: 1, pressure: 1))
        // 160 px in from the left host's right edge (1440): 1280...1440.
        let seedPoint = CGPoint(x: 1380, y: 450)

        let wide = ContinuityFileEdge(
            edge: .init(host: host, guestSide: .left, overlap: 0...900),
            catchThickness: 160,
            callbacks: .init(entered: { _, _ in false }, exited: {},
                             dropped: { _ in false }))
        defer { wide.close() }
        let wideSeed = try XCTUnwrap(wide.makeDragSeed(at: seedPoint,
                                                       from: event))
        XCTAssertTrue(wideSeed.panelCoversPoint,
                      "1380 is 60px in from the edge — inside the 160px "
                        + "catch surface")

        let zero = ContinuityFileEdge(
            edge: .init(host: host, guestSide: .left, overlap: 0...900),
            catchThickness: 0,
            callbacks: .init(entered: { _, _ in false }, exited: {},
                             dropped: { _ in false }))
        defer { zero.close() }
        let zeroSeed = try XCTUnwrap(zero.makeDragSeed(at: seedPoint,
                                                       from: event))
        XCTAssertFalse(zeroSeed.panelCoversPoint,
                       "at zero the strip never widens beyond the ordinary "
                         + "sentinel, so the same point 60px off the "
                         + "physical edge is no longer covered")
    }

    /// **A window the window server cannot see is not a catch surface.**
    ///
    /// The strip was `backgroundColor = .clear` over a view that draws
    /// nothing — every pixel at alpha zero — and the server routes mouse
    /// events straight through such a window.
    /// `NSWindow.windowNumber(at:)` never returned it, at any delay,
    /// deterministically over three rounds; frontness and key state made no
    /// difference and only the alpha did (measured 2026-08-15). That is why
    /// the synthetic down landed on the Finder desktop.
    ///
    /// Asserted against a real AppKit panel because both properties it reads
    /// are exactly the pair whose defaults look harmless in a diff.
    func testTheCatchPanelIsSomethingTheWindowServerCanHitTest() {
        let host = HostDisplayDescriptor(
            id: 41, name: "Studio Display",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            pixelSize: CGSize(width: 5120, height: 2880), isPrimary: true)
        let fileEdge = ContinuityFileEdge(
            edge: .init(host: host, guestSide: .left, overlap: 0...900),
            callbacks: .init(entered: { _, _ in false }, exited: {},
                             dropped: { _ in false }))
        defer { fileEdge.close() }

        XCTAssertTrue(fileEdge.catchSurfaceIsHitTestable,
                      "a fully transparent strip is a hole the seeding down "
                        + "falls through onto whatever is underneath")
        XCTAssertGreaterThan(ContinuityFileEdge.hitTestableAlpha, 0)
        XCTAssertLessThan(ContinuityFileEdge.hitTestableAlpha, 0.01,
                          "and it must stay below a visible tint: this strip "
                            + "sits over another app's window all day")
    }

    /// Against a real AppKit panel, not the mock: `catchSurfaceIsHitTestable`
    /// already reads `!panel.ignoresMouseEvents` as half of what makes the
    /// strip a valid destination — this is the other half of that same
    /// fact, that setting it TRUE is exactly what un-hit-tests the strip,
    /// which is the mechanism `setDropsThroughOwnSession` exists to drive.
    func testDropsThroughOwnSessionMakesTheStripNotHitTestableAndBackAgain() {
        let host = HostDisplayDescriptor(
            id: 41, name: "Studio Display",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            pixelSize: CGSize(width: 5120, height: 2880), isPrimary: true)
        let fileEdge = ContinuityFileEdge(
            edge: .init(host: host, guestSide: .left, overlap: 0...900),
            callbacks: .init(entered: { _, _ in false }, exited: {},
                             dropped: { _ in false }))
        defer { fileEdge.close() }
        XCTAssertTrue(fileEdge.catchSurfaceIsHitTestable,
                      "the ordinary state: a foreign drag must still be able "
                        + "to reach this destination")

        fileEdge.setDropsThroughOwnSession(true)
        XCTAssertFalse(fileEdge.catchSurfaceIsHitTestable,
                       "drop-through means the window server routes the "
                         + "OWN session's drag query straight past this "
                         + "panel to whatever is really underneath")

        fileEdge.setDropsThroughOwnSession(false)
        XCTAssertTrue(fileEdge.catchSurfaceIsHitTestable,
                      "restored the instant the live session ends, so the "
                        + "strip goes back to being an ordinary destination "
                        + "for the NEXT foreign drag")
    }

    /// The seed-time audit line carries the three facts that separate the
    /// failures a single frozen drag image could mean: the panel never went
    /// key, the window server never handed us the point, or this app was
    /// never front.
    func testTheSeedNamesKeyServerAndActivationTogether() throws {
        let host = HostDisplayDescriptor(
            id: 41, name: "Studio Display",
            frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
            pixelSize: CGSize(width: 5120, height: 2880), isPrimary: true)
        let fileEdge = ContinuityFileEdge(
            edge: .init(host: host, guestSide: .left, overlap: 0...900),
            callbacks: .init(entered: { _, _ in false }, exited: {},
                             dropped: { _ in false }))
        defer { fileEdge.close() }
        let event = try XCTUnwrap(NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 10, y: 10),
            modifierFlags: [], timestamp: 12, windowNumber: 14932,
            context: nil, eventNumber: 4242, clickCount: 1, pressure: 1))

        let seed = try XCTUnwrap(
            fileEdge.makeDragSeed(at: CGPoint(x: 1380, y: 450), from: event))

        for fact in ["panelKey=", "panelCoversPoint=", "serverTopWindow=",
                     "serverOwnsPoint=", "appActive="] {
            XCTAssertTrue(seed.summary.contains(fact),
                          "the audit line must carry \(fact) or the next "
                            + "metal round cannot tell these apart")
        }
    }

    func testReleasingBeforeARealEventAbandonsTheDragOutLoud() {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.controller.physicalPrimaryButtonHeld = { false }
        rig.environment.emit(.init(kind: .primaryUp,
                                   location: CGPoint(x: 1300, y: 450),
                                   delta: .zero, buttonsDown: false))

        XCTAssertTrue(rig.environment.fileDrags.isEmpty)
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("abandoned") && $0.1.contains("released before")
        })
        XCTAssertEqual(rig.environment.catchChanges, [true, false])
    }

    /// **A sample claiming "released" while the hardware says held is an
    /// echo, not a release.**
    ///
    /// Metal, 2026-08-15 02:48: four bound crossings in a row abandoned in
    /// the SAME SECOND as the cross — `the button was released before this
    /// Mac saw a real mouse event` while Michelle was still holding the
    /// button. The waiting path read `buttonsDown` off the first
    /// monitor-delivered sample after the tap came down, and that field is
    /// derived from the window server's event state — which this app's own
    /// consuming tap has been poisoning all pass long, because a swallowed
    /// `leftMouseDown` never updates it. Only the HID level sits beneath
    /// our own tap.
    func testAMovedSampleClaimingReleaseWhileTheButtonIsHeldDoesNotAbandon()
        throws {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.controller.physicalPrimaryButtonHeld = { true }
        /* The first monitor echo after teardown: a warp-synthesized
           mouseMoved, buttonsDown read from the poisoned session state. */
        rig.environment.emit(.init(kind: .moved,
                                   location: CGPoint(x: 1300, y: 450),
                                   delta: CGPoint(x: -8, y: 0),
                                   buttonsDown: false))

        XCTAssertEqual(rig.environment.catchChanges, [true],
                       "the handoff was abandoned on an echo while the "
                        + "human was still holding the button")
        XCTAssertFalse(rig.recorder.lines.contains {
            $0.1.contains("abandoned")
        })
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("claims the button is up")
                && $0.1.contains("physically held")
        }, "the suspect echo must be audited with what was read, or the "
            + "next metal round is undiagnosable again")

        /* The real release, corroborated by the hardware, still ends it. */
        rig.controller.physicalPrimaryButtonHeld = { false }
        rig.environment.emit(.init(kind: .moved,
                                   location: CGPoint(x: 1300, y: 450),
                                   delta: .zero, buttonsDown: false))
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("abandoned")
        })
    }

    /// A real `primaryUp` outranks the hardware read: taken as the release
    /// goes by, the HID state can still say held, and honouring it would
    /// keep a press alive past its own end.
    func testARealPrimaryUpAbandonsEvenIfTheHardwareReadLags() {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.controller.physicalPrimaryButtonHeld = { true }
        rig.environment.emit(.init(kind: .primaryUp,
                                   location: CGPoint(x: 1300, y: 450),
                                   delta: .zero, buttonsDown: false))

        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("abandoned") && $0.1.contains("released before")
        })
    }

    // MARK: - The gesture's consent outlives the epoch

    /// **The press binds; the cache merely published.**
    ///
    /// The round-2 audit recorded `selection dropped: the Continuity epoch
    /// ended` as the pointer crossed BACK — which is when the epoch ends by
    /// design, before any drop could have happened. If fulfillment read the
    /// cache, every crossing would redeem nothing. It reads the copy taken
    /// at press time, and this is that fact asserted rather than assumed.
    func testTheBoundStubOutlivesTheCacheItWasPublishedIn() throws {
        let rig = Rig()
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.endEpochDroppingTheCache()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        let item = try XCTUnwrap(rig.environment.fileDrags.first?.item)
        let provider = try XCTUnwrap(item.writer as? NSFilePromiseProvider)
        let stub = try XCTUnwrap(provider.userInfo as? ContinuityDragStub)
        XCTAssertEqual(stub.epoch, 7)
        XCTAssertEqual(stub.generation, 3,
                       "the drag carries the generation it was BOUND under, "
                        + "not whatever the cache holds at drop time")
    }

    /// And the wire is asked with that bound pair, from a cache that no
    /// longer exists at all.
    func testFulfillmentAsksWithTheBoundEpochNotTheLiveOne() throws {
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let asked = Asked()
        let transfer = ContinuityGrabTransfer(
            grab: { epoch, generation, _, _, completion in
                asked.epoch = epoch
                asked.generation = generation
                completion(.failure(.init(code: "grant-expired",
                                          message: "too late")))
            }, audit: { _, _ in })
        let cache = ContinuitySelectionCache { _, _ in }
        cache.apply(Self.selection(epoch: 7, generation: 3,
                                   item: Self.file(name: "Read Me")),
                    activeEpoch: 7)
        let bound = try cache.bindable(activeEpoch: 7).get()
        let dragged = transfer.dragItem(for: bound)     /* press time */
        cache.clear(reason: "the Continuity epoch ended")
        XCTAssertNil(cache.stub)

        let provider = try XCTUnwrap(dragged.writer as? NSFilePromiseProvider)
        _ = fulfill(transfer, to: staging.appendingPathComponent("Read Me"),
                    provider: provider)

        XCTAssertEqual(asked.epoch, 7)
        XCTAssertEqual(asked.generation, 3)
    }

    // MARK: - Eager fetch for app drop targets
    //
    // Metal, 2026-08-15: the drag pasteboard carried only an
    // NSFilePromiseProvider, so Finder took the drop and every other
    // application refused it silently — a promise-only pasteboard reads as
    // nothing-droppable to anything that never adopted
    // NSFilePromiseReceiver. The host knows a stub's size before the drag
    // even starts, so a small one is fetched during the crossing and the
    // drag carries a real file:// URL instead — see
    // ContinuityFileDragPolicy for the cap this reads, and
    // ContinuityGrabTransfer.EagerFetch for why resolving it must never
    // block.

    func testEagerEligibilityIsExactlyAtTheCapBoundary() {
        let cap = ContinuityFileDragPolicy.eagerFetchCapBytes
        XCTAssertTrue(ContinuityFileDragPolicy.eligibleForEagerFetch(
            dataSize: cap, resourceSize: 0), "the cap itself is eligible")
        XCTAssertFalse(ContinuityFileDragPolicy.eligibleForEagerFetch(
            dataSize: cap + 1, resourceSize: 0),
            "one byte over must not round down into eligibility")
        XCTAssertTrue(ContinuityFileDragPolicy.eligibleForEagerFetch(
            dataSize: cap / 2, resourceSize: cap / 2),
            "the two forks must be summed, not checked separately")
        XCTAssertFalse(ContinuityFileDragPolicy.eligibleForEagerFetch(
            dataSize: cap / 2, resourceSize: cap / 2 + 1))
    }

    /// The design's small-file path, start to finish: a stub under the cap
    /// gets a real fetch started immediately, and once that fetch finishes
    /// the drag's writer is a real file, not a promise.
    func testASmallStubStartsAnEagerFetchAndTheDragCarriesARealFileURL()
        throws {
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let delivery = try Self.delivery(name: "Read Me",
                                         bytes: Data("hello".utf8),
                                         in: staging)
        var audits: [(HostLog.LogLevel, String)] = []
        let fetched = expectation(description: "eager fetch completed")
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in completion(.success(delivery)) },
            audit: {
                audits.append(($0, $1))
                if $1.contains("eager fetch completed") { fetched.fulfill() }
            })
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: Self.file(name: "Read Me"))

        let item = transfer.dragItem(for: stub)
        XCTAssertNotNil(item.resolve,
                        "a stub under the cap must attempt an eager fetch")
        XCTAssertTrue(audits.contains {
            $0.1.contains("drag payload: eager") && $0.1.contains("5 bytes")
                && $0.1.contains("fetching during the crossing")
        }, "the decision must be logged the instant it is made, not only "
            + "once it resolves")
        wait(for: [fetched], timeout: 5)

        let resolved = item.finalized()
        let url = try XCTUnwrap(resolved.writer as? NSURL,
                                "a finished eager fetch must hand the drag "
                                    + "a real file, not a promise")
        XCTAssertEqual(try String(contentsOf: url as URL, encoding: .utf8),
                       "hello")
        XCTAssertTrue(audits.contains {
            $0.1.contains("drag payload: eager") && $0.1.contains("bytes")
                && $0.1.contains("fetched in") && $0.1.contains("ms")
                && $0.1.contains("using a real file URL, not a promise")
        })
    }

    /// The other half of the cap: a large stub must never even attempt a
    /// grab from `dragItem` — that grab belongs to the promise alone, on
    /// release, exactly as before this slice existed.
    func testAStubOverTheCapNeverAttemptsAnEagerFetch() {
        var audits: [(HostLog.LogLevel, String)] = []
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, _ in
                XCTFail("a stub over the cap must never start a grab from "
                    + "dragItem")
            }, audit: { audits.append(($0, $1)) })
        var oversized = Self.file(name: "Big File")
        oversized.dataSize = ContinuityFileDragPolicy.eagerFetchCapBytes + 1
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: oversized)

        let item = transfer.dragItem(for: stub)

        XCTAssertNil(item.resolve)
        XCTAssertTrue(item.writer is NSFilePromiseProvider)
        XCTAssertTrue(audits.contains {
            $0.1.contains("drag payload: promise") && $0.1.contains("over cap")
        })
    }

    /// **Resolving must never block**, however far from finished the fetch
    /// still is. Everything in this app — including the wire listener the
    /// fetch itself asks — runs on the main actor; a synchronous wait here
    /// would be this app deadlocking against its own completion.
    func testAnEagerFetchStillPendingAtDragStartFallsBackWithoutBlocking() {
        var audits: [(HostLog.LogLevel, String)] = []
        let held = Held()
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in held.completion = completion },
            audit: { audits.append(($0, $1)) })
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: Self.file(name: "Read Me"))

        let item = transfer.dragItem(for: stub)
        XCTAssertNotNil(item.resolve)

        let start = Date()
        let resolved = item.finalized()
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.1,
                          "resolving must never block on a fetch still in "
                            + "flight")
        XCTAssertTrue(resolved.writer is NSFilePromiseProvider,
                      "an unfinished fetch must fall back to the promise "
                        + "rather than hold the drag up")
        XCTAssertTrue(audits.contains {
            $0.0 == .warn
                && $0.1.contains("had not finished when the drag started")
        })
        XCTAssertNotNil(held.completion,
                        "the fetch is not cancelled, only not waited for — "
                            + "it may still finish and simply go unused")
    }

    /// A refusal from the Mac (a stale selection, a bad epoch) must fall
    /// back exactly like a slow one, named by its own code — indistinguishable
    /// from a dead fetch is the failure mode `ContinuityGrabTransfer`'s
    /// other refusal paths were built to avoid, and this path inherits it.
    func testAFailedEagerFetchFallsBackToThePromiseAndIsNamed() {
        var audits: [(HostLog.LogLevel, String)] = []
        let refused = expectation(description: "eager fetch refused")
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in
                completion(.failure(.init(code: "stale-selection",
                                          message: "the selection changed")))
            },
            audit: {
                audits.append(($0, $1))
                if $1.contains("eager fetch refused by the Mac") {
                    refused.fulfill()
                }
            })
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: Self.file(name: "Read Me"))

        let item = transfer.dragItem(for: stub)
        wait(for: [refused], timeout: 5)

        let resolved = item.finalized()
        XCTAssertTrue(resolved.writer is NSFilePromiseProvider)
        XCTAssertTrue(audits.contains {
            $0.1.contains("eager fetch refused by the Mac")
                && $0.1.contains("stale-selection")
        })
    }

    /// One grab lane, shared with the promise machinery: a stub bound while
    /// another grab is already in flight must not attempt a second one —
    /// that is what `ContinuityGrabTransfer.isBusy` already refuses on the
    /// promise side, and the eager lane must honor the same one-at-a-time
    /// rule rather than opening a second wire request underneath it.
    func testABusyGrabLaneSkipsTheEagerFetchAndUsesThePromiseOutright() {
        var audits: [(HostLog.LogLevel, String)] = []
        let asked = expectation(description: "the first grab reached the wire")
        let held = Held()
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in
                held.completion = completion
                asked.fulfill()
            }, audit: { audits.append(($0, $1)) })
        let busyStub = ContinuityDragStub(epoch: 7, generation: 1,
                                          item: Self.file(name: "First"))
        let first = transfer.promise(for: busyStub)
        transfer.filePromiseProvider(
            first, writePromiseTo: FileManager.default.temporaryDirectory
                .appendingPathComponent("First")) { _ in }
        wait(for: [asked], timeout: 5)
        XCTAssertTrue(transfer.isBusy)

        let secondStub = ContinuityDragStub(epoch: 7, generation: 2,
                                            item: Self.file(name: "Second"))
        let item = transfer.dragItem(for: secondStub)

        XCTAssertNil(item.resolve)
        XCTAssertTrue(audits.contains {
            $0.1.contains("eager fetch skipped")
                && $0.1.contains("already in flight")
        })
        _ = held
    }

    /// End to end through the real controller wiring, not `dragItem`
    /// called directly: the fetch that started at press time has finished
    /// by the time the crossing hands AppKit the drag, and the item that
    /// reaches AppKit is a real file.
    func testTheControllerHandsAppKitARealFileWhenTheFetchWonTheRace()
        throws {
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let delivery = try Self.delivery(name: "Read Me",
                                         bytes: Data("hello".utf8),
                                         in: staging)
        let rig = Rig(grabRequest: { _, _, _, _, completion in
            completion(.success(delivery))
        })
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        waitForAudit(rig, containing: "eager fetch completed")
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        let item = try XCTUnwrap(rig.environment.fileDrags.first?.item)
        let url = try XCTUnwrap(item.writer as? NSURL,
                                "the fetch finished before the drag "
                                    + "started; AppKit must have been "
                                    + "handed the real file, not a promise")
        XCTAssertEqual(try String(contentsOf: url as URL, encoding: .utf8),
                       "hello")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("using a real file URL, not a promise")
        })
    }

    /// The same race lost: nothing waits, so the ordinary promise still
    /// reaches AppKit and the drag is not held up a moment for it.
    func testTheControllerFallsBackToThePromiseWhenTheFetchIsStillPending()
        throws {
        let held = Held()
        let rig = Rig(grabRequest: { _, _, _, _, completion in
            held.completion = completion   /* never answers in this test */
        })
        rig.select(Self.file(name: "Read Me"))
        rig.enterGuest()
        rig.press()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        let item = try XCTUnwrap(rig.environment.fileDrags.first?.item)
        XCTAssertTrue(item.writer is NSFilePromiseProvider)
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.0 == .warn
                && $0.1.contains("had not finished when the drag started")
        })
        _ = held
    }

    private func waitForAudit(_ rig: Rig, containing text: String,
                              timeout: TimeInterval = 5) {
        let predicate = NSPredicate { _, _ in
            rig.recorder.lines.contains { $0.1.contains(text) }
        }
        let met = XCTNSPredicateExpectation(predicate: predicate,
                                            object: NSObject())
        wait(for: [met], timeout: timeout)
    }

    // MARK: - Fulfillment

    func testGrabWritesTheFileAndReportsWhatArrived() throws {
        var audits: [(HostLog.LogLevel, String)] = []
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let destination = staging.appendingPathComponent("Read Me")
        let delivery = try Self.delivery(name: "Read Me",
                                         bytes: Data("hello".utf8),
                                         in: staging)
        let asked = Asked()
        let transfer = ContinuityGrabTransfer(
            grab: { epoch, generation, _, _, completion in
                asked.epoch = epoch
                asked.generation = generation
                completion(.success(delivery))
            }, audit: { audits.append(($0, $1)) })
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: Self.file(name: "Read Me"))

        let failure = fulfill(transfer, to: destination, stub: stub)

        XCTAssertNil(failure)
        XCTAssertEqual(asked.epoch, 7)
        XCTAssertEqual(asked.generation, 3,
                       "a grab is bound to one generation, never to a name")
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8),
                       "hello")
        XCTAssertTrue(audits.contains { $0.1.contains("grab completed") })
        XCTAssertFalse(transfer.isBusy)
    }

    /// `stale-selection` is the guest refusing a grant it will not honour.
    /// It must reach macOS as a FAILED promise and the log as a named line —
    /// unnamed, it reads exactly like a dead wire.
    func testStaleSelectionRefusalFailsThePromiseAndIsNamed() throws {
        var audits: [(HostLog.LogLevel, String)] = []
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in
                completion(.failure(.init(code: "stale-selection",
                                          message: "the selection changed")))
            }, audit: { audits.append(($0, $1)) })
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: Self.file(name: "Read Me"))

        let failure = fulfill(transfer,
                              to: staging.appendingPathComponent("Read Me"),
                              stub: stub)

        XCTAssertEqual(failure as? ContinuityGrabTransfer.GrabError,
                       .wire(code: "stale-selection",
                             message: "the selection changed"))
        XCTAssertTrue(audits.contains {
            $0.0 == .error && $0.1.contains("stale-selection")
                && $0.1.contains("generation=3")
        }, "a refusal without its code is indistinguishable from silence")
        XCTAssertFalse(transfer.isBusy,
                       "a refusal must release the lane, or one bad drag "
                        + "wedges every later one")
    }

    /// The refusal above is named in the log, but nothing on screen used to
    /// say it — `notice` was `@Published` to nobody. `outcomeSink` is the
    /// forwarding seam `ContinuityFileDrag.configure` wires to
    /// `edge.reportFileGrabOutcome`; this pins that EVERY terminal outcome
    /// reaches it, not just the ones already covered by an audit line.
    func testAWrongFileRefusalReachesTheOutcomeSinkInPlainWords() throws {
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in
                completion(.failure(.init(code: "stale-selection",
                                          message: "the selection changed")))
            })
        var sunk: [String] = []
        transfer.outcomeSink = { sunk.append($0) }
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: Self.file(name: "Read Me"))

        _ = fulfill(transfer, to: staging.appendingPathComponent("Read Me"),
                   stub: stub)

        XCTAssertEqual(sunk, [transfer.notice])
        /* Composed through MachineNaming rather than spelled out, because
           the literal is what this assertion is FOR: it must keep saying a
           plain sentence rather than the wire's own code, and it must not
           also become the second place the product's noun for the driven
           machine is written down. It was a literal until 2026-08-16, when
           the tree-wide rename to "the guest" landed on the sentence and
           left this one copy behind. */
        XCTAssertEqual(sunk.first, MachineNaming.startingSentence(
            "the selection on \(MachineNaming.simpleReference) changed "
            + "before the file could be copied."),
            "a wrong-file refusal must reach the person in a plain "
                + "sentence, not the wire's own code")
    }

    /// The same seam for the ordinary success path — not required by the
    /// bug this exists for, but a sink that only ever fires on failure
    /// would be a second, narrower promise than the one `notice` already
    /// made.
    func testACompletedGrabAlsoReachesTheOutcomeSink() throws {
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let destination = staging.appendingPathComponent("Read Me")
        let delivery = try Self.delivery(name: "Read Me",
                                         bytes: Data("hello".utf8),
                                         in: staging)
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in completion(.success(delivery)) })
        var sunk: [String] = []
        transfer.outcomeSink = { sunk.append($0) }
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: Self.file(name: "Read Me"))

        _ = fulfill(transfer, to: destination, stub: stub)

        XCTAssertEqual(sunk, [transfer.notice])
    }

    /// `refusalSink` is the narrower sibling `ContinuityFileDrag.configure`
    /// wires to a system notification plus the menu-bar flash — the two
    /// surfaces a person mid-drag is actually looking at, not the
    /// Continuity page's own status line. It must fire with the SAME
    /// sentence `outcomeSink` gets, so a notification banner and the status
    /// line can never disagree about why a drag ended.
    func testAWrongFileRefusalReachesTheRefusalSinkTooWithTheSameSentence()
        throws {
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in
                completion(.failure(.init(code: "stale-selection",
                                          message: "the selection changed")))
            })
        var refused: [String] = []
        transfer.refusalSink = { refused.append($0) }
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: Self.file(name: "Read Me"))

        _ = fulfill(transfer, to: staging.appendingPathComponent("Read Me"),
                   stub: stub)

        XCTAssertEqual(refused, [transfer.notice],
                       "the refusal sink must carry exactly the sentence "
                           + "the status line got, never a second draft")
    }

    /// The negative half of the test above: a grab that SUCCEEDS must not
    /// ring the refusal sink. Firing it on success would interrupt a
    /// person with a notification for the ordinary case where their file
    /// arrived exactly as asked — the opposite of what `refusalSink` exists
    /// to be narrower than `outcomeSink` for.
    func testACompletedGrabDoesNotReachTheRefusalSink() throws {
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let destination = staging.appendingPathComponent("Read Me")
        let delivery = try Self.delivery(name: "Read Me",
                                         bytes: Data("hello".utf8),
                                         in: staging)
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in completion(.success(delivery)) })
        var refused: [String] = []
        transfer.refusalSink = { refused.append($0) }
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: Self.file(name: "Read Me"))

        _ = fulfill(transfer, to: destination, stub: stub)

        XCTAssertTrue(refused.isEmpty,
                      "a completed grab must not ring the refusal sink")
    }

    /// The third way a grab ends badly: the wire honoured the redemption
    /// but this Mac could not WRITE what arrived — a destination directory
    /// that no longer exists is the easiest way to force `FileConverter
    /// .materialize` to throw. This must reach `refusalSink` exactly like
    /// a wire refusal does; a person watching for "did my drag fail" does
    /// not care which half of the trip went wrong.
    func testAWriteFailureAfterAHonouredGrabAlsoReachesTheRefusalSink()
        throws {
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let delivery = try Self.delivery(name: "Read Me",
                                         bytes: Data("hello".utf8),
                                         in: staging)
        let vanished = staging.appendingPathComponent(
            "gone-\(UUID().uuidString)", isDirectory: true)
        let destination = vanished.appendingPathComponent("Read Me")
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in completion(.success(delivery)) })
        var refused: [String] = []
        transfer.refusalSink = { refused.append($0) }
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: Self.file(name: "Read Me"))

        let thrown = fulfill(transfer, to: destination, stub: stub)

        XCTAssertNotNil(thrown,
                        "writing into a directory that does not exist "
                            + "must actually fail, or this test proves "
                            + "nothing")
        XCTAssertEqual(refused, [transfer.notice])
    }

    /// The eager fetch (started at press time) and the promise-fallback
    /// redemption (started at drop time) can both reach the wire for the
    /// SAME generation when the eager fetch has not finished by drop —
    /// ordinary, not guest flakiness, and the refusal noise this was meant
    /// to distinguish from a scheduled retry (there is no such thing here)
    /// is exactly two attempts on one generation's audit trail.
    func testTwoAttemptsOnOneGenerationAreNumberedAndNamedAsSeparate()
        throws {
        var audits: [(HostLog.LogLevel, String)] = []
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        let stub = ContinuityDragStub(epoch: 9, generation: 4,
                                      item: Self.file(name: "main.c"))
        let delivery = try Self.delivery(name: "main.c",
                                         bytes: Data("int main(){}".utf8),
                                         in: staging)

        /* Both attempts travel through ONE transfer, because the attempt
           counter is per-instance: attempt 1 is the eager fetch started at
           press time, held open so it can be refused on cue; attempt 2 is
           the promise-fallback redemption at drop time, which this test
           lets succeed — the exact "refused, then `grant honored` seconds
           later" shape the metal log reported. */
        let firstReached = expectation(description: "attempt one reached")
        let held = Held()
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in
                if held.completion == nil {
                    held.completion = completion
                    firstReached.fulfill()
                } else {
                    completion(.success(delivery))
                }
            }, audit: { audits.append(($0, $1)) })

        _ = transfer.dragItem(for: stub)
        wait(for: [firstReached], timeout: 5)
        held.completion?(.failure(.init(code: "stale-selection",
                                        message: "empty stub name")))

        let failure = fulfill(transfer,
                              to: staging.appendingPathComponent("main.c"),
                              stub: stub)
        XCTAssertNil(failure, "the second attempt is the one that succeeds")

        XCTAssertTrue(audits.contains {
            $0.1.contains("attempt=1") && $0.1.contains("eager fetch")
        }, "the first (eager) attempt must be numbered 1")
        XCTAssertTrue(audits.contains {
            $0.1.contains("attempt=2") && $0.1.contains("grab requested")
        }, "the second (promise-fallback) attempt for the SAME generation "
            + "must be numbered 2, not read as a first attempt")
        XCTAssertTrue(audits.contains {
            $0.1.contains("does not retry a refused grab on its own")
        }, "the host must say plainly that it never schedules the retry "
            + "itself — the second attempt is a separate lane, not a "
            + "retry loop")
    }

    func testOneGrabAtATime() throws {
        let staging = try Self.temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: staging) }
        var audits: [(HostLog.LogLevel, String)] = []
        let asked = expectation(description: "the first grab reached the wire")
        let held = Held()
        let transfer = ContinuityGrabTransfer(
            grab: { _, _, _, _, completion in
                held.completion = completion
                asked.fulfill()
            }, audit: { audits.append(($0, $1)) })
        let stub = ContinuityDragStub(epoch: 7, generation: 3,
                                      item: Self.file(name: "Read Me"))

        /* The first never answers, so the lane stays held. */
        let first = transfer.promise(for: stub)
        transfer.filePromiseProvider(
            first, writePromiseTo: staging.appendingPathComponent("a")
        ) { _ in }
        wait(for: [asked], timeout: 5)

        let second = fulfill(transfer,
                             to: staging.appendingPathComponent("b"),
                             stub: stub)
        XCTAssertEqual(second as? ContinuityGrabTransfer.GrabError, .busy)
        XCTAssertTrue(audits.contains { $0.1.contains("already in flight") })
        XCTAssertNotNil(held.completion)
    }

    // MARK: - Fixtures

    private final class Asked {
        var epoch: UInt32?
        var generation: UInt32?
    }

    private final class Held {
        var completion: ((Result<GuestListener.FileDelivery,
                                 GuestListener.FileFailure>) -> Void)?
    }

    private func fulfill(_ transfer: ContinuityGrabTransfer, to url: URL,
                         stub: ContinuityDragStub) -> Error? {
        fulfill(transfer, to: url, provider: transfer.promise(for: stub))
    }

    /// The same redemption from a provider built EARLIER — the one the drag
    /// has been carrying since the press.
    private func fulfill(_ transfer: ContinuityGrabTransfer, to url: URL,
                         provider: NSFilePromiseProvider) -> Error? {
        let done = expectation(description: "promise")
        let box = Held()
        var thrown: Error?
        _ = box
        transfer.filePromiseProvider(
            provider, writePromiseTo: url
        ) { error in
            thrown = error
            done.fulfill()
        }
        wait(for: [done], timeout: 5)
        return thrown
    }

    private static func selection(epoch: UInt32, generation: UInt32,
                                  item: ContinuitySelection.Item?)
        -> ContinuitySelection {
        .init(version: ContinuityContract.version, epoch: epoch,
              generation: generation, source: .selection, item: item)
    }

    fileprivate static func file(name: String) -> ContinuitySelection.Item {
        .init(name: name, volumeRef: -1, dirID: 2, fileType: "TEXT",
              creator: "ttxt", dataSize: 5, resourceSize: 0,
              modifiedAt: 3_400_000_000, isFolder: false, icon: nil)
    }

    fileprivate static func folder(name: String) -> ContinuitySelection.Item {
        .init(name: name, volumeRef: -1, dirID: 2, fileType: nil,
              creator: nil, dataSize: nil, resourceSize: nil,
              modifiedAt: nil, isFolder: true, icon: nil)
    }

    private static func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("now-grab-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(
            at: url, withIntermediateDirectories: true)
        return url
    }

    /// A real staged delivery, produced by the real sink: `StagedFile` owns
    /// its temporary and cannot be conjured, which is the point of it.
    private static func delivery(name: String, bytes: Data,
                                 in directory: URL) throws
        -> GuestListener.FileDelivery {
        let sink = try InboundFileSink(directory: directory,
                                       expectedBytes: bytes.count)
        try sink.append(bytes)
        return .init(name: name, container: "data", fileType: "TEXT",
                     creator: "ttxt", modified: nil,
                     staged: try sink.finish(expectedCRC32: nil),
                     transferMs: 1, crc32: nil, resumeToken: nil)
    }

    // MARK: - The carried drag's presentation

    /// A pasteboard carrying one real file, the way a Finder drag arrives.
    private static func fileDrag(_ url: URL) -> NSPasteboard {
        let board = NSPasteboard(name: .init("carry.\(UUID().uuidString)"))
        board.clearContents()
        board.writeObjects([url as NSURL])
        return board
    }

    /// **THE IDENTITY CROSSES AT THE CROSSING** — the plan's one early
    /// decision. The guest must be able to draw an honest drag, right name
    /// and right icon, before a single byte moves; `draggingEntered` is the
    /// only moment this side holds both the pointer and what is being
    /// carried, so a gesture that reached the edge without publishing here
    /// would have to publish from memory later or not at all.
    func testCarryingAFileToTheEdgePublishesItOnceForTheGuestToDraw() throws {
        let rig = Rig()
        var carried: [String] = []
        var released = 0
        rig.controller.configureHostDragPresentation(
            arrived: { board in
                carried.append(ContinuityFileDrag.firstFile(on: board)?
                    .lastPathComponent ?? "none")
            },
            departed: { released += 1 })
        let url = URL(fileURLWithPath: "/tmp/\(UUID().uuidString)/main.c")
        let callbacks = try XCTUnwrap(rig.environment.fileCallbacks)

        _ = callbacks.entered(CGPoint(x: 1439, y: 450),
                              Self.fileDrag(url))
        XCTAssertEqual(carried, ["main.c"])
        /* The strip is asked again on every motion of the drag. */
        _ = callbacks.entered(CGPoint(x: 1439, y: 460),
                              Self.fileDrag(url))
        _ = callbacks.entered(CGPoint(x: 1439, y: 470),
                              Self.fileDrag(url))
        XCTAssertEqual(carried, ["main.c"],
                       "the offer is published once per gesture, not once "
                        + "per draggingUpdated: a generation that moves on "
                        + "every mouse motion names nothing")
        XCTAssertEqual(released, 0)
    }

    /// **A DRAG THAT BEGINS ON THE GUEST AND IS NEVER TOLD TO STOP** is the
    /// failure classic Finder punishes hardest, so every departure path
    /// tears the presentation down — and each does it exactly once.
    func testEveryDeparturePathEndsThePresentationExactlyOnce() throws {
        for departure in ["exit", "drop"] {
            let rig = Rig()
            var carried = 0
            var released = 0
            rig.controller.configureHostDragPresentation(
                arrived: { _ in carried += 1 }, departed: { released += 1 })
            let callbacks = try XCTUnwrap(rig.environment.fileCallbacks)
            let url = URL(fileURLWithPath: "/tmp/x/main.c")

            _ = callbacks.entered(CGPoint(x: 1439, y: 450),
                                  Self.fileDrag(url))
            XCTAssertEqual(carried, 1, departure)
            switch departure {
            case "exit": callbacks.exited()
            default: _ = callbacks.dropped(Self.fileDrag(url))
            }
            XCTAssertEqual(released, 1,
                           "the guest is still drawing a drag after \(departure)")
            /* Idempotent: a strip can be told twice, and telling the guest
               to stop a drag it already stopped is a second refusal in the
               log for no reason. */
            callbacks.exited()
            XCTAssertEqual(released, 1, "torn down twice after \(departure)")
        }
    }

    /// The release backstop reaches the PICTURE too. `draggingExited`
    /// belongs to another application's session and can simply not arrive;
    /// a guest left drawing a drag for a gesture that ended is the visible
    /// half of the same stuck-flag defect.
    func testTheSelfHealingReleaseAlsoEndsThePresentation() throws {
        let rig = Rig()
        var held = true
        var released = 0
        rig.controller.physicalPrimaryButtonHeld = { held }
        rig.controller.configureHostDragPresentation(
            arrived: { _ in }, departed: { released += 1 })
        rig.enterGuest()
        _ = try XCTUnwrap(rig.environment.fileCallbacks)
            .entered(CGPoint(x: 1439, y: 450),
                     Self.fileDrag(URL(fileURLWithPath: "/tmp/x/main.c")))
        held = false
        rig.press()
        rig.crossBackHolding()

        XCTAssertEqual(released, 1,
                       "the drag ended where no callback could see it and "
                        + "the guest was left holding the picture")
    }

    /// A drag carrying no file this Mac can name publishes nothing, and
    /// that is an ordinary answer rather than a defect: a drag can hold
    /// text, a colour, or a promise whose file does not exist yet. The DROP
    /// still decides — the transfer lane reads the pasteboard again, and it
    /// understands promises this path deliberately does not.
    func testADragWithNoNameableFileDrawsNothingAndRefusesNothing() throws {
        let rig = Rig()
        var carried = 0
        rig.controller.configureHostDragPresentation(
            arrived: { _ in carried += 1 }, departed: {})
        let callbacks = try XCTUnwrap(rig.environment.fileCallbacks)

        let text = NSPasteboard(name: .init("text.\(UUID().uuidString)"))
        text.clearContents()
        text.setString("not a file", forType: .string)
        _ = callbacks.entered(CGPoint(x: 1439, y: 450), text)

        XCTAssertNil(ContinuityFileDrag.firstFile(on: text))
        XCTAssertEqual(carried, 1,
                       "the controller still announces the arrival; deciding "
                        + "there is nothing to draw belongs to the wiring, "
                        + "which is the only place that can say so once")
    }

    // MARK: - Two features, one crossing

    /// **THE 17:22 CONFLATION, AS IT HAPPENED.** Metal, 2026-08-16: Michelle
    /// held a drag of a file on THIS Mac and carried it toward the guest.
    /// The guest→host machinery ran backwards at her gesture — it bound the
    /// guest's stale cached selection, sent a primary down the guest Finder
    /// began dragging `main.c` under, started an AppKit session to bring
    /// that file HERE, and refused its own grab `stale-selection`. A whole
    /// pipeline's work, three refusals, and all of it about a file nobody
    /// had picked up, while the file she was actually holding went nowhere.
    ///
    /// The mechanism is a race between two honest reporters of one gesture.
    /// A held drag moves the pointer across the edge, so the sample stream
    /// and the strip's own `draggingEntered` both see it arrive, by
    /// different routes and in either order. When the samples win, the
    /// controller is already `.active`, `hostFileEntered` declines to steer,
    /// `hostFileDrag` stays false — and nothing left anywhere says a host
    /// drag exists. This pins that the FACT is recorded regardless of who
    /// won, and that the crossing then binds nothing and returns nothing.
    func testACrossingUnderAHostDragBindsNothingAndReturnsNothing() throws {
        let rig = Rig()
        rig.controller.physicalPrimaryButtonHeld = { true }
        rig.select(Self.file(name: "main.c"), generation: 3)
        /* The samples win the race: Continuity is already active and
           steering when the strip finally hears about the drag. */
        rig.enterGuest()
        XCTAssertEqual(rig.environment.fileCallbacks?
            .entered(CGPoint(x: 1439, y: 450), .init(name: .drag)), false,
            "an active controller does not start steering a second time — "
                + "and that refusal is exactly what used to lose the fact")
        rig.press()
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        XCTAssertTrue(rig.environment.fileDrags.isEmpty,
                      "a crossing carrying a drag from THIS Mac must start "
                        + "no return drag: it is travelling the other way")
        XCTAssertFalse(rig.recorder.lines.contains {
            $0.1.contains("press bound to the guest selection")
        }, "nothing may be bound: the person's hand is on a host file")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("this cross carries a drag from this Mac")
        }, "the suppression must say so, or the next report of this reads "
            + "as a crossing that silently did nothing: \(rig.recorder.lines)")
    }

    /// **THE OTHER WAY, AND IT MUST STILL WORK.** A suppression that fires
    /// on the ordinary guest→host gesture would trade one broken direction
    /// for the other, and this is the direction that reached metal first
    /// (2026-08-15 13:43, the first file to cross the edge). Identical to
    /// the test above in every respect except the one that matters: no host
    /// drag is over this Mac.
    func testAnOrdinaryGuestCrossingIsUntouchedByTheSuppression() throws {
        let rig = Rig()
        rig.select(Self.file(name: "main.c"), generation: 3)
        rig.enterGuest()
        rig.press()
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        let item = try XCTUnwrap(rig.environment.fileDrags.first?.item,
                                 "the guest→host direction must still bind "
                                    + "and start its return drag")
        let provider = try XCTUnwrap(item.writer as? NSFilePromiseProvider)
        let stub = try XCTUnwrap(provider.userInfo as? ContinuityDragStub)
        XCTAssertEqual(stub.item.name, "main.c")
        XCTAssertFalse(rig.recorder.lines.contains {
            $0.1.contains("this cross carries a drag from this Mac")
        }, "no host drag exists here; suppressing this crossing would break "
            + "the direction that already works")
    }

    /// **A SUPPRESSION FLAG THAT ONLY A FOREIGN CALLBACK CAN CLEAR IS ONE
    /// THAT CAN STICK.** `draggingExited` belongs to a session in another
    /// application — the one class of event this controller cannot make
    /// arrive — and a stuck flag leaves the edge permanently deaf to real
    /// guest presses. That is a worse failure than the one being fixed, and
    /// a silent one. So the fact underneath clears it too.
    func testTheSuppressionClearsItselfWhenTheButtonIsNoLongerHeld() throws {
        let rig = Rig()
        var held = true
        rig.controller.physicalPrimaryButtonHeld = { held }
        rig.enterGuest()
        _ = rig.environment.fileCallbacks?.entered(CGPoint(x: 1439, y: 450), .init(name: .drag))
        /* The drag ends somewhere this app never hears about. */
        held = false
        rig.select(Self.file(name: "main.c"), generation: 3)
        rig.press()
        rig.dragAcrossTheGuest()
        rig.crossBackHolding()
        rig.deliverRealDragEvent()

        XCTAssertFalse(rig.environment.fileDrags.isEmpty,
                       "the edge went deaf: a released host drag left the "
                        + "suppression armed with nothing able to clear it")
        XCTAssertTrue(rig.recorder.lines.contains {
            $0.1.contains("the host drag over the shared edge is over")
        }, "self-healing must be audible, or a stuck flag and a healthy one "
            + "look identical afterwards")
    }
}

/// One ordered record of everything the two sides of a crossing do, because
/// the defect this slice fixes is an ORDER, and two separate arrays cannot
/// express one.
private enum CrossStep: Equatable {
    case guestPrimaryDown
    /// The position packet that puts the guest pointer back where the press
    /// began. It carries its point because WHERE it went is the defect: a
    /// step that merely happened would pass while releasing at the edge.
    case guestReturnedToPressOrigin(MirrorKit.Point)
    case guestPrimaryUp(MirrorKit.Point)
    case guestPointerLeft
    /// The synthetic session-state primary down, posted so the window
    /// server stops believing the button this app's own tap swallowed is
    /// up. Its position relative to `hostDragBegan` is the defect.
    case sessionButtonRearmed
    case hostDragBegan
}

private final class Ledger {
    var steps: [CrossStep] = []
}

private final class AuditRecorder {
    var lines: [(HostLog.LogLevel, String)] = []
}

@MainActor
private final class Rig {
    let layout: ContinuityDisplayLayout
    let controller: ContinuityEdgeController
    let environment: Environment
    let driver: Driver
    let ledger = Ledger()
    let recorder = AuditRecorder()
    private let cache: ContinuitySelectionCache
    private let listener: GuestListener
    private let fileTransfer: MirrorFileTransferModel
    let grab: ContinuityGrabTransfer
    private let sceneCalls = Ledger()
    private var epoch: UInt32 = 7

    /// How many times anything asked for Mirror's scene. The guest→host lane
    /// must never need one.
    var sceneLookups: Int { sceneCalls.steps.count }

    /// Nil keeps the ordinary "no Mac in this test" refusal every existing
    /// test relies on; a rig built for the eager-fetch lane supplies its own
    /// so a `dragItem(for:)` call can actually succeed or hang on demand.
    init(grabRequest: ContinuityGrabTransfer.GrabRequest? = nil) {
        let recorder = self.recorder
        let audit: (HostLog.LogLevel, String) -> Void = {
            recorder.lines.append(($0, $1))
        }
        let sceneCalls = self.sceneCalls
        layout = ContinuityDisplayLayout(
            hostDisplays: [HostDisplayDescriptor(
                id: 41, name: "Studio Display",
                frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                pixelSize: CGSize(width: 5120, height: 2880),
                isPrimary: true)],
            guestSize: CGSize(width: 800, height: 600),
            defaults: nil, observeScreens: false)
        driver = Driver(ledger: ledger)
        environment = Environment(ledger: ledger)
        let clock = self.cacheClock
        cache = ContinuitySelectionCache(
            audit: audit,
            now: { clock.value ?? ProcessInfo.processInfo.systemUptime })
        listener = GuestListener(identity: .init(version: "test",
                                                 name: "Host"))
        fileTransfer = MirrorFileTransferModel(listener: listener)
        grab = ContinuityGrabTransfer(
            grab: grabRequest ?? { _, _, _, _, completion in
                completion(.failure(.init(code: "disconnected",
                                          message: "no Mac in this test")))
            }, audit: audit)
        controller = ContinuityEdgeController(
            layout: layout, driver: driver, environment: environment,
            audit: audit)
        let cache = self.cache
        let epoch = self.epoch
        ContinuityFileDrag.configure(
            edge: controller,
            fileTransfer: fileTransfer,
            scene: {
                sceneCalls.steps.append(.hostDragBegan)
                return nil
            },
            selection: { cache.bindable(activeEpoch: epoch) },
            selectionMark: { cache.mark },
            grab: grab,
            audit: audit)
        controller.start()
    }

    deinit {
        MainActor.assumeIsolated { listener.stop() }
    }

    /// The epoch ending under a gesture that is still physically in flight.
    /// Crossing back ENDS the epoch by design, so this is the ordinary
    /// order of events and not a corner case.
    func endEpochDroppingTheCache() {
        cache.clear(reason: "the Continuity epoch ended")
    }

    /// Lets a test place a cache application on the same clock the
    /// controller reads — the only way to stage a publish that crossed the
    /// press on the wire, which is the case that must refuse.
    final class Clock { var value: TimeInterval? }
    let cacheClock = Clock()

    /// Apply the next selection as though it had landed at `at`.
    func selectAsOf(_ at: TimeInterval, _ item: ContinuitySelection.Item,
                    generation: UInt32) {
        cacheClock.value = at
        select(item, generation: generation)
        cacheClock.value = nil
    }

    func select(_ item: ContinuitySelection.Item,
                generation: UInt32 = 3) {
        cache.apply(.init(version: ContinuityContract.version, epoch: epoch,
                          generation: generation, source: .selection,
                          item: item),
                    activeEpoch: epoch)
        notePublished()
    }

    /// The Mac's drag plane publishing what the Drag Manager handed it at
    /// drag begin. No selection is involved — this is the generation a
    /// never-selected file gets, and the whole reason it can have one.
    func dragBeginsAsOf(_ at: TimeInterval, _ item: ContinuitySelection.Item,
                        generation: UInt32) {
        cacheClock.value = at
        dragBegins(item, generation: generation)
        cacheClock.value = nil
    }

    func dragBegins(_ item: ContinuitySelection.Item,
                    generation: UInt32 = 4) {
        cache.apply(.init(version: ContinuityContract.version, epoch: epoch,
                          generation: generation, source: .drag,
                          item: item),
                    activeEpoch: epoch)
        notePublished()
    }

    /// What `MirrorContinuityController` does with every arrival: hand it to
    /// the edge, which refuses it in every case but the one that arrives
    /// after a crossing it can still revise.
    private func notePublished() {
        guard let mark = cache.mark else { return }
        controller.noteSelectionPublished(mark)
    }

    /// A drag belonging to some application on THIS Mac, held over the
    /// shared edge. `37241007`: a crossing made under one binds nothing.
    func hostDragReachesTheEdge() {
        _ = environment.fileCallbacks?.entered(CGPoint(x: 1439, y: 450),
                                               .init(name: .drag))
    }

    func enterGuest() {
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1439, y: 450),
                               delta: CGPoint(x: 2, y: 0),
                               buttonsDown: false))
        controller.transportPhaseChanged(.active)
    }

    /// Where `press()` lands on the guest: the entry point of `enterGuest`,
    /// which the host frame and the guest scale in this rig make 1:1.
    static let pressOrigin = MirrorKit.Point(x: 24, y: 450)

    func press() {
        environment.emitCaptured(.init(kind: .primaryDown,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: .zero, buttonsDown: true))
    }

    /// Held motion away from the press before the cross, so the origin and
    /// the crossing point are two different places.
    func dragAcrossTheGuest() {
        environment.emitCaptured(.init(kind: .moved,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: CGPoint(x: 40, y: 20),
                                       buttonsDown: true))
    }

    /// The crossing itself, through the consuming tap — which has no NSEvent.
    func crossBackHolding() {
        environment.emitCaptured(.init(kind: .moved,
                                       location: CGPoint(x: 1439, y: 450),
                                       delta: CGPoint(x: -100, y: 0),
                                       buttonsDown: true))
    }

    /// The same clock the controller reads, so a test can place a witnessed
    /// event where the report will attribute it — or far enough back that it
    /// must not.
    func now() -> TimeInterval { ProcessInfo.processInfo.systemUptime }

    /// macOS finishing with the session this app started.
    func endHostDragSession(operation: NSDragOperation) {
        environment.fileCallbacks?.dragEnded(operation,
                                             CGPoint(x: 900, y: 400))
    }

    /// A held motion sample carrying no NSEvent — what the monitor keeps
    /// delivering while the window server catches up with the widen.
    func deliverHeldSampleWithoutEvent() {
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1300, y: 450),
                               delta: CGPoint(x: -8, y: 0),
                               buttonsDown: true))
    }

    /// The first physical `mouseDragged` after the tap died.
    func deliverRealDragEvent(eventNumber: Int = 4242) {
        // swiftlint:disable:next force_unwrapping
        let event = NSEvent.mouseEvent(
            with: .leftMouseDragged, location: CGPoint(x: 10, y: 10),
            modifierFlags: [], timestamp: 12, windowNumber: 0, context: nil,
            eventNumber: eventNumber, clickCount: 1, pressure: 1)!
        environment.emit(.init(kind: .moved,
                               location: CGPoint(x: 1300, y: 450),
                               delta: CGPoint(x: -8, y: 0),
                               buttonsDown: true),
                         event: event)
    }

    final class Driver: ContinuityEdgeDriving {
        var keyboardForwardingEnabled = true
        var escapeShortcut = ContinuityEscapeShortcut.controlOptionEscape
        /// A guest that declines the press — the transport not being active
        /// is the ordinary way. Nothing is held on the Mac afterwards.
        var acceptPresses = true
        private let ledger: Ledger

        init(ledger: Ledger) { self.ledger = ledger }

        func pointerMoved(to point: MirrorKit.Point) { _ = point }
        func pointerLeft() { ledger.steps.append(.guestPointerLeft) }
        func primaryDown(at point: MirrorKit.Point, inMenuBar: Bool,
                         sourceUptime: TimeInterval?) -> Bool {
            _ = (point, inMenuBar, sourceUptime)
            guard acceptPresses else { return false }
            ledger.steps.append(.guestPrimaryDown)
            return true
        }
        func primaryDragged(to point: MirrorKit.Point) -> Bool {
            _ = point
            return true
        }
        func settleHeldPosition(to point: MirrorKit.Point) -> Bool {
            ledger.steps.append(.guestReturnedToPressOrigin(point))
            return true
        }
        func primaryUp(at point: MirrorKit.Point) -> Bool {
            ledger.steps.append(.guestPrimaryUp(point))
            return true
        }
        func keyboardEvent(_ sample: HostKeySample) -> Bool {
            _ = sample
            return true
        }
    }

    final class Environment: ContinuityPointerEnvironment {
        final class Token: NSObject {}
        let ledger: Ledger
        var handler: ContinuityPointerEnvironment.SampleHandler?
        var captureHandler: ContinuityPointerEnvironment.SampleHandler?
        var fileCallbacks: ContinuityFileEdge.Callbacks?
        var fileDrags: [(item: HostFileDragItem, point: CGPoint,
                         event: NSEvent)] = []
        var catchChanges: [Bool] = []
        /// Synthetic session-state button posts, in order, with where.
        var syntheticButtonPosts: [(down: Bool, point: CGPoint)] = []
        var syntheticPostsSucceed = true

        init(ledger: Ledger) { self.ledger = ledger }

        func postSyntheticPrimaryButton(down: Bool,
                                        at screenPoint: CGPoint) -> Bool {
            syntheticButtonPosts.append((down, screenPoint))
            if syntheticPostsSucceed {
                ledger.steps.append(.sessionButtonRearmed)
            }
            return syntheticPostsSucceed
        }

        func start(_ handler: @escaping ContinuityPointerEnvironment
                    .SampleHandler) -> AnyObject {
            self.handler = handler
            return Token()
        }
        func stop(_ token: AnyObject) { _ = token }
        /// The witness lane. Available by default, so ordinary tests
        /// describe a Mac where the listen-only tap was granted; a test for
        /// the refusal sets `dragWitnessAvailable = false`.
        var dragWitnessAvailable = true
        var dragWitness = ContinuityDragWitness(installed: true)
        var dragWitnessStarts = 0
        var dragWitnessStops = 0

        func startDragWitness() -> AnyObject? {
            guard dragWitnessAvailable else { return nil }
            dragWitnessStarts += 1
            return Token()
        }
        func readDragWitness(_ token: AnyObject) -> ContinuityDragWitness {
            _ = token
            return dragWitness
        }
        func stopDragWitness(_ token: AnyObject) {
            _ = token
            dragWitnessStops += 1
        }
        func hideCursor(on displayID: UInt32) { _ = displayID }
        func showCursor(on displayID: UInt32) { _ = displayID }
        func moveCursor(on displayID: UInt32, to point: CGPoint) {
            _ = (displayID, point)
        }
        func setCursorMovementAssociated(_ associated: Bool) -> Bool {
            _ = associated
            return true
        }
        func startInputCapture(
            handler: @escaping ContinuityPointerEnvironment.SampleHandler,
            tapDisabled: @escaping @MainActor (String) -> Void
        ) -> AnyObject? {
            _ = tapDisabled
            captureHandler = handler
            return Token()
        }
        func stopInputCapture(_ token: AnyObject) {
            _ = token
            captureHandler = nil
        }
        var catchThicknesses: [CGFloat] = []

        func showFileEdge(_ edge: ContinuitySharedEdge,
                          catchThickness: CGFloat,
                          callbacks: ContinuityFileEdge.Callbacks)
            -> AnyObject {
            _ = edge
            catchThicknesses.append(catchThickness)
            fileCallbacks = callbacks
            return Token()
        }
        func updateFileEdge(_ token: AnyObject, edge: ContinuitySharedEdge,
                            catchThickness: CGFloat,
                            callbacks: ContinuityFileEdge.Callbacks) {
            _ = (token, edge)
            catchThicknesses.append(catchThickness)
            fileCallbacks = callbacks
        }
        func setFileEdgeCatching(_ token: AnyObject, _ catching: Bool) {
            _ = token
            catchChanges.append(catching)
        }
        var dropsThroughChanges: [Bool] = []
        func setFileEdgeDropsThroughOwnSession(_ token: AnyObject,
                                               _ dropsThrough: Bool) {
            _ = token
            dropsThroughChanges.append(dropsThrough)
        }
        /// Whether the WINDOW SERVER has put the catch surface under the
        /// seed point. True by default so the ordinary tests describe a Mac
        /// where it worked; the tests for the metal defect start it false
        /// and let it become true, which is what actually happens 15–25 ms
        /// after the widen.
        var catchSurfaceOwnsSeedPoint = true
        /// Every point the controller asked about, in order — the evidence
        /// that it asked at all rather than assumed.
        var catchHitTests: [CGPoint] = []

        func catchSurfaceHitTest(_ token: AnyObject, at screenPoint: CGPoint)
            -> ContinuityCatchHitTest {
            _ = token
            catchHitTests.append(screenPoint)
            return ContinuityCatchHitTest(
                serverTopWindowNumber: catchSurfaceOwnsSeedPoint ? 77 : 30,
                panelWindowNumber: 77)
        }
        func hideFileEdge(_ token: AnyObject) {
            _ = token
            fileCallbacks = nil
        }
        /// What the real environment would report about the session it
        /// started. Own-window by default; a test that wants the metal
        /// failure sets a foreign one.
        var dragSeed: ContinuityDragSeed? = ContinuityDragSeed(
            eventType: 6, serverTopWindowNumber: 77, appActive: true,
            windowNumber: 77, panelWindowNumber: 77,
            resolvedToPanel: true, clickCount: 1, panelKey: true,
            panelCoversPoint: true)

        func beginFileDrag(_ item: HostFileDragItem, at screenPoint: CGPoint,
                           sourceEvent: NSEvent) -> ContinuityDragSeed? {
            ledger.steps.append(.hostDragBegan)
            fileDrags.append((item, screenPoint, sourceEvent))
            return dragSeed
        }
        func emit(_ sample: HostPointerSample, event: NSEvent? = nil) {
            handler?(sample, event)
        }
        func emitCaptured(_ sample: HostPointerSample,
                          event: NSEvent? = nil) {
            captureHandler?(sample, event)
        }
    }
}
