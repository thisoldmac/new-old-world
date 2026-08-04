#ifndef NOW_CLOUD_PREVIEW_WELL_H
#define NOW_CLOUD_PREVIEW_WELL_H

#include <Carbon.h>

/* The ONE decoded cloud.preview image in memory, shared by every view
   that can show one -- Photos and Contacts alike. This used to be
   cloud_photos_view.c's own g_world/g_want_item/g_fetching/g_reask/
   g_fail, moved out whole: the 6MB partition still holds one
   preview-sized bitmap, not one per view, and now_wire_cloud_preview
   already refuses a second ask while one is in flight (wire.c) --
   which means the wire itself assumes exactly one caller. Contacts
   asking through its OWN copy of this state would either race Photos'
   or silently need the same "only one at a time" rule reinvented; this
   file is that rule, written once.

   A view calls _select on every selection change (its own CloudViewOps
   select op, or -1 on deselect/service-change, the shell's existing
   seam) and reads _ready/_fetching/_fail to decide what to draw --
   pixels, a loading line, or a refusal reason. `note` is called on
   every settle (arrival or refusal) so a view's own update handler
   knows to invalidate its pane; it is REBOUND on every _select call,
   so a view that has moved on (a later selection, or the outgoing view
   of a service switch) is never notified about an ask it no longer
   cares about -- the wire's answer still lands in the well (there is
   nothing else it could do with an ask already in flight), but only
   the CURRENT owner hears about it. */

typedef void (*CloudPreviewWellNote)(void);

/* Once, from cloud_create(): registers this file as the wire's one
   cloud.preview hook. */
void cloud_preview_well_init(void);

/* Window close / quit: releases the GWorld and un-registers the wire
   hook. Called before the window's controls go, same as every other
   cloud_*_view_dispose. */
void cloud_preview_well_dispose(void);

/* Selection changed: ask for service/item's preview at up to ww x wh
   (the caller's own well or pane) at the screen's actual depth.
   Evicts whatever the well already held -- one preview in memory,
   ever, matching Photos' original rule now enforced for both views.
   item NULL or empty (or ww/wh too small to be an honest ask) just
   evicts, with no new ask: deselected, or no pane to fill yet. */
void cloud_preview_well_select(const char *service, const char *item,
                               long ww, long wh, CloudPreviewWellNote note);

/* Whether the well currently holds ready pixels / has a fetch on the
   wire / has a refusal reason FOR THIS service+item -- false the
   instant a later _select moves the well on to something else, so a
   view never draws a stale answer under a fresh selection's name. */
Boolean cloud_preview_well_ready(const char *service, const char *item);
Boolean cloud_preview_well_fetching(const char *service, const char *item);
const char *cloud_preview_well_fail(const char *service, const char *item);

/* Draws the ready pixels, fit and centered inside dst, on owner's
   port, framing the destination rect the way the share panel's own
   blits do. Caller must have already checked _ready() for its own
   service/item -- this draws whatever the well holds without asking
   whose it is a second time. */
void cloud_preview_well_draw(WindowRef owner, const Rect *dst);

#endif /* NOW_CLOUD_PREVIEW_WELL_H */
