import Foundation

/// **Poll the guest's own process listing until one named process reaches a
/// state, or a bounded budget runs out.**
///
/// ## Why this is `process.list` and not a scene wait
///
/// L6's resume notes scoped `now_wait_for` against a fetchable scene —
/// "window titled X present/absent, process front" — and named `scene` as a
/// dependency because that is the richer predicate. `scene` has not landed
/// (see `docs/mcp-coverage.md`'s `scene.request` row): it needs a whole new
/// paging lane across the local socket, the same two-lane chunking
/// `CaptureScreenProjection` built for a screen, plus an `irVersion` gate
/// re-expressed inside this package without depending on MirrorKit. Those
/// notes also named the narrower path: **process-front alone could reuse
/// `now_list_processes` without waiting on `scene`.** This row is that
/// narrower path, landed now rather than left blocked on a lane that is not
/// there yet.
///
/// So the predicate is deliberately over `process.list`'s own rows — whether
/// a named process is running, is front, or is gone — and not over a
/// window's title or a control's state. A caller that needs to wait for a
/// WINDOW gets an honest gap here (see `faces` below) until `scene` lands;
/// this row does not simulate that richer wait by guessing from process
/// identity.
///
/// ## Bounded, and honestly timed out
///
/// The bound is at most `AgentIntegrationWaitPolicy.maximumTimeoutMs` (10
/// seconds) and this row does not take a longer one — an agent call that
/// can block the host's local socket indefinitely is the failure this cap
/// exists against. Running out the clock is reported as `timedOut`, never as
/// a refusal: the poll ran exactly as asked, `process.list` answered every
/// time it was asked, and what is reported is that the condition was false
/// at every one of those answers. A caller reading `timedOut` has learned
/// something true about the machine over that window, not that this row
/// failed.
///
/// ## What it polls with, and why a caller never sees the interval
///
/// Each read is a full `client.listProcesses()` call — the identical call
/// `ListProcessesProjection` makes — repeated at
/// `AgentIntegrationWaitPolicy.pollIntervalMs`. That interval is this row's
/// own cost control, not a fact about the connected Macintosh, so it is not
/// in the input schema: exposing it would let a caller hammer the local
/// socket at a rate this row is supposed to be the one deciding.
public enum WaitForProjection: HostProjection {
    public static let capability = HostCapabilityID("now_wait_for")

    /* Identical to ListProcessesProjection's — this row asks the guest for
       nothing beyond that listing, repeated. */
    public static let requires = [
        AgentIntegrationCapabilityNames.processList,
    ]

    public static let exposes = [
        AgentIntegrationCapabilityNames.processList,
    ]

    public static let acceptedArguments: Set<String> = [
        "name", "until", "timeoutMs",
    ]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .notReached(
            because: "A person watching the Processes page sees a state "
                + "change as it happens and has no use for a poll loop "
                + "that blocks waiting for one — that is the affordance an "
                + "agent lacks and a person at the screen already has. "
                + "There is also no richer window-level wait for a pane to "
                + "expose yet: this row's predicate is process.list's own "
                + "rows, and the scene-level wait \"is window X open\" is "
                + "gated on the scene projection landing first."),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves process.list."

    private enum Argument {
        static let name = "name"
        static let until = "until"
        static let timeoutMs = "timeoutMs"
    }

