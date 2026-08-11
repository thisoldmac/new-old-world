#ifndef NOW_SCENE_DIALOG_TEXT_H
#define NOW_SCENE_DIALOG_TEXT_H

/* The live text of a Dialog Manager text item — and the reason it needs a
   seam of its own.
 *
 * A DITL's bytes are the RESOURCE's template. `SetDialogItemText`, which is
 * how an application fills in a message at runtime, writes into the item's
 * own handle instead, and `GetDialogItemText` reads it back from there.
 * Measured on a live guest 2026-08-06: Internet Explorer's Error alert
 * reported item 4 as an empty `staticText` while the machine displayed
 * "Security failure.  The server reply is invalid." — that string sat in
 * the item's handle, verbatim, and nothing in the DITL knew about it.
 *
 * It is the item's LENGTH that forces a Toolbox call rather than one more
 * bounded read. The handle's logical size is the Memory Manager's business,
 * and the block header on this heap does not match the 24-bit-era layout:
 * the longword below the data holds a ZONE-RELATIVE offset rather than the
 * master pointer, and the tag byte's size-correction nibble reads zero while
 * the physical size overshoots the string by eight bytes. Header arithmetic
 * would append heap slop to every alert. `GetHandleSize` knows; nothing else
 * here does.
 *
 * The call is a foreign-memory read performed by the Memory Manager, not
 * foreign-context execution: it takes only the item handle, touches no other
 * process's globals, and runs in ours. The caller must still have proved,
 * through the memory seam, that the handle dereferences inside the target
 * partition — see `walk_dialog_items`. Toolbox-free callers link the stub. */

/* Copies at most `cap - 1` bytes plus a terminator. Returns the length
 * written, or -1 when the item has no readable text (which leaves whatever
 * the DITL template already gave the caller). */
short now_scene_dialog_item_text(unsigned long item_handle,
                                 char *out, short cap);

#endif
