#ifndef NOW_WEB_MODEL_H
#define NOW_WEB_MODEL_H

/* Toolbox-free vocabulary behind the Web page. The page, preferences and
   eventual relay all use these values; keeping them here prevents the UI
   from becoming a second interpretation of stored numeric settings. */

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

/* Formats the direct host listener and its start page. These never say
   localhost: classic Mac TCP stacks have not established that topology.
   The caller supplies the same host used by NOW's Connection page. */
void now_web_endpoint(const char *host, unsigned short port,
                      char *out, long cap);
void now_web_start_url(const char *host, unsigned short port,
                       NowWebProfile profile, NowWebLens lens,
                       char *out, long cap);

#endif /* NOW_WEB_MODEL_H */
