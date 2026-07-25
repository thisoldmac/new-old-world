#ifndef NOW68K_HEALTH_H
#define NOW68K_HEALTH_H

/*
 * health.h - machine-state readout for the panel.
 *
 * Two sample sets, on two different schedules, because they answer two
 * different questions on a 33 MHz machine:
 *
 *   STATIC facts cannot change for the life of a run (machine identity,
 *   CPU, System version, Virtual Memory, MacTCP version, screen geometry,
 *   physical RAM). health_init() samples every one of them ONCE, from
 *   Gestalt and the main GDevice, and caches the result. Re-running these
 *   Toolbox calls on every panel refresh would cost real time on this CPU
 *   for a number that never moves - pure jank, zero information.
 *
 *   DYNAMIC facts change while the app runs (free memory, the largest
 *   free block). health_sample_dynamic() reads them fresh every time it is
 *   called - it is cheap (two Memory Manager traps, no allocation) - and
 *   the caller decides the schedule. That schedule must be "the panel
 *   actually redrew", never an idle-loop timer of its own: idle work has
 *   to stay free (guest-ui-start-here.md).
 *
 * Every value comes two ways: a short ASCII string already built and ready
 * to hand to DrawString/TETextBox, and the raw number for now68k_log_num.
 * The strings are assembled with numfmt.h's append helpers at sample time,
 * never with snprintf - snprintf drags in newlib's float formatting tail
 * (~42 KB) into a 384 KB partition for a feature this app never uses.
 *
 * No allocation anywhere in this module: both structs are plain data,
 * owned by the caller (health_sample_dynamic) or by a single static
 * instance inside health.c (health_init/health_static). Fixed buffers
 * only; see health.c for the size arithmetic behind each one.
 */

typedef struct {
    /* gestaltMachineType raw response. Reported, never branched on - the
     * fleet spans emulator and metal builds of the same identity number
     * (finding fleet-gestalt-identity), so behavior must come from probed
     * capabilities below, not from this number. It is here for a human
     * reading the panel or the log, nothing else consults it. */
    long machine_type;
    char machine_str[24];          /* "mach=71" */

    /* gestaltProcessorType raw response, decoded to a name for the five
     * 68K values Gestalt defines (68000/68010/68020/68030/68040); an
     * unrecognized response (there should not be one on this CPU family)
     * falls back to the raw number rather than a guess. */
    long cpu_type;
    char cpu_str[16];              /* "68030" or "cpu=<n>" */

    /* gestaltSystemVersion raw response, decoded with the standard Mac OS
     * convention for this selector: high byte = major (decimal digits,
     * not BCD - System 8/9 report 0x08/0x09 plainly), low byte = minor
     * and bug-fix as two BCD nibbles (0x10 -> "1.0"). */
    long system_version;
    char system_str[16];           /* "sys=7.1.0" */

    /* -1 = Gestalt(gestaltVMAttr) itself failed (selector not present on
     * this OS - honestly unknown, not assumed off); 0 = present but off;
     * 1 = on. */
    int  vm_on;
    char vm_str[8];                /* "VM=on" / "VM=off" / "VM=?" */

    /* MacTCP's version selector (FOUR_CHAR_CODE('mtcp')) is not declared
     * in this toolchain's Gestalt.h - checked, it is absent - though it is
     * the selector MacTCP has answered since Inside Macintosh: Networking.
     * We probe it anyway and report exactly what Gestalt hands back or
     * that it did not answer; we do NOT decode the response into a
     * major.minor.fix guess, because unlike gestaltSystemVersion this
     * module has no toolchain header or measurement to stand behind that
     * decode. mactcp_known is 0 whenever the probe failed for any reason
     * (selector undefined, MacTCP not installed) - the string says so. */
    int  mactcp_known;
    long mactcp_version;           /* raw response; valid only if mactcp_known */
    char mactcp_str[32];           /* "MacTCP=raw:<n>" or "MacTCP=?" */

    /* Measured from the main GDevice's PixMap, not assumed from a spec
     * sheet - the later capture slice is sized off this number, so it has
     * to be what the machine actually reports. rowBytes is masked to the
     * low 14 bits per QuickDraw convention (the top two bits of a
     * PixMap's rowBytes are the pixMap-flag and a reserved bit, not part
     * of the byte count). */
    short screen_depth;            /* bits per pixel */
    short screen_width;            /* pixels */
    short screen_height;           /* pixels */
    long  screen_row_bytes;        /* bytes per scan line */
    char  screen_str[40];          /* "640x480x8 row=640" */

    /* gestaltPhysicalRAMSize, in bytes - NOT MemTop, which under-reports
     * badly on some real machines (a Quadra 950 with 256 MB measured
     * 6.7 MB via MemTop; finding fleet-gestalt-identity). */
    long physical_ram_bytes;
    char ram_str[24];              /* "RAM=4MB" */
} HealthStatic;

typedef struct {
    /* TempFreeMem(), not FreeMem(): FreeMem only sees this application's
     * own heap, which answers a different question than the one a human
     * asks when checking whether the machine is out of room (harness
     * workshop/mod_state.c makes the same call for the same reason). */
    long free_bytes;
    /* MaxBlock(): the largest single contiguous free block. Fragmentation,
     * not total free space, is the failure mode that actually bites on a
     * 384 KB partition - a NewHandle can fail with kilobytes of free
     * memory scattered in pieces too small to satisfy it. */
    long largest_block_bytes;

    char free_str[24];             /* "free=512K" */
    char largest_str[24];          /* "max=384K" */
} HealthDynamic;

/* Samples every STATIC fact once and caches it. Call after Toolbox init
 * (InitGraf/InitWindows must have run - this reads the main GDevice) and
 * before the panel first draws. Idempotent but not guarded against
 * re-entry with a flag: re-running four fixed-cost Gestalt calls and one
 * GDevice read is cheaper than the branch that would guard them, and a
 * caller that calls it twice gets the same answer both times (nothing
 * sampled here can change while the app runs). */
void health_init(void);

/* Returns a pointer to the cached static snapshot - never NULL, even
 * before health_init() has run (in that case every field reads its
 * zero/unknown default, not garbage). A cheap struct-field read, no
 * Toolbox calls; safe to call every time the panel redraws. */
const HealthStatic *health_static(void);

/* Samples every DYNAMIC fact fresh into *out. Cheap (TempFreeMem +
 * MaxBlock, two Memory Manager traps, no allocation) but not free - call
 * it when the panel actually redraws, never from an unconditional
 * idle-loop poll. */
void health_sample_dynamic(HealthDynamic *out);

#endif /* NOW68K_HEALTH_H */
