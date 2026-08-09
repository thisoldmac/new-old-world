/*
 * axref.h - pointer-free references for classic-Mac UI elements.
 *
 * A ref carries the live process identity plus window/control titles, their
 * duplicate-title occurrences, and an opaque observation fingerprint. It never
 * exposes a pointer or coordinate.
 */
#ifndef TIMBOTTU_AXREF_H
#define TIMBOTTU_AXREF_H

#include <stddef.h>
#include <stdint.h>

#define AX_REF_TITLE_MAX 255
#define AX_REF_MAX       1600

enum {
    AX_REF_OK = 0,
    AX_REF_INVALID = -1,
    AX_REF_OVERFLOW = -2
};

typedef struct {
    uint32_t      serial_hi;
    uint32_t      serial_lo;
    unsigned char window_title[AX_REF_TITLE_MAX + 1];
    size_t        window_title_len;
    unsigned int  window_occurrence;
    unsigned char control_title[AX_REF_TITLE_MAX + 1];
    size_t        control_title_len;
    unsigned int  control_occurrence;
    uint32_t      node_fingerprint;
} ax_ref;

uint32_t ax_ref_node_fingerprint(uint32_t serial_hi, uint32_t serial_lo,
                                 uint32_t window_address,
                                 uint32_t control_handle);
int ax_ref_build(char *out, size_t cap, const ax_ref *ref);
int ax_ref_parse(const char *text, size_t len, ax_ref *out);

#endif /* TIMBOTTU_AXREF_H */
