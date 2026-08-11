#include "web_model.h"

#include <stdio.h>

NowWebProfile now_web_profile_sanitize(short stored)
{
    if (stored >= kNowWebProfileClassilla
        && stored <= kNowWebProfileGeneric68K) {
        return (NowWebProfile)stored;
    }
    return kNowWebProfileClassilla;
}

NowWebLens now_web_lens_sanitize(short stored)
{
    if (stored >= kNowWebLensCompatible && stored <= kNowWebLensAI) {
        return (NowWebLens)stored;
    }
    return kNowWebLensCompatible;
}

const char *now_web_profile_name(NowWebProfile profile)
{
    switch (now_web_profile_sanitize((short)profile)) {
    case kNowWebProfileMacWeb: return "MacWeb";
    case kNowWebProfileGeneric68K: return "Generic 68K";
    default: return "Classilla";
    }
}

const char *now_web_profile_token(NowWebProfile profile)
{
    switch (now_web_profile_sanitize((short)profile)) {
    case kNowWebProfileMacWeb: return "macweb";
    case kNowWebProfileGeneric68K: return "generic68k";
    default: return "classilla";
    }
}

const char *now_web_lens_name(NowWebLens lens)
{
    switch (now_web_lens_sanitize((short)lens)) {
    case kNowWebLensReader: return "Reader";
    case kNowWebLensAI: return "AI Layout";
    default: return "Compatible Page";
    }
}

const char *now_web_lens_token(NowWebLens lens)
{
    switch (now_web_lens_sanitize((short)lens)) {
    case kNowWebLensReader: return "reader";
    case kNowWebLensAI: return "ai";
    default: return "compatible";
    }
}

void now_web_endpoint(const char *host, unsigned short port,
                      char *out, long cap)
{
    if (out == NULL || cap <= 0) return;
    if (host == NULL) host = "";
    snprintf(out, (size_t)cap, "%s:%u", host, port);
}

void now_web_start_url(const char *host, unsigned short port,
                       NowWebProfile profile, NowWebLens lens,
                       char *out, long cap)
{
    if (out == NULL || cap <= 0) return;
    if (host == NULL) host = "";
    snprintf(out, (size_t)cap,
             "http://%s:%u/?profile=%s&lens=%s", host, port,
             now_web_profile_token(profile), now_web_lens_token(lens));
}