    public static var mcpDescriptor: [String: Any] {
        let receipt: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "until": [
                    "type": "string",
                    "enum": ["running", "front", "gone"],
                ],
                "elapsedMs": ["type": "integer", "minimum": 0],
                "observedAt": ["type": "string", "format": "date-time"],
            ],
            "required": ["name", "until", "elapsedMs", "observedAt"],
            "additionalProperties": false,
        ]
        let timedOut: [String: Any] = [
            "type": "object",
            "properties": [
                "name": ["type": "string"],
                "until": [
                    "type": "string",
                    "enum": ["running", "front", "gone"],
                ],
                "elapsedMs": ["type": "integer", "minimum": 0],
                "timeoutMs": ["type": "integer", "minimum": 0],
                "lastObservedAt": [
                    "type": ["string", "null"], "format": "date-time",
                ],
            ],
            "required": [
                "name", "until", "elapsedMs", "timeoutMs",
            ],
            "additionalProperties": false,
        ]
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Wait For A New Old World Guest Process To Change State",
            "description":
                "Polls the connected guest's process listing — the same read now_list_processes performs — until a named process reaches the requested state, or timeoutMs runs out first. until: \"running\" waits for a process named name to appear; \"front\" waits for it to appear AND be frontmost; \"gone\" waits for no process by that name to be listed (waiting out a quit). timeoutMs is bounded to \(AgentIntegrationWaitPolicy.maximumTimeoutMs)ms; omitted means \(AgentIntegrationWaitPolicy.defaultTimeoutMs)ms. Running out the clock is reported as timedOut, not as a failure: the poll ran exactly as asked and the condition was simply false at every read taken. This row has no window-level predicate — it cannot wait for a window to open or close — because that needs the scene projection, which has not landed; see docs/mcp-coverage.md.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    Argument.name: [
                        "type": "string",
                        "minLength": 1,
                        "description":
                            "The process name to watch, exact match against process.list's own name field (as now_list_processes reports it).",
                    ],
                    Argument.until: [
                        "type": "string",
                        "enum": ["running", "front", "gone"],
                        "description":
                            "running: a process by this name is listed. front: it is listed and marked front. gone: no process by this name is listed.",
                    ],
                    Argument.timeoutMs: [
                        "type": "integer",
                        "minimum":
                            AgentIntegrationWaitPolicy.minimumTimeoutMs,
                        "maximum":
                            AgentIntegrationWaitPolicy.maximumTimeoutMs,
                        "description":
                            "Milliseconds to poll before giving up; omitted means \(AgentIntegrationWaitPolicy.defaultTimeoutMs). Bounded to \(AgentIntegrationWaitPolicy.maximumTimeoutMs) so a call cannot hold the host's local socket open indefinitely.",
                    ],
                ],
                "required": [Argument.name, Argument.until],
                "additionalProperties": false,
            ],
            "outputSchema": [
                "oneOf": [
                    variant("satisfied", "satisfied", receipt),
                    variant("timedOut", "timedOut", timedOut),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
            "annotations": HostProjectionSchema.readOnlyAnnotations,
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        if let refusal = arguments.refusalForUnknownMembers(
            tool: capability, accepting: acceptedArguments) {
            return .invalidArguments(refusal)
        }
        let object = arguments.object ?? [:]

        guard let name = object[Argument.name] as? String, !name.isEmpty
        else {
            return .invalidArguments(
                "\(capability.rawValue) requires name: a non-empty process "
                    + "name, exact match against process.list's own name "
                    + "field")
        }

        guard let untilRaw = object[Argument.until] as? String,
              let until = AgentIntegrationWaitCondition(rawValue: untilRaw)
        else {
            return .invalidArguments(
                "\(capability.rawValue) requires until to be one of "
                    + "running, front, gone")
        }

        var timeoutMs = AgentIntegrationWaitPolicy.defaultTimeoutMs
        if let raw = object[Argument.timeoutMs] {
            guard let value = raw as? Int,
                  AgentIntegrationWaitPolicy.isValidTimeout(value) else {
                return .invalidArguments(
                    "\(capability.rawValue) requires timeoutMs to be an "
                        + "integer between "
                        + "\(AgentIntegrationWaitPolicy.minimumTimeoutMs) "
                        + "and "
                        + "\(AgentIntegrationWaitPolicy.maximumTimeoutMs)")
            }
            timeoutMs = value
        }

        return await poll(
            name: name, until: until, timeoutMs: timeoutMs,
            through: client, clock: AgentIntegrationSystemWaitClock())
    }

    // MARK: - The poll loop, over an injectable clock

    /// The loop `invoke` runs with the real clock, and a test runs with a
    /// fake one — so the condition check, the timeout arithmetic and the
    /// multi-read sequencing are exercised for real, without a test suite
    /// spending wall-clock seconds asleep.
    static func poll(
        name: String, until: AgentIntegrationWaitCondition, timeoutMs: Int,
        through client: AgentIntegrationClient,
        clock: AgentIntegrationWaitClock
    ) async -> HostProjectionOutcome {
        let start = clock.now()
        var lastObservedAt: Date?
        while true {
            switch await client.listProcesses() {
            case .unavailable(let unavailable):
                return .value(.init(
                    AgentIntegrationWaitResult.unavailable(unavailable)))
            case .available(let snapshot):
                lastObservedAt = snapshot.observedAt
                let matches = snapshot.processes.filter { $0.name == name }
                let holds: Bool
                switch until {
                case .running:
                    holds = !matches.isEmpty
                case .front:
                    holds = matches.contains { $0.front }
                case .gone:
                    holds = matches.isEmpty
                }
                let elapsedMs = milliseconds(since: start, clock: clock)
                if holds {
                    return .value(.init(AgentIntegrationWaitResult.satisfied(
                        .init(name: name, until: until,
                             elapsedMs: elapsedMs,
                             observedAt: snapshot.observedAt))))
                }
                if elapsedMs >= timeoutMs {
                    return .value(.init(AgentIntegrationWaitResult.timedOut(
                        .init(name: name, until: until,
                             elapsedMs: elapsedMs, timeoutMs: timeoutMs,
                             lastObservedAt: lastObservedAt))))
                }
            }
            await clock.sleep(
                milliseconds: AgentIntegrationWaitPolicy.pollIntervalMs)
            let elapsedAfterSleep = milliseconds(since: start, clock: clock)
            if elapsedAfterSleep >= timeoutMs {
                return .value(.init(AgentIntegrationWaitResult.timedOut(
                    .init(name: name, until: until,
                         elapsedMs: elapsedAfterSleep, timeoutMs: timeoutMs,
                         lastObservedAt: lastObservedAt))))
            }
        }
    }

    private static func milliseconds(
        since start: Date, clock: AgentIntegrationWaitClock
    ) -> Int {
        Int(clock.now().timeIntervalSince(start) * 1000)
    }
}
