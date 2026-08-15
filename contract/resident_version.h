#ifndef NOW_RESIDENT_VERSION_H
#define NOW_RESIDENT_VERSION_H

/* The NOW Extension's release identity, stated once for every face that
   reports it. This is deliberately separate from the application version:
   the resident and application can be deployed independently.

   Development resident builds may share this tuple and are distinguished by
   deterministic build identity. Advance it only for an intentional resident
   release. tools/ext-bake-gate prevents rollback and still requires the exact
   combined resident source to be baked before refs/heads/main moves. */
#define NOW_RESIDENT_VERSION_MAJOR 1
#define NOW_RESIDENT_VERSION_MINOR 3

#define NOW_RESIDENT_STRINGIFY_INNER(value) #value
#define NOW_RESIDENT_STRINGIFY(value) NOW_RESIDENT_STRINGIFY_INNER(value)
#define NOW_RESIDENT_VERSION_STRING                                      \
    NOW_RESIDENT_STRINGIFY(NOW_RESIDENT_VERSION_MAJOR) "."              \
    NOW_RESIDENT_STRINGIFY(NOW_RESIDENT_VERSION_MINOR)

#endif /* NOW_RESIDENT_VERSION_H */
