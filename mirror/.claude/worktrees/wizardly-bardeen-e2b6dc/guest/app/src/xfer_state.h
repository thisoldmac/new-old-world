#ifndef TIMBOTTU_XFER_STATE_H
#define TIMBOTTU_XFER_STATE_H

#include <stddef.h>

int xfer_state_name(char *out, size_t cap, unsigned long generation, long id);
int xfer_state_parse(const char *name, unsigned long *generation, long *id);

#endif /* TIMBOTTU_XFER_STATE_H */
