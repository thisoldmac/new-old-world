#ifndef NOW_DEVELOPMENT_OPEN_H
#define NOW_DEVELOPMENT_OPEN_H

typedef enum DevOpenOutcome {
    kDevOpenAccepted = 0,
    kDevOpenOutcomeUnknown,
    kDevOpenRefused
} DevOpenOutcome;

/* AESend's result and the handler's reply are separate evidence. A timeout
   cannot be rounded to refusal: the server may finish after our deadline. */
DevOpenOutcome dev_open_classify(long send_error, long timeout_error,
                                 int reply_error_present,
                                 long reply_error);

#endif /* NOW_DEVELOPMENT_OPEN_H */
