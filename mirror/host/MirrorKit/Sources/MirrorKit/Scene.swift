import Foundation

/// The scene IR — the mirror's answer to "what's on the guest screen".
///
/// Port source: `prototypes/mirror/scene.py` (schema v0), which retires into
/// the golden-fixture oracle once this port passes its fixtures.
///
/// **FROZEN AT v1** (2026-07-31, MIRRORKIT-PLAN decision 5 — the parity gate).
/// The encoded field set is enumerated in `IRSchema` and asserted by
/// `IRFreezeTests`: adding or removing a field here turns the suite red. New
/// fields are additive within v1 (record them in `IRSchema.v1Additions`);
/// removing or renaming one moves `IR.version`. See `IRVersion.swift`.
///
/// Two properties are deliberately **outside** the frozen IR and excluded
/// from `Codable` — `Window.displayEpoch` and `Window.contentPlane`. Reasons
/// at their declarations. (`Window.island` was the first of that family and
/// was removed outright on 2026-08-07; `Window.items` was excluded with it and
/// re-entered as an additive v1 field on 2026-07-31, so it encodes.)
public struct Scene: Codable, Equatable, Sendable {
    /// IR version stamp — the body's self-stamp, the same number the service
    /// puts in `result["irVersion"]`. Always `IR.version`; the fixture corpus
    /// is pinned to it.
    public var version: Int
    /// Monotonically increasing per poller run.
    public var seq: Int
    /// "axtree" | "observe" (| "mock" in the spike).
    public var source: String
    /// Host epoch seconds at capture. Injected, not sampled, so scene
    /// building is a pure function (and fixture-testable).
    public var capturedAt: Double
    public var screen: ScreenSize
    public var apps: [AppRef]
    /// The real cross-process Process Manager truth — only the observe plane
    /// fills this shelf today.
    public var processes: [ProcessRef]?
    /// Front app's menubar, or nil (observe plane, or no menus on the wire).
    public var menubar: Menubar?
    /// Global stacking order, index 0 = frontmost.
    public var windows: [Window]
    /// Desktop icons from the Desktop Folder's Finder Info (fdLocation) —
    /// a semantic layer, not pixels. nil when not fetched this poll.
    public var desktopItems: [DesktopItem]?
    public var meta: Meta

    /// V1 required producers to spell a role even when they could not
    /// observe one. It remains decodable for fixtures and differential
    /// comparison, but no action may be authorized from that approximation.
    public var isApproximateReadOnly: Bool { version == 1 }

    public enum Knowledge: String, Codable, Equatable, Sendable {
        case known
        /// The machine named the CODE that draws this control - a `CDEF`
        /// resource id, via the Resource Manager - and the guest looked
        /// the id up in a documented table. One remove from `known`,
        /// which is the control answering about itself through
        /// `kControlKindTag`, and the distance matters: OS 9's own
        /// control panels build their controls from `CNTL` resources and
        /// the Control Manager declines to name them at all (measured
        /// 2026-08-07: Appearance 2 of 73, Date & Time 0 of 21), so
        /// `derived` is the only answer that exists for most of what a
        /// person actually drives. It is not a guess and it is not
        /// `known`; a consumer that needs the stronger claim tests for
        /// `known` explicitly.
        case derived
        case unknown
        case truncated
        case stale
    }

    public enum Completeness: String, Codable, Equatable, Sendable {
        case complete
        case partial
    }

    /// Whether a collection in this capture is authoritative enough to
    /// replace prior state. Only `complete` authorizes deletion of members
    /// that are absent from the new capture; every other value preserves the
    /// last complete observation and records why it could not be refreshed.
    public enum CoverageStatus: String, Codable, Equatable, Sendable {
        case complete
        case partial
        case retracted
        case failed
        case stale
        case unavailable
    }

    /// A typed collection-level observation claim. `owner` is a durable
    /// incarnation when the collection belongs to a process (for example its
    /// windows or menu bar), and is absent for machine-wide collections.
    public struct CoverageClaim: Codable, Equatable, Sendable {
        public var scope: String
        public var owner: String?
        public var status: CoverageStatus
        public var reason: String?
        /// How many members this claim's own bounded ledger has had to
        /// FORGET. Present only on `depth`, and only when nonzero.
        ///
        /// It exists because "absent because we forgot it" and "absent
        /// because we never saw it" are different facts, and a bounded
        /// ledger silently turns the first into the second. The front-order
        /// table keeps 32 slots; past that a process's rank is absent for a
        /// reason nothing on the wire could state.
        public var evicted: Int?

        public init(scope: String, owner: String? = nil,
                    status: CoverageStatus, reason: String? = nil,
                    evicted: Int? = nil) {
            self.scope = scope
            self.owner = owner
            self.status = status
            self.reason = reason
            self.evicted = evicted
        }
    }

    public struct Selection: Codable, Equatable, Sendable {
        public var start: Int
        public var end: Int
        public init(start: Int, end: Int) {
            self.start = start
            self.end = end
        }
    }

