#include "rom_dump.h"

#include <Carbon.h>

#include <stdio.h>
#include <string.h>

#include "fileshare.h"

static const char kROMDumpName[] = "New Old World ROM.bin";
static const char kROMDumpTemporaryName[] = "New Old World ROM.tmp";

/* CarbonLib omits LMGetROMBase even though the low-memory global remains the
   OS-owned source used by the ROM dumper. This is a read of the pointer at
   RomBase ($02AE), not a guessed physical address. */
static unsigned char *rom_base(void)
{
    unsigned char *base = NULL;

    /* RomBase is at an address that is not word-aligned.  Let the Toolbox
       copy its four bytes rather than asking the PPC compiler for an
       unaligned pointer load. */
    BlockMoveData((const void *)0x02AE, &base, sizeof base);
    return base;
}

int now_rom_dump(char *path, long path_cap, NowROMLayout *layout,
                 char *error, long error_cap)
{
    long gestalt_rom = 0;
    long machine_type = 0;
    short vref;
    long dir;
    Str255 name, temporary_name;
    FSSpec spec, temporary_spec;
    OSErr err;
    short refnum = -1;
    Boolean destination_exists;
    unsigned long offset = 0;
    unsigned char *rom = rom_base();

    if (path_cap > 0) path[0] = '\0';
    if (error_cap > 0) error[0] = '\0';
    (void)Gestalt(gestaltROMSize, &gestalt_rom);
    (void)Gestalt(gestaltMachineType, &machine_type);
    *layout = now_rom_layout((uint32_t)machine_type, (uint32_t)gestalt_rom);
    if (rom == NULL || layout->total_bytes == 0) {
        snprintf(error, (size_t)error_cap, "the ROM layout is unavailable");
        return 0;
    }
    if (now_files_share_root(&vref, &dir) != kFilesOK) {
        snprintf(error, (size_t)error_cap,
                 "the configured Files share is unavailable");
        return 0;
    }

    CopyCStringToPascal(kROMDumpName, name);
    err = FSMakeFSSpec(vref, dir, name, &spec);
    destination_exists = (err == noErr);
    if (err != noErr && err != fnfErr) {
        snprintf(error, (size_t)error_cap, "could not locate the dump (%d)",
                 (int)err);
        return 0;
    }
    CopyCStringToPascal(kROMDumpTemporaryName, temporary_name);
    err = FSMakeFSSpec(vref, dir, temporary_name, &temporary_spec);
    if (err == noErr) (void)FSpDelete(&temporary_spec);
    else if (err != fnfErr) {
        snprintf(error, (size_t)error_cap,
                 "could not prepare the temporary dump (%d)", (int)err);
        return 0;
    }
    err = FSpCreate(&temporary_spec, 'NOWo', 'BINA', smSystemScript);
    if (err != noErr) {
        snprintf(error, (size_t)error_cap,
                 "could not create the temporary dump (%d)", (int)err);
        return 0;
    }
    err = FSpOpenDF(&temporary_spec, fsWrPerm, &refnum);
    if (err == noErr) err = SetEOF(refnum, 0);
    while (err == noErr && offset < layout->total_bytes) {
        long count = (long)(layout->total_bytes - offset);
        long written;
        if (count > 64L * 1024L) count = 64L * 1024L;
        written = count;
        err = FSWrite(refnum, &written, rom + offset);
        if (err == noErr && written != count) err = writErr;
        if (err == noErr) offset += (unsigned long)written;
    }
    if (refnum >= 0) (void)FSClose(refnum);
    if (err != noErr) {
        (void)FSpDelete(&temporary_spec);
        snprintf(error, (size_t)error_cap, "the ROM write failed (%d)",
                 (int)err);
        return 0;
    }
    if (destination_exists) {
        err = FSpExchangeFiles(&temporary_spec, &spec);
        if (err == noErr) (void)FSpDelete(&temporary_spec);
    } else {
        err = FSpRename(&temporary_spec, name);
    }
    if (err != noErr) {
        (void)FSpDelete(&temporary_spec);
        snprintf(error, (size_t)error_cap,
                 "could not publish the completed dump (%d)", (int)err);
        return 0;
    }
    snprintf(path, (size_t)path_cap, "%s", kROMDumpName);
    return 1;
}
