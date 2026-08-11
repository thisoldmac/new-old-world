import CryptoKit
import Foundation

/// **A legal argument for every advertised tool.**
///
/// Getting one is the hard part of conformance, and the reason a sampling
/// driver is not good enough: the tools that are hardest to call are exactly
/// the ones nobody had ever called. Four of the act rows take a reference
/// that only `now_observe_elements` mints, and that walk did not exist on
/// this host's socket at all from 2026-07-31 until 2026-08-07 — so those
/// four had **no argument producer on any face** for a week and every gate
/// stayed green.
///
/// Three rules this book follows:
///
/// - **Chain, do not fabricate.** Where one tool mints what another needs,
///   the run calls them in that order and feeds the real value through. The
///   context below is what carries it.
/// - **A synthetic argument is declared as one.** Where nothing minted a
///   value, the recipe sends a syntactically valid reference that was never
///   minted, and the row is marked `synthetic`: the guest's revalidation
///   answering "no such reference" exercises the lane and proves nothing
///   about the capability. That distinction is a column, not a footnote.
/// - **A row with no legal argument at all is `uncovered` and named.** Never
///   skipped, never quietly absent.
enum MCPConformanceRecipes {

    /// Values harvested from earlier calls in the same run.
    struct Context {
        var elementReference: String?
        var textElementReference: String?
        var windowReference: String?
        var softwareReference: String?
        var processReference: String?
        var menu: (id: Int, item: Int, titleLeft: Int)?
        var guestFilePath: String?
        var uploadID: String?
        var mirrorSnapshotID: Int?
        var censusProbe: String?
        /// A bounded HFS-safe folder this run alone may create and use.
        let scratchFolder: String

        init() {
            scratchFolder = "NOW Conformance "
                + String(UUID().uuidString.prefix(8))
        }
    }

    enum Arguments {
        case send([String: Any], MCPConformance.ArgumentKind)
        case humanGated(String)
        case uncovered(String)
    }

    /// The recipe for one tool.
    ///
    /// `build` is a closure over the context rather than a literal because
    /// a chained argument is only known once the run reaches it.
    struct Recipe {
        let build: (Context) -> Arguments
        /// What this row proves when it is served, and what it does not.
        let note: String

        init(_ note: String,
             _ build: @escaping (Context) -> Arguments) {
            self.note = note
            self.build = build
        }

        /// The common case: fixed arguments, nothing chained.
        static func fixed(_ note: String,
                          _ arguments: [String: Any] = [:]) -> Recipe {
            Recipe(note) { _ in .send(arguments, .real) }
        }
    }

    /// A syntactically valid reference that was never minted.
    ///
    /// Deliberately a constant per prefix rather than a fresh UUID: a run's
    /// output is easier to read when the unminted references are visibly the
    /// same shape everywhere, and nothing here depends on uniqueness.
    static func unminted(_ prefix: String) -> String {
        prefix + "00000000-0000-4000-8000-000000000000"
    }

    /// The upload family addresses a transfer by a bare UUID rather than by
    /// a `now-…` reference, so its unminted form is spelled separately.
    static let neverIssuedUploadID = "00000000-0000-4000-8000-000000000000"

    /// One value owns the upload recipe's bytes, length, digest and chunk.
    /// Remembering the digest separately let the live conformance run stage
    /// four bytes and then fail its own integrity check.
    static let uploadProbe = Data("now\n".utf8)
    static let uploadProbeSHA256 = SHA256.hash(data: uploadProbe).map {
        String(format: "%02x", $0)
    }.joined()

