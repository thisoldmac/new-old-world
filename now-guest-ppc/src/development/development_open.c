#include "development_open.h"

DevOpenOutcome dev_open_classify(long send_error, long timeout_error,
                                 int reply_error_present,
                                 long reply_error)
{
    if (send_error == timeout_error) return kDevOpenOutcomeUnknown;
    if (send_error != 0) return kDevOpenRefused;
    if (reply_error_present && reply_error != 0) return kDevOpenRefused;
    return kDevOpenAccepted;
}
