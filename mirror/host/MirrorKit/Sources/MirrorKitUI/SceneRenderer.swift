import SwiftUI
import MirrorKit

/// Draws a `Scene` into a `GraphicsContext` on the guest's own logical
/// surface — the size the guest measured and sent, never one chosen here.
/// Port of `attic/web/mirror.js` + `platinum.css`; rendering rules mirror the
/// guest's `ui_theme.c`: only the front window gets racing stripes and
/// widgets; dialogs (kind==2) draw modal chrome (no title bar) over the gray
/// face, and only a button the guest explicitly identifies as default gets
/// the default ring.
/// Finder's full-screen backdrop window ("Desktop") is skipped: the real one
/// IS the desktop, so painting it would white out the pattern.
///
/// This is a pure draw function: the live Canvas view and the offscreen
/// render-screenshot both call it, so what a human sees and what an agent
/// inspects are the same pixels.
///
/// ## Every bitmap is sampled nearest-neighbour, and it must stay that way
///
/// `GraphicsContext` has no context-wide interpolation setting, so this is
/// stated per image — `.interpolation(.none)` at every `ctx.draw` of an
/// `Image`, here and in `DisplayReplay`, `BitmapFont` and `UnknownVisual`.
/// The `shouldInterpolate: false` flags scattered through this package are
/// **not** the same rule and do not cover it: they are set on hand-built
/// `CGImage`s only, while everything loaded from the asset pack through
/// `CGImageSourceCreateImageAtIndex` — the icon atlas, the desktop
/// picture, and the glyph sheet through which every character of text is
/// drawn — arrives with it defaulting to true.
///
/// Why it matters more than it sounds: the mirror's zoom stops are 50,
/// 100, 200 and 400 percent, all powers of two, so nearest-neighbour maps
/// each guest pixel onto a whole number of host pixels and a 1-pixel
/// Platinum rule becomes a crisp 2-pixel rule at 200%. With smoothing it
/// becomes a grey smear — and **a similarity score cannot see that**, so
/// no pixel gate in this package would fail. That is why the rule is
/// defended by a gate that reads the source instead:
/// `NearestNeighbourSamplingTests`.
public struct SceneRenderer {
    public let scene: MirrorKit.Scene
    /// Mirror-local UI state: the open menubar menu (drawn as a Platinum
    /// dropdown). nil = no menu open.
    public let openMenu: Int?
    /// 1-based index of the row under the pointer in the open menu.
    public let hoveredItem: Int?
    /// Name of the desktop icon the mirror believes is selected. See
    /// LiveMirrorView.selectedItem — this is our own model, not guest truth.
    public let selectedItem: String?
    /// A live drag/resize outline (guest coords), drawn on top — the classic
    /// Mac dotted-gray tracking rectangle. nil = not dragging.
    public let dragOutline: Rect?
    /// An item travelling under the pointer, drawn over everything. nil = no
    /// item drag in flight.
    public let itemDrag: ProvisionalDrag?
    /// A control the person is pressing, and how far the answer has got.
    /// nil = nothing is being pressed.
    public let pressed: PressedControl?

    /// **A press in flight — the third telling of the same decision.**
    ///
    /// Like `ProvisionalDrag` above, this is VIEW state and must never be
    /// folded back into the scene: a scene is what the guest said, and a
    /// press is what a person is doing. The distinction is sharper here than
    /// for the drag, because the guest cannot report a pressed control *even
    /// in principle* — Platinum draws the pressed state inside the
    /// application's `TrackControl` loop, which is precisely the state in
    /// which the application has stopped calling `GetNextEvent`, so the
    /// resident's scene walk cannot run to observe it. The IR gap is
    /// structural rather than an oversight, and `Scene.Control` accordingly
    /// carries no `hilite` field for this to be confused with.
    public struct PressedControl: Equatable {
        /// The ax2 ref of the control being pressed — the same identity the
        /// scene uses, so "is it still there?" is answerable.
        public var ref: String
        /// Content-relative, like every other control rect.
        public var frame: Rect
        /// Draw the face pressed. False once the press has settled.
        public var showsPressed: Bool
        /// Draw the wait indicator. `.waiting` only.
        public var showsSpinner: Bool
        /// 0...1 through `PressSession.patience`, for the determinate arc.
        public var progress: Double

        public init(ref: String, frame: Rect, showsPressed: Bool,
                    showsSpinner: Bool, progress: Double) {
            self.ref = ref
            self.frame = frame
            self.showsPressed = showsPressed
            self.showsSpinner = showsSpinner
            self.progress = progress
        }

        /// Build one from the core session, which is the only supported
        /// route — the flags are derived there so the renderer cannot
        /// disagree with the state machine about what a phase means.
        public init(_ session: PressSession, now: Date) {
            self.init(ref: session.ref, frame: session.frame,
                      showsPressed: session.showsPressed,
                      showsSpinner: session.showsSpinner,
                      progress: session.waitProgress(now: now))
        }
    }

    /// **An item in flight, and whether the guest has confirmed it yet.**
    ///
    /// The presentation contract's rule 1 is that the item moves with the
    /// pointer *immediately* — before any response — so this is view state,
    /// not scene state, and it must never be folded back into the scene. A
    /// scene is what the guest said; this is what a person is doing.
    public struct ProvisionalDrag: Equatable {
        /// The art: the item's own icon and name, so a person can see WHICH
        /// file is in flight.
        public var item: MirrorKit.Scene.DesktopItem
        /// Where it is now, in global guest coords.
        public var frame: Rect
        /// The guest has answered and the select is real. Until then the
        /// drawing says so — never the other way round.
        public var confirmed: Bool

        public init(item: MirrorKit.Scene.DesktopItem, frame: Rect,
                    confirmed: Bool) {
            self.item = item; self.frame = frame; self.confirmed = confirmed
        }
    }

    /// The colours the guest said it draws with, resolved against this
    /// side's fallbacks. Derived from the scene, so nothing has to remember
    /// to pass it — and `theme.provenance` says per colour which of the two
    /// each one came from.
    public var theme: SceneTheme { SceneTheme(scene) }

    public init(scene: MirrorKit.Scene, openMenu: Int? = nil,
                hoveredItem: Int? = nil, selectedItem: String? = nil,
                dragOutline: Rect? = nil,
                itemDrag: ProvisionalDrag? = nil,
                pressed: PressedControl? = nil) {
        self.scene = scene
        self.openMenu = openMenu
        self.hoveredItem = hoveredItem
        self.selectedItem = selectedItem
        self.dragOutline = dragOutline
        self.itemDrag = itemDrag
        self.pressed = pressed
    }

    /// The guest screen: the scene's own dimensions, and **nil when the
    /// scene carries none**.
    ///
    /// There is no fallback, because there is nothing true to fall back
    /// to. The rects in a scene are in the guest's screen space; without
    /// that space a drawn window has no position and a click has no
    /// destination. Callers refuse rather than draw into an invented
    /// coordinate system — a mirror that letterboxes a guessed surface
    /// looks right and aims wrong.
    public var logicalSize: CGSize? {
        scene.screen.known.map { CGSize(width: $0.w, height: $0.h) }
    }

    static func shouldSynthesizeAppleMenu(_ menus: [MirrorKit.Scene.Menu])
        -> Bool {
        !menus.contains(where: \.apple)
    }

    private static func nextOrdinaryMenuLeft(
        _ menus: [MirrorKit.Scene.Menu], after index: Int, from left: Int
    ) -> Int {
        menus.dropFirst(index + 1)
            .filter { $0.id != ObjectResolver.applicationMenuID }
            .compactMap(\.left)
            .filter { $0 > left }
            .min() ?? (left + 60)
    }

    public func draw(in ctx: GraphicsContext, size: CGSize) {
        // Fit the logical surface into the drawable — the SAME transform the
        // input inverts (FitTransform), so drawn pixels and click targets
        // register exactly.
        guard let logical = logicalSize else {
            /* The guest has not said how big its screen is, so every rect
               in this scene is in a space we do not have. Say that,
               rather than draw it somewhere plausible. */
            drawScreenUnknown(ctx, size)
            return
        }
        let fit = FitTransform(logical: logical, view: size)
        var ctx = ctx
        ctx.translateBy(x: fit.offset.x, y: fit.offset.y)
        ctx.scaleBy(x: fit.scale, y: fit.scale)
        let bounds = CGRect(origin: .zero, size: logical)
        ctx.clip(to: Path(bounds))

        drawDesktop(ctx, bounds)
        drawDesktopIcons(ctx)   // on the desktop, behind every window
        // Scene order: index 0 = frontmost. Paint back to front, skipping
        // what the guest doesn't show: invisible windows and the Finder
        // desktop backdrop.
        for window in scene.windows.reversed()
        where window.visible && !isDesktopBackdrop(window) {
            drawWindow(ctx, window)
        }
        drawMenubar(ctx, bounds)
        if let openMenu, let menus = scene.menubar?.menus,
           menus.indices.contains(openMenu) {
            drawDropdown(ctx, menus[openMenu])
        }
        /* NO PROCESS SHELF. It painted a 92px band over the BOTTOM OF THE
           GUEST'S OWN SCREEN - not beside it - so it covered the control
           strip, the bottom row of desktop icons and anything a window had
           down there, and it made the mirror unfaithful in the one way a
           mirror must never be: it showed something the Mac was not
           showing. What is running belongs on NOW's Processes page, which
           exists and is not drawn on top of the machine. */
        if let dragOutline {
            drawDragOutline(ctx, dragOutline)
        }
        if let itemDrag {
            drawItemDrag(ctx, itemDrag)
        }
    }

    /// The dragged item, over everything, marked provisional until the guest
    /// has confirmed the select.
    ///
    /// The style is `ProvisionalVisual`'s and only `ProvisionalVisual`'s —
    /// this function decides WHEN and WHERE, never what it looks like. A
    /// second place deciding that is how the marked unknown ended up with two
    /// copies of its fill, identical by coincidence and free to drift.
    private func drawItemDrag(_ ctx: GraphicsContext,
                              _ drag: ProvisionalDrag) {
        let f = drag.frame
        let frame = CGRect(x: CGFloat(f.l), y: CGFloat(f.t),
                           width: CGFloat(max(0, f.r - f.l)),
                           height: CGFloat(max(0, f.b - f.t)))
        guard drag.confirmed else {
            ProvisionalVisual.drawPlate(in: ctx, frame: frame)
            var ghost = ctx
            ghost.opacity = ProvisionalVisual.itemOpacity
            drawIcon(ghost, drag.item,
                     at: CGPoint(x: frame.minX + ProvisionalVisual.inset,
                                 y: frame.minY + ProvisionalVisual.inset))
            ProvisionalVisual.drawMark(in: ctx, frame: frame)
            return
        }
        /* Confirmed: the guest said yes, so the item is drawn as an item.
           Nothing PROMOTES a provisional drag to this on its own — the only
           way here is a real response, which is rule 2 of the contract and
           the whole reason the two drawings differ. */
        drawIcon(ctx, drag.item,
                 at: CGPoint(x: frame.minX + ProvisionalVisual.inset,
                             y: frame.minY + ProvisionalVisual.inset))
    }

    /// The classic Mac drag/resize tracking rectangle: a 2px dotted gray
    /// outline of the window at its would-be position.
    private func drawDragOutline(_ ctx: GraphicsContext, _ r: Rect) {
        let rect = CGRect(x: CGFloat(r.l), y: CGFloat(r.t),
                          width: CGFloat(max(0, r.r - r.l)),
                          height: CGFloat(max(0, r.b - r.t)))
        ctx.stroke(Path(rect), with: .color(Platinum.g5),
                   style: StrokeStyle(lineWidth: 2, dash: [3, 2]))
    }

    /// **Unknown, said out loud.** Not an error and not an empty mirror:
    /// the machine may be answering perfectly while this particular fact
    /// has not arrived. A person reading a blank grey rectangle would
    /// reasonably conclude the guest was down.
    private func drawScreenUnknown(_ ctx: GraphicsContext, _ size: CGSize) {
        ctx.fill(Path(CGRect(origin: .zero, size: size)),
                 with: .color(Platinum.g6))
        sysCentered("Screen size unknown", ctx,
                    centerX: size.width / 2, centerY: size.height / 2 - 8,
                    color: .black)
        sysCentered("Waiting for the Mac to say how big its screen is.", ctx,
                    centerX: size.width / 2, centerY: size.height / 2 + 10,
                    color: .black)
    }

    // MARK: - Text (Tier-2 bitmap, mock fallback)

    /// Draw system (Chicago) text, left-aligned at a baseline. Falls back to
    /// SwiftUI Text when the pack isn't bundled.
    private func sysText(_ s: String, _ ctx: GraphicsContext, x: CGFloat,
                         baselineY: CGFloat, color: Color, size: CGFloat = 13) {
        if let f = FontBook.system {
            f.draw(s, in: ctx, x: x, baselineY: baselineY, color: color)
        } else {
            ctx.draw(ctx.resolve(Text(s).font(Platinum.systemFont(size))
                        .foregroundColor(color)),
                     at: CGPoint(x: x, y: baselineY - 3), anchor: .bottomLeading)
        }
    }

    private func sysCentered(_ s: String, _ ctx: GraphicsContext,
                             centerX: CGFloat, centerY: CGFloat, color: Color,
                             size: CGFloat = 13) {
        if let f = FontBook.system {
            f.drawCentered(s, in: ctx, centerX: centerX, centerY: centerY,
                           color: color)
        } else {
            ctx.draw(ctx.resolve(Text(s).font(Platinum.systemFont(size))
                        .foregroundColor(color)),
                     at: CGPoint(x: centerX, y: centerY), anchor: .center)
        }
    }

    private func sysWidth(_ s: String, size: CGFloat = 13) -> CGFloat {
        if let f = FontBook.system { return CGFloat(f.width(s)) }
        return s.reduce(0) { acc, _ in acc + size * 0.6 }
    }

    /// Geneva (app/content) text, left-aligned at a baseline.
    private func appText(_ s: String, _ ctx: GraphicsContext, x: CGFloat,
                         baselineY: CGFloat, color: Color, small: Bool = false) {
        let font = small ? FontBook.small : FontBook.app
        if let f = font {
            f.draw(s, in: ctx, x: x, baselineY: baselineY, color: color)
        } else {
            ctx.draw(ctx.resolve(Text(s).font(Platinum.appFont(small ? 10 : 12))
                        .foregroundColor(color)),
                     at: CGPoint(x: x, y: baselineY - 2), anchor: .bottomLeading)
        }
    }

    // MARK: - Desktop

    /// The desktop, through the same ladder as every other rectangle.
    ///
    /// It used to tile `ppat` 16 unconditionally and fill
    /// `Platinum.desktopBlue` when the pack had none — two guesses, on the
    /// largest rectangle in the picture. Lane C measured the first as wrong
    /// on the image we run (the guest's desktop is an 800×600 picture, not
    /// a tiled pattern) and the second was never evidence of anything.
    ///
    /// Rung 3 draws art the pack IDENTIFIED; rung 4 marks the rest. A
    /// plausible wrong purple is exactly what rule 1 forbids.
    private func drawDesktop(_ ctx: GraphicsContext, _ bounds: CGRect) {
        /* THE MACHINE FIRST, THE PACK SECOND, AND SAY WHICH. Until the
           guest's own desktop answer reached the scene this could only ask
           the pack — a record of the disk image it was extracted from, and
           byte-identical whether that record still held or not. `resolve`
           asks the scene first and reports who answered; the plate below
           is what makes a substitution legible instead of silent. */
        let resolved = DesktopPattern.resolve(scene: scene, screen: bounds.size)
        defer {
            if resolved.provenance == .assetPack {
                drawSubstitutionPlate(ctx, bounds)
            }
        }
        switch resolved.answer {
        case .picture(let art):
            /* ONCE, AT THE ORIGIN, UNSCALED — the operation the machine
               performs. `answer` has already refused any picture whose
               size is not the screen's, so this cannot crop or stretch. */
            ctx.draw(Image(decorative: art, scale: 1)
                        .interpolation(.none),
                     in: CGRect(x: bounds.minX, y: bounds.minY,
                                width: CGFloat(art.width),
                                height: CGFloat(art.height)))
        case .pattern(let tile):
            let tw = CGFloat(tile.width), th = CGFloat(tile.height)
            guard tw > 0, th > 0 else { break }
            let image = Image(decorative: tile, scale: 1)
                .interpolation(.none)
            var y = bounds.minY
            while y < bounds.maxY {
                var x = bounds.minX
                while x < bounds.maxX {
                    ctx.draw(image, in: CGRect(x: x, y: y, width: tw, height: th))
                    x += tw
                }
                y += th
            }
        case .unknown(let why):
            /* The marked unknown, at desktop scale. `why` is deliberately
               NOT drawn — the mirror talking about itself inside a picture
               of the machine — but it is the sentence a diagnostic asks
               for, and it is why this is an enum rather than an optional. */
            _ = why
            drawUnavailableVisual(ctx, bounds, "")
        }
    }

