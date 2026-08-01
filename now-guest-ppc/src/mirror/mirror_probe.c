#include "mirror_probe.h"

#include <Carbon.h>

#include <stdio.h>
#include <string.h>

#include "proc_actions.h"

/* Each resident publishes ONE thing: the address of a block in the system
   heap, under a Gestalt selector spelled the same as the block's own
   magic. Read the selector, read the magic back out of the block, and the
   answer is either "a Mirror resident of version N is loaded" or nothing.

   THE VALUES BELOW ARE READ FROM MIRROR'S HEADERS, NOT COPIED FROM THEM:

     AXPeek   mirror/guest/extensions/axpeek/src/axshared.h
              AX_GESTALT/AX_MAGIC 'TBax', AX_VERSION 4.
              AXShared begins magic, version, seq, ...
     QDPeek   mirror/guest/extensions/qdpeek/src/qdshared.h
              QD_GESTALT/QD_MAGIC 'TBqd', QD_VERSION 1.
              QDShared begins magic, version, seq, ...
     Portal   mirror/guest/extensions/portal/src/ptshared.h
              PT_GESTALT/PT_MAGIC 'TBpt', PT_VERSION 4.
              PTShared begins SEQ, magic, version - the seqlock comes
              first in this one and not in the other two, which is
              exactly the sort of difference a second copy of the header
              would eventually get wrong.

   Only the first two or three longs are touched, so this reads no field
   whose layout could move under it, and it never writes. Mirror's block
   is Mirror's. */
typedef struct {
    unsigned long selector;
    unsigned long magic;
    short magic_at;            /* index into the block, counted in longs */
    short version_at;
    unsigned long known;       /* the version Mirror ships today */
} MirrorExtSpec;

static const MirrorExtSpec k_ext[kMirrorExtCount] = {
    { 0x54426178UL, 0x54426178UL, 0, 1, 4UL },   /* 'TBax' */
    { 0x54427164UL, 0x54427164UL, 0, 1, 1UL },   /* 'TBqd' */
    { 0x54427074UL, 0x54427074UL, 1, 2, 4UL }    /* 'TBpt' */
};

/* Where Mirror's own tools stage the agent: mirror/tools/stage-agent.py
   writes it to "Macintosh HD:TimBotTu:mirror-dev:mirror-agent". The
   volume is resolved as the BOOT disk rather than taken from that string,
   because "Macintosh HD" is one machine's disk name and this application
   also runs on Macs whose disk is called something else. */
static const char *k_dev_folder = "TimBotTu";
static const char *k_agent_folder = "mirror-dev";
static const char *k_agent_file = "mirror-agent";

/* Resolved once per probe and reused by the poll, which may not do file
   I/O. Empty until a probe has run. */
static FSSpec g_spec;
static Boolean g_have_spec;
static char g_path[kMirrorPathMax];

static void p2c(ConstStr255Param p, char *out, long cap)
{
    long n = p[0];

    if (n > cap - 1) {
        n = cap - 1;
    }
    memcpy(out, p + 1, (size_t)n);
    out[n] = '\0';
}

/* --- extensions ------------------------------------------------------ */

static void probe_extension(int i, MirrorFacts *facts)
{
    const MirrorExtSpec *spec = &k_ext[i];
    const unsigned long *block;
    long response = 0;

    facts->ext_state[i] = kMirrorExtAbsent;
    facts->ext_version[i] = 0;

    /* A Gestalt failure IS the answer, and the truthful one: an extension
       that did not load publishes nothing, and an extension that is not
       installed did not load. The page's own words separate the two
       causes, because this call cannot. */
    if (Gestalt((OSType)spec->selector, &response) != noErr
        || response == 0) {
        return;
    }
    block = (const unsigned long *)response;
    if (block[spec->magic_at] != spec->magic) {
        /* The selector is answering with something that is not the block
           it names. Not ours to interpret, and not a version question. */
        return;
    }
    facts->ext_version[i] = block[spec->version_at];
    facts->ext_state[i] = facts->ext_version[i] == spec->known
                              ? kMirrorExtResident
                              : kMirrorExtOtherVersion;
}

/* --- where the agent lives ------------------------------------------- */

/* The directory called `name` inside `dir`, by ID. PBGetCatInfo with
   ioFDirIndex 0 looks a name up in ioDrDirID and answers with that item's
   own ID - the documented way to walk a path one segment at a time, and
   preferable here to handing FSMakeFSSpec a partial pathname, whose
   colon rules are the kind of thing that is right on the machine or not
   at all. */
