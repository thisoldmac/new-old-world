#ifndef NOW_WEB_MODEL_H
#define NOW_WEB_MODEL_H

/* Toolbox-free legacy compatibility vocabulary retained for preference
   migration and native formatting tests. Rendering choices now belong to
   the host module; the guest relay sends only method and target. */

enum { kNowWebDefaultPort = 5180 };

typedef enum {
    kNowWebProfileClassilla = 1,
    kNowWebProfileMacWeb,
    kNowWebProfileGeneric68K
} NowWebProfile;

typedef enum {
    kNowWebLensCompatible = 1,
    kNowWebLensReader,
    kNowWebLensAI
} NowWebLens;

NowWebProfile now_web_profile_sanitize(short stored);
NowWebLens now_web_lens_sanitize(short stored);
const char *now_web_profile_name(NowWebProfile profile);
const char *now_web_profile_token(NowWebProfile profile);
const char *now_web_lens_name(NowWebLens lens);
const char *now_web_lens_token(NowWebLens lens);

/* Formats an endpoint and the historical query-shaped start page. Product
   UI uses only now_web_endpoint for the guest-local proxy. */
void now_web_endpoint(const char *host, unsigned short port,
                      char *out, long cap);
void now_web_start_url(const char *host, unsigned short port,
                       NowWebProfile profile, NowWebLens lens,
                       char *out, long cap);

#endif /* NOW_WEB_MODEL_H */
