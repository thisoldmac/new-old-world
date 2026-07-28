/*
 * shot68.c - implementation of shot68.h. Read that header first: it
 * carries why the recording port is the Window Manager's, why the picture
 * streams instead of accumulating, why the banded version of this was
 * abandoned, and why an 8-bit screen is the only one it will capture.
 *
 * STATIC BUDGET (file-scope BSS - the put-pic callback takes no refCon, so
 * its state has nowhere else to live):
 *   g_buf            the write buffer                        1024 bytes
 *   g_procs          one CQDProcs for the recording port        ~80 bytes
 *   g_put_upp        one UPP (a ProcPtr on 68K)                   4 bytes
 *   scalars          refnum, flags, counters, timers            ~28 bytes
 *   ----------------------------------------------------------------------
 *   total                                                     ~1.1 KB
 * Plus the one read-baseline band GWorld - 640 x 32 x 8 bits = 20 KB -
 * taken and given back inside one call, and closed before the recording
 * pass even begins. Nothing else allocates on any path, so the whole
 * capture's ceiling is ~21 KB against a 384 KB partition, independent of
 * how big the screen is.
 *
 * THE RE-ENTRY GUARD IS LOAD-BEARING HERE, more than it is in vprobe68.c.
 * That state above is file-scope; two captures running at once would
 * interleave two pictures' opcodes into one file and produce a plausible
 * PICT that decodes to nonsense. A second call is refused.
 *
 * No printf family (numfmt.h and n68_shot.h's formatters only).
 */
#include "shot68.h"

#include "log.h"
#include "numfmt.h"
#include "screen68.h"
#include "wire68.h"

#include <Events.h>
#include <Files.h>
#include <Folders.h>
#include <MacMemory.h>
#include <MacWindows.h>
#include <OSUtils.h>
#include <QDOffscreen.h>
#include <Quickdraw.h>
#include <ToolUtils.h>

#include <string.h>

enum {
    /* One FSWrite per kilobyte rather than per opcode. QuickDraw hands the
     * put proc a few bytes at a time for opcodes and up to a packed row at
     * a time for pixels; an unbuffered write per call would be thousands
     * of File Manager round trips for one screen. */
    kShotIOBuf = 1024,

    /* Every PICT begins with 512 bytes an application may use for whatever
     * it likes and readers skip. Zeroed here. */
    kShotPictHeader = 512,

    /* The worst case this capture can take, stated rather than timed,
     * because nothing here pumps and the number that matters is how long
     * the wire can go quiet. vprobe measured the 180c's banded CopyBits at
     * ~200 ms for a frame (docs/vram-readout-68k.md); the read baseline
     * pays that once, and the recording pass reads the same bytes and
     * packs them, which on a 33 MHz 68030 is generously ~10x the read.
     * Writing ~100 KB to this machine's disk is under a second. 200 + 200
     * + 2000 + 1000, tripled for a machine slower than anyone expects, is
     * ~10 s - against wire68.c's ~65 s death timer. That margin is why
     * this capture does not need to pump in the middle of itself, and
     * therefore cannot tear. If a real 180c ever exceeds it, the number to
     * change is here and the fix is banding the PUMP, not the picture. */
    kShotWorstCaseMs = 10000
};

/* The 10 bytes this file composes by hand between the 512-byte header and
 * the first opcode. If a toolchain ever pads this struct, the picture
 * would decode with its frame shifted by the padding - a wrong image
 * rather than a failed one, which is the kind that ships. */
_Static_assert(sizeof(Picture) == 10,
               "a padded Picture header would shift every PICT this file "
               "writes");

/* ---- the streaming put-pic proc ------------------------------------------- */

static Boolean      g_running = false;
static CQDProcs     g_procs;
static QDPutPicUPP  g_put_upp = NULL;
static short        g_ref = 0;          /* 0 = measuring only, no file */
static int          g_saving = 0;
static OSErr        g_write_err = noErr;
static long         g_streamed = 0;     /* picture bytes past the 10-byte header */
static unsigned long g_write_us = 0;
static char         g_buf[kShotIOBuf];
static long         g_buf_n = 0;