static Boolean dir_child(short vref, long dir, const char *name, long *out)
{
    CInfoPBRec pb;
    Str255 pname;

    CopyCStringToPascal(name, pname);
    memset(&pb, 0, sizeof pb);
    pb.dirInfo.ioNamePtr = pname;
    pb.dirInfo.ioVRefNum = vref;
    pb.dirInfo.ioDrDirID = dir;
    pb.dirInfo.ioFDirIndex = 0;
    if (PBGetCatInfoSync(&pb) != noErr) {
        return false;
    }
    if ((pb.hFileInfo.ioFlAttrib & ioDirMask) == 0) {
        return false;                 /* a file by that name, not a folder */
    }
    *out = pb.dirInfo.ioDrDirID;
    return true;
}

static void volume_name(short vref, char *out, long cap)
{
    HParamBlockRec pb;
    Str63 name;

    name[0] = 0;
    memset(&pb, 0, sizeof pb);
    pb.volumeParam.ioNamePtr = name;
    pb.volumeParam.ioVRefNum = vref;
    pb.volumeParam.ioVolIndex = 0;    /* by ioVRefNum, not by index */
    if (PBHGetVInfoSync(&pb) != noErr) {
        name[0] = 0;
    }
    p2c(name, out, cap);
}

/* Resolves g_spec and g_path. The PATH is written whether or not the file
   is there: "we looked here and found nothing" is the useful half of a
   missing agent, and a page that omits the location leaves the person
   guessing which of several checkouts it meant. */
static void resolve_agent(void)
{
    short vref;
    long sysdir;
    long devdir;
    long agentdir;
    char vol[64];

    g_have_spec = false;
    g_path[0] = '\0';

    if (FindFolder(kOnSystemDisk, kSystemFolderType, kDontCreateFolder,
                   &vref, &sysdir) != noErr) {
        return;
    }
    volume_name(vref, vol, (long)sizeof vol);
    snprintf(g_path, sizeof g_path, "%.31s:%s:%s:%s", vol, k_dev_folder,
             k_agent_folder, k_agent_file);

    if (!dir_child(vref, fsRtDirID, k_dev_folder, &devdir)
        || !dir_child(vref, devdir, k_agent_folder, &agentdir)) {
        return;
    }
    {
        Str255 leaf;

        CopyCStringToPascal(k_agent_file, leaf);
        if (FSMakeFSSpec(vref, agentdir, leaf, &g_spec) != noErr) {
            return;
        }
    }
    g_have_spec = true;
}

/* --- is it running --------------------------------------------------- */

/* One file, two names for it, and the answer must be the same either way:
   the Process Manager reports the application's own FSSpec, so identity
   here is volume, parent directory and name - the file itself.

   It is NOT the creator signature, and that is a finding rather than a
   shortcut. Mirror's agent is built by Retro68 with no creator override,
   so it carries the default '????' (verified in the MacBinary header of
   mirror/guest/app/build/mirror-agent.bin). Every other Retro68 build on
   the machine carries the same one, including the lab's own workers - so
   a signature match would report "the Mirror agent is running" about
   whatever else happened to be. The signature is still read and shown,
   because it is a fact worth seeing beside the row. */
static Boolean same_file(const FSSpec *a, const FSSpec *b)
{
    return (Boolean)(a->vRefNum == b->vRefNum && a->parID == b->parID
                     && EqualString(a->name, b->name, false, true));
}

static void signature_text(OSType sig, char *out, long cap)
{
    unsigned char raw[4];
    int i;

    if (cap < 5) {
        if (cap > 0) {
            out[0] = '\0';
        }
        return;
    }
    memcpy(raw, &sig, sizeof raw);
    for (i = 0; i < 4; ++i) {
        /* A creator is four bytes, not four characters; anything outside
           printable ASCII is shown as a dot rather than sent to
           DrawString, which would draw whatever MacRoman makes of it. */
        out[i] = (raw[i] >= 0x20 && raw[i] < 0x7F) ? (char)raw[i] : '.';
    }
    out[4] = '\0';
}

