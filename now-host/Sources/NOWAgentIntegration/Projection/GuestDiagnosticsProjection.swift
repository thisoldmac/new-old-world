import Foundation

/// The bounds the three diagnostics share, stated once because three rows,
/// the host-side owner and the module all read them.
///
/// Every number here is a **guest** buffer, restated on this side so a
/// schema can publish a bound a caller can rely on without reading C. They
/// are the largest of the four tables that answer these verbs, so the bound
/// stays ahead of the guests rather than shortening them:
///
/// | Buffer | Rows | Label | Value |
/// |---|:--:|:--:|:--:|
/// | `vprobe`, Carbon guest (`vprobe.h :: VProbeRow`, called with 20) | 20 | 24 | 48 |
/// | `vprobe`, NOW-68K (`n68_vprobe.h`) | 17 | 18 | 30 |
/// | `shotdiag`, NOW-68K (`n68_cmdresult.h :: N68CmdRows`) | 20 | 32 | 48 |
/// | `putstat`, Carbon guest (`commands.c :: run_putstat`) | 11 | — | — |
public enum AgentIntegrationDiagnosticsPolicy {
    /// The row ceiling: the largest guest table, so it cannot truncate any
    /// answer these verbs can produce today. If one ever answers past it,
    /// `note` says so rather than the tail vanishing — the same rule
    /// `catsearch` states, and for the same reason.
    public static let maximumRows = 20
    public static let maximumLabelScalars = 32
    public static let maximumValueScalars = 48

    /// A refusal from the guest: `vprobe-busy`, `vprobe-refused`,
    /// `vprobe-failed`, `shotdiag-refused`. `putstat` has no refusal path —
    /// it reads counters and always answers — which is a fact about that
    /// verb and not a promise this side makes on its behalf.
    public static let maximumFailureCodeScalars = 64
    public static let maximumMessageScalars = 200

    /// How long the host waits, and it is worth knowing that this is the
    /// ONLY bound in the chain.
    ///
    /// `catsearch` sits inside a guest that gives up after 20 s per pass, so
    /// its host bound only has to be larger than the machine's. Neither
    /// `vprobe` nor `shotdiag` has a guest-side give-up: they run a
    /// full-screen read to completion (~3 s on the Carbon guest, longer on a
    /// 68030) and answer when they are done. So 40 s is not padding around a
    /// smaller number — it is the whole watchdog, and it sits under the local
    /// socket's 45 s window for this operation
    /// (`AgentIntegrationLocalClient`, which classifies `diagnostics` with
    /// capture) so a slow answer arrives as this capability's own typed
    /// refusal rather than as a transport error, which teaches its caller
    /// nothing.
    public static let commandTimeout: TimeInterval = 40

    /// What `note` says when the host had to bound the answer. The one host
    /// sentence `AgentIntegrationGuestRowReport.note` carries for these
    /// verbs, and attributed in the text for exactly that reason.
    public static func truncationNote(verb: String, answered: Int) -> String {
        "The host bounded \(verb) to \(maximumRows) rows; the guest answered "
            + "\(answered). The rows beyond the bound are not here."
    }
}

/// The shape all three diagnostics answer in, rendered once.
///
/// Private to this file rather than hoisted into `HostProjectionSchema`:
/// `CatalogSearchProjection` left a note asking for the hoist when the
/// second `x-rowArray` row landed, and by now five of them have landed in
/// parallel branches with a fragment each. Hoisting is a shared-file edit
/// that would have to reconcile five published schemas at once, which is a
/// job for whoever integrates them and not a side effect of this row.
private func diagnosticReport(
    verb: String, note: String, groupDescription: String
) -> [String: Any] {
    let policy = AgentIntegrationDiagnosticsPolicy.self
    let row: [String: Any] = [
        "type": "object",
        "properties": [
            "label": [
                "type": "string",
                "maxLength": policy.maximumLabelScalars,
            ],
            "value": [
                "type": "string",
                "maxLength": policy.maximumValueScalars,
            ],
        ],
        "required": ["label", "value"],
        "additionalProperties": false,
    ]
    let group: [String: Any] = [
        "type": "object",
        "properties": [
            "name": ["const": verb],
            "rows": [
                "type": "array",
                "maxItems": policy.maximumRows,
                "items": row,
                "description": groupDescription,
            ],
        ],
        "required": ["name", "rows"],
        "additionalProperties": false,
    ]
    return [
        "type": "object",
        "properties": [
            "verb": ["const": verb],
            "groups": [
                "type": "array",
                "maxItems": 1,
                "items": group,
            ],
            "note": [
                "type": ["string", "null"],
                "maxLength": 200,
                "description": note,
            ],
            "observedAt": ["type": "string", "format": "date-time"],
        ],
        "required": ["verb", "groups", "observedAt"],
        "additionalProperties": false,
    ]
}