static void shot_flush(void)
{
    long count = g_buf_n;
    unsigned long t0;
    OSErr err;

    if (count <= 0) {
        return;
    }
    g_buf_n = 0;
    if (!g_saving || g_ref == 0) {
        return;             /* --no-save: encoded, counted, never written */
    }
    t0 = screen68_micros();
    if (g_write_err == noErr) {
        err = FSWrite(g_ref, &count, g_buf);
        if (err != noErr) {
            g_write_err = err;
        }
    }
    g_write_us += screen68_micros() - t0;
}

/* QuickDraw calls this for every byte of picture it generates, from inside
 * CopyBits, with the picture open on the current port.
 *
 * IT MOVES MEMORY, WHICH A QUICKDRAW BOTTLENECK IS TOLD NOT TO DO. Inside
 * Macintosh's rule is that a custom bottleneck must not move or purge, and
 * FSWrite can. The concession that makes a streaming write legal is made
 * at the call site instead: both pixmap handles CopyBits is holding are
 * locked across the call, so nothing QuickDraw is pointing at can go
 * anywhere. See the recording pass below. */
static pascal void shot_put_pic(const void *dataPtr, short byteCount)
{
    const char *p = (const char *)dataPtr;
    long n = (long)byteCount;

    if (p == NULL || n <= 0) {
        return;
    }
    g_streamed += n;
    while (n > 0) {
        long room = (long)sizeof g_buf - g_buf_n;
        long take = n < room ? n : room;

        memcpy(g_buf + g_buf_n, p, (size_t)take);
        g_buf_n += take;
        p += take;
        n -= take;
        if (g_buf_n >= (long)sizeof g_buf) {
            shot_flush();
        }
    }
}

static void put_state_reset(int saving, short ref)
{
    g_saving = saving;
    g_ref = ref;
    g_write_err = noErr;
    g_streamed = 0;
    g_write_us = 0;
    g_buf_n = 0;
}

/* ---- the file ------------------------------------------------------------- */

static void c_to_pascal(const char *src, Str255 dst)
{
    long n = 0;

    while (src[n] != '\0' && n < 31) {
        dst[n + 1] = (unsigned char)src[n];
        ++n;
    }
    dst[0] = (unsigned char)n;
}

/* Picks a name nothing on the desktop already has, creates the file and
 * opens its data fork. A SECOND SHOT CANNOT CLOBBER THE FIRST: the
 * contemporary name is per-second, so two captures inside one second would
 * collide, and the collision is answered with a tick-stamped name rather
 * than an overwrite. FSMakeFSSpec returning noErr means the name is TAKEN;
 * fnfErr is the answer we want. */
static OSErr shot_open_file(char *name_out, long name_cap, short *ref_out)
{
    short vref;
    long dirid;
    FSSpec spec;
    Str255 pname;
    OSErr err;
    DateTimeRec when;
    long attempt;

    *ref_out = 0;
    err = FindFolder(kOnSystemDisk, kDesktopFolderType, kCreateFolder,
                     &vref, &dirid);
    if (err != noErr) {
        return err;
    }

    GetTime(&when);
    for (attempt = 0; attempt < 2; ++attempt) {
        if (n68_shot_name(name_out, name_cap, when.year, when.month,
                          when.day, when.hour, when.minute, when.second,
                          (unsigned long)TickCount(), attempt) <= 0) {
            return bdNamErr;
        }
        c_to_pascal(name_out, pname);
        err = FSMakeFSSpec(vref, dirid, pname, &spec);
        if (err == fnfErr) {
            break;
        }
        if (err != noErr) {
            return err;
        }
    }
    if (err != fnfErr) {
        return dupFNErr;
    }

    /* 'ttxt' so SimpleText opens it with a double-click, exactly as the
     * PowerPC guest's screenshots do - the two machines' output should be
     * the same kind of thing on the desktop. */
    err = FSpCreate(&spec, 'ttxt', 'PICT', smSystemScript);
    if (err != noErr) {
        return err;
    }
    err = FSpOpenDF(&spec, fsRdWrPerm, ref_out);
    if (err != noErr) {
        *ref_out = 0;
    }
    return err;
}

