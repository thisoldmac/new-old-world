#include "capture_store.h"

#include <string.h>

void capture_store_init(CaptureStore *store)
{
    memset(store, 0, sizeof *store);
    store->selected = -1;
}

void capture_store_dispose(CaptureStore *store)
{
    short index;

    for (index = 0; index < store->count; ++index) {
        capture_image_dispose(&store->images[index]);
    }
    capture_store_init(store);
}

void capture_store_append(CaptureStore *store, CaptureImage *image)
{
    if (store->count == kCaptureHistoryCapacity) {
        short index;

        capture_image_dispose(&store->images[0]);
        for (index = 1; index < store->count; ++index) {
            store->images[index - 1] = store->images[index];
        }
        --store->count;
    }
    store->images[store->count] = *image;
    memset(image, 0, sizeof *image);
    store->selected = store->count;
    ++store->count;
}

const CaptureImage *capture_store_current(const CaptureStore *store)
{
    if (store->selected < 0 || store->selected >= store->count) {
        return NULL;
    }
    return &store->images[store->selected];
}

Boolean capture_store_select_previous(CaptureStore *store)
{
    if (store->selected <= 0) {
        return false;
    }
    --store->selected;
    return true;
}

Boolean capture_store_select_next(CaptureStore *store)
{
    if (store->selected < 0 || store->selected + 1 >= store->count) {
        return false;
    }
    ++store->selected;
    return true;
}