/// A guest refusal, in the guest's own words and bounded.
private var diagnosticFailure: [String: Any] {
    let policy = AgentIntegrationDiagnosticsPolicy.self
    return [
        "type": "object",
        "properties": [
            "code": [
                "type": "string",
                "maxLength": policy.maximumFailureCodeScalars,
            ],
            "message": [
                "type": "string",
                "maxLength": policy.maximumMessageScalars,
                "description":
                    "The guest's own code and sentence when it refused, bounded and control-escaped; otherwise the host's. \"This machine does not serve this diagnostic\" arrives here too, as the guest's `unknown-command` — which is the answer, not an error.",
            ],
        ],
        "required": ["code", "message"],
        "additionalProperties": false,
    ]
}

// MARK: - Why this is three rows and not one

/// # The diagnostics trio — three rows, one operation, one module
///
/// `vprobe`, `shotdiag` and `putstat` are the three diagnostics the guests
/// serve, and P1 #13 of `docs/plans/2026-07-30-005` is a **decision** rather
/// than a projection: they could have been declared deliberate gaps on the
/// grounds that an agent does not need them, and the call (2026-07-29) is
/// that they get a home instead, because a diagnostic an agent can read and
/// a person cannot is exactly the asymmetry this work exists to close.
/// `shotdiag` is the concrete case — it is the verb that found the
/// PowerBook 180c's 24-bit addressing defect, and until now it was reachable
/// from nothing.
///
/// ## The crux: `requires` is a conjunction and these three do not co-occur
///
/// | verb | measures | served by |
/// |---|---|---|
/// | `vprobe` | framebuffer read cost by access method | **both guests** |
/// | `shotdiag` | where a staged capture read from | NOW-68K only |
/// | `putstat` | where a received file spent its time | the Carbon guest only |
///
/// The batched verb edit (P1a) gave this side **one** local operation with a
/// closed probe enum, which is right: none of the three takes an argument,
/// all three answer the same `x-rowArray` shape, and they share one home.
/// But an operation is a serialization lane, and a **row** is the unit of
/// availability — and one row cannot carry three different availabilities.
///
/// Worked through, every one-row shape is dishonest:
///
/// | One row requiring… | What the capability ledger reports | Why it is wrong |
/// |---|---|---|
/// | all three | `unavailable` against **every** guest, forever | no guest serves all three; the tool would be dead on arrival, in a sentence that reads as a fact about the Macintosh |
/// | `vprobe` only, exposing `vprobe` only | available on both guests | the tool would still ANSWER `shotdiag` and `putstat` while `docs/mcp-coverage.md` went on calling them unreached gaps — a doc lie the derived gap table cannot see |
/// | `vprobe` only, exposing all three | — | rejected by the seam: `exposes ⊆ requires` is enforced (`MCPCoverageTests`), and rightly, since a row cannot hand back an answer it had no grounds to ask for |
///
/// **The census's shape does not rescue it, and the reason is precise.**
/// `HardwareCensusProjection` keeps two levels of outcome apart — the CALL
/// says whether a Macintosh answered, the PROBE says what it found — and
/// that works because a census probe is an ARGUMENT: it is not in any
/// command table, so the ledger could not resolve it even if a row asked.
/// These three are not arguments. They are first-class commands in the
/// guest's own `help` table, which the ledger resolves ONE AT A TIME. Wearing
/// the census's shape here would take three capabilities the ledger can
/// answer for individually and collapse them into one it must lie about.
///
/// So: **three rows, one per verb, each requiring and exposing exactly its
/// own command.** Each is then exactly as available as the connected machine
/// makes it, derived from that machine's own `help` table — which is how
/// `gestalt`, `tail`, `catsearch` and `reveal` are already PowerPC-only
/// without a line on this side asking which guest answered — and all three
/// gap rows close honestly.
///
/// ## How a caller learns which of the three its machine answers
///
/// Two routes, and both are the guest's answer rather than this side's guess:
///
/// - **Before calling** — `now_session_capabilities` reports one row per
///   registered projection, each with its `state`, its `requires` and a
///   sentence. `now_capture_diagnostics` reads `unavailable` against the
///   Carbon guest because `shotdiag` is absent from the `help` table that
///   guest sent; `now_framebuffer_probe` reads available against both. No
///   guest identity is consulted anywhere in that derivation.
/// - **On calling anyway** — the guest refuses by name (`unknown-command`),
///   and that refusal crosses back verbatim in the call's `refused` arm.
///
/// The second is deliberately the CALL's refusal and not a per-probe outcome
/// inside a completed one, and that is not the conflation the census warns
/// about: there is no report to put an outcome in, because the guest never
/// ran a diagnostic — it declined to recognise a verb. A completed call
/// carrying "the machine does not have this" would be claiming a measurement
/// happened.
///
/// ## `vprobe` says nothing about whether capture works
///
/// Stated here because it has already misled a reading of the 1400c: an
/// earlier `vprobe` run reported `CopyBits failed`, and that failure does
/// **not** reproduce through `capture.request` (plan 005, Metal). They are
/// different paths, and `vprobe`'s baseline row failing is a fact about
/// `vprobe`'s own CopyBits baseline. Nothing in these rows, their schemas or
/// the module may imply that a red row here means the Screenshots page is
/// broken.
public enum FramebufferProbeProjection: HostProjection {
    public static let capability =
        HostCapabilityID("now_framebuffer_probe")

