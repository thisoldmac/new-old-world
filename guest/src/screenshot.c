#include "screenshot.h"

#include <stdio.h>
#include <string.h>

#include "capture.h"

static long micros_to_ms(UnsignedWide start, UnsignedWide end)
{
    unsigned long lo = end.lo - start.lo;   /* spans are well under 2^32 us */
    return (long)(lo / 1000);
}

/* Records the GWorld into a PICT; QuickDraw emits PackBits-compressed
   opcodes on its own. Caller disposes the handle. */
static PicHandle encode_pict(CaptureImage *image)
{
    CGrafPtr saved_port;
    GDHandle saved_device;
    PicHandle pic;
    PixMapHandle pixels = GetGWorldPixMap(image->world);

    if (pixels == NULL || !LockPixels(pixels)) {
        return NULL;
    }
    GetGWorld(&saved_port, &saved_device);
    SetGWorld(image->world, NULL);
    pic = OpenPicture(&image->bounds);
    if (pic != NULL) {
        ClipRect(&image->bounds);
        CopyBits(GetPortBitMapForCopyBits(image->world),
                 GetPortBitMapForCopyBits(image->world),
                 &image->bounds, &image->bounds, srcCopy, NULL);
        ClosePicture();
    }
    SetGWorld(saved_port, saved_device);
    UnlockPixels(pixels);
    if (pic != NULL && GetHandleSize((Handle)pic) <= (Size)sizeof(Picture)) {
        KillPicture(pic);
        return NULL;
    }
    return pic;
}

/* Names the file the contemporary way — "Screenshot 2026-07-19 22.53.01"
   (30 chars; HFS caps names at 31, which is why there is no " at ") — and
   writes the PICT (512-byte header + picture data), type PICT / creator
   ttxt so SimpleText opens it with a double-click. */
static OSErr save_pict(PicHandle pic, char *name_out, long name_cap)
{
    short vref, ref;
    long dirid;
    FSSpec spec;
    OSErr err;
    int n;
    char name[40];
    Str255 pname;
    long len;
    char header[512];

    err = FindFolder(kOnSystemDisk, kDesktopFolderType, kCreateFolder,
                     &vref, &dirid);
    if (err != noErr) {
        return err;
    }
    for (n = 0; n < 2; ++n) {
        if (n == 0) {
            DateTimeRec when;

            GetTime(&when);
            snprintf(name, sizeof name,
                     "Screenshot %04u-%02u-%02u %02u.%02u.%02u",
                     (unsigned)when.year % 10000u,
                     (unsigned)when.month % 100u,
                     (unsigned)when.day % 100u,
                     (unsigned)when.hour % 100u,
                     (unsigned)when.minute % 100u,
                     (unsigned)when.second % 100u);
        } else {
            /* Same-second collision: ticks are unique enough. */
            snprintf(name, sizeof name, "Screenshot %lu",
                     (unsigned long)TickCount());
        }
        CopyCStringToPascal(name, pname);
        err = FSMakeFSSpec(vref, dirid, pname, &spec);
        if (err == fnfErr) {
            break;
        }
    }
    if (n >= 100) {
        return dupFNErr;
    }
    err = FSpCreate(&spec, 'ttxt', 'PICT', smSystemScript);
    if (err != noErr) {
        return err;
    }
    err = FSpOpenDF(&spec, fsRdWrPerm, &ref);
    if (err != noErr) {
        return err;
    }
    memset(header, 0, sizeof header);
    len = sizeof header;
    err = FSWrite(ref, &len, header);
    if (err == noErr) {
        HLock((Handle)pic);
        len = GetHandleSize((Handle)pic);
        err = FSWrite(ref, &len, *pic);
        HUnlock((Handle)pic);
    }
    FSClose(ref);
    if (err == noErr) {
        snprintf(name_out, name_cap, "%s", name);
    }
    return err;
}

int now_screenshot(short depth, short bands, Boolean save, ShotStats *stats,
                   char *err, long err_cap)
{
    BandedCapture cap;
    CaptureImage image;
    PicHandle pic;
    UnsignedWide t0, t1, t2;
    int rc;
    int b;
    OSErr oserr;

    memset(stats, 0, sizeof *stats);
    err[0] = '\0';

    Microseconds(&t0);
    rc = banded_capture_begin(depth, bands, &cap);
    while (rc == kCaptureOK && cap.next_band < cap.bands) {
        rc = banded_capture_step(&cap);
        if (rc == kCaptureMoreBands) {
            rc = kCaptureOK;
        }
    }
    Microseconds(&t1);
    if (rc == kCaptureOK) {
        image = cap.image;
        stats->bands = cap.bands;
        for (b = 0; b < cap.bands; ++b) {
            long us = (long)cap.band_us[b];
            if (b == 0 || us < stats->band_min_us) {
                stats->band_min_us = us;
            }
            if (us > stats->band_max_us) {
                stats->band_max_us = us;
            }
        }
    }
    if (rc != kCaptureOK) {
        switch (rc) {
        case kCaptureInvalidDepth:
            snprintf(err, err_cap, "depth must be 1, 2, 4, 8, 16 or 32");
            break;
        case kCaptureNoMemory:
            snprintf(err, err_cap, "not enough memory at %d-bit", depth);
            break;
        default:
            snprintf(err, err_cap, "capture failed (%d)", rc);
            break;
        }
        return rc;
    }

    pic = encode_pict(&image);
    Microseconds(&t2);
    if (pic == NULL) {
        capture_image_dispose(&image);
        snprintf(err, err_cap, "PICT encoding failed");
        return kCapturePixelsUnavailable;
    }

    stats->width = (short)(image.bounds.right - image.bounds.left);
    stats->height = (short)(image.bounds.bottom - image.bounds.top);
    stats->depth = depth;
    stats->raw_bytes = image.pixel_bytes;
    stats->pict_bytes = GetHandleSize((Handle)pic);
    stats->capture_ms = micros_to_ms(t0, t1);
    stats->encode_ms = micros_to_ms(t1, t2);

    if (save) {
        oserr = save_pict(pic, stats->saved_name, sizeof stats->saved_name);
        if (oserr != noErr) {
            KillPicture(pic);
            capture_image_dispose(&image);
            snprintf(err, err_cap, "save failed (error %d)", oserr);
            return kCapturePixelsUnavailable;
        }
    }
    KillPicture(pic);
    capture_image_dispose(&image);
    return 0;
}
