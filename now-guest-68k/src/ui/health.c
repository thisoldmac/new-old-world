/*
 * health.c - see health.h.
 *
 * Every Toolbox call here is synchronous and cheap (a Gestalt trap, a
 * GDevice field read, or a Memory Manager trap) - nothing here is a
 * MacTCP operation, so none of net.h's one-op-in-flight or
 * interrupt-time rules apply to this file. health_init() is meant to run
 * once, off the main loop's idle path entirely.
 */
#include "health.h"
#include "numfmt.h"

#include <Gestalt.h>
#include <Quickdraw.h>
#include <MacMemory.h>

/*
 * MacTCP's version selector. Checked against this toolchain's Gestalt.h
 * (universal/CIncludes) - it is not declared there, MacTCP being outside
 * Universal Interfaces' scope by the time that header was assembled - but
 * it is the selector Inside Macintosh: Networking documents MacTCP as
 * answering. Declared locally instead of silently assuming an upstream
 * name exists (the grep-blindness trap: CIncludes are ISO-8859/CR and a
 * failed grep reads as "not defined" instead of "not searched right").
 */
#define kGestaltMacTCP FOUR_CHAR_CODE('mtcp')

/* Cached once by health_init(); health_static() only ever reads this. */
static HealthStatic gStatic;

/* Appends a literal, then NUL-terminates on success. On failure (the
 * buffer was too small for what we tried to put in it) falls back to a
 * short, always-fitting marker rather than leaving the buffer whatever
 * partial/garbage state the failed append left it in - every one of
 * these buffers is sized generously enough in health.h that the fallback
 * path is not expected to run, but a display string must never be left
 * unterminated on the strength of that expectation alone. */
static void finish(char *buf, long cap, long pos, int ok)
{
    if (ok && pos < cap) {
        buf[pos] = '\0';
        return;
    }
    if (cap > 0) {
        buf[0] = '?';
        buf[(cap > 1) ? 1 : 0] = '\0';
    }
}

static void fmt_machine(HealthStatic *hs)
{
    long pos = 0;
    int ok = now68k_fmt_append_str(hs->machine_str, sizeof hs->machine_str,
                                    &pos, "mach=")
        && now68k_fmt_append_long(hs->machine_str, sizeof hs->machine_str,
                                   &pos, hs->machine_type);
    finish(hs->machine_str, sizeof hs->machine_str, pos, ok);
}

static void fmt_cpu(HealthStatic *hs)
{
    long pos = 0;
    const char *name;
    int ok;

    /* Gestalt defines exactly these five 68K processor codes; anything
     * else means either a CPU family this app was never built to run on,
     * or a Gestalt response this file has not seen before - either way,
     * show the raw number rather than a name we cannot back up. */
    switch (hs->cpu_type) {
    case gestalt68000: name = "68000"; break;
    case gestalt68010: name = "68010"; break;
    case gestalt68020: name = "68020"; break;
    case gestalt68030: name = "68030"; break;
    case gestalt68040: name = "68040"; break;
    default:           name = NULL;    break;
    }

    if (name != NULL) {
        ok = now68k_fmt_append_str(hs->cpu_str, sizeof hs->cpu_str, &pos, name);
    } else {
        ok = now68k_fmt_append_str(hs->cpu_str, sizeof hs->cpu_str, &pos, "cpu=")
            && now68k_fmt_append_long(hs->cpu_str, sizeof hs->cpu_str, &pos,
                                       hs->cpu_type);
    }
    finish(hs->cpu_str, sizeof hs->cpu_str, pos, ok);
}

