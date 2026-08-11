import XCTest
import MirrorKit
@testable import Host

/// **What the `decode_ms` bracket actually costs, on documents captured
/// off a real guest.**
///
/// The bracket in `MirrorCycleClocks` runs from "the delivery arrived" to
/// "the Mirror published it". On 2026-08-06 it read 12,457 ms for a
/// six-window machine and 324 ms for the same machine one window earlier
/// — a 38x jump for 11% more content, which reads exactly like an
/// accidental quadratic in the decode.
///
/// It is not. This file is the measurement that says so: the whole
/// CPU-side pipeline a delivery goes through — JSON decode, the reducer,
/// the projection — over the largest documents this project has captured,
/// with a bound that fails long before a person could feel it. Everything
/// above that bound in the live bracket is guest round-trips the cycle
/// makes while holding itself open, and belongs to a different repair.
///
/// The bound is deliberately generous (200 ms for a document three times
/// the size of the slow one). A perf test that fails on a loaded CI box
/// gets deleted; this one only fires for the defect class it names — work
/// that grows superlinearly with the scene.
final class MirrorDecodeCostTests: XCTestCase {

    /// Generous by design: the observed cost is under 10 ms, so this fires
    /// at ~20x regression and never on a busy machine.
    private static let bound: TimeInterval = 0.200

    private func document(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json",
                              subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    /// One delivery's worth of host CPU: decode, reduce, project.
    @discardableResult
    private func pipeline(_ document: Data,
                          previous: MirrorReplica? = nil,
                          seq: Int? = nil) throws
        -> (replica: MirrorReplica, seconds: TimeInterval) {
        let session = MirrorGuestSession(guest: "fixture",
                                         incarnation: "session-a")
        let started = Date()
        var scene = try NOWMirrorSceneDecoder.decode(irVersion: 2,
                                                     document: document)
        _ = NOWMirrorSceneDecoder.phases(from: document)
        if let seq { scene.seq = seq }
        let observation = GuestSceneObservation(
            session: session, scene: scene, receivedAt: Date())
        guard case .accepted(let replica) =
            MirrorReplicaReducer.reduce(observation, previous: previous)
        else {
            throw UnexpectedTestResult(
                description: "the reducer rejected a real document")
        }
        _ = replica.snapshot.scene
        return (replica, Date().timeIntervalSince(started))
    }

    /// The scene the slow cycles were reading: a six-window machine with a
    /// modal up. If the pathology were in our decode it would show here.
    func testTheModalSceneDecodesFarBelowTheBound() throws {
        let cost = try pipeline(try document("scene-quit-modal")).seconds
        XCTAssertLessThan(
            cost, Self.bound,
            "decoding one captured six-window scene took \(Int(cost * 1000))ms. "
            + "The live bracket reported 12,457ms for this shape of machine; "
            + "if that time is HERE, this is where to look.")
    }

    /// Three documents of growing size, the largest ~70 KB — nearly three
    /// times the one that produced 12.5 s on the wire.
    func testEveryCapturedSceneDecodesFarBelowTheBound() throws {
        for name in ["now-scene-ir-v1", "scene-plane-held",
                     "now-scene-self-front-visible",
                     "now-scene-self-hidden-but-front"] {
            let data = try document(name)
            let irVersion = name == "now-scene-ir-v1" ? 1 : 2
            let session = MirrorGuestSession(guest: "fixture",
                                             incarnation: "session-a")
            let started = Date()
            let scene = try NOWMirrorSceneDecoder.decode(irVersion: irVersion,
                                                         document: data)
            let observation = GuestSceneObservation(
                session: session, scene: scene, receivedAt: Date())
            if case .accepted(let replica) =
                MirrorReplicaReducer.reduce(observation, previous: nil) {
                _ = replica.snapshot.scene
            }
            let cost = Date().timeIntervalSince(started)
            XCTAssertLessThan(
                cost, Self.bound,
                "\(name).json (\(data.count) bytes) cost "
                + "\(Int(cost * 1000))ms to decode, reduce and project")
        }
    }

    /// **The shape of the defect, not just its size.** A quadratic hides
    /// from a single-document bound: the fixture is simply not big enough.
    /// Successive reductions against a growing previous replica are where
    /// per-element rework over the whole document would compound, so this
    /// runs the same document ten times in a chain and asserts the total
    /// stays inside a linear budget.
    func testRepeatedReductionDoesNotCompound() throws {
        let data = try document("scene-quit-modal")
        var previous: MirrorReplica?
        let base = try NOWMirrorSceneDecoder.decode(irVersion: 2,
                                                    document: data).seq
        let started = Date()
        for step in 1...10 {
            previous = try pipeline(data, previous: previous,
                                    seq: base + step).replica
        }
        let cost = Date().timeIntervalSince(started)
        XCTAssertLessThan(
            cost, Self.bound * 10,
            "ten chained reductions of one scene cost \(Int(cost * 1000))ms; "
            + "work that grows with the replica rather than with the "
            + "delivery compounds exactly here")
    }
}