    /// **The mark that says this desktop is the pack's, not the machine's.**
    ///
    /// The honesty requirement this whole seam exists for: when the live
    /// answer arrives, the desktop came from the machine; when the pack is
    /// standing in, that has to be LEGIBLE rather than silently identical.
    /// A render that looks the same either way is how the pack's record of
    /// a disk image went on being trusted for as long as it did.
    ///
    /// It is a plate in the bottom-left corner rather than a wash over the
    /// surface, and that is a deliberate trade. The desktop is the largest
    /// rectangle in the picture and a fidelity sweep compares it pixel for
    /// pixel; tinting or hatching it would make every substituted render
    /// fail a comparison for a reason that has nothing to do with what is
    /// being compared. A bounded plate in a corner windows do not usually
    /// reach says the same thing and costs a known, small region.
    ///
    /// Nothing marks ``DesktopPattern/Provenance/machine`` — an unmarked
    /// desktop means the machine named it, and that is the point.
    private func drawSubstitutionPlate(_ ctx: GraphicsContext,
                                       _ bounds: CGRect) {
        let caption = "desktop from asset pack, not this machine"
        let ascent = CGFloat(FontBook.small?.ascent ?? 8)
        let inset: CGFloat = 6
        let pad = UnknownVisual.captionInset
        let textW = CGFloat(FontBook.small?.width(caption)
                            ?? Int(CGFloat(caption.count) * 6))
        let plate = CGRect(x: bounds.minX + inset,
                           y: bounds.maxY - inset - (ascent + pad * 2),
                           width: min(textW + pad * 2,
                                      max(bounds.width - inset * 2, 0)),
                           height: ascent + pad * 2)
        guard plate.width > pad * 2, plate.height > 0,
              bounds.contains(plate.origin) else { return }
        var clipped = ctx
        clipped.clip(to: Path(plate))
        clipped.fill(Path(plate), with: .color(UnknownVisual.ground))
        clipped.stroke(Path(plate), with: .color(UnknownVisual.edge),
                       lineWidth: 1)
        appText(caption, clipped, x: plate.minX + pad,
                baselineY: plate.minY + pad + ascent,
                color: UnknownVisual.caption, small: true)
    }

    // MARK: - Desktop icons

    /// fdLocation is the icon cell's top-left in global screen coords; the
    /// 32×32 icon sits at the top, the label centered beneath.
    static let iconSize: CGFloat = 32

    private func drawDesktopIcons(_ ctx: GraphicsContext) {
        guard let items = scene.desktopItems else { return }
        for item in items where item.placed {
            let origin = CGPoint(x: item.x, y: item.y)
            // Desktop selection is still optimistic host feedback. Folder
            // windows carry Finder's own selection in `FinderPresentation`;
            // desktop selection does not yet have a correlated snapshot.
            drawIcon(ctx, item, at: origin,
                     selected: selectedItem == item.name)
        }
    }

    /// Draw one icon (desktop or window item) with its box top-left at
    /// `origin` in the current ctx space.
    private func drawIcon(_ ctx: GraphicsContext,
                          _ item: MirrorKit.Scene.DesktopItem,
                          at origin: CGPoint,
                          selected: Bool = false,
                          replayed: DisplayReplay.Coverage? = nil) {
        /* THE BOX THE FINDER DREW, not a constant 32. `bounds of` answers
           16×16 for a LIST-view row and the Finder stacks those rows at a
           19-point pitch, so a 32-point icon drawn at a row's top-left runs
           through the row below it and over the name, date, size and kind
           the machine itself wrote there. That is Michelle's "switching a
           Finder window to list view prints icons in a list on top of the
           list", and it is the same constant `FinderItems.clickPoint`
           already stopped trusting for the same reason.
           `HitTester.targetSize` owns the rule; this is the drawing half of
           it, and the two must stay one number or a click lands where
           nothing was drawn. */
        let box = CGRect(origin: origin, size: Self.iconBoxSize(item))
        drawGenericIcon(ctx, box, item: item)

        // Selection is an INVERSION, not a backing box. The Finder darkens the
        // icon itself and flips the label to white-on-black; a rectangle behind
        // the icon is a different visual language and reads as a highlight
        // rather than a selection. Darken through the icon's own pixels so the
        // artwork still shows, which is what OS 8.5+ does.
        if selected {
            var inv = ctx
            inv.blendMode = .multiply
            inv.fill(Path(box), with: .color(Platinum.g4))
        }

        // Name label: Geneva 9 (the real Finder label font, per the finding),
        // centered under the icon. Unselected it sits on a white patch; selected
        // the patch goes black and the text white, as the Finder draws it.
        /* A LIST ROW HAS NO LABEL OF OURS. Its name is a COLUMN the machine
           wrote, level with the row icon rather than under it; a centred
           patch there is a second name in the wrong place, over the first.
           Same discriminator `HitTester.targetSize` uses to decide whether
           a label height belongs in the hit box at all. */
        guard Self.itemDrawsItsOwnLabel(item) else { return }
        let label = item.name
        let w = CGFloat(FontBook.small?.width(label) ?? label.count * 6)
        let ascent = CGFloat(FontBook.small?.ascent ?? 9)
        let labelY = box.maxY + 1
        let patch = CGRect(x: box.midX - w / 2 - 2, y: labelY,
                           width: w + 4, height: ascent + 3)
        /* RUNG 1 BEATS RUNG 3 FOR THE WORDS, and it is asked here rather
           than for the whole cell because the two halves of an icon are not
           the same claim. The ICON is art addressed by identity and the
           machine cannot offer a better one through this renderer — its own
           icon arrives as an unjoined blit, which carries geometry and no
           pixels, so the strongest thing the replay can put in that box is a
           generic stub or an "unavailable" hatch. The roster outranks both,
           which is why the icon box excludes the replay outright
           (`finderItemFrames`).

           The NAME is the opposite. The Finder writes it as a real text run
           — truncated with an ellipsis at the cell's width, wrapped onto two
           lines, inverted when selected — and every one of those facts is
           something this side would have to invent. So the label yields to
           the machine's own run wherever there is one, through the same
           `textCovers` test a semantic label uses, and draws only where the
           replay was silent. Drawn unconditionally it was Michelle's
           "Finder item icons seem to be drawing their label twice". */
        if replayed?.textCovers(patch) == true { return }
        ctx.fill(Path(patch), with: .color(selected ? Platinum.g6 : .white))
        appText(label, ctx, x: box.midX - w / 2, baselineY: labelY + ascent,
                color: selected ? .white : Platinum.g6, small: true)
    }

    /// The item's icon: the real OS 9 generic bitmap (IconAtlas) when we have
    /// one, else a procedural Platinum glyph — plus the alias badge.
    private func drawGenericIcon(_ ctx: GraphicsContext, _ box: CGRect,
                                 item: MirrorKit.Scene.DesktopItem) {
        if let bitmap = IconAtlas.icon(for: item,
                                       size: IconAtlas.Size.fitting(box)) {
            ctx.draw(Image(decorative: bitmap, scale: 1)
                        .interpolation(.none), in: box)
            drawAliasBadge(ctx, box, item: item)
            return
        }
        drawProceduralIcon(ctx, box, item: item)
    }

