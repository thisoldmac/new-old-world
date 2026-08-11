#include "development_open.h"

#include <assert.h>

int main(void)
{
    const long timeout = -1712;

    assert(dev_open_classify(0, timeout, 0, 0) == kDevOpenAccepted);
    assert(dev_open_classify(0, timeout, 1, 0) == kDevOpenAccepted);
    assert(dev_open_classify(0, timeout, 1, -1708) == kDevOpenRefused);
    assert(dev_open_classify(-1708, timeout, 0, 0) == kDevOpenRefused);
    assert(dev_open_classify(timeout, timeout, 0, 0)
           == kDevOpenOutcomeUnknown);
    return 0;
}