    /// One bounded List Manager cell reported by the guest semantic plane.
    /// Rows are 1-based and columns 0-based, preserving the resident table's
    /// native coordinate conventions instead of flattening a multi-column
    /// list into one lossy string.
    public struct ListCell: Codable, Equatable, Sendable {
        public var row: Int
        public var column: Int
        public var text: String
        public var selected: Bool

        public init(row: Int, column: Int, text: String, selected: Bool) {
            self.row = row
            self.column = column
            self.text = text
            self.selected = selected
        }
    }

    /// Evidence carried by IR v2. Every semantic field is independently
    /// optional; absence never means false. `knowledge` describes the whole
    /// observation, while `completeness` prevents a bounded prefix from
    /// becoming actionable.
    public struct Semantics: Codable, Equatable, Sendable {
        public var knowledge: Knowledge
        public var kind: String?
        /// WHERE the control's definition function came from, when `kind`
        /// could not be determined: `system`, `application` or
        /// `indeterminate`. It is a strictly weaker claim than `kind` and
        /// must never be promoted into one — `system` says a documented
        /// answer exists somewhere, not that this is a push button. It
        /// exists to size the undetermined population: a system-defined
        /// control is a producer gap worth closing, an application-defined
        /// one is a control whose only evidence will ever be its drawing.
        public var definition: String?
        /// The resource id of the control definition function the guest's
        /// Resource Manager named, when `kind` could not be determined
        /// anyway. Present only beside `knowledge == .unknown`, and it
        /// separates two very different gaps: no id at all means the guest
        /// could not even ask, while an id means the lookup worked and the
        /// id was not enough.
        ///
        /// Ids 0 and 23 are the overwhelming case and are the classic and
        /// Appearance button FAMILIES — push button, check box and radio
        /// button behind one id, told apart only by a variation code that
        /// cannot be read from outside the owning process. So most of an
        /// OS 9 control panel's controls are `unknown` with `cdef: 0`.
        ///
        /// NEVER MAP THIS TO A KIND. `cdef: 0` is not a push button; it is
        /// three possible controls with one number, and treating it as the
        /// first of them is the exact defect this field records.
        public var cdef: Int?
        public var action: String?
        public var state: String?
        public var value: String?
        public var listCells: [ListCell]?
        public var listTotalCount: Int?
        public var selection: Selection?
        public var focused: Bool?
        public var isDefault: Bool?
        public var provenance: String?
        public var completeness: Completeness?

        public init(knowledge: Knowledge, kind: String? = nil,
                    definition: String? = nil,
                    cdef: Int? = nil,
                    action: String? = nil, state: String? = nil,
                    value: String? = nil,
                    listCells: [ListCell]? = nil,
                    listTotalCount: Int? = nil,
                    selection: Selection? = nil,
                    focused: Bool? = nil, isDefault: Bool? = nil,
                    provenance: String? = nil,
                    completeness: Completeness? = nil) {
            self.knowledge = knowledge
            self.kind = kind
            self.definition = definition
            self.cdef = cdef
            self.action = action
            self.state = state
            self.value = value
            self.listCells = listCells
            self.listTotalCount = listTotalCount
            self.selection = selection
            self.focused = focused
            self.isDefault = isDefault
            self.provenance = provenance
            self.completeness = completeness
        }

        /// WHY `derived` AUTHORISES. The bar this property enforces is
        /// "the machine said so", not "the strongest possible source said
        /// so". A `CDEF` resource id comes from the Resource Manager
        /// naming a loaded resource; the id-to-kind table is Apple's own
        /// `ControlDefinitions.h`. Nothing in that chain is a shape
        /// heuristic or a value-range guess - which is what
        /// `presentation-inference` is, and why it stays excluded by
        /// name. Holding `derived` out would have left every control in
        /// every OS 9 control panel undrivable while the render drew them
        /// perfectly, which is the exact split this refuses to ship.
        public var authorizesAction: Bool {
            (knowledge == .known || knowledge == .derived)
                && completeness == .complete
                && action != nil
                && provenance != "presentation-inference"
        }
    }

    /// **The guest's screen, and the only place its size is stated.**
    ///
    /// One machine, one answer: the guest measures its own `gdRect` and
    /// sends `scene.screen.w/h`, and every consumer reads it from here.
    /// Nothing on this side may decide for itself what size the other
    /// machine's screen is — four places once did (800×600 in the host
    /// window, 800×600 in the poller, 1024×768 in the theme, 640×480 in
    /// the chat prompt), and a wrong screen is not cosmetic: it decides
    /// hit-test mapping, what "fit" means, and what a model is told it
    /// is looking at.
    ///
    /// `unknown` is a state, not a missing value. It means the guest has
    /// not said yet — never "assume something plausible". A caller that
    /// cannot proceed without a size refuses and says so.
    public struct ScreenSize: Codable, Equatable, Sendable {
        public var w: Int
        public var h: Int
        public init(w: Int, h: Int) { self.w = w; self.h = h }