static void fmt_system(HealthStatic *hs)
{
    long pos = 0;
    /* Standard Mac OS decode for gestaltSystemVersion: high byte is the
     * major version as a plain decimal number (System 8/9 answer 0x08 /
     * 0x09, not BCD), low byte is minor and bug-fix packed as two BCD
     * nibbles (0x10 -> minor 1, bugfix 0; e.g. System 7.1.0 -> 0x0710). */
    long major = (hs->system_version >> 8) & 0xFF;
    long minor = (hs->system_version >> 4) & 0xF;
    long bugfix = hs->system_version & 0xF;
    int ok = now68k_fmt_append_str(hs->system_str, sizeof hs->system_str,
                                    &pos, "sys=")
        && now68k_fmt_append_long(hs->system_str, sizeof hs->system_str,
                                   &pos, major)
        && now68k_fmt_append_str(hs->system_str, sizeof hs->system_str,
                                  &pos, ".")
        && now68k_fmt_append_long(hs->system_str, sizeof hs->system_str,
                                   &pos, minor)
        && now68k_fmt_append_str(hs->system_str, sizeof hs->system_str,
                                  &pos, ".")
        && now68k_fmt_append_long(hs->system_str, sizeof hs->system_str,
                                   &pos, bugfix);
    finish(hs->system_str, sizeof hs->system_str, pos, ok);
}

static void fmt_vm(HealthStatic *hs)
{
    long pos = 0;
    const char *s = (hs->vm_on < 0) ? "VM=?" : (hs->vm_on ? "VM=on" : "VM=off");
    int ok = now68k_fmt_append_str(hs->vm_str, sizeof hs->vm_str, &pos, s);
    finish(hs->vm_str, sizeof hs->vm_str, pos, ok);
}

static void fmt_mactcp(HealthStatic *hs)
{
    long pos = 0;
    int ok;

    if (!hs->mactcp_known) {
        /* Honest, not a guess: either the selector is undefined on this
         * OS or MacTCP is not installed - this file cannot and does not
         * tell those two apart, and says so rather than picking one. */
        ok = now68k_fmt_append_str(hs->mactcp_str, sizeof hs->mactcp_str,
                                    &pos, "MacTCP=?");
    } else {
        /* Reported as the raw Gestalt response, not decoded into a
         * major.minor.fix guess - see health.h for why: unlike
         * gestaltSystemVersion, this module has no toolchain header or
         * measurement backing a particular byte layout for 'mtcp'. */
        ok = now68k_fmt_append_str(hs->mactcp_str, sizeof hs->mactcp_str,
                                    &pos, "MacTCP=raw:")
            && now68k_fmt_append_long(hs->mactcp_str, sizeof hs->mactcp_str,
                                       &pos, hs->mactcp_version);
    }
    finish(hs->mactcp_str, sizeof hs->mactcp_str, pos, ok);
}

static void fmt_screen(HealthStatic *hs)
{
    long pos = 0;
    int ok = now68k_fmt_append_long(hs->screen_str, sizeof hs->screen_str,
                                     &pos, hs->screen_width)
        && now68k_fmt_append_str(hs->screen_str, sizeof hs->screen_str,
                                  &pos, "x")
        && now68k_fmt_append_long(hs->screen_str, sizeof hs->screen_str,
                                   &pos, hs->screen_height)
        && now68k_fmt_append_str(hs->screen_str, sizeof hs->screen_str,
                                  &pos, "x")
        && now68k_fmt_append_long(hs->screen_str, sizeof hs->screen_str,
                                   &pos, hs->screen_depth)
        && now68k_fmt_append_str(hs->screen_str, sizeof hs->screen_str,
                                  &pos, " row=")
        && now68k_fmt_append_long(hs->screen_str, sizeof hs->screen_str,
                                   &pos, hs->screen_row_bytes);
    finish(hs->screen_str, sizeof hs->screen_str, pos, ok);
}

static void fmt_ram(HealthStatic *hs)
{
    long pos = 0;
    long mb = hs->physical_ram_bytes / (1024L * 1024L);
    int ok = now68k_fmt_append_str(hs->ram_str, sizeof hs->ram_str, &pos, "RAM=")
        && now68k_fmt_append_long(hs->ram_str, sizeof hs->ram_str, &pos, mb)
        && now68k_fmt_append_str(hs->ram_str, sizeof hs->ram_str, &pos, "MB");
    finish(hs->ram_str, sizeof hs->ram_str, pos, ok);
}

/* Reads the main GDevice's PixMap into hs->screen_*. Isolated in its own
 * function because it is the one sample here that is not a plain Gestalt
 * call - it walks GDHandle -> PixMapHandle, and a NULL anywhere in that
 * chain (no color QuickDraw device, an unusual boot state) must fail soft
 * into zeroed fields, never dereference. */