    /// One entry per capability. The gate checks this dictionary's keys
    /// against `tools/list` **both ways**, so a capability added without a
    /// recipe fails naming itself, and a recipe for a capability that no
    /// longer exists fails too.
    // Construction-time immutable; Recipe contains only immutable closures.
    nonisolated(unsafe) static let all: [String: Recipe] = [

        // MARK: Host projects

        "now_projects": .fixed(
            "Lists the bounded host-owned Projects root without changing it "
                + "and without addressing a Macintosh.",
            ["operation": "list"]),
        "now_development_environment": .fixed(
            "Reads the guest's path-free qualified environment; needs nothing."),
        "now_development": .fixed(
            "Build status is the read-only member of the closed Development "
                + "family. It needs no project or product reference and "
                + "does not start, cancel, launch or hand off anything.",
            ["operation": "build-status"]),

        // MARK: Session

        "now_list_machines": .fixed(
            "Needs nothing. The one row whose success is proof the socket "
                + "answered at all."),
        "now_session_capabilities": .fixed(
            "probeCostly false: the cheap form, which is what a client asks "
                + "first.",
            ["probeCostly": false]),

        // MARK: The machine

        "now_hardware_census": Recipe(
            "One probe by name. The registry is the guest's, so the name is "
                + "taken from the guest's own capability report when this "
                + "run has one and falls back to the probe every guest has."
        ) { context in
            .send(["probe": context.censusProbe ?? "cpu"], .real)
        },
        "now_machine_facts": .fixed("Needs nothing."),
        "now_list_processes": .fixed("Needs nothing."),

        // MARK: The observation that mints everything below

        "now_observe_elements": .fixed(
            "No serial: an absent process is a COMPLETE request meaning the "
                + "frontmost application. This row is the argument producer "
                + "for four of the act rows, so its verdict decides whether "
                + "they run on minted references or synthetic ones."),

        // MARK: Mirror

        /* First of the family, and that is a chain rather than tidiness:
           every other `now_semantic_ui_*` row reads a state engine that only
           runs while the Mirror is open, and a conformance host launched
           without `--open-mirror` has none. Its own descriptor says so.

           It arrived here at the 019 integration round 3 rather than with
           the row: `018-open-mirror` landed the capability and
           `019-conformance` landed this recipe book, on branches neither
           of which could see the other. The gate named it on the merge —
           which is the whole reason it checks the surface BOTH ways
           instead of sampling. */
        "now_semantic_ui_start": .fixed(
            "Needs nothing. Opening a Mirror loses no work and asking "
                + "twice leaves one, so a conformance run may take it."),
        "now_semantic_ui_status": .fixed("Needs nothing."),
        "now_semantic_ui_snapshot": .fixed("Needs nothing."),
        "now_semantic_ui_find": .fixed(
            "A query that matches whatever is there. Finding nothing is a "
                + "served answer, not a refusal.",
            ["query": "e"]),
        "now_semantic_ui_wait": Recipe(
            "Waits for the snapshot AFTER the one this run has in hand, "
                + "with the shortest timeout the schema allows — a "
                + "conformance run may not hold a lane open."
        ) { context in
            .send(["afterSnapshotID": context.mirrorSnapshotID ?? 1,
                   "timeoutMs": 1000], context.mirrorSnapshotID == nil
                    ? .synthetic : .real)
        },
        "now_semantic_ui_metrics": .fixed("Needs nothing."),
        "now_semantic_ui_lifecycle": .fixed("Needs nothing."),
        "now_semantic_ui_journal": .fixed("Needs nothing."),
        "now_semantic_ui_wait_for_settlement": .fixed(
            "A never-issued operation ID is a complete bounded query; a live "
                + "run may honestly answer not found without dispatching.",
            ["operationID": "conformance-never-issued", "timeoutMs": 1]),
        "now_semantic_ui_act": .fixed(
            "cancel: the one gesture that acts on the HOST's lane rather than "
                + "the machine, so it needs no entity and no published "
                + "scene. Every other gesture would move something this "
                + "run's later rows read.",
            ["gesture": "cancel"]),
        "now_guest_log_tail": .fixed(
            "One of the three lanes that were advertised and dead until "
                + "2026-08-07.",
            ["lines": 5]),

        // MARK: Costly observation

        "now_capture_screen": .fixed(
            "Depth 1: a legible monochrome screen in tens of kilobytes. A "
                + "conformance run has no business asking a 1400c for 32 "
                + "bits per pixel.",
            ["depth": 1]),
        "now_stream_screen": .fixed(
            "stop, and deliberately not start: a stream and a capture are "
                + "mutually exclusive on the wire, so opening a bracket here "
                + "would decide the verdict of the row above by ordering. "
                + "Stopping a bracket nobody opened is a real request with a "
                + "real answer.",
            ["intention": "stop"]),
        "now_catalog_search": .fixed("Needs nothing."),
        "now_framebuffer_probe": .fixed("Needs nothing."),
        "now_capture_diagnostics": .fixed("Needs nothing."),
        "now_transfer_diagnostics": .fixed("Needs nothing."),
        "now_software_inventory": .fixed(
            "The apps domain, from the start. Absent cursor rebuilds the "
                + "guest's cache, which is the whole sweep and the honest "
                + "first call.",
            ["domain": "apps"]),

        // MARK: The verbs that change the machine

        "now_launch_software": Recipe(
            "By reference when the inventory above minted one, and never by "
                + "name: a name would launch whatever matched on the "
                + "machine, which a conformance run must not decide."
        ) { context in
            guard let reference = context.softwareReference else {
                return .send(
                    ["reference": unminted("now-software-")], .synthetic)
            }
            return .send(["reference": reference], .real)
        },
        "now_reveal_item": .fixed(
            "The System Folder, which exists on every Mac OS volume and is "
                + "opened rather than moved.",
            ["target": "System Folder"]),
        "now_bring_to_front": Recipe(
            "A process reference `now_list_processes` minted, so the front "
                + "it asks for is one the machine actually has. It is the "
                + "one act row in this run that is allowed a real target: "
                + "fronting an application is reversible by fronting "
                + "another, and it destroys nothing."
        ) { context in
            guard let reference = context.processReference else {
                return .send(
                    ["reference": unminted("now-process-")], .synthetic)
            }
            return .send(["reference": reference], .real)
        },
        "now_request_quit": Recipe(
            "**Deliberately unsatisfiable.** A completed quit would end a "
                + "process the rest of this run reads, and a conformance "
                + "driver that closes applications on the machine it is "
                + "measuring is not one anybody will run twice. The refusal "
                + "is the pass, and the row is marked synthetic so nobody "
                + "reads it as proof the verb works."
        ) { _ in
            .send(["reference": unminted("now-process-")], .synthetic)
        },

        // MARK: The act plane

        "now_window_act": Recipe(
            "select, on an observed window. The one act that changes nothing "
                + "a later row reads — move and resize would leave the "
                + "machine somewhere this run put it."
        ) { context in
            guard let window = context.windowReference else {
                return .send(["window": unminted("now-window-"),
                              "action": "select"], .synthetic)
            }
            return .send(["window": window, "action": "select"], .real)
        },
        "now_control_act": Recipe(
            "**Synthetic on purpose even when a reference exists.** Pressing "
                + "an arbitrary observed control presses whatever it happens "
                + "to be — a Quit button, an OK on a dialog nobody read. "
                + "The lane is exercised by a reference the guest refuses; "
                + "the capability is proven by a driven pass, not by this."
        ) { _ in
            .send(["element": unminted("now-element-"), "part": 10],
                  .synthetic)
        },
        "now_menu_act": Recipe(
            "**Synthetic on purpose**, for the same reason as the control "
                + "row: an arbitrary menu item on the front application is "
                + "an arbitrary command. titleLeft is sent because it is the "
                + "act's identity check, earned by the 18/20 hijack "
                + "measurement, and a driver that omitted it would be "
                + "exercising a weaker path than the product's."
        ) { _ in
            .send(["menu": 32767, "item": 1, "titleLeft": -32768],
                  .synthetic)
        },
        "now_text_get": Recipe(
            "A minted text reference when the walk found one — this is the "
                + "row a completed reading has to come through — and an "
                + "unminted one otherwise."
        ) { context in
            guard let element = context.textElementReference else {
                return .send(["element": unminted("now-element-")],
                             .synthetic)
            }
            return .send(["element": element], .real)
        },
        "now_text_set": Recipe(
            "**Synthetic always.** The write is destructive and has no undo "
                + "this surface can reach; replacing the contents of "
                + "whatever field happened to be observed is not something a "
                + "gate may do. Its reachability was proven by a driven "
                + "pass, not here."
        ) { _ in
            .send(["element": unminted("now-element-"),
                   "text": "conformance"], .synthetic)
        },

        // MARK: Transfers

        "now_transfer_approved_artifact": Recipe(
            "**Human-gated.** An approval receipt is minted by a person "
                + "approving a transfer in the host's own UI, and nothing on "
                + "this surface can produce one — there is no MCP row that "
                + "offers an artifact for approval. A syntactic receipt "
                + "would exercise the pattern check and nothing else, so it "
                + "is named as an authority boundary instead of dressed up "
                + "as a refusal."
        ) { _ in
            .humanGated(
                "no MCP row mints an approvalReceipt; it comes from a "
                    + "person approving a transfer in the host UI")
        },
        "now_transfer_cancel": .fixed(
            "Needs nothing. Cancelling a transfer nobody started is a real "
                + "request with a real answer."),

        // MARK: Guest Files

        "now_guest_files_capabilities": .fixed("Needs nothing."),
        "now_guest_files_list": .fixed(
            "No path: the host-owned guestRoot. This row mints the paths the "
                + "three below take."),
        "now_guest_files_stat": Recipe(
            "A path the listing above returned."
        ) { context in
            guard let path = context.guestFilePath else {
                return .send(["path": "no-such-item"], .synthetic)
            }
            return .send(["path": path], .real)
        },
        "now_guest_files_download": Recipe(
            "The same path the stat took."
        ) { context in
            guard let path = context.guestFilePath else {
                return .send(["path": "no-such-item"], .synthetic)
            }
            return .send(["path": path], .real)
        },
        "now_guest_files_mutate": Recipe(
            "mkdir, into a folder named for this run. The only mutation "
                + "shape that creates rather than moves or destroys — a "
                + "trash or a move would act on a file somebody put there."
        ) { context in
            .send(["mutation": "mkdir", "path": context.scratchFolder],
                  .real)
        },
        "now_guest_files_upload_begin": Recipe(
            "A four-byte file, by its real sha256. This row mints the "
                + "uploadID the two below take, so it runs before them and "
                + "they chain off it."
        ) { context in
            .send([
                "destinationPath": context.scratchFolder + ":probe.txt",
                "bytes": uploadProbe.count,
                "container": "data",
                "sha256": uploadProbeSHA256,
            ], .real)
        },
        "now_guest_files_upload_append": Recipe(
            "The four bytes, at offset zero, against the upload the row "
                + "above opened."
        ) { context in
            guard let uploadID = context.uploadID else {
                return .send(["uploadID": neverIssuedUploadID,
                              "offset": 0,
                              "data": uploadProbe.base64EncodedString()],
                             .synthetic)
            }
            return .send(["uploadID": uploadID, "offset": 0,
                          "data": uploadProbe.base64EncodedString()],
                         .real)
        },
        "now_guest_files_upload_commit": Recipe(
            "Closes the same upload. A run that left one open would leave a "
                + "temp fork on the machine it was measuring."
        ) { context in
            guard let uploadID = context.uploadID else {
                return .send(["uploadID": neverIssuedUploadID], .synthetic)
            }
            return .send(["uploadID": uploadID], .real)
        },
    ]

    /// The order the run calls them in.
    ///
    /// It is **not** the catalog order, and the difference is the point: a
    /// producer must run before its consumers. Everything not named here
    /// runs afterwards in the surface's own order, so a new capability needs
    /// no edit unless something chains off it.
    static let producersFirst = [
        "now_list_machines",
        "now_session_capabilities",
        "now_list_processes",
        // Before every other Mirror row, for the reason its recipe gives:
        // they read an engine that does not run until this has been asked.
        "now_semantic_ui_start",
        "now_semantic_ui_snapshot",
        "now_observe_elements",
        "now_software_inventory",
        "now_guest_files_list",
        "now_guest_files_mutate",
        "now_guest_files_upload_begin",
    ]
}