/* The 10 bytes between the 512-byte header and the first opcode. Composed
 * here rather than read back out of the PicHandle: with a custom
 * putPicProc the handle is never grown past its own header, so the only
 * thing it could tell us is what we already passed to OpenPicture.
 *
 * picSize is the low 16 bits of the whole picture's length. For anything
 * over 32 KB that field is meaningless and every version-2 reader ignores
 * it in favour of the file's length - stated here because writing a
 * deliberately-truncated number looks like a bug otherwise. */
static OSErr shot_patch_header(short ref, const Rect *frame, long data_bytes)
{
    Picture hdr;
    long count = (long)sizeof hdr;
    OSErr err;

    err = SetFPos(ref, fsFromStart, (long)kShotPictHeader);
    if (err != noErr) {
        return err;
    }
    hdr.picSize = (short)((data_bytes + (long)sizeof hdr) & 0xFFFFL);
    hdr.picFrame = *frame;
    return FSWrite(ref, &count, &hdr);
}

/* ---- the capture ---------------------------------------------------------- */

/* Before the capture and after it, never inside it - a pumped event can
 * move a window, and a picture recorded across that is a torn one.
 * vprobe68.c's shape, including the nested guard: wire_idle() can walk all
 * the way back into command dispatch and reach this file again. */
static void shot_pump(void)
{
    static Boolean pumping = false;
    EventRecord event;

    if (!pumping) {
        pumping = true;
        wire_idle();
        pumping = false;
    }
    (void)WaitNextEvent(0, &event, 0, NULL);
}

static void say(char *why, long why_cap, const char *text)
{
    long pos = 0;

    if (why == NULL || why_cap <= 0) {
        return;
    }
    (void)now68k_fmt_append_str(why, why_cap - 1, &pos, text);
    why[pos > 0 && pos < why_cap ? pos : 0] = '\0';
}

static void say_num(char *why, long why_cap, const char *before, long n,
                    const char *after)
{
    long pos = 0;

    if (why == NULL || why_cap <= 0) {
        return;
    }
    (void)(now68k_fmt_append_str(why, why_cap - 1, &pos, before)
           && now68k_fmt_append_long(why, why_cap - 1, &pos, n)
           && now68k_fmt_append_str(why, why_cap - 1, &pos, after));
    why[pos > 0 && pos < why_cap ? pos : 0] = '\0';
}

/* The cursor can never be inside what is being read. ShieldCursor takes
 * its rectangle in the current port's LOCAL coordinates plus the offset of
 * that origin from the global one; passing an already-global rectangle
 * with a zero offset is the documented way to shield a global rectangle,
 * and it is the only spelling that stays right whichever port happens to
 * be current when it is called. Balanced with ShowCursor on every path,
 * including the ones that fail. */
static void shield_global(const Rect *global_rect)
{
    Point zero;

    zero.h = 0;
    zero.v = 0;
    ShieldCursor(global_rect, zero);
}

static void watch_cursor(void)
{
    CursHandle c = GetCursor(watchCursor);

    if (c != NULL && *c != NULL) {
        SetCursor(*c);
    }
}