    /// The procedural fallback (used only when the bitmap is missing).
    private func drawProceduralIcon(_ ctx: GraphicsContext, _ box: CGRect,
                                    item: MirrorKit.Scene.DesktopItem) {
        let folderTint = Color(hex: 0x9DB0C6)
        if item.kind == "disk" {
            // A beige hard-drive: a rounded box with a face plate + slot.
            let body = CGRect(x: box.minX + 2, y: box.minY + 7,
                              width: box.width - 4, height: box.height - 12)
            ctx.fill(Path(roundedRect: body, cornerRadius: 2),
                     with: .color(Color(hex: 0xE8E4D8)))
            ctx.stroke(Path(roundedRect: body, cornerRadius: 2),
                       with: .color(Platinum.g6), lineWidth: 1)
            bevel(ctx, body.insetBy(dx: 1, dy: 1), light: Platinum.g0,
                  shadow: Platinum.g4)
            // Face plate lines + a small slot.
            ctx.fill(Path(CGRect(x: body.minX + 3, y: body.midY - 1,
                                 width: 8, height: 2)),
                     with: .color(Platinum.g5))
            ctx.fill(Path(CGRect(x: body.maxX - 8, y: body.minY + 3,
                                 width: 5, height: 2)),
                     with: .color(Platinum.selection))
            drawAliasBadge(ctx, box, item: item)
            return
        }
        if item.kind == "folder" {
            // Manila-ish folder: a tab + body.
            let tab = CGRect(x: box.minX + 2, y: box.minY + 6,
                             width: 12, height: 4)
            ctx.fill(Path(roundedRect: tab, cornerRadius: 1),
                     with: .color(folderTint))
            let body = CGRect(x: box.minX + 1, y: box.minY + 9,
                              width: box.width - 3, height: box.height - 13)
            ctx.fill(Path(roundedRect: body, cornerRadius: 2),
                     with: .color(folderTint))
            ctx.stroke(Path(roundedRect: body, cornerRadius: 2),
                       with: .color(Platinum.g6), lineWidth: 1)
        } else if item.type == "APPL" {
            // Generic application: a rounded tile with a diamond.
            let tile = box.insetBy(dx: 4, dy: 2)
            ctx.fill(Path(roundedRect: tile, cornerRadius: 3),
                     with: .color(Platinum.g1))
            ctx.stroke(Path(roundedRect: tile, cornerRadius: 3),
                       with: .color(Platinum.g6), lineWidth: 1)
            var d = Path()
            d.move(to: CGPoint(x: tile.midX, y: tile.minY + 4))
            d.addLine(to: CGPoint(x: tile.maxX - 4, y: tile.midY))
            d.addLine(to: CGPoint(x: tile.midX, y: tile.maxY - 4))
            d.addLine(to: CGPoint(x: tile.minX + 4, y: tile.midY))
            d.closeSubpath()
            ctx.fill(d, with: .color(Platinum.selection))
        } else {
            // Generic document: a white page with a folded top-right corner.
            let page = CGRect(x: box.minX + 6, y: box.minY + 1,
                              width: box.width - 12, height: box.height - 3)
            let fold: CGFloat = 6
            var p = Path()
            p.move(to: CGPoint(x: page.minX, y: page.minY))
            p.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY))
            p.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
            p.addLine(to: CGPoint(x: page.maxX, y: page.maxY))
            p.addLine(to: CGPoint(x: page.minX, y: page.maxY))
            p.closeSubpath()
            ctx.fill(p, with: .color(.white))
            ctx.stroke(p, with: .color(Platinum.g6), lineWidth: 1)
            // The dog-ear.
            var ear = Path()
            ear.move(to: CGPoint(x: page.maxX - fold, y: page.minY))
            ear.addLine(to: CGPoint(x: page.maxX - fold, y: page.minY + fold))
            ear.addLine(to: CGPoint(x: page.maxX, y: page.minY + fold))
            ctx.stroke(ear, with: .color(Platinum.g5), lineWidth: 1)
            // A couple of text lines.
            for dy in stride(from: 5, through: 11, by: 3) {
                ctx.fill(Path(CGRect(x: page.minX + 3, y: page.minY + CGFloat(dy),
                                     width: page.width - 8, height: 1)),
                         with: .color(Platinum.g3))
            }
        }

        drawAliasBadge(ctx, box, item: item)
    }

    /// The alias badge: a small italic arrow, bottom-left (overlaid on either
    /// the real bitmap or the procedural glyph).
    private func drawAliasBadge(_ ctx: GraphicsContext, _ box: CGRect,
                                item: MirrorKit.Scene.DesktopItem) {
        guard item.alias else { return }
        var a = Path()
        a.move(to: CGPoint(x: box.minX + 2, y: box.maxY - 3))
        a.addLine(to: CGPoint(x: box.minX + 9, y: box.maxY - 3))
        a.addLine(to: CGPoint(x: box.minX + 6, y: box.maxY - 9))
        ctx.fill(Path(CGRect(x: box.minX + 1, y: box.maxY - 11,
                             width: 10, height: 10)),
                 with: .color(.white.opacity(0.85)))
        ctx.stroke(a, with: .color(Platinum.g6), lineWidth: 1)
    }

    // MARK: - Menu bar

    private func drawMenubar(_ ctx: GraphicsContext, _ bounds: CGRect) {
        let bar = CGRect(x: 0, y: 0, width: bounds.width,
                         height: Platinum.menubarHeight)
        ctx.fill(Path(bar), with: .color(Platinum.g1))
        ctx.fill(Path(CGRect(x: 0, y: bar.maxY, width: bar.width, height: 1)),
                 with: .color(Platinum.g6))

        // Titles sit at the wire's MenuList lefts — guest-true layout.
        let menus = scene.menubar?.menus ?? []
        for (i, menu) in menus.enumerated() {
            /* The Application menu is drawn by the right-hand block
               below, as the icon and name it actually is, and its
               dropdown is the GUEST's - Hide, Hide Others, Show All and
               the applications.
             *
               I made this skip once before while the guest was reporting
               no such menu, so it removed Apple's and left ours: a
               regression, and Michelle named it as one. It is right only
               now that scene_self.c reports -16489. Its `left` is 0
               because a right-aligned menu's position is the Menu
               Manager's, not ours - which is precisely why it must not
               be drawn from this loop, where left is the position. */
            if menu.id == ObjectResolver.applicationMenuID { continue }
            /* A menu bar is a positional surface, so a menu the producer
               never placed cannot be drawn in it. Skipped rather than
               drawn at 0, which is where an absent `left` used to land -
               on top of the Apple menu, and hit-testable there. */
            guard let left = menu.left else { continue }
            if i == openMenu {
                let next = Self.nextOrdinaryMenuLeft(menus, after: i,
                                                     from: left)
                ctx.fill(Path(CGRect(x: CGFloat(left) - 6, y: 0,
                                     width: CGFloat(next - left), height: 19)),
                         with: .color(Platinum.selection))
            }
            drawMenuTitle(ctx, menu.apple ? "\u{F8FF}" : menu.title,
                          apple: menu.apple, left: CGFloat(left),
                          highlighted: i == openMenu)
        }
        if Self.shouldSynthesizeAppleMenu(menus) {
            drawMenuTitle(ctx, "\u{F8FF}", apple: true, left: 10,
                          highlighted: false)
        }

        // Right side, in the OS 9 order: the Application menu is RIGHTMOST —
        // it is the app switcher, and it carries the front app's icon — with
        // the clock to its left. This used to be the other way round.
        let front = scene.apps.first(where: { $0.front })
        let appWidth = CGFloat(HitTester.appMenuWidth(scene))
        let appLeft = bounds.width - appWidth
        let guestAppMenuOpen = openMenu.flatMap { index in
            menus.indices.contains(index) ? menus[index].id : nil
        } == ObjectResolver.applicationMenuID
        let switcherOpen = guestAppMenuOpen

        if switcherOpen {
            ctx.fill(Path(CGRect(x: appLeft, y: 0,
                                 width: appWidth, height: 19)),
                     with: .color(Platinum.selection))
        }
        if let front {
            let iconBox = CGRect(x: appLeft + 6, y: 2, width: 16, height: 16)
            /* One of the few places identity is KNOWN rather than inferred:
               the process census reports each app's creator signature, and
               `apps` and `processes` share the PSN, so this is a join on a
               reported key — Sherlock's own icon rather than a generic
               application glyph. Generic when the census is absent or the
               pack has no icon for that signature. 16x16 art, because that
               is the size OS 9 draws into this slot. */
            let small = IconAtlas.Size.small
            let signature = scene.processes?
                .first(where: { $0.psn == front.psn })?.signature
            if let img = IconAtlas.processIcon(signature: signature, size: small)
                ?? IconAtlas.namedIcon("application", size: small) {
                ctx.draw(Image(decorative: img, scale: 1)
                            .interpolation(.none), in: iconBox)
            } else {
                ctx.fill(Path(roundedRect: iconBox, cornerRadius: 2),
                         with: .color(Platinum.g3))
            }
            appText(front.name, ctx, x: appLeft + 26, baselineY: 14,
                    color: switcherOpen ? Platinum.g0 : Platinum.g6)
        }
        _ = drawRightAligned(ctx, Self.clockString(scene.capturedAt),
                             at: appLeft - 12)

    }

    private func drawMenuTitle(_ ctx: GraphicsContext, _ title: String,
                               apple: Bool, left: CGFloat,
                               highlighted: Bool) {
        let color = highlighted ? Platinum.g0 : Platinum.g6
        let mid = Platinum.menubarHeight / 2
        // The Apple glyph isn't in the bitmap strike — draw it via Text.
        if apple {
            ctx.draw(ctx.resolve(Text(title).font(Platinum.systemFont(14))
                        .foregroundColor(color)),
                     at: CGPoint(x: left + 6, y: mid), anchor: .center)
        } else {
            sysCentered(title, ctx, centerX: left + sysWidth(title) / 2,
                        centerY: mid, color: color)
        }
    }

    // MARK: - Dropdown (mirror-drawn Platinum menu)

    /// Geometry is deterministic (no text measurement) so the view's item
    /// hit-testing and this drawing can never disagree. Rows follow the
    /// guest's 16 px standard; the panel width is an estimate — long
    /// titles clip rather than shift the rows.
    /// A menu's dropdown, kept ON THE SCREEN.
    ///
    /// It used to drop straight down from the title with no bound, which
    /// is right for every menu except the ones near the right edge — and
    /// the Application menu is always there. At `left` 716 of an 800-wide
    /// screen a 150pt dropdown ran off the edge entirely, so choosing
    /// Hide / Hide Others / Show All was impossible: the menu opened
    /// where nobody could see or click it. Watched 2026-08-03.
    ///
    /// A Mac right-aligns such a menu under its own title, which is what
    /// the clamp reproduces.
    public static func dropdownFrame(_ menu: MirrorKit.Scene.Menu,
                                     screenWidth: Int = 0) -> CGRect {
        let maxLen = menu.items.map(\.title.count).max() ?? 8
        let width = CGFloat(min(max(120, maxLen * 8 + 56), 320))
        /* UNREACHABLE WITH A nil LEFT, and stated rather than defaulted:
           an unplaced menu is not drawn in the strip above and the hit
           tester returns no index for one, so nothing can open its
           dropdown. The zero is a total function's tail, not a position
           anything is placed by. */
        var x = CGFloat(menu.left ?? 0) - 6
        if menu.id == ObjectResolver.applicationMenuID, screenWidth > 0 {
            /* The Menu Manager reports no useful left edge for the
               right-aligned application menu. Its title geometry comes
               from the screen edge, so its guest-provided dropdown must
               use that same anchor rather than the nominal left == 0. */
            x = Swift.max(0, CGFloat(screenWidth) - width)
        } else if screenWidth > 0, x + width > CGFloat(screenWidth) {
            x = Swift.max(0, CGFloat(screenWidth) - width)
        }
        return CGRect(x: x,
                      y: Platinum.menubarHeight + 1,
                      width: width,
                      height: CGFloat(menu.items.count * 16) + 4)
    }

    /// The item under a guest point inside the dropdown, or nil.
    public static func dropdownItem(_ menu: MirrorKit.Scene.Menu,
                                    x: Int, y: Int,
                                    screenWidth: Int = 0)
        -> MirrorKit.Scene.MenuItem? {
        let frame = dropdownFrame(menu, screenWidth: screenWidth)
        guard CGFloat(x) >= frame.minX, CGFloat(x) < frame.maxX,
              CGFloat(y) >= frame.minY + 2 else { return nil }
        let row = (y - Int(frame.minY) - 2) / 16
        guard row >= 0, row < menu.items.count else { return nil }
        return menu.items[row]
    }

    private func drawDropdown(_ ctx: GraphicsContext,
                              _ menu: MirrorKit.Scene.Menu) {
        // A menu is a SELECTABLE surface, not a picture of one: the hovered row
        // inverts, the way the Menu Manager draws a tracked item. Selection is
        // by item identity from here on — the row the human is looking at is the
        // row that acts, with no coordinate round-trip through the guest.
        let frame = Self.dropdownFrame(menu, screenWidth: scene.screen.w)
        ctx.fill(Path(frame.offsetBy(dx: 2, dy: 2)),
                 with: .color(.black.opacity(0.35)))
        ctx.fill(Path(frame), with: .color(Platinum.g0))
        ctx.stroke(Path(frame), with: .color(Platinum.g6), lineWidth: 1)

        var y = frame.minY + 2
        for item in menu.items {
            defer { y += 16 }
            let hovered = (hoveredItem == item.index) && !item.separator
                          && item.enabled
            if hovered {
                ctx.fill(Path(CGRect(x: frame.minX + 1, y: y,
                                     width: frame.width - 2, height: 16)),
                         with: .color(Platinum.g6))
            }
            if item.separator {
                ctx.fill(Path(CGRect(x: frame.minX + 2, y: y + 7,
                                     width: frame.width - 4, height: 1)),
                         with: .color(Platinum.g3))
                continue
            }
            let color = hovered ? Platinum.g0
                                : (item.enabled ? Platinum.g6 : Platinum.g3)
            var clipped = ctx
            clipped.clip(to: Path(CGRect(x: frame.minX, y: y,
                                         width: frame.width - 34, height: 16)))
            if item.mark {
                clipped.draw(clipped.resolve(Text("✓").font(Platinum.systemFont(12))
                                .foregroundColor(color)),
                             at: CGPoint(x: frame.minX + 6, y: y + 8),
                             anchor: .center)
            }
            sysText(item.title, clipped, x: frame.minX + 14, baselineY: y + 12,
                    color: color)
            // ⌘ isn't in the bitmap strike — draw the shortcut via Text.
            if !item.cmd.isEmpty {
                ctx.draw(ctx.resolve(Text("⌘\(item.cmd)")
                             .font(Platinum.systemFont(12))
                             .foregroundColor(color)),
                         at: CGPoint(x: frame.maxX - 8, y: y + 8),
                         anchor: .trailing)
            }
        }
    }

    @discardableResult
    private func drawRightAligned(_ ctx: GraphicsContext, _ string: String,
                                  at rightX: CGFloat) -> CGFloat {
        let w = sysWidth(string)
        sysText(string, ctx, x: rightX - w,
                baselineY: Platinum.menubarHeight / 2 + 4, color: Platinum.g6)
        return rightX - w
    }

    static func clockString(_ capturedAt: Double) -> String {
        // Deterministic across runs: fixed locale + UTC, so a fixture always
        // renders the same pixels.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "h:mm a"
        return formatter.string(from: Date(timeIntervalSince1970: capturedAt))
    }

    // MARK: - Windows

    /// The desktop backdrop, from the one shared rule (HitTester) — never a
    /// real Finder folder window (those are kind 20 too). Painting it would
    /// white out the pattern the real machine shows through.
    private func isDesktopBackdrop(_ win: MirrorKit.Scene.Window) -> Bool {
        HitTester.isDesktopBackdrop(win)
    }

    private func drawWindow(_ ctx: GraphicsContext, _ win: MirrorKit.Scene.Window) {
        guard win.rect.r - win.rect.l > 2,
              win.rect.b - win.rect.t > 2 else { return }
        let active = win.front
        /* `kind` says WHO OWNS the window, not what it looks like. Both a
           modal alert and a titled assistant are windowKind 2, because
           both came from the Dialog Manager - the LOOK is the WDEF
           variant, which IR v1 does not carry.
         *
           Deciding chrome from kind alone drew Internet Setup Assistant
           as a bare bordered rectangle: no title bar, no title, no close
           or collapse box, while the machine gave it all four. Watched
           2026-08-03, and it took the whole of rung 1 with it, because a
           window with no title bar has nothing to drag, zoom or close.
         *
           Until the variant is carried, the title is the honest
           discriminator and it is already in the IR: a modal alert has
           no title, and anything the Window Manager gives a title bar
           has one to put in it. Same shape as the control-role rule - a
           titled thing is not the untitled kind. */
        let isDialog = !WindowChrome.hasTitleBar(win)

        /* TWO DECISIONS, NOT ONE, and collapsing them was a defect.
         *
           THIRD REVISION, 2026-08-07: the COLOUR is no longer decided
           here at all. `theme.face(forWindowKind:)` answers it from what
           the guest's own Appearance Manager reported in `meta.theme`,
           falling back to the Platinum constants for a scene that
           carries none. What stays here is the kind→brush MAPPING, which
           is a fact about the Window Manager rather than about a theme.
         *
           It also fixed a case the comment below could not: a
           kind-2000 (application-defined) panel such as Appearance's own
           was hardcoded to literal white, so no theme could ever move
           it. It now gets kThemeBrushDocumentWindowBackground, which is
           the brush that actually names that face.
         *
           `isDialog` above answers "does this window have a title bar",
           and it is right to key that on the title. It was ALSO being
           used to answer "what colour is the content face", and those two
           questions have different answers for the same window: the Date
           & Time control panel is windowKind 2 with a title, so it drew
           chrome correctly and then filled its whole body white.
         *
           The face follows the WINDOW MANAGER'S OWNER, not the chrome. A
           Dialog Manager window is erased with the Appearance Manager's
           `kThemeBrushDialogBackgroundActive` whether or not it has a
           title bar - one brush, and the guest itself asks for it by that
           name in three places (workshop_window.c, confirm.c,
           census_module.c). So `kind == 2` alone decides the face.
         *
           `kind` is the WindowRecord's own `windowKind`, read out of the
           machine - not something this side inferred. Anything else keeps
           white, which is what a document window's content really is. */
        let windowFace = theme.face(forWindowKind: win.kind,
                                    untitled: win.title.isEmpty)

        /* **TWO GEOMETRIES, AND EACH SIDE OF THIS MERGE OWNED ONE.**
           (Round 8, 2026-08-07, resolved by reading rather than by keeping
           both — the two branches disagreed about the same six lines.)

           TITLED — the frame is OUTSIDE the content, six pixels wide.
           Measured on the left, right and bottom of eight windows, always
           the same five colours reading outward: `000000`, then a raised
           band `FFFFFF · CCCCCC · CCCCCC · 999999` lit from the top-left,
           then `000000` again, then a one-pixel black drop shadow on the
           right and bottom offset by one. This used to be a one-pixel black
           rectangle ON the scene rect with a translucent grey blur behind
           it, which put the frame INSIDE the content the guest drew and
           lost twelve pixels of window furniture on every window the mirror
           has ever shown.

           DIALOG — the CONTENT BOX is the fixed point and the chrome is
           drawn around it. It used to be the other way round, so a titleless
           dialog's content began 14 pixels above and 6 right of where the
           guest put it. `HitTester` reads `WindowChrome.contentOrigin`, so
           it could not find a button a person had just aimed at, and Mail's
           Internet-setup alert became a modal nobody could dismiss. Both
           sides now read that one function.

           The titled case does NOT go through `WindowChrome.contentOrigin`
           arithmetic here because it does not need to: `PlatinumTitleBar.
           Row.contentTop` is the same 20, counted off the machine, and the
           titled render is no longer off by the (1, 2) that WindowChrome's
           note used to describe. */
        let content: CGRect
        let frame: CGRect
        if isDialog {
            content = rect(WindowChrome.content(win))
            frame = content.insetBy(dx: -CGFloat(WindowChrome.dialogBand),
                                    dy: -CGFloat(WindowChrome.dialogBand))
            /* Modal dialog chrome: NO title bar — a raised border band with
               an inner hairline, content face flush inside it. Its WDEF
               variant is not a document frame and nothing here was measured
               against one, so the painting is left exactly as it was; only
               WHICH rectangle it is hung on has changed. */
            ctx.fill(Path(frame.offsetBy(dx: 2, dy: 2)),
                     with: .color(.black.opacity(0.35)))
            ctx.fill(Path(frame), with: .color(Platinum.g6))
            let face = frame.insetBy(dx: 1, dy: 1)
            ctx.fill(Path(face), with: .color(Platinum.g2))
            bevel(ctx, face,
                  light: active ? Platinum.g0 : Platinum.g1,
                  shadow: active ? Platinum.g4 : Platinum.g3)
            let innerFrame = face.insetBy(dx: 4, dy: 4)
            ctx.fill(Path(CGRect(x: innerFrame.minX, y: innerFrame.minY,
                                 width: innerFrame.width, height: 1)),
                     with: .color(Platinum.g4))
            ctx.stroke(Path(innerFrame), with: .color(Platinum.g6),
                       lineWidth: 1)
        } else {
            frame = rect(win.rect)
            /* THE INACTIVE FRAME IS THE SAME SHAPE IN DIFFERENT COLOURS —
               measured, not guessed, on 2026-08-07. See PlatinumTitleBar's
               "Inactive" section: the geometry is identical to a pixel and
               only the inks move. */
            let edge = Color(rgb: active ? PlatinumTitleBar.frame
                                         : PlatinumTitleBar.inactiveFrame)
            let outer = CGRect(
                x: frame.minX - 6,
                y: frame.minY + CGFloat(PlatinumTitleBar.Row.outerFrame),
                width: frame.width + 12,
                height: frame.height + 6
                        - CGFloat(PlatinumTitleBar.Row.outerFrame))
            // The drop shadow: one pixel, right and bottom, offset one.
            ctx.fill(Path(CGRect(x: outer.maxX, y: outer.minY + 1,
                                 width: 1, height: outer.height)),
                     with: .color(edge))
            ctx.fill(Path(CGRect(x: outer.minX + 1, y: outer.maxY,
                                 width: outer.width, height: 1)),
                     with: .color(edge))
            ctx.fill(Path(outer), with: .color(edge))
            let band = outer.insetBy(dx: 1, dy: 1)
            ctx.fill(Path(band),
                     with: .color(Color(rgb: active
                                        ? PlatinumTitleBar.face
                                        : PlatinumTitleBar.inactiveFace)))
            if active {
                bevel(ctx, band,
                      light: Color(rgb: PlatinumTitleBar.lit),
                      shadow: Color(rgb: PlatinumTitleBar.bandShadow))
            }
            content = CGRect(
                x: frame.minX,
                y: frame.minY + CGFloat(PlatinumTitleBar.Row.contentTop),
                width: frame.width,
                height: max(0, frame.height
                               - CGFloat(PlatinumTitleBar.Row.contentTop)))
            ctx.fill(Path(CGRect(x: content.minX - 1, y: content.minY - 1,
                                 width: content.width + 2,
                                 height: content.height + 2)),
                     with: .color(edge))
            drawTitlebar(ctx, win, active: active)
        }
        /* The content face, and NOTHING on top of it. There used to be a
           `g4` rule along the content's first row, standing in for the title
           bar's bottom edge. The machine puts that edge in the FRAME — the
           `999999` shadow row and the black row above the content — so the
           rule was a second copy of it, painted one row INTO the guest's own
           drawing. It ate the first row of every window's content. */
        ctx.fill(Path(content), with: .color(windowFace))

        var contentCtx = ctx
        contentCtx.clip(to: Path(content))

        /* Absence is visible. A window whose guest scene carries no text,
           controls, dialog items, Finder items, display list, or declared
           visual region is not an empty white application: it is content the
           Mirror cannot currently express. Key Caps and NOW's own Workshop
           exposed why silently painting white is a fidelity defect even when
           their detailed drawing is outside the semantic core. */
        /* Controls do not constitute the content plane. NOW's Workshop has
           several real buttons over a large hand-drawn canvas; counting those
           buttons made the rest of the body silently white again. */
        let hasReportedContent = win.display != nil
            || win.text != nil
            || win.dialogItems != nil
            || win.items != nil
        if !hasReportedContent {
            drawUnavailableVisual(contentCtx, content,
                                  Self.absentContentCaption(win))
        }

        /* THE PIXEL ISLAND USED TO DRAW HERE, and it is gone (2026-08-07).
           When the poller held the guest's real framebuffer bytes for this
           window, they were drawn in place of everything below — so this
           branch decided the whole content area for any window without a
           named item roster.

           That is why it had to go rather than be left switched off: a
           window that looked right here looked right because it was a
           PHOTOGRAPH of the guest, and comparing it against the guest
           compared the guest's pixels with themselves. Every render score
           taken over such a window measured nothing.

           The rule it broke: guest-originated pixels may only reach the
           screen through the asset pack (`IconAtlas`), never off the wire.
           The display replay below already obeys it — it carries geometry
           and identity, and draws the pack's art or an honest "unavailable"
           hatch. Prior art: `archive/pixel-islands-2026-08-07/`. */

        // P3 owns unstructured content, while P2 owns concrete drawing wholly
        // contained by an exact semantic control/dialog rectangle. The replay
        // still carries whole-window background erases through those regions;
        // only control-local CopyBits/text/shapes yield to guest semantics.
        /* Finder's interior has one owner: its semantic snapshot. Even a
           stale display list from a pre-policy run must not re-enable the
           metal-proven Finder P3 path underneath it. */
        let finderOwnsInterior = win.app == "Finder" && win.items != nil
        let displayOwnsVisuals = !finderOwnsInterior
            && !(win.display?.isEmpty ?? true)
        /* A DITL resource-control row and its live ControlRecord share one
           ref. The DITL can only say "unknown resource", while P2 may later
           prove that exact control is a list or another drawable control.
           Prefer the more specific guest fact; the old unconditional DITL
           precedence painted a hatch over Date & Time's real list payload. */
        /* THE TWO ROWS THAT SHARE A REF ARE ONE THING, AND WHICHEVER
           KNOWS MORE ABOUT IT DRAWS. A DITL row and its live
           ControlRecord are the same object seen through two windows,
           so exactly one of them may draw and the other must stand
           down. Until 2026-08-07 the tie was broken by asking the
           CONTROL alone for `knowledge == .known`, and the CDEF route
           answers `derived` — so twenty of Date & Time's twenty-one
           controls lost to dialog items carrying `knowledge: unknown,
           kind: null`, which is nothing at all. That is why the panel
           has had no group boxes in any sweep, and why the Charcoal
           strike could not be seen in its titles even after the string
           began arriving whole: the row that would have drawn them was
           being skipped in favour of a row that knew less.
           Asked as a comparison, the alert case that motivated the old
           rule keeps working and for the right reason:
           `scene-ie-error-alert` has the OPPOSITE shape — its three
           buttons are `unknown` controls beside `known` pushButton
           items — so the item still wins there. */
        let itemsByRef: [String: MirrorKit.Scene.DialogItem] =
            (win.dialogItems ?? []).reduce(into: [:]) { table, item in
                if let ref = item.ref { table[ref] = item }
            }
        let semanticControlRefs: Set<String> = Set(win.controls.compactMap {
            control -> String? in
            Self.semanticOutranks(control, itemsByRef[control.ref])
                ? control.ref : nil
        })
        let dialogRefs: Set<String> = Set((win.dialogItems ?? []).compactMap {
            item -> String? in
            guard let ref = item.ref,
                  !semanticControlRefs.contains(ref) else { return nil }
            return ref
        })
        let semanticFrames = win.controls.compactMap { control -> CGRect? in
            guard control.visible, Self.semanticOwnsDisplay(control),
                  !dialogRefs.contains(control.ref),
                  let local = control.rect else { return nil }
            return rect(local).offsetBy(dx: content.minX, dy: content.minY)
        } + (win.dialogItems ?? []).compactMap { item -> CGRect? in
            /* ONLY AN ITEM THIS HOST ACTUALLY DRAWS may silence the
               guest's own drawing under it. A control earns that right
               through `semanticOwnsDisplay`; a dialog item had no
               equivalent gate, so every visible DITL row — user items,
               unknown resource shells, pictures, the slots an
               application draws itself — excluded the replay and then
               drew nothing or a hatch in its place. Date & Time lost its
               date, its time, both group boxes and every field to
               twenty such rows (2026-08-06). `drawsConcretely` is the
               same question `drawDialogItem` already asks itself. */
            guard item.visible,
                  Self.dialogItemOwnsDisplay(item),
                  item.ref.map({ !semanticControlRefs.contains($0) }) ?? true
            else { return nil }
            return rect(item.rect).offsetBy(dx: content.minX, dy: content.minY)
        } + Self.finderItemFrames(win, content: content)
        /* WHAT THE REPLAY INKED, so a placeholder cannot claim a
           rectangle it already filled. See DisplayReplay.Coverage and
           docs/render-composition.md > "the rule for anyone adding a
           placeholder". */
        let replayCoverage = DisplayReplay.Coverage()
        /* A BACKGROUND IS GROUND, SO IT GOES DOWN FIRST. `panel`,
           `placard`, `selectionBand` and `separator` are the four DITL
           kinds that fill a rectangle and say nothing about what is in
           it — which is why `dialogItemOwnsDisplay` already refuses to
           let them silence the drawing under them. They were still drawn
           AFTER the replay, and that was invisible only for as long as
           the first gate silenced every drawn run inside them: the
           moment rung 1 stopped yielding, NOW's Workshop sidebar
           replayed all fifteen of its rows and then had its own `panel`
           painted flat white over the lot.

           Order, not another exclusion. The machine paints its ground
           and then draws on it, and so does this: backgrounds under the
           replay, the Control Manager's furniture over it. A coverage
           test could not stand in for that — `covers` intersects, so one
           inked pixel anywhere would suppress a whole panel. */
        for item in win.dialogItems ?? [] where item.visible
                && Self.dialogItemIsBackground(item.semantic.kind)
                && (item.ref.map { !semanticControlRefs.contains($0) }
                    ?? true) {
            drawDialogItem(contentCtx, item, contentOrigin: content.origin,
                           windowFace: windowFace)
        }
        /* AND SO DOES A GROUND CONTROL — but only where there is no
           drawing for it to be ground UNDER. See `controlIsGround`: the
           chain's order is the application's, not a stacking order, and
           a pane that happens to arrive last must not bury what came
           before it.
           The condition is the same one every other control answers a
           few lines below, and it has to be: a window whose interior
           the replay owns has already been answered by rung 1, and a
           pane drawn ahead of it would put "Structured content
           unavailable" under Date & Time's own Time Zone group for the
           length of one repaint. Ground marks an absence; where there
           is no absence it draws nothing at all. */
        for control in win.controls where control.visible
                && Self.controlIsGround(control)
                && !displayOwnsVisuals
                && !Self.groundWrapsTheChain(control, in: win)
                && !dialogRefs.contains(control.ref) {
            drawControl(contentCtx, control, contentOrigin: content.origin,
                        isDefault: false, windowFace: windowFace)
        }
        if !finderOwnsInterior, let display = win.display {
            DisplayReplay.draw(display, in: contentCtx, content: content,
                               excluding: semanticFrames,
                               ladder: Self.ladder(for: win, content: content,
                                                   owning: semanticFrames),
                               coverage: replayCoverage)
        }
        if !displayOwnsVisuals, let text = win.text {
            drawWindowText(contentCtx, text, in: content)
        }
        for control in win.controls where control.visible
                && !dialogRefs.contains(control.ref)
                && !Self.controlIsGround(control)
                && (!displayOwnsVisuals || Self.semanticOwnsDisplay(control)
                    || Self.isWindowFurniture(control)) {
            drawControl(contentCtx, control, contentOrigin: content.origin,
                        isDefault: control.semantic?.isDefault == true,
                        replayed: replayCoverage,
                        windowFace: windowFace)
        }
        /* An alert's default-outline slot is a DITL user item laid OVER the
           button it outlines, and it is drawn after it. Painting a
           placeholder there erased Internet Explorer's OK button and left
           two hatched boxes where the machine showed one button (captured
           2026-08-06, `scene-ie-error-alert.json`). So a placeholder yields
           to anything concrete that is already under it. */
        let drawnItems = win.dialogItems?.filter {
            $0.visible && Self.drawsConcretely($0.semantic.kind)
                && ($0.ref.map { !semanticControlRefs.contains($0) } ?? true)
        }.map {
            rect($0.rect).offsetBy(dx: content.minX, dy: content.minY)
        } ?? []
        for item in win.dialogItems ?? [] where item.visible
                && !Self.dialogItemIsBackground(item.semantic.kind)
                && (item.ref.map { !semanticControlRefs.contains($0) }
                    ?? true) {
            drawDialogItem(contentCtx, item, contentOrigin: content.origin,
                           covering: drawnItems,
                           replayed: replayCoverage,
                           windowFace: windowFace)
        }
        // Finder icon-view items, in window-local content coords — the
        // Finder's own live positions, so what is drawn is where the guest
        // drew it. Clipped to the icon field (the strip below the info bar and
        // inside the scrollbars): a scrolled window reports positions that run
        // off both ends, and the guest clips them exactly here.
        if let items = win.items {
            let area = FinderItems.iconArea(win)
            var iconCtx = contentCtx
            iconCtx.clip(to: Path(CGRect(
                x: content.minX + CGFloat(area.l),
                y: content.minY + CGFloat(area.t),
                width: CGFloat(max(0, area.r - area.l)),
                height: CGFloat(max(0, area.b - area.t)))))
            for item in items where item.placed {
                let selected = win.finder?.selectedNames.contains(item.name)
                    == true || selectedItem == item.name
                drawFinderItem(iconCtx, item,
                               at: CGPoint(
                                x: content.minX + CGFloat(item.x),
                                y: content.minY + CGFloat(item.y)),
                               view: win.finder?.view ?? .unknown,
                               selected: selected,
                               replayed: replayCoverage)
            }
        }
        // Grow box sits on top of the content, at the window corner.
        if !isDialog {
            drawGrowBox(ctx, win)
        }
    }

    /// A Finder item has three measured presentations. The box always comes
    /// from Finder; view tells us whether the name belongs below it or beside
    /// it. Before this field existed list and small-icon views both arrived as
    /// 16x16 boxes, so the renderer could only omit the name and hope P3 drew
    /// the columns — exactly the dependency this slice removes.
    private func drawFinderItem(
        _ ctx: GraphicsContext, _ item: MirrorKit.Scene.DesktopItem,
        at origin: CGPoint, view: MirrorKit.Scene.FinderPresentation.View,
        selected: Bool, replayed: DisplayReplay.Coverage?
    ) {
        if view == .icon || view == .unknown && Self.itemDrawsItsOwnLabel(item) {
            drawIcon(ctx, item, at: origin, selected: selected,
                     replayed: replayed)
            return
        }

        let box = CGRect(origin: origin, size: Self.iconBoxSize(item))
        drawGenericIcon(ctx, box, item: item)
        if selected {
            var inverted = ctx
            inverted.blendMode = .multiply
            inverted.fill(Path(box), with: .color(Platinum.g4))
        }
        let ascent = CGFloat(FontBook.small?.ascent ?? 9)
        let width = CGFloat(FontBook.small?.width(item.name)
                            ?? item.name.count * 6)
        let label = CGRect(x: box.maxX + 4, y: box.minY,
                           width: width + 4, height: ascent + 3)
        ctx.fill(Path(label), with: .color(selected ? Platinum.g6 : .white))
        appText(item.name, ctx, x: label.minX + 2,
                baselineY: label.minY + ascent,
                color: selected ? .white : Platinum.g6, small: true)
    }

    /// The Platinum title bar, drawn the way the machine draws it.
    ///
    /// Every colour and every distance here is MEASURED off the guest's own
    /// QMP screendumps and lives once, in `MirrorKit.PlatinumTitleBar`, which
    /// carries the evidence. Read that file before changing a number here.
    ///
    /// **The drain could not help with this one.** For the tab strip the
    /// Appearance Manager leaked its parameters through the QuickDraw
    /// bottlenecks; for the title bar it leaks nothing at all — the WDEF does
    /// not draw into an application port, and fourteen captures contain no
    /// title-bar op and no window title anywhere in their text ops. So this is
    /// rung 4 of `docs/deriving-a-drawn-procedure.md`, pixels only.
    ///
    /// What this replaced, and what each was wrong about:
    ///
    /// * the band was 18 rows starting at `t+1`; the machine's is 22 starting
    ///   at `t-2`, with a black frame row and a lit row above the face;
    /// * the stripes were white lines every two pixels on the face, full
    ///   width. The machine alternates `FFFFFF` and **`777777`** — a grey the
    ///   ported palette does not contain — for exactly twelve rows, and the
    ///   field stops six pixels clear of the close box and seven clear of the
    ///   first right-hand widget rather than running under them;
    /// * the title patch was `width + 16` and centred on the bar; the
    ///   machine's is `width + 8` centred on the window;
    /// * the widgets were flat bevelled squares in the wrong places.
    private func drawTitlebar(_ ctx: GraphicsContext, _ win: MirrorKit.Scene.Window,
                              active: Bool) {
        let r = win.rect
        let L = CGFloat(r.l), R = CGFloat(r.r), T = CGFloat(r.t)

        /* The band, top to bottom. It starts TWO ROWS ABOVE the scene rect:
           `Scene.Window.rect` is the content port grown up by 20, and the
           machine's outer frame is 22 above the content on every window
           measured. The two rows above `t` are the window's own frame and its
           lit edge, and without them a Platinum window has no top edge at
           all — which is why every render has read as a floating grey slab. */
        let band = CGRect(x: L, y: T + CGFloat(PlatinumTitleBar.Row.outerFrame),
                          width: R - L,
                          height: CGFloat(PlatinumTitleBar.Row.contentTop
                                          - PlatinumTitleBar.Row.outerFrame))
        ctx.fill(Path(band),
                 with: .color(Color(rgb: active ? PlatinumTitleBar.face
                                                : PlatinumTitleBar.inactiveFace)))
        let edge = active ? PlatinumTitleBar.frame
                          : PlatinumTitleBar.inactiveFrame
        row(ctx, band, PlatinumTitleBar.Row.outerFrame, T, edge)
        row(ctx, band, PlatinumTitleBar.Row.contentFrame, T, edge)
        if active {
            row(ctx, band, PlatinumTitleBar.Row.litEdge, T, PlatinumTitleBar.lit)
            row(ctx, band, PlatinumTitleBar.Row.bandShadow, T,
                PlatinumTitleBar.bandShadow)
        }

        let title = win.title.isEmpty ? "untitled" : win.title
        let titleWidth = Int(sysWidth(title).rounded())

        /* AN INACTIVE TITLE BAR IS A DIFFERENT DRAWING, not a dimmed one —
           and this is now MEASURED rather than inferred. Nothing in the
           private asset store had ever contained one: every background window
           in all fourteen sweep captures is fully occluded. So one was
           photographed on 2026-08-07 on a lane-private guest, two control
           panels deep, and it says the geometry is unchanged to a pixel while
           three colours move and two things vanish. `PlatinumTitleBar`'s
           "Inactive" section and the capture's own PROVENANCE.md carry it.

           No stripes, no widgets, and no title PATCH: with the band flat there
           is nothing to punch the title out of, and the machine punches
           nothing. The title's baseline does not move. */
        guard active else {
            var titleCtx = ctx
            titleCtx.clip(to: Path(band))
            let patch = PlatinumTitleBar.titlePatch(r, titleWidth: titleWidth,
                                                    dark: false)
            sysText(title, titleCtx,
                    x: CGFloat(patch.l + PlatinumTitleBar.patchPad),
                    baselineY: T + CGFloat(PlatinumTitleBar.titleBaseline),
                    color: Color(rgb: PlatinumTitleBar.inactiveTitle))
            return
        }

        // The striped field runs between the close box and the first
        // right-hand widget; the title patch is punched out of it, and BOTH
        // sit one pixel right on the dark rows.
        let firstRightWidgetLeft =
            (WindowChrome.widgetBox(win, .zoom) ?? PlatinumTitleBar.collapseBox(r)).l
        for k in 0..<PlatinumTitleBar.stripeRows {
            let dark = k % 2 == 1
            let y = T + CGFloat(PlatinumTitleBar.Row.stripesTop + k)
            let run = PlatinumTitleBar.stripeRun(
                r, firstRightWidgetLeft: firstRightWidgetLeft, dark: dark)
            let patch = PlatinumTitleBar.titlePatch(r, titleWidth: titleWidth,
                                                    dark: dark)
            let ink = Color(rgb: dark ? PlatinumTitleBar.stripeDark
                                      : PlatinumTitleBar.lit)
            stripe(ctx, from: run.from, to: min(run.to, patch.l - 1), y: y,
                   color: ink)
            stripe(ctx, from: max(run.from, patch.r), to: run.to, y: y,
                   color: ink)
        }

        let patch = PlatinumTitleBar.titlePatch(r, titleWidth: titleWidth,
                                                dark: true)
        var titleCtx = ctx
        titleCtx.clip(to: Path(rect(patch)))
        sysText(title, titleCtx, x: CGFloat(patch.l + PlatinumTitleBar.patchPad),
                baselineY: T + CGFloat(PlatinumTitleBar.titleBaseline),
                color: Color(rgb: PlatinumTitleBar.frame))

        // Boxes come from WindowChrome (guest coords) — the exact rects the
        // hit-tester checks, so what's drawn is what's clickable. `.zoom`
        // answers nil until the guest reports the WDEF variant; a widget the
        // machine may not have is not drawn.
        for widget in WindowChrome.Widget.allCases {
            drawWbox(ctx, win, widget)
        }
    }

    /// One full-width row of the title-bar band, at `offset` from `t`.
    private func row(_ ctx: GraphicsContext, _ band: CGRect, _ offset: Int,
                     _ T: CGFloat, _ rgb: UInt32) {
        ctx.fill(Path(CGRect(x: band.minX, y: T + CGFloat(offset),
                             width: band.width, height: 1)),
                 with: .color(Color(rgb: rgb)))
    }

    /// One run of one stripe row, in guest pixels, inclusive of both ends —
    /// `LineTo` inks both endpoints and so does this.
    private func stripe(_ ctx: GraphicsContext, from: Int, to: Int,
                        y: CGFloat, color: Color) {
        guard to >= from else { return }
        ctx.fill(Path(CGRect(x: CGFloat(from), y: y,
                             width: CGFloat(to - from + 1), height: 1)),
                 with: .color(color))
    }

    /// A title-bar widget: a recess, a ring, and a diagonal ramp.
    ///
    /// The machine's widget is **sunk into the bar** — one pixel of `888888`
    /// along its top and left, one of `FFFFFF` along its bottom and right,
    /// each a pixel outside the button. Inside the `222222` ring the 7×7 core
    /// is an anti-diagonal ramp through the seven greys, one step every two
    /// diagonals, dark at the top-left and white at the bottom-right. The old
    /// drawer had a flat face with a plain bevel and no ramp at all.
    ///
    /// The glyphs, also counted: the close box has **none**; the zoom box is a
    /// 7×7 square outline sharing the ring's own top and left edges; the
    /// collapse box is two full-width bars at local rows 4 and 6 — not the one
    /// centred line this used to draw.
    private func drawWbox(_ ctx: GraphicsContext,
                          _ win: MirrorKit.Scene.Window,
                          _ widget: WindowChrome.Widget) {
        guard let g = WindowChrome.widgetBox(win, widget) else { return }
        let box = rect(g)
        let recess = rect(PlatinumTitleBar.widgetRecess(g))
        let shadow = Color(rgb: PlatinumTitleBar.recessShadow)
        let lit = Color(rgb: PlatinumTitleBar.lit)
        // Recess: shadow along top+left, highlight along bottom+right, each
        // one pixel outside the button and offset by one along its run.
        ctx.fill(Path(CGRect(x: recess.minX, y: recess.minY,
                             width: recess.width - 1, height: 1)), with: .color(shadow))
        ctx.fill(Path(CGRect(x: recess.minX, y: recess.minY,
                             width: 1, height: recess.height - 1)), with: .color(shadow))
        ctx.fill(Path(CGRect(x: recess.minX + 1, y: recess.maxY - 1,
                             width: recess.width - 1, height: 1)), with: .color(lit))
        ctx.fill(Path(CGRect(x: recess.maxX - 1, y: recess.minY + 1,
                             width: 1, height: recess.height - 1)), with: .color(lit))

        let ink = Color(rgb: PlatinumTitleBar.widgetInk)
        ctx.fill(Path(box), with: .color(ink))
        // Inside the ring: a light edge top+left, a shadow edge bottom+right,
        // and the ramp in the middle.
        let inner = box.insetBy(dx: 1, dy: 1)
        ctx.fill(Path(inner), with: .color(Color(rgb: PlatinumTitleBar.face)))
        ctx.fill(Path(CGRect(x: inner.maxX - 1, y: inner.minY + 1,
                             width: 1, height: inner.height - 1)), with: .color(shadow))
        ctx.fill(Path(CGRect(x: inner.minX + 1, y: inner.maxY - 1,
                             width: inner.width - 1, height: 1)), with: .color(shadow))
        ctx.fill(Path(CGRect(x: inner.minX, y: inner.minY, width: 1, height: 1)),
                 with: .color(lit))
        for v in 0..<7 {
            for u in 0..<7 {
                let step = PlatinumTitleBar.widgetRamp[
                    PlatinumTitleBar.widgetRampIndex(u: u, v: v)]
                ctx.fill(Path(CGRect(x: inner.minX + 1 + CGFloat(u),
                                     y: inner.minY + 1 + CGFloat(v),
                                     width: 1, height: 1)),
                         with: .color(Color(rgb: step)))
            }
        }

        switch widget {
        case .close:
            break          // the machine draws no glyph in a close box
        case .zoom:
            ctx.fill(Path(CGRect(x: box.minX + 6, y: box.minY,
                                 width: 1, height: 7)), with: .color(ink))
            ctx.fill(Path(CGRect(x: box.minX, y: box.minY + 6,
                                 width: 7, height: 1)), with: .color(ink))
        case .collapse:
            for local in [4, 6] {
                ctx.fill(Path(CGRect(x: box.minX, y: box.minY + CGFloat(local),
                                     width: box.width, height: 1)),
                         with: .color(ink))
            }
        }
    }

    /// The grow box at the window's bottom-right (front, non-dialog).
    private func drawGrowBox(_ ctx: GraphicsContext,
                             _ win: MirrorKit.Scene.Window) {
        guard let guestBox = WindowChrome.growBox(win) else { return }
        let box = rect(guestBox)
        ctx.fill(Path(box), with: .color(Platinum.g2))
        ctx.stroke(Path(box), with: .color(Platinum.g6), lineWidth: 1)
        bevel(ctx, box.insetBy(dx: 1, dy: 1),
              light: Platinum.g0, shadow: Platinum.g4)
        // Two diagonal hatch lines — the classic grow-box glyph.
        for off in [4, 8] {
            var p = Path()
            p.move(to: CGPoint(x: box.minX + CGFloat(off), y: box.maxY - 2))
            p.addLine(to: CGPoint(x: box.maxX - 2, y: box.minY + CGFloat(off)))
            ctx.stroke(p, with: .color(Platinum.g5), lineWidth: 1)
        }
    }

    private func drawWindowText(_ ctx: GraphicsContext,
                                _ text: MirrorKit.Scene.TextContent,
                                in content: CGRect) {
        let body = text.content.replacingOccurrences(of: "\r", with: "\n")
        let padded = content.insetBy(dx: 8, dy: 6)
        let lineH = CGFloat(FontBook.app?.cellHeight ?? 14)
        var baseline = padded.minY + CGFloat(FontBook.app?.ascent ?? 10)
        for line in body.split(separator: "\n", omittingEmptySubsequences: false) {
            if baseline > padded.maxY { break }
            appText(String(line), ctx, x: padded.minX, baselineY: baseline,
                    color: Platinum.g6)
            baseline += lineH
        }
    }

    // MARK: - Controls

    /// A control renders as a button only when its title is real text —
    /// AXPeek reads titles as raw MacRoman and custom controls can carry
    /// garbage (U+FFFD after repair-decode) that must not be promoted.
    static func looksLikeButton(_ ctl: MirrorKit.Scene.Control) -> Bool {
        if ctl.semantic?.kind == "pushButton" || ctl.role == "button" {
            return true
        }
        guard !ctl.title.isEmpty,
              !ctl.title.unicodeScalars.contains(where: {
                  $0.value < 32 || $0.value == 127 || $0.value == 0xFFFD
              }) else { return false }
        guard let r = ctl.rect else { return false }
        return (r.b - r.t) <= 26 && (r.r - r.l) > 20
    }

    /// **Rung 3's identities, gathered from the semantic plane.**
    ///
    /// The one rule: a rectangle is NAMED only because P2 said what is at
    /// it. Never because of its size, never because of its shape. See
    /// ``ProvenanceLadder`` and docs/render-composition.md.
    ///
    /// Two exclusions carry the weight, and both were paid for by sweep A:
    ///
    /// - **A derived cell names nothing.** `DrawnCellGrid` derives Sherlock
    ///   2's channel grid from the drawing itself, so a cell's evidence IS
    ///   the pixels — it can say where the cell is and which is selected,
    ///   and nothing at all about the art inside it. Sweep A found nine
    ///   page icons in that grid. They are unknowns.
    /// - **An untyped control names nothing.** A Finder window's scroll
    ///   bars arrive with `role: "unknown"` and no semantic kind, so their
    ///   16×16 arrow blits get no name and draw as marked unknowns rather
    ///   than as documents. That is the whole of Michelle's complaint #5,
    ///   and "arrows or a marked unknown, never a page" is the exit
    ///   criterion it became.
    public static func ladder(for win: MirrorKit.Scene.Window,
                              content: CGRect,
                              owning: [CGRect]) -> ProvenanceLadder {
        func place(_ r: MirrorKit.Rect) -> CGRect {
            CGRect(x: content.minX + CGFloat(r.l), y: content.minY + CGFloat(r.t),
                   width: CGFloat(max(0, r.r - r.l)),
                   height: CGFloat(max(0, r.b - r.t)))
        }
        var named: [(rect: CGRect, art: ProvenanceLadder.NamedArt)] = []
        for control in win.controls where control.visible {
            guard let rect = control.rect,
                  control.semantic?.knowledge == .known,
                  let kind = control.semantic?.kind,
                  kind != MirrorKit.DrawnCellGrid.cellKind,
                  !Self.isBackgroundKind(kind) else { continue }
            named.append((place(rect), .control))
        }
        for item in win.dialogItems ?? [] where item.visible {
            let kind = item.semantic.kind
            if kind == "icon" {
                named.append((place(item.rect), .icon))
            } else if item.semantic.knowledge == .known,
                      !Self.isBackgroundKind(kind ?? "") {
                named.append((place(item.rect), .control))
            }
        }
        return .init(owning: owning, named: named,
                     inkIsCurrent: win.displayEpoch?.stale != true)
    }

    /// Backgrounds name nothing: they routinely wrap most of a dialog, and
    /// a background that claimed every blit inside it would be the
    /// `dialogItemOwnsDisplay` defect wearing a third hat.
    static func isBackgroundKind(_ kind: String) -> Bool {
        kind == "panel" || kind == "placard" || kind == "selectionBand"
            || kind == "groupBox" || kind == "userItem"
    }

    /// Window furniture the Control Manager draws OVER application content
    /// on the real machine. A scrollbar is chrome, not app drawing: a
    /// display-owned window must still show it, or the bar appears only as
    /// whatever fragments of it the app's own stream happened to carry —
    /// which is exactly the missing-arrows render this line fixed.
    static func isWindowFurniture(_ ctl: MirrorKit.Scene.Control) -> Bool {
        ctl.semantic?.kind == "scrollBar" || ctl.role == "scrollbar"
            /* A DERIVED CELL draws over the display for the same reason,
               and it is the only honest arrangement here. Its evidence IS
               the display — so it must not clip the rectangle it was
               derived from (`semanticOwnsDisplay` stays false for it) —
               but the two facts it adds, the cell's frame and WHICH ONE
               IS SELECTED, are precisely what the drawing stream could
               not say. So it draws a frame and a selection over content
               it leaves intact, rather than replacing it. */
            || ctl.semantic?.kind == MirrorKit.DrawnCellGrid.cellKind
    }

    /// Whether P2 carries enough visual facts to replace P3 inside the whole
    /// control rectangle. Containers, partial lists, and value-less popups do
    /// not: clipping their rectangle erased the Date & Time labels and list
    /// rows that only the guest's drawing stream knew.
    /// **The TEXT a control's semantics carry, or nil — and `derived`
    /// carries none.**
    ///
    /// `semantic.value` is read by this renderer as the string a control
    /// DISPLAYS: a static label's words, a field's contents, a popup's
    /// chosen item. The CDEF route cannot supply that. It names the code
    /// that draws a control by its resource id and then reports
    /// `GetControlValue` in the same key — so every one of Memory's
    /// twelve reachable static labels arrived carrying the string "0",
    /// and the renderer drew a `0` hard against the machine's own first
    /// glyph: "Ⅱirtual Memory", "Ⅱurrent Theme" (sweep B, R2). The popup
    /// was worse — it drew the menu INDEX, "1", over the machine's
    /// "Macintosh HD".
    ///
    /// The producer is being fixed in the same change
    /// (`now-guest-ppc/src/scene/scene_json.c`, which no longer emits
    /// `value` for a derived control at all, the number already riding
    /// in the control's own `value`). This gate is the receiver's half
    /// and is not redundant: every committed capture in this tree still
    /// carries the old field, the 68K guest is a separate producer, and
    /// the rule is true independently of who is sending — **the claim
    /// must be no stronger than the evidence, and a CDEF id is not
    /// evidence about a string.**
    public static func semanticText(_ semantic: MirrorKit.Scene.Semantics?)
        -> String? {
        guard let semantic, semantic.knowledge == .known,
              let value = semantic.value, !value.isEmpty else { return nil }
        return value
    }

    static func semanticOwnsDisplay(_ ctl: MirrorKit.Scene.Control) -> Bool {
        switch ctl.semantic?.kind {
        case "pushButton", "checkBox", "radioButton":
            return !ctl.title.isEmpty
        case "popupMenu":
            return Self.semanticText(ctl.semantic) != nil
        case "progressIndicator":
            return ctl.value != nil
        case "disclosureTriangle":
            return ctl.semantic?.state != nil
        case "scrollBar":
            return ctl.min != nil && ctl.max != nil && ctl.value != nil
        case "listBox":
            return !(ctl.semantic?.listCells?.isEmpty ?? true)
        case "staticText", "editText":
            return Self.semanticText(ctl.semantic) != nil
                || !ctl.title.isEmpty
        case "columnHeader":
            return !ctl.title.isEmpty
        case "groupBox":
            return false
        default:
            return false
        }
    }

    /// A typed control may replace its exact unknown DITL resource shell
    /// without claiming the whole rectangle against P3. Group boxes are the
    /// important distinction: their border/title are complete structured
    /// facts, but their interior may still contain application drawing.
    /// Whether `ctl` should draw INSTEAD OF the dialog item that shares
    /// its reference — the two being one object reported twice.
    ///
    /// `semanticSupersedesResource` is the `known` half and is
    /// unchanged. What is added is the `derived` half, and it is stated
    /// as a comparison rather than as a second threshold: a control the
    /// CDEF route classified outranks an item that carries **no kind at
    /// all**, and outranks nothing else. An item that knows what it is
    /// keeps the rectangle.
    public static func semanticOutranks(_ ctl: MirrorKit.Scene.Control,
                                 _ item: MirrorKit.Scene.DialogItem?)
        -> Bool {
        if Self.semanticSupersedesResource(ctl) { return true }
        guard ctl.semantic?.knowledge == .derived,
              ctl.semantic?.kind != nil else { return false }
        guard let item else { return true }
        return item.semantic.knowledge == .unknown
            || item.semantic.kind == nil
    }

    static func semanticSupersedesResource(
        _ ctl: MirrorKit.Scene.Control
    ) -> Bool {
        guard ctl.semantic?.knowledge == .known else { return false }
        switch ctl.semantic?.kind {
        case "groupBox", "staticText", "editText", "columnHeader":
            return true
        case "listBox":
            /* Knowing this is a list is enough to reject the DITL's generic
               unknown-resource hatch. It is not enough to replace P3: until
               cells arrive, semanticOwnsDisplay remains false and the guest's
               structured drawing continues through this rectangle. */
            return true
        default:
            return semanticOwnsDisplay(ctl)
        }
    }

    /// `windowFace` is the colour THIS window's content was erased with —
    /// see `Platinum.dialogFace`. A control that knocks a hole in the face
    /// to sit in (a group box's title band) must fill that hole with the
    /// face, not with a constant, or the hole becomes a visible plate on
    /// every window whose face is not white.
    private func drawControl(_ ctx: GraphicsContext, _ ctl: MirrorKit.Scene.Control,
                             contentOrigin: CGPoint, isDefault: Bool,
                             replayed: DisplayReplay.Coverage? = nil,
                             windowFace: Color = Platinum.g0) {
        guard let local = ctl.rect else { return }   // rect is content-local
        let frame = rect(local).offsetBy(dx: contentOrigin.x,
                                         dy: contentOrigin.y)
        guard frame.width > 0, frame.height > 0 else { return }
        /* RUNG 1 BEATS RUNG 2 HERE TOO, and until sweep B nothing on
           this path asked. `drawDialogItem` has consulted `Coverage`
           since 2026-08-06 and its twin did not, so the two planes
           answered the same question differently — which is the drift
           the ladder exists to stop. See `Coverage.textCovers`. */
        func replayedWords(_ piece: CGRect) -> Bool {
            replayed?.textCovers(piece) == true
        }
        /* AND A WHOLE WIDGET YIELDS WHERE THE MACHINE DREW ONE. These
           branches do not annotate a rectangle, they REPLACE it — a
           filled Platinum pill, a mark box, a popup face — so drawing
           one over a rectangle the replay already answered is rung 2
           painting over rung 1, which is the defect this whole change
           is about. Memory measured it the moment the classification
           reached the renderer: OS 9 builds its radio buttons from a
           CDEF the guest reports as the button FAMILY, so six of the
           panel's radios arrived as `pushButton` and six Platinum pills
           landed on top of the machine's own radios and labels.
           `mostlyCovers`, not `covers`: the panel's own face paint is
           swept-over ground and must not count, which is the bound that
           predicate already carries. */
        func replayedWidget(_ piece: CGRect) -> Bool {
            /* WORDS COUNT, and they are usually the only thing that
               fits. `mostlyCovers` asks about the RECTANGLE, and a
               control rect is a slack box: Memory's "On" radio is 37
               points holding a 16-point run, so the area test said no
               and a pill landed on the machine's own radio anyway.
               A run of the machine's own text inside a control's
               rectangle is as good evidence that the machine drew that
               control as anything this side will ever have. */
            replayed?.mostlyCovers(piece) == true || replayedWords(piece)
        }

        // Guest-proven semantics win. These are the CDEF procIDs NOW recorded
        // when it created its own controls; collapsing them all to buttons is
        // what made Workshop popups and checkboxes appear as pills.
        switch ctl.semantic?.kind {
        case "pushButton":
            guard !replayedWidget(frame) else { return }
            drawButton(ctx, ctl, frame, isDefault: isDefault)
            return
        case "checkBox":
            /* PER PIECE, NOT PER ROW, and this is the second time that
               distinction has cost check boxes. A choice control's
               LABEL arrives as a text op and its little mark box does
               not, so a row-wide yield takes both: NOW's own Workshop
               lost the tick beside "Compress on wire (PackBits)" the
               first time this gate was written whole. Same split
               `drawDialogItem` has made since 2026-08-06. */
            drawChoice(ctx, ctl, frame, radio: false,
                       markIsDrawn: { replayedWidget($0) },
                       labelIsDrawn: { replayedWords($0) })
            return
        case "radioButton":
            drawChoice(ctx, ctl, frame, radio: true,
                       markIsDrawn: { replayedWidget($0) },
                       labelIsDrawn: { replayedWords($0) })
            return
        case "popupMenu":
            guard !replayedWords(frame) else { return }
            drawPopup(ctx, ctl, frame)
            return
        case "groupBox":
            /* A group box is a frame and a label, and the label half
               yields on its own terms: the band it knocks out of its
               own rule is the machine's if the machine drew the title
               there. */
            drawGroup(ctx, ctl, frame, windowFace: windowFace,
                      titleIsDrawn: { replayedWords($0) })
            return
        case "progressIndicator":
            drawProgress(ctx, ctl, frame)
            return
        case "disclosureTriangle":
            drawDisclosure(ctx, ctl, frame)
            return
        case "listBox":
            drawListSelection(ctx, ctl, frame)
            return
        case "staticText":
            guard !replayedWords(frame) else { return }
            appText(Self.semanticText(ctl.semantic) ?? ctl.title, ctx,
                    x: frame.minX,
                    baselineY: frame.minY
                        + CGFloat(FontBook.app?.ascent ?? 10),
                    color: ctl.enabled ? Platinum.g6 : Platinum.g3)
            return
        case "editText":
            guard !replayedWords(frame) else { return }
            ctx.fill(Path(frame), with: .color(Platinum.g0))
            ctx.stroke(Path(frame), with: .color(Platinum.g6), lineWidth: 1)
            appText(Self.semanticText(ctl.semantic) ?? ctl.title, ctx,
                    x: frame.minX + 3, baselineY: frame.midY + 4,
                    color: ctl.enabled ? Platinum.g6 : Platinum.g3)
            return
        case "columnHeader":
            ctx.fill(Path(frame), with: .color(Platinum.g2))
            ctx.stroke(Path(frame), with: .color(Platinum.g5), lineWidth: 1)
            appText(ctl.title, ctx, x: frame.minX + 4,
                    baselineY: frame.midY + 4,
                    color: ctl.enabled ? Platinum.g6 : Platinum.g3)
            return
        case MirrorKit.DrawnCellGrid.cellKind:
            drawDrawnCell(ctx, ctl, frame)
            return
        case "dataBrowser", "userPane", "imageWell", "systemControl":
            /* These are real guest-proven regions, but this semantic slice
               does not yet carry their private rows or drawing. Never turn
               that bounded absence back into an empty application surface. */
            /* GROUND IS NOT CONTENT, AND GROUND THAT ARRIVES LAST MUST
               NOT PAINT OVER WHAT CAME BEFORE IT. A `userPane` is the
               control-plane spelling of a DITL `userItem`, and that
               branch settled this question one plane over: a user pane
               has no content of its OWN, so whatever appears inside it
               was drawn by the application — P3's business, not a
               semantic fact. Appearance's outermost control is a user
               pane covering the whole content rect and LAST in the
               chain, so the plate erased all six tabs the replay had
               just drawn (integration round 4). The absence is still
               marked wherever the machine drew nothing; what it may no
               longer do is claim a rectangle the replay already
               answered. Same rule as slice 16's backgrounds-under-the-
               replay, arriving at a control instead of a dialog item. */
            guard !(replayed?.covers(frame) ?? false) else { return }
            drawUnavailableVisual(ctx, frame,
                                  Self.semanticText(ctl.semantic)
                                    ?? (ctl.title.isEmpty
                                        ? "Structured content unavailable"
                                        : ctl.title))
            return
        default:
            break
        }

        // Ranged control: recessed track + thumb positioned from value.
        if (ctl.semantic?.kind == "scrollBar"
                || (ctl.semantic == nil && ctl.role == "scrollbar")),
           let max = ctl.max, let min = ctl.min,
           max > min {
            drawScrollbar(ctx, frame, value: ctl.value ?? min,
                          min: min, max: max, enabled: ctl.enabled)
            return
        }
        // Scrollbar-shaped but unranged (min==max, e.g. an empty document):
        // draw the empty track, not a dashed mystery box.
        let narrow = Swift.min(frame.width, frame.height)
        let long = Swift.max(frame.width, frame.height)
        if ctl.title.isEmpty, narrow <= 20, long >= 3 * narrow {
            drawScrollbar(ctx, frame, value: 0, min: 0, max: 0,
                          enabled: ctl.enabled)
            return
        }

        /* A v2 unknown is not permission to reconstruct a button from title
           and geometry. Keep that old approximation only for legacy scenes,
           where it is presentation-only and cannot authorize an action. */
        if ctl.semantic == nil && Self.looksLikeButton(ctl) {
            drawButton(ctx, ctl, frame, isDefault: isDefault)
        } else {
            drawGeneric(ctx, ctl, frame)
        }
    }

    private func drawChoice(_ ctx: GraphicsContext,
                            _ ctl: MirrorKit.Scene.Control,
                            _ frame: CGRect, radio: Bool,
                            markIsDrawn: (CGRect) -> Bool = { _ in false },
                            labelIsDrawn: (CGRect) -> Bool = { _ in false }) {
        let mark = CGRect(x: frame.minX, y: frame.midY - 6,
                          width: 12, height: 12)
        let shape = radio ? Path(ellipseIn: mark) : Path(mark)
        let on = ctl.semantic?.state == "on" || ctl.checked
        if !markIsDrawn(mark) {
        ctx.fill(shape, with: .color(Platinum.g0))
        ctx.stroke(shape,
                   with: .color(ctl.enabled ? Platinum.g6 : Platinum.g3),
                   lineWidth: 1)
        if on {
            if radio {
                ctx.fill(Path(ellipseIn: mark.insetBy(dx: 3, dy: 3)),
                         with: .color(Platinum.g6))
            } else {
                var tick = Path()
                tick.move(to: CGPoint(x: mark.minX + 2, y: mark.midY))
                tick.addLine(to: CGPoint(x: mark.minX + 5,
                                         y: mark.maxY - 3))
                tick.addLine(to: CGPoint(x: mark.maxX - 2,
                                         y: mark.minY + 2))
                ctx.stroke(tick, with: .color(Platinum.g6), lineWidth: 2)
            }
        }
        }
        let label = CGRect(x: frame.minX + 16, y: frame.minY,
                           width: max(0, frame.width - 16),
                           height: frame.height)
        guard !labelIsDrawn(label) else { return }
        appText(ctl.title, ctx, x: frame.minX + 16,
                baselineY: frame.midY + 4,
                color: ctl.enabled ? Platinum.g6 : Platinum.g3)
    }

    private func drawPopup(_ ctx: GraphicsContext,
                           _ ctl: MirrorKit.Scene.Control,
                           _ frame: CGRect) {
        /* NOT `semantic.value` RAW: the CDEF route reports the menu
           INDEX there, and Memory's disk popup drew "1" over the
           machine's "Macintosh HD". See `semanticText`. */
        let value = Self.semanticText(ctl.semantic)
        let labelWidth: CGFloat = if value != nil && !ctl.title.isEmpty {
            min(frame.width * 0.45,
                CGFloat(FontBook.app?.width(ctl.title) ?? 0) + 12)
        } else {
            0
        }
        if labelWidth > 0 {
            appText(ctl.title, ctx, x: frame.minX,
                    baselineY: frame.midY + 4,
                    color: ctl.enabled ? Platinum.g6 : Platinum.g3)
        }
        let face = CGRect(x: frame.minX + labelWidth, y: frame.minY,
                          width: frame.width - labelWidth,
                          height: frame.height)
        ctx.fill(Path(face), with: .color(Platinum.g1))
        ctx.stroke(Path(face),
                   with: .color(ctl.enabled ? Platinum.g6 : Platinum.g3),
                   lineWidth: 1)
        bevel(ctx, face.insetBy(dx: 1, dy: 1),
              light: Platinum.g0, shadow: Platinum.g4)
        appText(value ?? ctl.title, ctx, x: face.minX + 4,
                baselineY: face.midY + 4,
                color: ctl.enabled ? Platinum.g6 : Platinum.g3)
        sysCentered("▼", ctx, centerX: face.maxX - 9,
                    centerY: face.midY,
                    color: ctl.enabled ? Platinum.g6 : Platinum.g3)
    }

    private func drawGroup(_ ctx: GraphicsContext,
                           _ ctl: MirrorKit.Scene.Control,
                           _ frame: CGRect,
                           windowFace: Color = Platinum.g0,
                           titleIsDrawn: (CGRect) -> Bool = { _ in false }) {
        ctx.stroke(Path(frame.insetBy(dx: 0.5, dy: 0.5)),
                   with: .color(ctl.enabled ? Platinum.g4 : Platinum.g3),
                   lineWidth: 1)
        guard !ctl.title.isEmpty else { return }
        let titleWidth = CGFloat(FontBook.app?.width(ctl.title) ?? 0)
        let patch = CGRect(x: frame.minX + 8, y: frame.minY - 1,
                           width: titleWidth + 8, height: 14)
        guard !titleIsDrawn(patch) else { return }
        // Knock the box's own rule out from behind the title, in the face
        // the window was erased with.
        ctx.fill(Path(patch), with: .color(windowFace))
        appText(ctl.title, ctx, x: patch.minX + 4,
                baselineY: patch.minY + 10,
                color: ctl.enabled ? Platinum.g6 : Platinum.g3)
    }

    private func drawProgress(_ ctx: GraphicsContext,
                              _ ctl: MirrorKit.Scene.Control,
                              _ frame: CGRect) {
        ctx.fill(Path(frame), with: .color(Platinum.g0))
        ctx.stroke(Path(frame), with: .color(Platinum.g6), lineWidth: 1)
        let min = ctl.min ?? 0
        let max = ctl.max ?? 100
        let value = Swift.min(max, Swift.max(min, ctl.value ?? min))
        guard max > min else { return }
        let fraction = CGFloat(value - min) / CGFloat(max - min)
        let fill = frame.insetBy(dx: 2, dy: 2)
        ctx.fill(Path(CGRect(x: fill.minX, y: fill.minY,
                             width: fill.width * fraction,
                             height: fill.height)),
                 with: .color(Platinum.g4))
    }

    private func drawDisclosure(_ ctx: GraphicsContext,
                                _ ctl: MirrorKit.Scene.Control,
                                _ frame: CGRect) {
        let down = ctl.semantic?.state == "on"
        let box = CGRect(x: frame.minX, y: frame.midY - 5,
                         width: 10, height: 10)
        var triangle = Path()
        if down {
            triangle.move(to: CGPoint(x: box.minX, y: box.minY + 2))
            triangle.addLine(to: CGPoint(x: box.maxX, y: box.minY + 2))
            triangle.addLine(to: CGPoint(x: box.midX, y: box.maxY))
        } else {
            triangle.move(to: CGPoint(x: box.minX + 2, y: box.minY))
            triangle.addLine(to: CGPoint(x: box.maxX, y: box.midY))
            triangle.addLine(to: CGPoint(x: box.minX + 2, y: box.maxY))
        }
        triangle.closeSubpath()
        ctx.fill(triangle,
                 with: .color(ctl.enabled ? Platinum.g6 : Platinum.g3))
        appText(ctl.title, ctx, x: frame.minX + 14,
                baselineY: frame.midY + 4,
                color: ctl.enabled ? Platinum.g6 : Platinum.g3)
    }

    /// Whether `drawDialogItem` renders this kind as itself rather than as a
    /// placeholder. The placeholder branch consults it so it can decline to
    /// paint over a real one.
    static func drawsConcretely(_ kind: String?) -> Bool {
        switch kind {
        case "panel", "placard", "selectionBand", "separator", "staticText",
             "editText", "checkBox", "radioButton", "popupMenu", "pushButton",
             "icon":
            return true
        default:
            return false
        }
    }

    /// Whether a DITL row may SILENCE the guest's own drawing beneath it —
    /// the dialog-item half of ``semanticOwnsDisplay``, which controls have
    /// had all along and items did not.
    ///
    /// The two questions are not the same. `drawsConcretely` asks whether
    /// the placeholder branch should stand down; this asks whether the row
    /// carries the CONTENT that region needs. A `staticText` with no value
    /// and no title draws an empty box, so letting it exclude the replay
    /// trades the machine's own words for nothing — which is how Date &
    /// Time lost its date and its time on 2026-08-06 while the same capture
    /// rendered whole in the fixture harness, whose scenes carry no dialog
    /// items at all.
    ///
    /// `panel`, `placard` and `selectionBand` are deliberately NOT here:
    /// they are backgrounds, they routinely wrap most of a dialog, and a
    /// background that swallowed every op inside it would be this defect
    /// with a different name.
    /// A DITL row's `title`, if it is TEXT at all.
    ///
    /// It is not always. The guest's dialog walk reports the item's text
    /// by reading a handle, and when that read fails it reports the
    /// POINTER — `\u{1e}πN,\u{1e}πM@` is eight bytes of 68K address, and
    /// the Memory panel's 2026-08-06 capture carries twenty rows like it.
    /// Drawn, they are mojibake over the panel's own words; believed, they
    /// make a row look like it carries content and silence the drawing
    /// underneath it. Both happened.
    ///
    /// Control bytes are the discriminator because no Mac OS dialog label
    /// contains one, and a corrupted read reliably does. This is a
    /// renderer-side defence, not a fix: the walk reporting an address as
    /// a string is a guest defect and belongs in docs/open-issues.md.
    public static func displayableTitle(_ title: String) -> String? {
        guard !title.isEmpty,
              !title.unicodeScalars.contains(where: {
                  $0.value < 0x20 || $0.value == 0x7f
              }), !Self.holdsParamText(title) else { return nil }
        return title
    }

    /// **A `^1` IS A TEMPLATE, AND ONLY THE MACHINE HOLDS THE
    /// SUBSTITUTION.**
    ///
    /// `ParamText` fills `^0`–`^3` at draw time from four strings the
    /// Dialog Manager holds; the DITL resource keeps the template
    /// forever, so a walk of the item list reads the template and never
    /// the sentence a person saw. Memory's own paragraph is the case:
    /// the resource says "The current estimated size is ^1K." and the
    /// machine drew "…is 8160K." (sweep B).
    ///
    /// Drawn, that row asserts a sentence nobody ever displayed. So it
    /// is not a displayable title at all, for the same reason and
    /// through the same gate as a title that came back as a pointer:
    /// both are strings this host was handed and neither is a string
    /// the machine put on screen. Refusing it here refuses it twice
    /// over — the row may no longer SILENCE the drawing beneath it
    /// (`dialogItemOwnsDisplay`), and it may no longer draw itself —
    /// which leaves the guest's own run, the only producer that has the
    /// substituted value.
    ///
    /// Deliberately not "substitute something plausible": a value this
    /// side invents is the confident wrong answer rung 4 exists to
    /// forbid, and the `^` is at least legibly broken.
    public static func holdsParamText(_ title: String) -> Bool {
        var previous: Character?
        for character in title {
            if previous == "^", character.isNumber { return true }
            previous = character
        }
        return false
    }

    /// The DITL kinds that are GROUND — they fill a rectangle and say
    /// nothing about what is inside it. Named once because two rules read
    /// it: they may never silence the drawing under them
    /// (`dialogItemOwnsDisplay`), and they are drawn BEFORE the replay
    /// rather than after it, because that is where ground goes.
    /// The control-plane spelling of ``dialogItemIsBackground``.
    ///
    /// A `userPane` is a REGION an application draws into. It fills a
    /// rectangle and says nothing about what is in it, which is the
    /// whole definition of ground — `isBackgroundKind` has listed it as
    /// naming nothing since the ladder was written, and the DITL twin
    /// `userItem` has declined to draw over its contents for as long.
    ///
    /// What was missing was the ORDER. Appearance's outermost control is
    /// a user pane covering the entire content rect and it is LAST in
    /// the chain, so its marked-unknown plate was painted after the six
    /// tabs and erased every one of them (integration round 4, watched
    /// on the emulator). The coverage guard in `drawControl` answers the
    /// armed case; it cannot answer the unarmed one, where there is no
    /// ink to yield to and the pane still buries the controls before it.
    ///
    /// Same fix as slice 16 made for the four background DITL kinds:
    /// ground goes down FIRST, and the machine draws on it afterwards.
    /// Not another exclusion — the plate still marks an honest absence
    /// where nothing else reaches that rectangle.
    public static func controlIsGround(_ ctl: MirrorKit.Scene.Control) -> Bool {
        ctl.semantic?.kind == "userPane"
    }

    /// **A PANE THAT WRAPS THE CHAIN IS NOT AN UNKNOWN — the chain is
    /// what is inside it.**
    ///
    /// Ground still marks an honest absence, and that rule outranks any
    /// panel looking tidier. But rung 4 is "nobody can account for it",
    /// and a root user pane holding eighteen classified controls is
    /// accounted for by those eighteen. Marking it says the whole
    /// window's interior is unreachable while the renderer is about to
    /// draw most of it — which is `isBackgroundKind`'s own rule, that a
    /// background names nothing, arriving at the marker instead of at
    /// the blit.
    ///
    /// A pane with nothing inside it still marks, because then nobody
    /// really can account for it. Monitors has one of each.
    static func groundWrapsTheChain(_ ground: MirrorKit.Scene.Control,
                                    in win: MirrorKit.Scene.Window) -> Bool {
        guard let outer = ground.rect else { return false }
        return win.controls.contains { other in
            guard other.visible, other.ref != ground.ref,
                  !Self.controlIsGround(other), let inner = other.rect,
                  inner.r > inner.l, inner.b > inner.t else { return false }
            return inner.l >= outer.l && inner.t >= outer.t
                && inner.r <= outer.r && inner.b <= outer.b
        }
    }

    static func dialogItemIsBackground(_ kind: String?) -> Bool {
        switch kind {
        case "panel", "placard", "selectionBand", "separator": return true
        default: return false
        }
    }

    /// **The third sibling of ``semanticOwnsDisplay`` and
    /// ``dialogItemOwnsDisplay``, and the one that was missing.**
    ///
    /// Those two arbitrate the machine's own drawing against controls and
    /// against DITL rows. Nothing arbitrated it against `win.items` — the
    /// Finder roster — so a folder window holding both the machine's ink and
    /// our icon roster drew both, and Michelle saw it directly while
    /// driving on 2026-08-07: *"I can actually see the icon being selected
    /// underneath it. it looks like we're not only rendering the label
    /// twice, we're rendering the whole icon twice."* Same one mechanism
    /// behind icons drawn twice, labels drawn twice, and icons landing over
    /// list-view rows.
    ///
    /// ## Which side wins, and why it is not one side
    ///
    /// The cell is SPLIT, the way this renderer already splits a check box
    /// into its mark and its label:
    ///
    /// * **The icon box is the roster's.** It is rung-3 art addressed by
    ///   identity — the item's kind, type and creator picking a bitmap out
    ///   of `IconAtlas`. The replay cannot better it: the Finder's own icon
    ///   reaches this side as an unjoined blit, which by
    ///   ``ProvenanceLadder``'s own rule "carries geometry and no pixels",
    ///   so the strongest thing it can draw in that box is a generic
    ///   document stub or the marked-unknown hatch. Excluding it there is
    ///   not overruling the machine; the machine's pixels are not on offer,
    ///   and the project's standing gate is that they never will be off the
    ///   wire. **If a Finder icon blit is ever seen to JOIN, this is the
    ///   line to revisit** — real ink would outrank the pack, and the
    ///   exclusion would have to become a per-piece yield.
    /// * **The name is the machine's.** It writes it as a real text run,
    ///   ellipsised at the cell width, wrapped, inverted when selected —
    ///   facts this side would have to invent. So the label is not excluded
    ///   at all; it yields per piece through `Coverage.textCovers`, in
    ///   ``drawIcon``.
    ///
    /// ## Absence stays absence
    ///
    /// This is arbitration, never suppression. A folder window with a roster
    /// and no display list still draws every icon and every label — that is
    /// the ordinary case today, and the pixel islands' removal means there
    /// is nothing behind the roster to fall back on. An item that is not
    /// placed, is invisible, or has no name is not drawn and claims nothing:
    /// an unplaced item has no rectangle to claim, and a claim without a
    /// drawing is exactly the defect `dialogItemOwnsDisplay` was written to
    /// end.
    static func finderItemOwnsDisplay(_ item: MirrorKit.Scene.DesktopItem)
        -> Bool {
        item.placed && !item.invisible && !item.name.isEmpty
    }

    /// The icon box this renderer will fill for `item`, content-local.
    ///
    /// The Finder's own drawn box (`bounds of`) when it gave one, capped at
    /// the icon view's 32 so an oversized report cannot claim a window. The
    /// 32×32 default is the icon view's measured cell and the only size a
    /// record predating `bounds` can mean.
    static func iconBoxSize(_ item: MirrorKit.Scene.DesktopItem) -> CGSize {
        guard let w = item.w, let h = item.h, w > 0, h > 0 else {
            return CGSize(width: Self.iconSize, height: Self.iconSize)
        }
        return CGSize(width: min(CGFloat(w), Self.iconSize),
                      height: min(CGFloat(h), Self.iconSize))
    }

    /// Whether the roster draws a centred name UNDER `item` — true in the
    /// icon views, false for a list row, whose name is a column beside it.
    /// The same threshold `HitTester.targetSize` uses to decide whether a
    /// label's height belongs in the item's hit box.
    static func itemDrawsItsOwnLabel(_ item: MirrorKit.Scene.DesktopItem)
        -> Bool {
        guard let h = item.h, h > 0 else { return true }
        return CGFloat(h) >= Self.iconSize
    }

    /// The rectangles a window's Finder roster owns against the replay.
    ///
    /// **Clipped to the icon field**, and that is not decoration: a scrolled
    /// window reports positions that run off both ends of its content, and
    /// an unclipped claim would punch holes in the info bar and the
    /// scrollbars for items nobody can see. The guest clips them at exactly
    /// this rectangle (`FinderItems.iconArea`) and so does the drawing a few
    /// hundred lines above.
    static func finderItemFrames(_ win: MirrorKit.Scene.Window,
                                 content: CGRect) -> [CGRect] {
        guard let items = win.items else { return [] }
        let a = FinderItems.iconArea(win)
        let field = CGRect(x: content.minX + CGFloat(a.l),
                           y: content.minY + CGFloat(a.t),
                           width: CGFloat(max(0, a.r - a.l)),
                           height: CGFloat(max(0, a.b - a.t)))
        return items.compactMap { item -> CGRect? in
            guard Self.finderItemOwnsDisplay(item) else { return nil }
            let box = CGRect(origin: CGPoint(x: content.minX + CGFloat(item.x),
                                             y: content.minY + CGFloat(item.y)),
                             size: Self.iconBoxSize(item))
                .intersection(field)
            guard !box.isNull, box.width > 0, box.height > 0 else { return nil }
            return box
        }
    }

    static func dialogItemOwnsDisplay(_ item: MirrorKit.Scene.DialogItem)
        -> Bool {
        switch item.semantic.kind {
        case "checkBox", "radioButton", "pushButton", "separator":
            return true
        case "popupMenu":
            return item.semantic.value != nil
        case "staticText", "editText":
            return item.semantic.value != nil
                || Self.displayableTitle(item.title) != nil
        default:
            return false
        }
    }

    private func drawDialogItem(_ ctx: GraphicsContext,
                                _ item: MirrorKit.Scene.DialogItem,
                                contentOrigin: CGPoint,
                                covering drawn: [CGRect] = [],
                                replayed: DisplayReplay.Coverage? = nil,
                                windowFace: Color = Platinum.g0) {
        let frame = rect(item.rect).offsetBy(dx: contentOrigin.x,
                                             dy: contentOrigin.y)
        guard frame.width > 0, frame.height > 0 else { return }
        /* RUNG 1 BEATS RUNG 2, PIECE BY PIECE. Two branches — `icon` and
           the placeholder default — already yielded to what the replay
           had inked; the rest drew their own label over the machine's,
           and Date & Time printed "Set Daylight-Saving Time
           Automatically" twice, one string over the other, the moment
           the replay stopped being silenced (`DisplayReplay.semanticOwns`).

           It is asked PER PIECE and not once for the whole row, and the
           difference is visible: a check box's LABEL arrives as a text
           op and its little box does not, so a row-wide test drew
           neither and Date & Time lost both of its check boxes. `covers`
           intersects, so the question has to be put about the rectangle
           the piece is about to fill. */
        func inked(_ piece: CGRect) -> Bool {
            replayed?.mostlyCovers(piece) == true
        }
        /* AND A LABEL ASKS A DIFFERENT QUESTION FROM A MARK BOX. A DITL
           row is a slack box sized by whoever wrote the resource and the
           run inside it is as wide as the words, so "does the ink fill
           half this rectangle" is the rectangle's question and not the
           text's — Memory's 102-point "Disk Cache" row holds a 48-point
           run and drew its own copy four points off the machine's, on
           every string in the panel (sweep B, R1). See
           `Coverage.textCovers`. */
        func words(_ piece: CGRect) -> Bool {
            replayed?.textCovers(piece) == true || inked(piece)
        }
        switch item.semantic.kind {
        case "panel":
            // A DITL group box's interior is the window's own face - the
            // application never painted it a different colour, it simply
            // did not paint it. Filling white made a white plate on any
            // window whose face is the dialog grey.
            ctx.fill(Path(frame), with: .color(windowFace))
            ctx.stroke(Path(frame), with: .color(Platinum.g5), lineWidth: 1)
        case "placard":
            ctx.fill(Path(frame), with: .color(Platinum.g2))
            ctx.stroke(Path(frame), with: .color(Platinum.g4), lineWidth: 1)
        case "selectionBand":
            ctx.fill(Path(frame), with: .color(Platinum.g3))
        case "separator":
            ctx.fill(Path(frame), with: .color(Platinum.g4))
        case "staticText":
            /* AND THE MACHINE'S OWN RUN OUTRANKS THE LABEL. The two
               gates are separate — whether a row may SILENCE P3, and
               whether it may DRAW OVER it — and this branch answered the
               first and never the second. It did not show while the
               first gate silenced every drawn run inside a DITL
               rectangle; the moment rung 1 stopped yielding (see
               `DisplayReplay.semanticOwns`) both strings would land in
               the same place.
               The drawn run is the better answer wherever it exists: it
               is what the application actually put on screen, truncation
               and all. NOW's Workshop sidebar is the case — the guest
               drew "Capture and stre…" and this row says "Capture and
               stream". */
            guard !words(frame) else { break }
            appText(item.semantic.value
                    ?? Self.displayableTitle(item.title) ?? "",
                    ctx, x: frame.minX,
                    baselineY: frame.minY
                        + CGFloat(FontBook.app?.ascent ?? 10),
                    color: item.enabled ? Platinum.g6 : Platinum.g3)
        case "editText":
            guard !words(frame) else { break }
            ctx.fill(Path(frame), with: .color(Platinum.g0))
            ctx.stroke(Path(frame), with: .color(Platinum.g6), lineWidth: 1)
            appText(item.semantic.value
                    ?? Self.displayableTitle(item.title) ?? "", ctx,
                    x: frame.minX + 3, baselineY: frame.midY + 4,
                    color: item.enabled ? Platinum.g6 : Platinum.g3)
            if item.semantic.focused == true {
                ctx.stroke(Path(frame.insetBy(dx: -2, dy: -2)),
                           with: .color(Platinum.g6), lineWidth: 1)
            }
        case "checkBox", "radioButton":
            let markBox = CGRect(x: frame.minX, y: frame.midY - 6,
                                 width: 12, height: 12)
            let shape = item.semantic.kind == "radioButton"
                ? Path(ellipseIn: markBox) : Path(markBox)
            if !inked(markBox) {
                ctx.fill(shape, with: .color(Platinum.g0))
                ctx.stroke(shape, with: .color(Platinum.g6), lineWidth: 1)
                if item.semantic.state == "on" {
                    let dot = markBox.insetBy(dx: 3, dy: 3)
                    ctx.fill(item.semantic.kind == "radioButton"
                             ? Path(ellipseIn: dot) : Path(dot),
                             with: .color(Platinum.g6))
                }
            }
            let label = CGRect(x: frame.minX + 16, y: frame.minY,
                               width: max(0, frame.width - 16),
                               height: frame.height)
            if !words(label) {
                appText(item.title, ctx, x: frame.minX + 16,
                        baselineY: frame.midY + 4,
                        color: item.enabled ? Platinum.g6 : Platinum.g3)
            }
        case "popupMenu":
            guard !words(frame) else { break }
            ctx.fill(Path(frame), with: .color(Platinum.g1))
            ctx.stroke(Path(frame), with: .color(Platinum.g6), lineWidth: 1)
            appText(item.semantic.value ?? item.title, ctx,
                    x: frame.minX + 4, baselineY: frame.midY + 4,
                    color: item.enabled ? Platinum.g6 : Platinum.g3)
            sysCentered("▼", ctx, centerX: frame.maxX - 10,
                        centerY: frame.midY, color: Platinum.g6)
        case "pushButton":
            /* THE ONE BRANCH ON THIS PLANE THAT NEVER ASKED. Every other
               case here has yielded to the replay since 2026-08-06 and
               this one did not, so a dialog item classified `pushButton`
               painted a filled Platinum pill over the machine's own ink
               unconditionally — the same defect `019-sweepb-regressions`
               fixed in `drawControl`, surviving in its twin. It is the
               same question and it gets the same answer: a button
               REPLACES its rectangle rather than annotating it, so where
               the machine already drew there, rung 2 has nothing to add.

               `words`, not `inked`: a DITL row is a slack box and a
               button's rectangle holds a short run, so the area test
               alone says no on exactly the rows this is about — the
               `mostlyCovers`-is-the-rectangle's-question lesson, one
               plane over. It also covers the radio-CDEF case that
               reaches this plane, where OS 9 hands a radio back in the
               button family. */
            guard !words(frame) else { break }
            let ctl = MirrorKit.Scene.Control(
                ref: item.ref ?? "", role: "button", title: item.title,
                rect: item.rect, enabled: item.enabled, visible: item.visible,
                checked: item.semantic.state == "on",
                semantic: item.semantic)
            drawButton(ctx, ctl, frame,
                       isDefault: item.semantic.isDefault == true)
        case "icon":
            /* THE GUEST SAID THIS IS AN ICON, so "Visual unavailable" is a
               false claim: the visual is known to exist and only its
               PIXELS are missing. NOW's own Workshop sidebar has fifteen
               of these and every one of them rendered as a hatch
               (2026-08-06 screenshot), which reads as fifteen broken
               rows rather than as one thing this host has not been told.

               The generic stub at the item's true position is the answer
               docs/render-composition.md already gives for an icon-sized
               blit, and this is the same question one plane over. It
               yields to the guest's own drawing where P3 carried it —
               a real icon always beats a stub of one. */
            guard !(replayed?.covers(frame) ?? false) else { break }
            if let icon = IconAtlas.namedIcon(
                "document", size: IconAtlas.Size.fitting(frame)) {
                ctx.draw(Image(decorative: icon, scale: 1)
                            .interpolation(.none), in: frame)
            }
        case "userItem":
            /* A user item has no content of its OWN — whatever appears there
               is drawn by the application, which is P3's business and not a
               semantic fact. So "Visual unavailable" over one asserts content
               that may not exist, and in an alert it usually does not: the
               Dialog Manager's default-outline slot is a user item, and the
               machine draws nothing but a ring inside it. */
            break
        default:
            /* `resCtrl`, pictures and other custom drawing are bounded facts
               even when their pixels are not. A dashed empty box still reads
               as missing UI; an explicit placeholder keeps the omission
               honest without covering later semantic items — or, per
               `covering`, earlier ones. */
            /* CONTAINS, not intersects: a placeholder that WRAPS a real item
               is the outline slot, and hatching it hides the item. A
               placeholder that merely sits inside a larger drawn item is
               ordinary furniture — the Workshop's icons all live inside its
               panel, and an `intersects` test erased every one of them. */
            guard !drawn.contains(where: { frame.contains($0) }) else {
                break
            }
            /* AND THE GUEST'S OWN DRAWING OUTRANKS IT TOO. "Visual
               unavailable" over pixels this host just replayed is not a
               weaker claim than the evidence, it is a false one — the
               visual was available and is underneath. NOW's Workshop
               sidebar lost fourteen icons to this, and Date & Time its
               date and its time. An erase is deliberately not counted as
               drawing; see DisplayReplay.Coverage. */
            guard !(replayed?.covers(frame) ?? false) else { break }
            drawUnavailableVisual(ctx, frame,
                                  item.title.isEmpty
                                    ? "Visual unavailable" : item.title)
        }
    }

    /// One cell of a grid derived from the drawing stream
    /// (`MirrorKit.DrawnCellGrid`): a Platinum well frame, and — where the
    /// derivation could read it — the selection.
    ///
    /// It draws FRAMES, never a fill, and that restraint is the whole
    /// design. The cell's own picture is already on the canvas: the replay
    /// put the well's theme art and the channel icon there in guest order,
    /// and this control is a second reading of the same ops rather than a
    /// replacement for them. Filling the rectangle would erase the one
    /// thing inside it nobody else can supply.
    private func drawDrawnCell(_ ctx: GraphicsContext,
                               _ ctl: MirrorKit.Scene.Control,
                               _ frame: CGRect) {
        let box = frame.insetBy(dx: 0.5, dy: 0.5)
        // Recessed well: shadow on the top/left, highlight on the
        // bottom/right — the Platinum inset, drawn as two open paths so
        // the interior stays untouched.
        var shadow = Path()
        shadow.move(to: CGPoint(x: box.minX, y: box.maxY))
        shadow.addLine(to: CGPoint(x: box.minX, y: box.minY))
        shadow.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        ctx.stroke(shadow, with: .color(Platinum.g4), lineWidth: 1)
        var light = Path()
        light.move(to: CGPoint(x: box.minX, y: box.maxY))
        light.addLine(to: CGPoint(x: box.maxX, y: box.maxY))
        light.addLine(to: CGPoint(x: box.maxX, y: box.minY))
        ctx.stroke(light, with: .color(Platinum.g0), lineWidth: 1)

        /* Selection is the fact P3 could not state, so it is drawn
           unmistakably: the guest marks the live channel by blitting a
           different well from its sprite sheet, and a ring in the
           selection colour is this side's equivalent. `checked` is only
           ever set where the derivation actually read a selection. */
        guard ctl.checked else { return }
        ctx.stroke(Path(box), with: .color(Platinum.selection), lineWidth: 1)
        ctx.stroke(Path(box.insetBy(dx: 1, dy: 1)),
                   with: .color(Platinum.selection), lineWidth: 1)
    }

    /// **What an empty interior is allowed to CLAIM.**
    ///
    /// "Guest content not reported" is a statement about the machine, and it
    /// was drawn over two situations that are not the same one:
    ///
    /// - the content plane was armed on this window and the guest drew
    ///   nothing this host could express — the sentence is true; and
    /// - the content plane was never armed on this window at all, because
    ///   P3 is a per-window spotlight and something else holds it — the
    ///   sentence is a claim about a guest we never asked.
    ///
    /// A window nobody looked at rendered identically to a window whose
    /// interior genuinely failed, so no screenshot of this product could
    /// distinguish a design limit from a defect. That is the whole reason
    /// this exists; see ``ContentPlaneAttention`` and docs/open-issues.md,
    /// "one window interior at a time".
    ///
    /// `nil` attention keeps the old sentence deliberately: a scene from a
    /// host with no content plane, or a window with no exact guest address,
    /// has no second answer to offer and inventing one would be the same
    /// class of mistake in the other direction.
    /// AND SAY WHICH SILENCE THIS IS, when the content plane has no answer
    /// but the control plane does. Two lanes wrote a caption producer for
    /// this hatch on 2026-08-07 and each was right about a different
    /// question — whether this window was ever *looked at* (``contentPlane``)
    /// and whether its *controls* arrived (``controlsKnowledge``). Merged
    /// rather than picked, because a renderer with two caption producers is
    /// the drift this function was extracted to prevent.
    ///
    /// Order is the point. `notAttempted` outranks everything: a window
    /// nobody spotlighted has nothing to say about its controls either, and
    /// naming the control pool there would explain the wrong silence.
    ///
    /// **Only `notFetched` earns a sentence of its own**, and the first
    /// version of this fold got that wrong in a way its own tests caught.
    /// `notFetched` is a POSITIVE statement by the guest — the scene-wide
    /// control pool filled before this window, and asking again with room
    /// would answer it — so it is the one state that is not about this
    /// window at all. `unknown` is the opposite: ``Scene/ControlsState`` is
    /// explicit that it means the producer does not report this and
    /// therefore could not tell us. Drawing "Controls unknown" over an
    /// ordinary scene from an older guest would put a diagnosis on every
    /// window in it, which is exactly the guess the `nil`-attention clause
    /// below refuses to make in the other direction.
    static func absentContentCaption(_ win: MirrorKit.Scene.Window) -> String {
        switch win.contentPlane {
        case .notAttempted: return "Interior not captured — one window at a time"
        case .armed, .none:
            switch win.controlsKnowledge {
            case .notFetched: return "Controls not fetched"
            case .unknown, .empty, .complete: return "Guest content not reported"
            }
        }
    }

    private func drawUnavailableVisual(_ ctx: GraphicsContext,
                                       _ frame: CGRect,
                                       _ label: String) {
        guard frame.width > 1, frame.height > 1 else { return }
        var clipped = ctx
        clipped.clip(to: Path(frame))
        /* The look lives in UnknownVisual and nowhere else — see its
           header for why it is quiet and how the pick was made. This site
           and DisplayReplay's used to hold two identical copies of the
           fill, free to drift apart with nothing to notice. */
        UnknownVisual.drawGround(in: clipped, frame: frame)
        let ascent = CGFloat(FontBook.small?.ascent ?? 8)
        guard let at = UnknownVisual.captionOrigin(in: frame,
                                                   ascent: ascent) else { return }
        let caption = label.isEmpty ? "Visual unavailable" : label
        appText(caption, clipped, x: at.x, baselineY: at.y,
                color: UnknownVisual.caption, small: true)
    }

    private func drawButton(_ ctx: GraphicsContext, _ ctl: MirrorKit.Scene.Control,
                            _ frame: CGRect, isDefault: Bool) {
        /* A DISABLED item never wears the ring. `isDefault` comes from the
           DialogRecord's `aDefItem`, which the Dialog Manager initialises to
           1 and only `SetDialogDefaultItem` moves — so an application that
           greys its first button and rings another leaves `aDefItem` behind.
           Date & Time's Set Time Zone does exactly that: item 1 `Done` is
           disabled, the machine rings `Cancel`, and the mirror drew the ring
           on the greyed Done (docs/open-issues.md, 2026-08-06). Declining to
           ring a disabled button is not the whole answer — nothing here knows
           where the ring WENT — but it stops the mirror asserting something
           the machine contradicts. */
        if isDefault && ctl.enabled {
            // The default ring: 3px frame at 2px offset.
            let ring = frame.insetBy(dx: -5, dy: -5)
            ctx.stroke(Path(roundedRect: ring, cornerRadius: 10),
                       with: .color(Platinum.g6), lineWidth: 3)
        }
        let path = Path(roundedRect: frame, cornerRadius: 7)
        ctx.fill(path,
                 with: .color(ctl.checked ? Platinum.g2 : Platinum.g1))
        ctx.stroke(path,
                   with: .color(ctl.enabled ? Platinum.g6 : Platinum.g3),
                   lineWidth: 1)
        if ctl.enabled {
            // Approximate the inset bevel inside the rounded border.
            let inner = frame.insetBy(dx: 1.5, dy: 1.5)
            var light = Path()
            light.move(to: CGPoint(x: inner.minX, y: inner.maxY - 2))
            light.addLine(to: CGPoint(x: inner.minX, y: inner.minY))
            light.addLine(to: CGPoint(x: inner.maxX - 2, y: inner.minY))
            ctx.stroke(light, with: .color(Platinum.g0), lineWidth: 1)
        }
        /* THE PRESS, over the button's own drawing and under its label.
           `PressedVisual` decides what it looks like and this decides only
           WHEN — the same split `drawItemDrag` keeps, and for the same
           reason: a second place deciding the appearance is how the marked
           unknown ended up with two copies of its fill.

           Over the face rather than instead of it, because this is NOT a
           mirrored Platinum pressed state. The guest never draws one for a
           synthesized press — it answers `act-not-taken: armed, and the
           application never called TrackControl` — so replacing the face
           with an imitation would assert a machine state that does not
           exist. See `PressedVisual`. */
        if isPressed(ctl) {
            PressedVisual.drawPressed(in: ctx, frame: frame)
        }
        let color = ctl.enabled ? Platinum.g6 : Platinum.g3
        let mark = ctl.checked ? "✓ " : ""
        let markW = mark.isEmpty ? 0 : 10
        sysCentered(ctl.title, ctx,
                    centerX: frame.midX + CGFloat(markW) / 2,
                    centerY: frame.midY, color: color)
        if ctl.checked {
            ctx.draw(ctx.resolve(Text("✓").font(Platinum.systemFont(12))
                        .foregroundColor(color)),
                     at: CGPoint(x: frame.midX - sysWidth(ctl.title) / 2 - 4,
                                 y: frame.midY), anchor: .center)
        }
        /* The wait bar LAST, so it sits over the label's descenders rather
           than under them. It is drawn inside the button's own lower edge and
           never covers the title — a person who cannot read which button is
           busy has been told less, not more. */
        if let pressed, pressed.ref == ctl.ref, pressed.showsSpinner {
            PressedVisual.drawWait(in: ctx, frame: frame,
                                   progress: pressed.progress)
        }
    }

    /// Whether this control is the one under the person's finger.
    ///
    /// Matched by `ref` — the scene's own identity — rather than by rect or
    /// title. Two buttons in one dialog can share a title ("OK" in a stack of
    /// sheets) and a rect moves when the window does; a ref is what the act
    /// itself names, so the thing that lights up is the thing that was sent.
    private func isPressed(_ ctl: MirrorKit.Scene.Control) -> Bool {
        pressed?.ref == ctl.ref && pressed?.showsPressed == true
    }

    private func drawGeneric(_ ctx: GraphicsContext, _ ctl: MirrorKit.Scene.Control,
                             _ frame: CGRect) {
        ctx.stroke(Path(frame), with: .color(Platinum.g3),
                   style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
        guard !ctl.title.isEmpty else { return }
        var clipped = ctx
        clipped.clip(to: Path(frame))
        let w = CGFloat(FontBook.small?.width(ctl.title) ?? 0)
        appText(ctl.title, clipped, x: frame.midX - w / 2,
                baselineY: frame.midY + 4, color: Platinum.g4, small: true)
    }

    /// Draw the bounded cells P2 read from the guest's List Manager. A partial
    /// prefix is still useful presentation evidence, while `completeness`
    /// remains available to policy and prevents it authorizing an action.
    private func drawListSelection(_ ctx: GraphicsContext,
                                   _ ctl: MirrorKit.Scene.Control,
                                   _ frame: CGRect) {
        ctx.fill(Path(frame), with: .color(Platinum.g0))
        ctx.stroke(Path(frame), with: .color(Platinum.g6), lineWidth: 1)
        bevel(ctx, frame.insetBy(dx: 1, dy: 1),
              light: Platinum.g4, shadow: Platinum.g1)
        let body = frame.insetBy(dx: 3, dy: 3)
        let cells = ctl.semantic?.listCells ?? []
        if cells.isEmpty {
            let first = CGRect(x: body.minX, y: body.minY,
                               width: body.width,
                               height: Swift.min(16, body.height))
            ctx.fill(Path(first), with: .color(Platinum.g2))
            var clipped = ctx
            clipped.clip(to: Path(body))
            /* Not the raw field: a list classified by CDEF id reports
               `GetControlValue` there, and Monitors printed a bare "0"
               inside both of its empty wells. See `semanticText`. */
            appText(Self.semanticText(ctl.semantic)
                    ?? "Selected value unavailable",
                    clipped, x: body.minX + 3, baselineY: body.minY + 12,
                    color: ctl.enabled ? Platinum.g6 : Platinum.g3,
                    small: true)
            return
        }

        let rows = Dictionary(grouping: cells, by: \.row)
            .sorted { $0.key < $1.key }
        let columnCount = Swift.max(1, (cells.map(\.column).max() ?? 0) + 1)
        let rowHeight: CGFloat = 18
        let visibleCount = Swift.min(rows.count,
                                     Int(body.height / rowHeight))
        var clipped = ctx
        clipped.clip(to: Path(body))
        for rowIndex in 0..<visibleCount {
            let rowCells = rows[rowIndex].value.sorted { $0.column < $1.column }
            let rowFrame = CGRect(x: body.minX,
                                  y: body.minY + CGFloat(rowIndex) * rowHeight,
                                  width: body.width, height: rowHeight)
            /* The selected row is filled with the highlight the GUEST
               reported, not with the chrome grey it used to borrow.
               0xCCCCCC was the Gray Space theme's answer; the extracted
               Platinum constant that replaced it was 0xCCCCFF, read once
               out of a theme FILE. `theme.highlight` is the live
               low-memory colour, so a theme switched while this guest
               runs moves it. The constant remains the fallback. */
            if rowCells.contains(where: \.selected) {
                clipped.fill(Path(rowFrame), with: .color(theme.highlight))
            }
            for column in 0..<columnCount {
                let cellWidth = body.width / CGFloat(columnCount)
                let cellFrame = CGRect(x: body.minX
                                           + CGFloat(column) * cellWidth,
                                       y: rowFrame.minY,
                                       width: cellWidth,
                                       height: rowHeight)
                if column > 0 {
                    clipped.fill(Path(CGRect(x: cellFrame.minX,
                                             y: cellFrame.minY,
                                             width: 1,
                                             height: cellFrame.height)),
                                 with: .color(Platinum.g2))
                }
                guard let cell = rowCells.first(where: {
                    $0.column == column
                }) else { continue }
                appText(cell.text, clipped, x: cellFrame.minX + 3,
                        baselineY: cellFrame.minY + 13,
                        color: ctl.enabled ? Platinum.g6 : Platinum.g3,
                        small: true)
            }
        }
    }

    private func drawScrollbar(_ ctx: GraphicsContext, _ frame: CGRect,
                               value: Int, min: Int, max: Int,
                               enabled: Bool) {
        ctx.fill(Path(frame), with: .color(Platinum.g1))
        ctx.stroke(Path(frame),
                   with: .color(enabled ? Platinum.g6 : Platinum.g3),
                   lineWidth: 1)
        // Recessed: shadow top-left, highlight bottom-right.
        bevel(ctx, frame.insetBy(dx: 1, dy: 1),
              light: Platinum.g4, shadow: Platinum.g0)

        /* The arrow buttons. A Platinum scrollbar is arrows-track-arrows,
           and the CDEF draws the arrows whether or not the control has a
           range — an empty document still shows them, dimmed. One square
           button per end, sized by the bar's narrow dimension, and the
           thumb's travel is the TRACK between them, which is why the
           track rect is computed here and shared below. */
        let vertical = frame.height > frame.width
        let narrow = Swift.min(frame.width, frame.height)
        let long = Swift.max(frame.width, frame.height)
        var track = frame
        if long >= 3 * narrow {
            let a: CGRect
            let b: CGRect
            if vertical {
                a = CGRect(x: frame.minX, y: frame.minY,
                           width: frame.width, height: narrow)
                b = CGRect(x: frame.minX, y: frame.maxY - narrow,
                           width: frame.width, height: narrow)
                track = frame.insetBy(dx: 0, dy: narrow)
            } else {
                a = CGRect(x: frame.minX, y: frame.minY,
                           width: narrow, height: frame.height)
                b = CGRect(x: frame.maxX - narrow, y: frame.minY,
                           width: narrow, height: frame.height)
                track = frame.insetBy(dx: narrow, dy: 0)
            }
            drawScrollArrow(ctx, a, vertical: vertical, towardMin: true,
                            enabled: enabled)
            drawScrollArrow(ctx, b, vertical: vertical, towardMin: false,
                            enabled: enabled)
        }

        guard max > min else { return }   // unranged: empty track, no thumb
        let frac = CGFloat(value - min) / CGFloat(max - min)
        var thumb: CGRect
        let tw = Swift.max(track.width * 0.16, 10)
        let th = Swift.max(track.height * 0.16, 10)
        if vertical {
            thumb = CGRect(x: track.minX + 1,
                           y: track.minY + frac * (track.height - th),
                           width: track.width - 2, height: th)
        } else {
            thumb = CGRect(x: track.minX + frac * (track.width - tw),
                           y: track.minY + 1,
                           width: tw, height: track.height - 2)
        }
        thumb = thumb.intersection(track.insetBy(dx: 1, dy: 1))
        guard !thumb.isNull, thumb.width > 2, thumb.height > 2 else { return }
        ctx.fill(Path(thumb), with: .color(Platinum.g2))
        ctx.stroke(Path(thumb), with: .color(Platinum.g6), lineWidth: 1)
        bevel(ctx, thumb.insetBy(dx: 1, dy: 1),
              light: Platinum.g0, shadow: Platinum.g4)
    }

    /// One scrollbar arrow button: raised square, black triangle pointing
    /// out of the track.
    private func drawScrollArrow(_ ctx: GraphicsContext, _ box: CGRect,
                                 vertical: Bool, towardMin: Bool,
                                 enabled: Bool) {
        ctx.fill(Path(box), with: .color(Platinum.g1))
        ctx.stroke(Path(box), with: .color(enabled ? Platinum.g6 : Platinum.g3),
                   lineWidth: 1)
        bevel(ctx, box.insetBy(dx: 1, dy: 1),
              light: Platinum.g0, shadow: Platinum.g4)
        let inset = box.insetBy(dx: box.width * 0.28, dy: box.height * 0.28)
        var tri = Path()
        if vertical {
            let tipY = towardMin ? inset.minY : inset.maxY
            let baseY = towardMin ? inset.maxY : inset.minY
            tri.move(to: CGPoint(x: inset.midX, y: tipY))
            tri.addLine(to: CGPoint(x: inset.minX, y: baseY))
            tri.addLine(to: CGPoint(x: inset.maxX, y: baseY))
        } else {
            let tipX = towardMin ? inset.minX : inset.maxX
            let baseX = towardMin ? inset.maxX : inset.minX
            tri.move(to: CGPoint(x: tipX, y: inset.midY))
            tri.addLine(to: CGPoint(x: baseX, y: inset.minY))
            tri.addLine(to: CGPoint(x: baseX, y: inset.maxY))
        }
        tri.closeSubpath()
        ctx.fill(tri, with: .color(enabled ? Platinum.g6 : Platinum.g3))
    }

    // MARK: - Helpers

    private func rect(_ r: MirrorKit.Rect) -> CGRect {
        CGRect(x: CGFloat(r.l), y: CGFloat(r.t),
               width: CGFloat(Swift.max(0, r.r - r.l)),
               height: CGFloat(Swift.max(0, r.b - r.t)))
    }

    /// Raised bevel: 1px light along top-left, 1px shadow along
    /// bottom-right (`theme_bevel`). Swap the colors for recessed.
    private func bevel(_ ctx: GraphicsContext, _ r: CGRect,
                       light: Color, shadow: Color) {
        ctx.fill(Path(CGRect(x: r.minX, y: r.minY, width: r.width, height: 1)),
                 with: .color(light))
        ctx.fill(Path(CGRect(x: r.minX, y: r.minY, width: 1, height: r.height)),
                 with: .color(light))
        ctx.fill(Path(CGRect(x: r.minX, y: r.maxY - 1,
                             width: r.width, height: 1)),
                 with: .color(shadow))
        ctx.fill(Path(CGRect(x: r.maxX - 1, y: r.minY,
                             width: 1, height: r.height)),
                 with: .color(shadow))
    }
}
