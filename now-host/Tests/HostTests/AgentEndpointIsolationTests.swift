import Foundation
import XCTest
@testable import NOWAgentIntegration

/// **Two stacks on one Mac, or one of them silently answers for the
/// other.**
///
/// The agent endpoint is per-uid, which is the right shape for the
/// product and the wrong one for a desk where several sessions run at
/// once: the first host to bind owns `host.sock`, and every MCP client
/// on the machine then reaches that host and whatever guest it is
/// driving — with nothing on either side saying so.
///
/// `NOW_AGENT_SOCKET_SUFFIX` gives a run its own endpoint. These are the
/// two properties it has to have: it must actually move the socket, and
/// it must not be able to move it somewhere the caller did not name.
final class AgentEndpointIsolationTests: XCTestCase {

    func testASuffixMovesTheEndpointAndNoSuffixLeavesItAlone() throws {
        XCTAssertEqual(AgentIntegrationEndpoint.sanitisedSuffix(nil), "")
        XCTAssertEqual(AgentIntegrationEndpoint.sanitisedSuffix(""), "")
        XCTAssertEqual(
            AgentIntegrationEndpoint.sanitisedSuffix("019conf"), "-019conf")
        XCTAssertEqual(
            AgentIntegrationEndpoint.sanitisedSuffix("lane_A-2"),
            "-lane_A-2")
    }

    /// A suffix that would name a path outside the temporary directory,
    /// or one long enough to push the socket past the platform's own
    /// limit, is REFUSED rather than escaped.
    ///
    /// Escaping would put a host on an endpoint its author did not name,
    /// which is the same collision arriving by the other door.
    func testASuffixCannotNameSomewhereElse() throws {
        for hostile in ["../elsewhere", "a/b", "with space", "dot.dot",
                        "null\0byte",
                        String(repeating: "x", count: 25)] {
            XCTAssertEqual(
                AgentIntegrationEndpoint.sanitisedSuffix(hostile), "",
                "\(hostile.debugDescription) was accepted as a suffix")
        }
    }

    /// The socket path is derived in ONE place, so a host and the
    /// companion that talks to it cannot disagree about where it is.
    ///
    /// They are separate processes; a second spelling of this rule is a
    /// second place for them to drift, and the failure would be a client
    /// that connects to nothing while a healthy host listens.
    func testTheSuffixIsReadInExactlyOnePlace() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources")
        var readers: [String] = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let text = try? String(contentsOf: url, encoding: .utf8),
                  text.contains("NOW_AGENT_SOCKET_SUFFIX") else { continue }
            readers.append(url.lastPathComponent)
        }
        XCTAssertEqual(
            readers, ["AgentIntegrationUnixSocket.swift"],
            "NOW_AGENT_SOCKET_SUFFIX is read in \(readers.count) place(s): "
                + "\(readers.joined(separator: ", ")). It must be read "
                + "where the endpoint is BUILT and nowhere else — a "
                + "second reader is how a host and its companion end up "
                + "on different sockets while both look healthy.")
    }
}
