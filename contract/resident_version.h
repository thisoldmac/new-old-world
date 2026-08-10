#ifndef NOW_RESIDENT_VERSION_H
#define NOW_RESIDENT_VERSION_H

/* The NOW Extension's release identity, stated once for every face that
   reports it. This is deliberately separate from the application version:
   the resident and application can be deployed independently.

   Every resident source change advances this tuple. tools/ext-bake-gate
   enforces that at commit time and again when refs/heads/main moves, so a
   newly baked resident cannot keep presenting an older release identity. */
#define NOW_RESIDENT_VERSION_MAJOR 1
#define NOW_RESIDENT_VERSION_MINOR 1

#define NOW_RESIDENT_STRINGIFY_INNER(value) #value
#define NOW_RESIDENT_STRINGIFY(value) NOW_RESIDENT_STRINGIFY_INNER(value)
#define NOW_RESIDENT_VERSION_STRING                                      \
    NOW_RESIDENT_STRINGIFY(NOW_RESIDENT_VERSION_MAJOR) "."              \
    NOW_RESIDENT_STRINGIFY(NOW_RESIDENT_VERSION_MINOR)

#endif /* NOW_RESIDENT_VERSION_H */