static void sample_screen(HealthStatic *hs)
{
    GDHandle gd = GetMainDevice();
    PixMapHandle pm;

    hs->screen_depth = 0;
    hs->screen_width = 0;
    hs->screen_height = 0;
    hs->screen_row_bytes = 0;

    if (gd == NULL || *gd == NULL) {
        return;
    }
    pm = (**gd).gdPMap;
    if (pm == NULL || *pm == NULL) {
        return;
    }

    /* gdRect is the device's own bounds in global coordinates - the
     * number a capture slice actually cares about - rather than the
     * PixMap's (often origin-relative) bounds field. */
    hs->screen_width = (short)((**gd).gdRect.right - (**gd).gdRect.left);
    hs->screen_height = (short)((**gd).gdRect.bottom - (**gd).gdRect.top);
    hs->screen_depth = (**pm).pixelSize;
    /* rowBytes' top two bits are the PixMap-flag and a reserved bit, not
     * part of the byte count (Inside Macintosh: Imaging With QuickDraw) -
     * mask them off or a monochrome/low-depth screen reads as a huge
     * negative rowBytes. */
    hs->screen_row_bytes = (long)((unsigned short)(**pm).rowBytes & 0x3FFF);
}

void health_init(void)
{
    long response;

    gStatic.machine_type = 0;
    if (Gestalt(gestaltMachineType, &response) == noErr) {
        gStatic.machine_type = response;
    }
    fmt_machine(&gStatic);

    gStatic.cpu_type = 0;
    if (Gestalt(gestaltProcessorType, &response) == noErr) {
        gStatic.cpu_type = response;
    }
    fmt_cpu(&gStatic);

    gStatic.system_version = 0;
    if (Gestalt(gestaltSystemVersion, &response) == noErr) {
        gStatic.system_version = response;
    }
    fmt_system(&gStatic);

    gStatic.vm_on = -1;
    if (Gestalt(gestaltVMAttr, &response) == noErr) {
        gStatic.vm_on = (response & (1L << gestaltVMPresent)) ? 1 : 0;
    }
    fmt_vm(&gStatic);

    gStatic.mactcp_known = 0;
    gStatic.mactcp_version = 0;
    if (Gestalt(kGestaltMacTCP, &response) == noErr) {
        gStatic.mactcp_known = 1;
        gStatic.mactcp_version = response;
    }
    fmt_mactcp(&gStatic);

    sample_screen(&gStatic);
    fmt_screen(&gStatic);

    gStatic.physical_ram_bytes = 0;
    if (Gestalt(gestaltPhysicalRAMSize, &response) == noErr) {
        gStatic.physical_ram_bytes = response;
    }
    fmt_ram(&gStatic);
}

const HealthStatic *health_static(void)
{
    return &gStatic;
}

void health_sample_dynamic(HealthDynamic *out)
{
    long pos;
    int ok;

    if (out == NULL) {
        return;
    }

    /* TempFreeMem/MaxBlock, not FreeMem - see health.h. */
    out->free_bytes = TempFreeMem();
    out->largest_block_bytes = MaxBlock();

    pos = 0;
    ok = now68k_fmt_append_str(out->free_str, sizeof out->free_str, &pos,
                                "free=")
        && now68k_fmt_append_long(out->free_str, sizeof out->free_str, &pos,
                                   out->free_bytes / 1024L)
        && now68k_fmt_append_str(out->free_str, sizeof out->free_str, &pos,
                                  "K");
    finish(out->free_str, sizeof out->free_str, pos, ok);

    pos = 0;
    ok = now68k_fmt_append_str(out->largest_str, sizeof out->largest_str,
                                &pos, "max=")
        && now68k_fmt_append_long(out->largest_str, sizeof out->largest_str,
                                   &pos, out->largest_block_bytes / 1024L)
        && now68k_fmt_append_str(out->largest_str, sizeof out->largest_str,
                                  &pos, "K");
    finish(out->largest_str, sizeof out->largest_str, pos, ok);
}