        /// No guest has said. Distinct from a real screen, and the wire's
        /// own encoding of absence — a scene with no `screen` object
        /// decodes to zeroes.
        public static let unknown = ScreenSize(w: 0, h: 0)

        public var isKnown: Bool { w > 0 && h > 0 }

        /// The size, or nil when no guest has said. The form a consumer
        /// should reach for, because it cannot be used without deciding
        /// what to do about `unknown`.
        public var known: ScreenSize? { isKnown ? self : nil }
    }

    public struct AppRef: Codable, Equatable, Sendable {
        public var psn: String
        public var name: String
        public var front: Bool
        /// Process identity across captures. A PSN alone can be reused after
        /// an application quits, so reducers key continuity from this token.
        public var incarnation: String? = nil
        /// The process's own declaration that it has no user interface —
        /// `modeOnlyBackground` in its 'SIZE' resource, as the guest's
        /// Process Manager reports it. "Headless" and "faceless" are the
        /// same fact in prose.
        ///
        /// `nil` is NOT `false`. It means the producer did not say, which
        /// is a different claim from "this process has a face"; a scene
        /// from a guest that predates the field reads nil on every row.
        /// Never derive it from a window count — see `ProcessPresence`.
        public var backgroundOnly: Bool? = nil
        /// Per-app oracle error (`ax_oracle_*`), surfaced honestly.
        public var error: String?
    }

    public struct ProcessRef: Codable, Equatable, Sendable {
        public var psn: String
        public var name: String
        public var front: Bool
        public var signature: String
        public var incarnation: String? = nil
        /// See `AppRef.backgroundOnly`. Carried on both rows because the
        /// two arrays are populated from the same Process Manager walk
        /// and a consumer may hold either.
        public var backgroundOnly: Bool? = nil
    }

    public struct Menubar: Codable, Equatable, Sendable {
        public var app: String
        public var menus: [Menu]
    }

    public struct Menu: Codable, Equatable, Sendable {
        /// Empty for the Apple menu (the wire sends the Chicago apple byte).
        public var title: String
        public var apple: Bool
        /// Guest menubar x of this title (MenuList `left`), or **nil when
        /// the producer did not report one**.
        ///
        /// Optional because it used to default to 0, and 0 is not a
        /// missing reading — it is the x of the leftmost menu. A menu act
        /// arms its press at this coordinate plus four, so an unreported
        /// `left` armed at x=4, which is the Apple menu, and answered
        /// whoever pressed it next. That is the measured 18/20 hijack
        /// reintroduced by a `?? 0` (2026-08-07). The host knew it had
        /// never learned the number and manufactured one anyway.
        ///
        /// So the absence is carried rather than filled, and every
        /// consumer answers it the same way: a menu bar is a POSITIONAL
        /// surface, so a menu with no position is not drawn, not hit
        /// tested, and not pressed. A title painted at an invented
        /// position and a press armed at one are the same mistake at two
        /// severities, and giving the renderer a fallback the act path
        /// refused would put the two back into disagreement — which is
        /// the defect this whole change exists to close.
        public var left: Int?
        /// The guest's own menu ID. Carried because acting by IDENTITY needs it:
        /// the Portal answers the application's MenuSelect with (menuID, item),
        /// and a title is not an identity the Menu Manager understands.
        public var id: Int
        public var items: [MenuItem]
    }

    public struct MenuItem: Codable, Equatable, Sendable {
        public var title: String
        /// 1-based Menu Manager item index — the row the guest will draw
        /// this item at when the menu opens (menu-drag targeting).
        public var index: Int
        public var separator: Bool
        public var enabled: Bool
        public var mark: Bool
        /// ⌘-shortcut character, or "" — actuation sends the KEYCODE, not
        /// this char (Finder matches on keycode; CONTROL-SURFACE.md).
        public var cmd: String
    }

    /// **Which kind of empty an empty `controls` array is.**
    ///
    /// `controls` is required by the IR, so `[]` has carried three
    /// different facts since the plane was written and there was nowhere
    /// beside it to say which. The producer's own verdict prose named two
    /// of them in a sentence in `meta.errors`, keyed on a window title —
    /// readable by a person and by nothing else.
    ///
    /// `notFetched` is the one that had no name at all. The guest's
    /// control pool is shared across every window in a scene; a window
    /// walked after it filled is refused a slot and retracts, so a panel
    /// with twenty controls arrives as `[]` for a reason that has nothing
    /// to do with that panel.
    ///
    /// - `empty` is a fact about the MACHINE and the only one of the four
    ///   that licenses drawing a bare window.
    /// - `unknown` is the machine being unreadable where we may look.
    /// - `notFetched` is a fact about US, and the only one asking again
    ///   could answer.
    public enum ControlsState: String, Codable, Equatable, Sendable {
        case complete
        case empty
        case unknown
        case notFetched
    }

