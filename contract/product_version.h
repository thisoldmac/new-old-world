#ifndef NOW_PRODUCT_VERSION_H
#define NOW_PRODUCT_VERSION_H

/* Product release identity, shared by the classic guest and the update
   manifest generator. Host/Xcode and Finder-resource copies are pinned to
   this authority by ProductIdentityTests because those build systems cannot
   consume one C macro directly. A scratch build is distinguished by build
   identity; it does not invent a release version. */
#define NOW_PRODUCT_VERSION_MAJOR 0
#define NOW_PRODUCT_VERSION_MINOR 2
#define NOW_PRODUCT_VERSION_PATCH 0
#define NOW_PRODUCT_VERSION "0.2.0"

#endif
