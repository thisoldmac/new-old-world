#ifndef NOW_PRODUCT_VERSION_H
#define NOW_PRODUCT_VERSION_H

/* Product release identity, shared by the classic guest and the update
   manifest generator. Host/Xcode and Finder-resource copies are pinned to
   this authority by ProductIdentityTests because those build systems cannot
   consume one C macro directly. Development builds on serial branches may
   share this release version: their deterministic build IDs and artifact
   digests distinguish them. Advance this tuple only for an intentional
   product release; the main-ref gate prevents rollback and stale copies. */
#define NOW_PRODUCT_VERSION_MAJOR 0
#define NOW_PRODUCT_VERSION_MINOR 2
#define NOW_PRODUCT_VERSION_PATCH 0
#define NOW_PRODUCT_VERSION "0.2.0"

#endif