    public struct Window: Codable, Equatable, Sendable {
        /// Stable-ish: psn + title + occurrence index.
        public var id: String
        public var app: String
        public var psn: String
        public var title: String
        public var kind: Int?
        /// Rendered box in global px — content port grown upward by the
        /// title-bar height.
        public var rect: Rect
        /// Frontmost window of the front app.
        public var front: Bool
        public var z: Int
        /// The Window Manager's visible flag, honestly carried — renderers
        /// and action models decide what to do with an invisible window.
        public var visible: Bool
        public var controls: [Control]
        /// **Which kind of empty `controls` is** — see ``ControlsState``.
        ///
        /// The producer sends it only where the array cannot speak for
        /// itself, so `nil` beside a NON-empty array means `complete` and
        /// `nil` beside an empty one means `unknown`. Read it through
        /// ``controlsKnowledge``, never directly; the raw optional exists
        /// to keep an unrecognised future word decodable.
        public var controlsState: String? = nil
        /// Live Dialog Manager items, distinct from the structural Control
        /// Manager chain because edit/static items do not share its identity
        /// or actuation path. nil means not reported; [] means proven empty.
        public var dialogItems: [DialogItem]? = nil
        /// The act-plane reference this window actuates through - the same
        /// symmetry invariant `Control.ref` carries, one level up.
        ///
        /// **The producer has always sent it and this model dropped it**,
        /// which is why no window has ever been closable, movable or
        /// resizable from a mirror: every act addressed by reference needs
        /// one, and a windowID (`psn + title + occurrence`) is a rendering
        /// key that nothing on a guest can resolve. The archived NOW port
        /// recorded the same drop one layer further out and stopped there.
        ///
        /// Optional because a producer may honestly have none: NOW's own
        /// Carbon window is not readable at the classic offsets, so it
        /// reports no reference rather than a fabricated one.
        public var ref: String? = nil
        /// The window record's own address on the guest, when the producer
        /// could say.
        ///
        /// Carried for ONE reason: it is the only exact join key between a
        /// scene and the machine it describes. `id` is a rendering key that
        /// moves when the title or the stacking moves, titles collide, and
        /// a modal alert has none — so a structural differ keyed on any of
        /// them mis-joins, and a mis-join is indistinguishable from a real
        /// mismatch. Nothing renders from this; it exists so a harness can
        /// say *which* window it is comparing.
        public var addr: UInt32? = nil
        /// Process incarnation plus the exact WindowRecord address. Absent
        /// for windows the guest cannot identify exactly (notably a Carbon
        /// application describing its own window through the Toolbox).
        public var incarnation: String? = nil
        /// **Whether the machine draws a close box / a zoom box** — the
        /// WindowRecord's own `goAwayFlag` and `spareFlag`, one byte each,
        /// beside the `windowKind` the walk already reads.
        ///
        /// They exist because this side was INFERRING them from `kind`, and
        /// `kind` cannot carry the answer. The corpus falsifies the inference
        /// with a single pair: **Extensions Manager is `kind == 2` and HAS a
        /// zoom box; Memory is `kind == 2` and has none.** Seven of eleven
        /// windows were drawn one the machine does not draw, `HitTester`
        /// reported it, and a zoom act therefore sent a click into the racing
        /// stripes — which the Window Manager reads as the start of a DRAG.
        ///
        /// **nil is "not reported", never "no such widget."** A producer that
        /// has not learned to send these leaves them absent, and a consumer
        /// keeps whatever it did before rather than taking a close box away
        /// from every older guest. `WindowChrome` is where that asymmetry is
        /// spelled out: a zoom box needs proof, a close box needs only the
        /// absence of a denial.
        ///
        /// There is no `growBox` companion — see ``WindowChrome/growBox(_:)``
        /// and mirror/docs/IR-V2.md. The record holds no grow flag.
        public var closeBox: Bool? = nil
        public var zoomBox: Bool? = nil
        /// Dialog TextEdit content (`kind==2` windows only today).
        public var text: TextContent?
        /// Icon-view items for a Finder window, in WINDOW-LOCAL content
        /// coords — the Finder's own live `position of`, which is scroll-
        /// compensated (`FinderItems`). nil when not fetched, or when the
        /// window is not a resolvable Finder folder window.
        ///
        /// **Additive within IR v1** (`IRSchema.v1Additions`, lane H2
        /// 2026-07-31). It was held out of the v1 freeze because the only
        /// source then available was `fdLocation`, the SAVED icon grid, whose
        /// values are wrong the moment the Finder lays a window out or scrolls
        /// it — and freezing a field whose values are known wrong obliges us
        /// to keep serving the wrong number. It re-enters now that the
        /// positions are the Finder's own, verified by clicking a computed
        /// point and being told the right file was selected. No major bump:
        /// a consumer that has never heard of the key ignores it.
        public var items: [DesktopItem]? = nil
        /// The QuickDraw content plane: draw ops captured by QDPeek
        /// (`qdtrace`), port-local coords, replayed into the content area.
        /// nil when not traced. The renderer draws it in place of the empty
        /// content rect.
        public var display: [DisplayOp]?
        /// Which clock `display` came off — see ``DisplayEpoch``. nil means
        /// this window has NO content stream, which is the common healthy
        /// case and renders semantics-only rather than waiting.
        ///
        /// **Not in the frozen IR (v1/v2)**: it is host-internal render state
        /// that happens to live on this struct. Every number in it already
        /// crosses the wire on the drain records themselves.
        public var displayEpoch: DisplayEpoch? = nil
        /* REMOVED 2026-08-07: `island: PixelIsland?`.
           It held this window's content area as the guest's REAL pixels,
           fetched over the wire by `ScenePoller` and composited into the
           render. NOW gates over-the-wire pixels as a post-stability
           enrichment; the feature arrived as a passenger inside the
           1 August wholesale vendoring of this subproject, and nobody
           decided to cross the gate.

           Why it had to go rather than be left switched off: wherever an
           island covered a window, comparing "our render" against "the
           guest's pixels" compared the guest's pixels against themselves.
           The measurement and its subject were the same bytes.

           Prior art, kept whole for a later deliberate re-implementation:
           `archive/pixel-islands-2026-08-07/`. */
        /// **Whether the content plane was ever ASKED about this window** —
        /// see ``ContentPlaneAttention``. nil when the host has no content
        /// plane at all (no P3, or a guest that does not serve `qdtrace`),
        /// which is the case where neither answer would be true.
        ///
        /// **Not in the frozen IR**, for the same reason `displayEpoch` is
        /// not: host-internal render state that happens to live
        /// on this struct. It describes what THIS host did, not what the
        /// machine is, so there is nothing for a guest to send.
        public var contentPlane: ContentPlaneAttention? = nil

