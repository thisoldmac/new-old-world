#ifndef NOW_DEVELOPMENT_TOOLCHAIN_MAC_H
#define NOW_DEVELOPMENT_TOOLCHAIN_MAC_H

#include <Carbon.h>

#include "development_contract.h"

OSErr dev_toolchain_measure(short vref, long directory,
                            DevToolchain *toolchain);

#endif
