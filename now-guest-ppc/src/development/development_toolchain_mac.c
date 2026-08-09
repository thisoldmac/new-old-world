#include "development_toolchain_mac.h"

#include <stdio.h>
#include <string.h>

static OSErr child_directory(short vref, long parent,
                             ConstStr255Param name, long *directory)
{
    CInfoPBRec info;
    OSErr err;

    memset(&info, 0, sizeof info);
    info.dirInfo.ioNamePtr = (StringPtr)name;
    info.dirInfo.ioVRefNum = vref;
    info.dirInfo.ioFDirIndex = 0;
    info.dirInfo.ioDrDirID = parent;
    err = PBGetCatInfoSync(&info);
    if (err == noErr && !(info.dirInfo.ioFlAttrib & ioDirMask)) {
        err = dirNFErr;
    }
    if (err == noErr) *directory = info.dirInfo.ioDrDirID;
    return err;
}

static int child_file_exists(short vref, long parent,
                             ConstStr255Param name)
{
    FSSpec spec;
    return FSMakeFSSpec(vref, parent, name, &spec) == noErr;
}

OSErr dev_toolchain_measure(short vref, long directory,
                            DevToolchain *toolchain)
{
    long tools = 0;
    OSErr tools_err;

    if (toolchain == NULL || vref == 0 || directory == 0) return paramErr;
    memset(toolchain, 0, sizeof *toolchain);
    snprintf(toolchain->id, sizeof toolchain->id, "mpw-%04x-%08lx",
             (unsigned short)vref, (unsigned long)directory);
    strcpy(toolchain->version, "structural-1");
    toolchain->toolserver_found = child_file_exists(
        vref, directory, (ConstStr255Param)"\pToolServer");
    tools_err = child_directory(vref, directory,
        (ConstStr255Param)"\pTools", &tools);
    toolchain->compiler_found = tools_err == noErr && child_file_exists(
        vref, tools, (ConstStr255Param)"\pMrC");
    dev_toolchain_qualify(toolchain);
    return toolchain->state == kDevToolchainQualified ? noErr : fnfErr;
}