Shot68Status shot68_capture(const N68ShotArgs *a, N68ShotStats *s,
                            char *why, long why_cap)
{
    Screen68 sc;
    Band68 band;
    Rect shield;
    CGrafPtr save_port;
    GDHandle save_device;
    CGrafPtr wmgr = NULL;
    CQDProcsPtr saved_procs = NULL;
    RgnHandle saved_clip = NULL;
    PicHandle pic = NULL;
    N68ShotArgs args;
    char name[kN68ShotNameCap];
    unsigned long read_us = 0;
    unsigned long rec_us = 0;
    unsigned long write_us_before = 0;
    unsigned long t0;
    long bands;
    long i;
    long rows;
    long top;
    short ref = 0;
    SignedByte screen_state = 0;
    SignedByte port_state = 0;
    OSErr err = noErr;

    if (s == NULL || why == NULL || why_cap <= 0) {
        return kShot68Geometry;
    }
    memset(s, 0, sizeof *s);
    why[0] = '\0';
    name[0] = '\0';

    if (g_running) {
        say(why, why_cap, "a screenshot is already being taken on this Mac");
        return kShot68Busy;
    }

    n68_shot_args_init(&args);
    if (a != NULL) {
        args = *a;
    }
    if (args.depth != kN68ShotDepth) {
        say_num(why, why_cap,
                "screenshot captures 8-bit screens only; asked for ",
                args.depth, "-bit");
        return kShot68Depth;
    }

    switch (screen68_info(&sc, "screenshot", why, why_cap)) {
    case kScreen68OK:
        break;
    case kScreen68NoScreen:
        return kShot68NoScreen;
    default:
        return kShot68Geometry;
    }
    if (sc.depth != kN68ShotDepth) {
        /* Refuses rather than converts - see shot68.h. The sentence names
         * the depth it found, because "set the monitor to 256 colours" is
         * an action a person can take and "screenshot failed" is not. */
        say_num(why, why_cap, "this screen is ", sc.depth,
                "-bit; screenshot captures 8-bit natively and will not "
                "convert");
        return kShot68Depth;
    }

    g_running = true;
    shot_pump();                 /* before, never during: see shot68.h */
    watch_cursor();

    if (!screen68_band_open(&band, &sc, (short)kN68ShotBandRows)) {
        InitCursor();
        g_running = false;
        say(why, why_cap, "no memory for a capture band on this Mac");
        return kShot68NoMemory;
    }
    bands = n68_shot_band_count(sc.height, (long)kN68ShotBandRows);

    /* --- phase one: the read baseline ------------------------------------- */
    /* The same banded CopyBits vprobe times, on the same 20 KB band, so the
     * two capabilities' numbers are comparable - and the subtrahend that
     * turns the recording pass into an encode cost. band.rows is walked
     * down for a short last band rather than the remainder being dropped:
     * 480 divides by 32, but nothing says the next screen will. */
    for (i = 0; i < bands; ++i) {
        rows = n68_shot_band_rows(sc.height, (long)kN68ShotBandRows, i);
        top = n68_shot_band_top(sc.height, (long)kN68ShotBandRows, i);
        band.rows = (short)rows;
        shield = sc.bounds;
        shield.top = (short)(sc.bounds.top + top);
        shield.bottom = (short)(shield.top + rows);
        shield_global(&shield);
        read_us += screen68_band_copy(&band, &sc, top);
        ShowCursor();
    }
    band.rows = (short)kN68ShotBandRows;
    screen68_band_close(&band);   /* the recording pass needs no pixels */

    /* --- the file, if this shot is being saved ---------------------------- */
    if (args.save) {
        err = shot_open_file(name, (long)sizeof name, &ref);
        if (err != noErr) {
            InitCursor();
            g_running = false;
            say_num(why, why_cap,
                    "could not create a screenshot on the desktop (error ",
                    (long)err, ")");
            return kShot68File;
        }
    }
    put_state_reset(args.save, ref);

    if (args.save) {
        long count = (long)kShotPictHeader + (long)sizeof(Picture);

        memset(g_buf, 0, sizeof g_buf);
        t0 = screen68_micros();
        err = FSWrite(ref, &count, g_buf);   /* 512 zeros + 10 placeholder */
        g_write_us += screen68_micros() - t0;
        if (err != noErr) {
            g_write_err = err;
        }
    }

    /* --- phase two: record the picture, streaming it out ------------------ */
    GetGWorld(&save_port, &save_device);
    SetStdCProcs(&g_procs);
    g_put_upp = NewQDPutPicUPP(shot_put_pic);
    if (g_put_upp == NULL) {
        goto encode_failed;
    }
    g_procs.putPicProc = g_put_upp;
    write_us_before = g_write_us;

    GetCWMgrPort(&wmgr);
    if (wmgr == NULL || wmgr->portPixMap == NULL) {
        goto encode_failed;
    }
    saved_clip = NewRgn();
    SetPort((GrafPtr)wmgr);
    if (saved_clip != NULL) {
        GetClip(saved_clip);
    }
    ClipRect(&sc.bounds);
    saved_procs = wmgr->grafProcs;
    wmgr->grafProcs = &g_procs;
    ForeColor(blackColor);
    BackColor(whiteColor);

    pic = OpenPicture(&sc.bounds);
    if (pic != NULL) {
        /* THE HANDLES CopyBits HOLDS MUST NOT MOVE WHILE THE PUT PROC
         * WRITES. Both pixmaps are dereferenced at the call site and
         * QuickDraw keeps those pointers for the whole call - during which
         * shot_put_pic runs and FSWrite can relocate a handle.
         * HGetState/HSetState rather than HLock/HUnlock because neither
         * handle is ours: the screen's belongs to the GDevice and this one
         * to the Window Manager, and clearing a lock bit this code did not
         * set would clear one that was not ours to clear. */
        screen_state = HGetState((Handle)sc.pix);
        port_state = HGetState((Handle)wmgr->portPixMap);
        HLock((Handle)sc.pix);
        HLock((Handle)wmgr->portPixMap);

        shield = sc.bounds;
        shield_global(&shield);
        t0 = screen68_micros();
        /* Recording, not blitting: with a picture open QuickDraw hands the
         * source pixels to the put proc as a packed opcode and the
         * destination port's pixels are never written. That is what makes
         * a 300 KB screen cost a 1 KB buffer. */
        CopyBits((BitMap *)*sc.pix, (BitMap *)*wmgr->portPixMap,
                 &sc.bounds, &sc.bounds, srcCopy, NULL);
        rec_us += screen68_micros() - t0;
        ShowCursor();
        ClosePicture();

        HSetState((Handle)wmgr->portPixMap, port_state);
        HSetState((Handle)sc.pix, screen_state);
    }

    wmgr->grafProcs = saved_procs;
    if (saved_clip != NULL) {
        SetClip(saved_clip);
        DisposeRgn(saved_clip);
        saved_clip = NULL;
    }
    SetGWorld(save_port, save_device);
    DisposeQDPutPicUPP(g_put_upp);
    g_put_upp = NULL;
    if (pic != NULL) {
        KillPicture(pic);
        pic = NULL;
    }

    if (g_streamed == 0) {
        goto encode_failed;
    }
    shot_flush();

    if (args.save) {
        if (g_write_err == noErr) {
            t0 = screen68_micros();
            err = shot_patch_header(ref, &sc.bounds, g_streamed);
            g_write_us += screen68_micros() - t0;
            if (err != noErr) {
                g_write_err = err;
            }
        }
        FSClose(ref);
        ref = 0;
        if (g_write_err != noErr) {
            InitCursor();
            g_running = false;
            say_num(why, why_cap,
                    "the screenshot could not be written (error ",
                    (long)g_write_err, ")");
            return kShot68File;
        }
    }

    InitCursor();

    s->width = sc.width;
    s->height = sc.height;
    s->depth = sc.depth;
    s->raw_bytes = sc.visible_row * sc.height;
    s->pict_bytes = (long)kShotPictHeader + (long)sizeof(Picture) + g_streamed;
    s->read_ms = (long)(read_us / 1000UL);
    /* The difference of two passes - stated in n68_shot.h, and floored
     * here rather than allowed to go negative: on a screen that packs
     * almost for free the two passes can land within each other's noise,
     * and a negative millisecond count is not a measurement. */
    {
        unsigned long shot_write_us = g_write_us - write_us_before;
        unsigned long enc = rec_us;

        if (enc > shot_write_us) {
            enc -= shot_write_us;
        } else {
            enc = 0;
        }
        if (enc > read_us) {
            enc -= read_us;
        } else {
            enc = 0;
        }
        s->encode_ms = (long)(enc / 1000UL);
    }
    s->write_ms = (long)(g_write_us / 1000UL);
    if (args.save) {
        memcpy(s->saved_name, name, sizeof s->saved_name);
        s->saved_name[sizeof s->saved_name - 1] = '\0';
    }
    now68k_log_num("shot: packed bytes", s->pict_bytes);
    g_running = false;
    shot_pump();
    return kShot68OK;

encode_failed:
    if (wmgr != NULL && saved_procs != NULL) {
        wmgr->grafProcs = saved_procs;
    }
    if (saved_clip != NULL) {
        SetClip(saved_clip);
        DisposeRgn(saved_clip);
    }
    SetGWorld(save_port, save_device);
    if (pic != NULL) {
        KillPicture(pic);
    }
    if (g_put_upp != NULL) {
        DisposeQDPutPicUPP(g_put_upp);
        g_put_upp = NULL;
    }
    if (ref != 0) {
        FSClose(ref);
    }
    InitCursor();
    g_running = false;
    now68k_log("shot: QuickDraw would not record");
    say(why, why_cap, "QuickDraw would not record this screen as a picture");
    return kShot68Encode;
}
