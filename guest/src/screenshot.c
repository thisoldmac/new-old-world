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

/* Finds a free "NOW Shot N" name on the desktop and writes the PICT file
   (512-byte header + picture data), type PICT / creator ttxt so SimpleText
   opens it with a double-click. */
static OSErr save_pict(PicHandle pic, char *name_out, long name_cap)
{
    short vref, ref;
    long dirid;
    FSSpec spec;
    OSErr err;
    int n;
    char name[32];
    Str255 pname;
    long len;
    char header[512];

    err = FindFolder(kOnSystemDisk, kDesktopFolderType, kCreateFolder,
                     &vref, &dirid);
    if (err != noErr) {
        return err;
    }
    for (n = 1; n < 100; ++n) {
        snprintf(name, sizeof name, "NOW Shot %d", n);
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

int now_screenshot(short depth, Boolean save, ShotStats *stats,
                   char *err, long err_cap)
{
    CaptureImage image;
    PicHandle pic;
    UnsignedWide t0, t1, t2;
    int rc;
    OSErr oserr;

    memset(stats, 0, sizeof *stats);
    err[0] = '\0';

    Microseconds(&t0);
    rc = capture_screen(depth, &image);
    Microseconds(&t1);
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