static Boolean find_agent(ProcessSerialNumber *psn, char *sig, long sig_cap)
{
    ProcessSerialNumber walk;
    ProcessInfoRec info;
    FSSpec spec;
    Str31 name;

    if (!g_have_spec) {
        return false;
    }
    walk.highLongOfPSN = 0;
    walk.lowLongOfPSN = kNoProcess;
    while (GetNextProcess(&walk) == noErr) {
        memset(&info, 0, sizeof info);
        info.processInfoLength = sizeof info;
        info.processName = name;
        info.processAppSpec = &spec;
        if (GetProcessInformation(&walk, &info) != noErr) {
            continue;                 /* it went away mid-walk */
        }
        if (!same_file(&spec, &g_spec)) {
            continue;
        }
        if (psn != NULL) {
            *psn = walk;
        }
        if (sig != NULL) {
            signature_text(info.processSignature, sig, sig_cap);
        }
        return true;
    }
    return false;
}

/* --- the published calls --------------------------------------------- */

void now_mirror_poll_agent(MirrorFacts *facts)
{
    facts->agent_sig[0] = '\0';
    if (!g_have_spec) {
        facts->agent = kMirrorAgentNoFile;
        return;
    }
    facts->agent = find_agent(NULL, facts->agent_sig,
                              (long)sizeof facts->agent_sig)
                       ? kMirrorAgentRunning
                       : kMirrorAgentStopped;
}

void now_mirror_probe(MirrorFacts *facts)
{
    int i;

    for (i = 0; i < kMirrorExtCount; ++i) {
        probe_extension(i, facts);
    }
    resolve_agent();
    strncpy(facts->agent_path, g_path, sizeof facts->agent_path - 1);
    facts->agent_path[sizeof facts->agent_path - 1] = '\0';
    now_mirror_poll_agent(facts);
}

void now_mirror_agent_start(MirrorFacts *facts)
{
    LaunchParamBlockRec lp;
    OSErr err;

    /* Re-resolve rather than trust the last probe: the usual way an agent
       arrives on a machine is somebody staging it while this is running,
       and refusing to look again would make "Enable" dead until relaunch. */
    now_mirror_probe(facts);
    if (facts->agent == kMirrorAgentRunning) {
        snprintf(facts->note, sizeof facts->note,
                 "The Mirror agent is already running.");
        return;
    }
    if (!g_have_spec) {
        snprintf(facts->note, sizeof facts->note,
                 "There is no agent at %.100s. Mirror's own tools put it "
                 "there; NOW does not install it.", g_path);
        return;
    }

    memset(&lp, 0, sizeof lp);
    lp.launchBlockID = extendedBlock;
    lp.launchEPBLength = extendedBlockLen;
    lp.launchControlFlags = launchContinue | launchNoFileFlags;
    lp.launchAppSpec = (FSSpecPtr)&g_spec;
    err = LaunchApplication(&lp);
    if (err == memFullErr) {
        snprintf(facts->note, sizeof facts->note,
                 "Not enough free memory to start the Mirror agent. Quit "
                 "something and try again.");
        return;
    }
    if (err != noErr) {
        snprintf(facts->note, sizeof facts->note,
                 "The Mirror agent would not start: LaunchApplication "
                 "reported error %d.", err);
        return;
    }

    /* noErr says the Process Manager accepted it, which is not the same
       as a process existing. Ask, and say which one we got. */
    now_mirror_poll_agent(facts);
    if (facts->agent == kMirrorAgentRunning) {
        snprintf(facts->note, sizeof facts->note,
                 "Started the Mirror agent. It has no windows and no menus "
                 "- it runs behind everything.");
    } else {
        snprintf(facts->note, sizeof facts->note,
                 "The Mac accepted the launch, but no such process is "
                 "running. The agent quit at once, or it is not the "
                 "application it appears to be.");
    }
}

void now_mirror_agent_stop(MirrorFacts *facts)
{
    ProcessSerialNumber psn;
    OSErr err;

    if (!find_agent(&psn, NULL, 0)) {
        now_mirror_poll_agent(facts);
        snprintf(facts->note, sizeof facts->note,
                 "The Mirror agent is not running.");
        return;
    }
    err = now_proc_ask_quit(&psn);
    if (err != noErr) {
        snprintf(facts->note, sizeof facts->note,
                 "The Mac would not deliver a quit request to the Mirror "
                 "agent: error %d.", err);
        return;
    }
    /* Deliberately not "stopped". The event is queued; the agent quits
       when the Process Manager next schedules it, and only the next poll
       can say whether it did. Claiming the outcome here is how a page
       ends up disagreeing with the machine it is describing. */
    snprintf(facts->note, sizeof facts->note,
             "Asked the Mirror agent to quit. This page says so when it "
             "has.");
}