    /* One command, and the only one of the trio both guests serve. No
       `familyPolicy` row is owed or wanted — this is not a message family,
       so the ledger resolves it against the table `help` fills, which is
       what makes availability a fact the machine supplied. Checked against
       `AgentIntegrationCapabilityLedger.familyPolicy` rather than assumed;
       `MCPCoverageTests` fires if a requirement resolves to neither. */
    public static let requires =
        [AgentIntegrationCapabilityNames.vprobeCommand]

    /* The measurement IS the answer, so a caller reaches `vprobe` here.
       Nothing about it is consumed internally. */
    public static let exposes =
        [AgentIntegrationCapabilityNames.vprobeCommand]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "DiagnosticsModuleView.swift",
                         symbol: "model.run(.vprobe)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves the vprobe command."

    public static var mcpDescriptor: [String: Any] {
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Measure a New Old World Guest's Framebuffer Read Cost",
            "description":
                "Measures what reading the connected Mac's screen memory costs, by access method: raw framebuffer reads at 8, 16, 32 and 64-bit widths against the CopyBits baseline, whether a reread hits a cache, whether a partial read scales linearly, and whether the raw reads are pixel-faithful. Takes no arguments. It is a MEASUREMENT and it wants a still screen — around three seconds on the Carbon guest and longer on a 68030 — so a run while something is animating measures the animation too. Answers rows in the guest's own words. IMPORTANT: a failing row here is a fact about this probe's own read path and NOT about screen capture. A CopyBits baseline failure has been reported by this verb on hardware whose captures cross correctly through now_capture_screen; the two use different paths and must not be conflated.",
            "inputSchema": HostProjectionSchema.emptyInput,
            "outputSchema": [
                "oneOf": [
                    variant("completed", payload: "completed", schema:
                        diagnosticReport(
                            verb: "vprobe",
                            note:
                                "Present only when a bound was reached. The Carbon guest offers no note for this verb and NOW-68K reports its own dropped-row count inside the rows, so the only sentence that appears here is the host saying it had to shorten the answer.",
                            groupDescription:
                                "The guest's own rows, in its own order and wording: one per access width, the CopyBits baseline, the reread and linearity checks, fidelity, and on NOW-68K an Addressing row. Never parsed on this side — a host that turned \"CopyBits failed\" into a typed field would be answering for the machine.")),
                    variant("refused", payload: "refused",
                            schema: diagnosticFailure),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
            "annotations": [
                /* Reads the framebuffer the OS hands any application and
                   changes nothing on the machine — no device register is
                   touched (`vprobe.h`). */
                "readOnlyHint": true,
                "destructiveHint": false,
                /* Not idempotent, and honestly so: it is a measurement.
                   A second run rides whatever cache the first one filled
                   and answers different numbers, so a caller told this was
                   idempotent would be entitled to cache it. */
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        if let refusal = arguments.refusalIfAnyPresent(tool: capability) {
            return .invalidArguments(refusal)
        }
        return .value(.init(await client.runDiagnostic(.vprobe)))
    }
}

/// Where a staged capture read from — `shotdiag`, and the sharpest reason
/// this whole row set exists.
///
/// It stages one capture down the guest's **real** path
/// (`shotstage68_diagnose` IS `shotstage68_write`, with the facts recorded on
/// the way past), records the framebuffer base as the guest resolved it, that
/// base through `StripAddress`, whether the machine is in 32-bit addressing
/// at the moment of the walk, and the first sixteen bytes of row 0 as the
/// walk sees them beside the same row as CopyBits copies it — then discards
/// the scratch file. Identical samples mean the base is right and the fault
/// is downstream; different ones name the byte.
///
/// **It is not a capture and must not be read as one.** Nothing crosses the
/// bulk channel, no image is produced, and a person wanting a picture wants
/// `now_capture_screen`. What it costs is what a capture costs, because it
/// does the same full-screen read and pack.
///
/// NOW-68K only, by derivation: the verb is absent from the Carbon guest's
/// `help` table, so against that guest this row is `unavailable` in typed
/// form with the ledger's own sentence. There is no reduced form and none is
/// wanted — a "shotdiag with the walk skipped" would answer nothing this
/// verb exists to answer.
public enum CaptureDiagnosticsProjection: HostProjection {
    public static let capability =
        HostCapabilityID("now_capture_diagnostics")

    /* `shotdiag` alone. NOT `capture.request` as well, though this verb
       stages a capture: the row asks the guest for one command and gets one
       row array back, the bulk channel is never opened, and requiring the
       capture family would switch the row off against a guest that serves
       the diagnostic — availability by association rather than by what was
       asked. */
    public static let requires =
        [AgentIntegrationCapabilityNames.shotdiagCommand]

    public static let exposes =
        [AgentIntegrationCapabilityNames.shotdiagCommand]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "DiagnosticsModuleView.swift",
                         symbol: "model.run(.shotdiag)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves the shotdiag command."

    public static var mcpDescriptor: [String: Any] {
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Read Where a New Old World Guest's Capture Read From",
            "description":
                "Stages one screen capture down the connected Mac's real capture path and reports where the walk read from, then discards it: the framebuffer base as the guest resolved it, that base through StripAddress, whether the machine is in 32-bit addressing at the moment of the walk, and the first sixteen bytes of row 0 as the walk sees them beside the same row as CopyBits copies it. Identical samples mean the base is right and the fault is downstream; different ones name the byte. This is the verb that found the PowerBook 180c's 24-bit addressing defect. Takes no arguments. NOT a capture: no image is produced and nothing crosses the transfer channel — use the capture tool for a picture. It costs what a capture costs, since it does the same full-screen read and pack, and it wants a still screen. Answers rows in the guest's own words.",
            "inputSchema": HostProjectionSchema.emptyInput,
            "outputSchema": [
                "oneOf": [
                    variant("completed", payload: "completed", schema:
                        diagnosticReport(
                            verb: "shotdiag",
                            note:
                                "Present only when a bound was reached. The guest states its verdict and every edge of the answer inside the rows, so the only sentence that appears here is the host saying it had to shorten them.",
                            groupDescription:
                                "The guest's own rows, in its own order and wording — the resolved base, its stripped form, the addressing mode, the two row-0 samples, and the guest's own verdict line. The samples are carried verbatim and never compared on this side: which one is right is the question the machine was asked.")),
                    variant("refused", payload: "refused",
                            schema: diagnosticFailure),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
            "annotations": [
                /* Read-only on the machine's state, and the one write it
                   makes it removes: the staged scratch file is discarded
                   before the answer is sent (`run_shotdiag`). */
                "readOnlyHint": true,
                "destructiveHint": false,
                /* A measurement of a live walk: a second run reads the
                   screen as it is then, and the byte samples are of
                   whatever is on it. */
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        if let refusal = arguments.refusalIfAnyPresent(tool: capability) {
            return .invalidArguments(refusal)
        }
        return .value(.init(await client.runDiagnostic(.shotdiag)))
    }
}

/// Where the last file the guest RECEIVED spent its time — `putstat`.
///
/// Bytes, chunk and write counts, the milliseconds inside `FSWrite` against
/// the whole receive path, what a resume started from, the CRC reseed cost
/// and the receive backlog. Measured **on that machine**, which is the only
/// place the disk can be told apart from the wire — diagnosing a transfer
/// from the far end of it is how several wrong theories got their evidence.
///
/// **This is the one the host already reads and nobody else could.** The
/// host consults these counters internally to size a transfer; a person
/// watching a slow upload had no way to ask, which is rule 3's asymmetry in
/// its plainest form.
///
/// It is the cheapest row on this surface — it reads counters and cannot
/// refuse — and it is about the LAST transfer, so it answers zeroes on a
/// machine that has received nothing this launch. Those zeroes are the
/// guest's own rows, carried through: this side does not turn them into
/// "no transfer yet", because how a guest reports an empty counter set is
/// the guest's to say.
///
/// The Carbon guest only, by derivation from `help`.
public enum TransferDiagnosticsProjection: HostProjection {
    public static let capability =
        HostCapabilityID("now_transfer_diagnostics")

    /* `putstat` alone, and NOT `file.put`: the counters describe the last
       receive and reading them asks nothing of the transfer lane. Requiring
       the lane would make a diagnostic unavailable on a guest that serves
       it, which is the association error the trio's header warns about. */
    public static let requires =
        [AgentIntegrationCapabilityNames.putstatCommand]

    public static let exposes =
        [AgentIntegrationCapabilityNames.putstatCommand]

    public static let faces: [HostCapabilityFace: HostFaceReach] = [
        .appUI: .reached(file: "DiagnosticsModuleView.swift",
                         symbol: "model.run(.putstat)"),
        .mcp: .reachedByRegistry,
        .appIntents: .appIntentsFaceNotBuiltYet,
    ]

    public static let availabilityNote =
        "The connected guest serves the putstat command."

    public static var mcpDescriptor: [String: Any] {
        let variant = HostProjectionSchema.resultVariant
        return [
            "title": "Read a New Old World Guest's Transfer Diagnostics",
            "description":
                "Reads where the last file the connected Mac RECEIVED spent its time, measured on that machine: bytes, chunk and write counts, the milliseconds inside FSWrite against the whole receive path, what a resumed transfer started from, the CRC reseed cost, and the receive backlog and its peak. Measured there because that is the only place the disk can be told apart from the wire. Takes no arguments and costs the machine nothing — it reads counters. It describes the LAST transfer, so a machine that has received nothing since it launched answers its own zeroes, carried through as it wrote them rather than reinterpreted here. Answers rows in the guest's own words.",
            "inputSchema": HostProjectionSchema.emptyInput,
            "outputSchema": [
                "oneOf": [
                    variant("completed", payload: "completed", schema:
                        diagnosticReport(
                            verb: "putstat",
                            note:
                                "Present only when a bound was reached. The guest offers none for this verb — its row set is fixed — so the only sentence that appears here is the host saying it had to shorten the answer.",
                            groupDescription:
                                "The guest's own rows, in its own order and wording. Zeroes mean the counters are zero, which on this verb is what a machine that has received nothing looks like; read the rows, not an absence.")),
                    /* The arm is rendered even though `putstat` has no
                       refusal path of its own: an `unknown-command` from a
                       guest without the verb arrives here, and so does the
                       host's own timeout. A row that omitted the arm would
                       be publishing a schema its caller can be handed
                       something outside. */
                    variant("refused", payload: "refused",
                            schema: diagnosticFailure),
                    HostProjectionSchema.unavailableVariant,
                ],
            ],
            "annotations": [
                "readOnlyHint": true,
                "destructiveHint": false,
                /* Not idempotent: the counters move as transfers happen,
                   and the whole point of reading them is that they are
                   about the machine's most recent one. */
                "idempotentHint": false,
                "openWorldHint": false,
            ],
        ]
    }

    public static func invoke(
        _ arguments: HostProjectionArguments,
        through client: AgentIntegrationClient
    ) async -> HostProjectionOutcome {
        if let refusal = arguments.refusalIfAnyPresent(tool: capability) {
            return .invalidArguments(refusal)
        }
        return .value(.init(await client.runDiagnostic(.putstat)))
    }
}
