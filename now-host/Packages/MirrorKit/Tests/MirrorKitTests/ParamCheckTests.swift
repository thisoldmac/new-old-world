import XCTest
@testable import MirrorKit

/// The near-miss these pin: `mirror.act.key {key: "q", modifiers: ["command"]}`
/// — the contract's name is `mods` — typed a literal `q` into an open document
/// and reported `performed: true`. An unread parameter is indistinguishable
/// from an absent one, so a dropped ⌘ does not fail, it does something else.
final class ParamCheckTests: XCTestCase {

    private let actKey: Set<String> = ["key", "mods"]

    func testTheExactCallThatMisfiredIsNowRefused() {
        let got = ParamCheck.unknown(["key", "modifiers"], known: actKey)
        XCTAssertEqual(got, ["modifiers"])
    }

    func testAWellFormedCallPasses() {
        XCTAssertTrue(ParamCheck.unknown(["key", "mods"], known: actKey).isEmpty)
    }

    /// The envelope is not any one method's business, and a method that had to
    /// list `session` in its own accepted set would eventually forget to.
    func testEnvelopeKeysAreAcceptedWithoutBeingDeclared() {
        XCTAssertTrue(ParamCheck.unknown(["key", "mods", "session", "settle"],
                                         known: actKey).isEmpty)
    }

    /// `settleTimeoutMs` is read by `performAct` AFTER the method returns, so
    /// no method's own accepted set mentions it. A gate built only from the
    /// arguments a method reads directly would reject a parameter that has
    /// always worked — which is the near-miss this whole file is about, running
    /// in the other direction.
    func testTheDeferredSettleTimeoutIsPartOfTheEnvelope() {
        XCTAssertTrue(ParamCheck.unknown(["key", "settleTimeoutMs"],
                                         known: actKey).isEmpty)
    }

    func testEveryUnknownIsReported_notJustTheFirst() {
        XCTAssertEqual(ParamCheck.unknown(["key", "modifiers", "delay"],
                                          known: actKey),
                       ["delay", "modifiers"])
    }

    /// Sorted, because an error message that reorders between runs is one
    /// nobody can assert on.
    func testTheOrderIsStable() {
        XCTAssertEqual(ParamCheck.unknown(["zeta", "alpha"], known: actKey),
                       ["alpha", "zeta"])
    }

    /// The message has to name the right spelling. "unknown parameter" alone
    /// leaves the caller guessing which of `mods`/`modifiers` is real — which
    /// is the entire failure being fixed.
    func testTheMessageNamesBothWhatWeGotAndWhatWeAccept() {
        let m = ParamCheck.message(method: "mirror.act.key",
                                   got: ["modifiers"], known: actKey)
        XCTAssertTrue(m.contains("modifiers"), m)
        XCTAssertTrue(m.contains("mods"), m)
        XCTAssertTrue(m.contains("mirror.act.key"), m)
    }

    /// An empty accepted-set is a method that takes only the envelope; it must
    /// still refuse arguments rather than accept anything.
    func testAMethodThatTakesNoArgumentsStillRefusesThem() {
        XCTAssertEqual(ParamCheck.unknown(["scope"], known: []), ["scope"])
    }
}