        /// The frozen IR is everything except the two host-internal shelves
        /// above. Listing the keys explicitly is also what makes an
        /// accidentally-added property fail to encode silently: a new field
        /// must be named here to reach the wire, and named in `IRSchema` to
        /// pass the freeze gate.
        enum CodingKeys: String, CodingKey {
            case id, app, psn, title, kind, rect, front, z, visible
            case controls, controlsState, dialogItems, text, display
            case items          // additive in v1 — see the declaration
            case ref            // additive in v1 — see the declaration
            case addr           // additive in v1 — see the declaration
            case incarnation    // IR v2 durable reducer identity
            case closeBox, zoomBox  // IR v2 — see the declarations
        }

        /// **What is known about this window's controls**, with the
        /// producer's economy undone in one place.
        ///
        /// The word rides only where the array is empty, so this applies
        /// the three rules that make absence unambiguous:
        ///
        /// 1. A non-empty `controls` is `complete`. No other state can
        ///    produce one, so the producer does not spend 28 bytes per
        ///    window saying so — measured at 900 bytes against a 64 KB
        ///    scene ceiling the guest already touches.
        /// 2. An empty `controls` WITH the word means the word.
        /// 3. An empty `controls` WITHOUT it is `unknown`, because it came
        ///    from a producer that does not report this and therefore
        ///    could not tell us. Reading it as `empty` would be the
        ///    conflation the field exists to end, one layer up.
        ///
        /// A word this build has never heard of is also `unknown` — a
        /// newer guest saying something we cannot interpret is precisely
        /// the case for admitting we do not know.
        public var controlsKnowledge: ControlsState {
            if !controls.isEmpty { return .complete }
            guard let raw = controlsState,
                  let state = ControlsState(rawValue: raw) else {
                return .unknown
            }
            /* `complete` beside an empty array is not a state this
               producer can be in; taking it at its word would assert
               "walked, and here they are" over nothing. */
            return state == .complete ? .unknown : state
        }
    }

    public struct Control: Codable, Equatable, Sendable {
        /// The ax2 ref this control actuates through — the symmetry invariant.
        public var ref: String
        /// "control", or "scrollbar" when ranged.
        public var role: String
        public var title: String
        /// Content-relative rect for rendering; nil when the wire had none.
        public var rect: Rect?
        public var enabled: Bool
        /// Hidden controls (e.g. a closed drawer's sliders) are carried,
        /// not dropped — `axdo` refuses them anyway (`not_actionable`).
        public var visible: Bool
        public var value: Int?
        public var min: Int?
        public var max: Int?
        /// Whether a checkbox-like control is on.
        ///
        /// **Decodes to false when absent**, and that tolerance is
        /// deliberate rather than lax. A producer that reads a
        /// ControlRecord without its defProc cannot say what KIND of
        /// control it has, and `checked` is meaningless without that -
        /// NOW's scene walk says exactly this and refuses to emit the
        /// key rather than assert a fact it cannot know. Requiring it
        /// made an otherwise complete and correct IR v1 document
        /// undecodable over one field nobody could honestly fill.
        ///
        /// Absent therefore means "not known to be checked", which is
        /// what false already meant for every control that is not a
        /// checkbox. A producer that CAN determine it still sends it.
        public var checked: Bool = false
        /// IR v2 evidence. nil on v1 is approximate presentation only and
        /// cannot authorize an action.
        public var semantic: Semantics? = nil

