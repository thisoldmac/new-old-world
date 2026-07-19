#ifndef SCREENSHOTS_CAPTURE_STORE_H
#define SCREENSHOTS_CAPTURE_STORE_H

#include "capture.h"

enum { kCaptureHistoryCapacity = 12 };

typedef struct {
    CaptureImage images[kCaptureHistoryCapacity];
    short count;
    short selected;
} CaptureStore;

void capture_store_init(CaptureStore *store);
void capture_store_dispose(CaptureStore *store);
void capture_store_append(CaptureStore *store, CaptureImage *image);
const CaptureImage *capture_store_current(const CaptureStore *store);
Boolean capture_store_select_previous(CaptureStore *store);
Boolean capture_store_select_next(CaptureStore *store);

#endif