        /* Declaring an initialiser suppresses the compiler's memberwise
           one, and SceneBuilder builds these by hand - so it is restored
           verbatim rather than left to be discovered as a type-check
           timeout in another file. */
        public init(ref: String, role: String, title: String,
                    rect: Rect? = nil, enabled: Bool, visible: Bool,
                    value: Int? = nil, min: Int? = nil, max: Int? = nil,
                    checked: Bool = false, semantic: Semantics? = nil) {
            self.ref = ref
            self.role = role
            self.title = title
            self.rect = rect
            self.enabled = enabled
            self.visible = visible
            self.value = value
            self.min = min
            self.max = max
            self.checked = checked
            self.semantic = semantic
        }

        /* Swift's synthesised Decodable demands every non-optional key
           whether or not the property has a default, so the tolerance
           above needs saying out loud. Everything else decodes exactly as
           the synthesised initialiser would. */
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            ref = try c.decode(String.self, forKey: .ref)
            role = try c.decode(String.self, forKey: .role)
            title = try c.decode(String.self, forKey: .title)
            rect = try c.decodeIfPresent(Rect.self, forKey: .rect)
            enabled = try c.decode(Bool.self, forKey: .enabled)
            visible = try c.decode(Bool.self, forKey: .visible)
            value = try c.decodeIfPresent(Int.self, forKey: .value)
            min = try c.decodeIfPresent(Int.self, forKey: .min)
            max = try c.decodeIfPresent(Int.self, forKey: .max)
            checked = try c.decodeIfPresent(Bool.self, forKey: .checked) ?? false
            semantic = try c.decodeIfPresent(Semantics.self, forKey: .semantic)
        }
    }

    public struct DialogItem: Codable, Equatable, Sendable {
        public var number: Int
        public var title: String
        public var rect: Rect
        public var enabled: Bool
        public var visible: Bool
        public var ref: String?
        public var semantic: Semantics

        public init(number: Int, title: String, rect: Rect, enabled: Bool,
                    visible: Bool, ref: String? = nil,
                    semantic: Semantics) {
            self.number = number
            self.title = title
            self.rect = rect
            self.enabled = enabled
            self.visible = visible
            self.ref = ref
            self.semantic = semantic
        }
    }

    public struct TextContent: Codable, Equatable, Sendable {
        public var content: String
        public var active: Bool
    }

    /// One desktop icon. Position is the saved Finder `fdLocation` in GLOBAL
    /// screen coords; `placed` is false for {0,0} (Finder auto-arranges those
    /// at draw time — the real position isn't in the catalog, so we don't
    /// invent one). `type`/`creator` key a future per-app icon; today the
    /// renderer draws a generic glyph by kind/alias.
    public struct DesktopItem: Codable, Equatable, Sendable {
        public var name: String
        /// `folder` | `disk` | `application` | `file`, reduced from the
        /// Finder's own kind string by whichever producer read it.
        ///
        /// **It is four words, and it does not name a control panel** — a
        /// `cdev` arrives here as a plain `file`, so anything that needs to
        /// tell one from a document reads `type` rather than this. Said
        /// out loud because this comment used to claim two of the four,
        /// and a reader who believed it would predict a Finder window for
        /// every control panel — which is exactly the settlement defect of
        /// 2026-08-05.
        public var kind: String
        public var type: String?
        public var creator: String?
        public var x: Int
        public var y: Int
        /// The size of the box the Finder actually drew, when the producer
        /// asked for it — `bounds of` an item, minus its top-left.
        ///
        /// **Why a size at all, when every icon is 32×32.** It is not. A
        /// window in list view draws a 16×16 row icon, and one in small-icon
        /// view a 16×16 icon on a different grid; only the icon view's box is
        /// 32×32. A producer that reported a position and let the reader
        /// assume the size therefore described a list row as if it were an
        /// icon on a grid — see the `view` measurement in `FinderItems`.
        ///
        /// **nil is a real answer**, and means the producer did not ask. Every
        /// reader falls back to the 32×32 icon box, which is what it assumed
        /// before this field existed, so an older fixture decodes unchanged.
        public var w: Int?
        public var h: Int?

        /// **Where this position came from**, which is a different question
        /// from whether there is one.
        ///
        /// `placed` was doing both jobs and could not: it is set to `true` by
        /// `FinderItems.merge` from the box the Finder actually drew, by
        /// `SceneBuilder.desktopItems` from the *saved* `fdLocation` grid, and
        /// by `ScenePoller.placeVolumes` from a layout rule this side
        /// **invented**. Three provenances, one boolean, and every reader that
        /// asked "do we know where this is?" got `true` from the one that had
        /// made the answer up.
        ///
        /// That is tolerable while the only consumer is a renderer — an icon a
        /// few pixels off is cosmetic. It stops being tolerable the moment
        /// something must put an item BACK: a snap-back to an invented home
        /// moves a file to a place it never was, and does it confidently.
        /// So the provenance is carried, and `homeIsTrustworthy` is the one
        /// question the drag plane asks.
        ///
        /// **nil is a real answer** and means the producer did not say — an
        /// older fixture, or a path not yet moved onto this field. It reads as
        /// untrustworthy, deliberately: a default of "drawn" would make every
        /// old fixture claim a provenance it never had.
        public var origin: PositionOrigin?

        /// May something be returned to this position?
        ///
        /// Only the Finder's own drawn box qualifies. The saved grid is close
        /// enough to draw from and not close enough to aim with (it differed
        /// from the drawn position by a constant (52, 25) on the probe folder,
        /// and diverged completely once a window scrolled — see `FinderItems`).
        public var homeIsTrustworthy: Bool { origin == .drawn }

        public var placed: Bool
        public var alias: Bool
        public var invisible: Bool

        /// What an alias POINTS AT, when the producer could ask.
        ///
        /// An alias file's own `kind`, `type` and `creator` describe the
        /// alias and never its target, so an alias to an application and
        /// an alias to a folder are indistinguishable from the fields
        /// above — which is why every alias used to be unclassifiable,
        /// and why opening one predicted a Finder window that never
        /// appeared. Measured 2026-08-07: the desktop's `Mail` is an
        /// alias whose original is an `APPL` named `Mail`, and opening
        /// it launches a process named `Mail`.
        ///
        /// **Optional because "we did not ask" and "it points at
        /// nothing" are different facts.** A broken alias, a producer
        /// with no scripting, or a target on an unmounted volume all
        /// leave this nil, and nil must keep the old prediction rather
        /// than acquire a new way to be wrong.
        public var aliasTarget: AliasTarget?

        /// Public because a HOST may know icons the guest's own walk
        /// cannot: NOW reads the Toolbox's windows, controls and menus,
        /// and a Finder icon is none of those - it is a file the Finder
        /// draws, and only the Finder knows where. Those arrive over
        /// AppleScript and are merged into the scene on this side.
        public init(name: String, kind: String, type: String?,
                    creator: String?, x: Int, y: Int, placed: Bool,
                    alias: Bool, invisible: Bool,
                    aliasTarget: AliasTarget? = nil,
                    w: Int? = nil, h: Int? = nil,
                    origin: PositionOrigin? = nil) {
            self.name = name; self.kind = kind; self.type = type
            self.creator = creator; self.x = x; self.y = y
            self.w = w; self.h = h
            self.placed = placed; self.alias = alias
            self.invisible = invisible
            self.aliasTarget = aliasTarget
            self.origin = origin
        }

        /// The item an alias resolves to. Same three fields the alias
        /// itself carries, so a consumer classifies a target exactly the
        /// way it classifies any other item — one rule, not two.
        public struct AliasTarget: Codable, Equatable, Sendable {
            /// The TARGET's name, which is what a launched process is
            /// named after. An alias may be renamed freely and often is,
            /// so this is not the same string as the item's `name`.
            public var name: String
            public var kind: String
            public var type: String?
            public var creator: String?

            public init(name: String, kind: String,
                        type: String?, creator: String?) {
                self.name = name; self.kind = kind
                self.type = type; self.creator = creator
            }
        }
    }

    /// How a desktop or window item's position was established. The ladder is
    /// ordered: a later producer may overwrite an earlier one's position only
    /// by climbing it, never by descending.
    ///
    /// The vocabulary matches the one this arc already settled for content —
    /// **`empty`** is a fact about the machine, **`unknown`** is a fact about
    /// us — applied to geometry: `drawn` and `saved` are things the guest told
    /// us, `unknown` is what we say when the answer is ours rather than its.
    public enum PositionOrigin: String, Codable, Equatable, Sendable {
        /// `bounds of` the item, as the Finder has actually laid it out now.
        /// The only provenance a snap-back may use.
        case drawn
        /// The catalog's saved `fdLocation` icon grid. Good enough to draw a
        /// desktop from; not the box the Finder drew, and not a home.
        case saved
        /// **We made it up.** A volume laid out by our own default rule
        /// because nothing would tell us where the Finder put it. It is drawn
        /// — a disk you cannot see at all is worse than one a few inches off —
        /// and no act may aim with it.
        case unknown
    }

    /// The colours the GUEST'S OWN Appearance Manager hands out, asked
    /// once per scene rather than assumed here.
    ///
    /// Every field is optional and an absent one means the ask failed —
    /// never "black". A nil `Theme` altogether means the producer did not
    /// ask, which is a different fact: the first says that machine would
    /// not name the brush, the second that nobody looked. A renderer
    /// meeting either falls back to its own constant and should say so.
    ///
    /// This is not the theme's palette and must not become one. These are
    /// fills the machine makes on request; a renderer's bevel greys have
    /// no producer on the machine to ask and would arrive here as guesses
    /// wearing a wire format. See `contract/asyncapi.yaml`, "WHAT COLOUR
    /// THE MACHINE DRAWS WITH".
    public struct Theme: Codable, Equatable, Sendable {
        /// `#RRGGBB` — kThemeBrushDialogBackgroundActive.
        public var dialogBackground: String?
        /// `#RRGGBB` — kThemeBrushAlertBackgroundActive.
        public var alertBackground: String?
        /// `#RRGGBB` — kThemeBrushDocumentWindowBackground.
        public var documentBackground: String?
        /// `#RRGGBB` — the low-memory selection colour.
        public var highlight: String?
        /// The screen depth the brushes were ASKED AT. A brush answers
        /// differently at 8 bits than at 32, so a colour with no depth
        /// beside it cannot be checked against a screendump.
        public var depth: Int?

        public init(dialogBackground: String? = nil,
                    alertBackground: String? = nil,
                    documentBackground: String? = nil,
                    highlight: String? = nil,
                    depth: Int? = nil) {
            self.dialogBackground = dialogBackground
            self.alertBackground = alertBackground
            self.documentBackground = documentBackground
            self.highlight = highlight
            self.depth = depth
        }
    }

    /// **What the guest says its desktop is drawn from.**
    ///
    /// The renderer's only source for the largest rectangle in the picture
    /// was the offline asset pack's `manifest.json` — a record of the disk
    /// image the pack was extracted from. That is true for a guest booted
    /// from that image and unchanged since, and silently wrong the moment
    /// either stops holding, with nothing anywhere to notice. A guest-side
    /// route to the live answer had been built and served as the `desktop`
    /// command, and nothing on this side had ever read it.
    ///
    /// This is that answer, on the wire. The pack is now the *declared*
    /// fallback: `DesktopPattern.resolve(scene:screen:)` returns which of
    /// the two spoke, and a render standing on the pack must say so.
    ///
    /// **It is not art.** The flattened `ppat` bytes the command verb
    /// carries as hex are an identity, not something drawable, and the
    /// pixels come from the pack either way. Naming is the job: it lets
    /// this side check whether the art it holds is the art that machine is
    /// showing, instead of assuming it.
    ///
    /// **Absence is the whole point.** A nil `Meta.desktop` means the
    /// producer did not ask, and is the only state in which the pack may
    /// stand in at all. `source == "unknown"` means we asked and that
    /// machine would not say — the marked unknown, never a guessed
    /// pattern. See `contract/asyncapi.yaml`, "WHAT THE DESKTOP IS DRAWN
    /// FROM".
    public struct Desktop: Codable, Equatable, Sendable {
        /// `pattern`, `picture`, or `unknown`. Left a `String` rather than
        /// an enum for the same reason the rest of this IR is: a value
        /// this decoder has never heard of must survive decoding, not
        /// fail the whole scene.
        public var source: String
        /// Whether a pattern could be read at all. True beside
        /// `source: picture` is normal — a picture is drawn OVER the
        /// pattern layer, and that layer shows wherever it does not reach.
        public var hasPattern: Bool
        /// Whether a desktop picture is configured, from the picture ALIAS
        /// tag rather than the name tag. Independent of `hasPattern`.
        public var hasPicture: Bool
        /// True length of the flattened pattern. Absent when unknown —
        /// never a negative length on the wire.
        public var patternBytes: Int?
        /// What the machine CHOSE. Absent means the tag was absent, not
        /// that the desktop is nameless.
        public var patternName: String?
        public var pictureName: String?

        public init(source: String, hasPattern: Bool, hasPicture: Bool,
                    patternBytes: Int? = nil, patternName: String? = nil,
                    pictureName: String? = nil) {
            self.source = source
            self.hasPattern = hasPattern
            self.hasPicture = hasPicture
            self.patternBytes = patternBytes
            self.patternName = patternName
            self.pictureName = pictureName
        }
    }

    public struct Meta: Codable, Equatable, Sendable {
        public var latencyMs: Double?
        public var bytes: Int?
        public var errors: [String]
        /// Plane annotation (the observe plane marks itself pre-AXPeek).
        public var plane: String?
        /// Typed collection authority. Human-readable `errors` remains for
        /// diagnostics; reducers make replacement/deletion decisions here.
        public var coverage: [CoverageClaim]? = nil
        /// What the guest's Appearance Manager actually draws with.
        public var theme: Theme? = nil
        /// What the guest says its desktop is drawn from. nil means this
        /// producer did not ask — see `Scene.Desktop`.
        public var desktop: Desktop? = nil
    }
}

/// A normalized rectangle in the scene's coordinate space.
public struct Rect: Codable, Equatable, Sendable {
    public var l: Int
    public var t: Int
    public var r: Int
    public var b: Int
    public var width: Int { r - l }
    public var height: Int { b - t }
    public init(l: Int, t: Int, r: Int, b: Int) {
        self.l = l; self.t = t; self.r = r; self.b = b
    }
}
