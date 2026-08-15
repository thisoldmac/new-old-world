#ifndef NOW_WORKSHOP_MODULE_H
#define NOW_WORKSHOP_MODULE_H

#include <Carbon.h>
#include "product_features.generated.h"
#include "workshop_module_ids.h"
#include "workshop_scene.h"

/* The contract between the Workshop window and the modules that live
   inside it. The Workshop owns the WindowRef, the placards, and event
   routing; a module owns only its child controls, its drawing state,
   and its callbacks. Modules are created lazily on first selection and
   then hidden rather than disposed, so switching away never loses
   Console history, a file listing, or capture settings. */


typedef struct WorkshopModuleOps {
    OSErr (*create)(WindowRef owner, const Rect *body);
    void (*dispose)(void);
    void (*show)(Boolean visible);
    void (*layout)(const Rect *body);
    void (*draw)(void);
    Boolean (*click)(const EventRecord *event, Point local);
    Boolean (*key)(const EventRecord *event);
    void (*activate)(Boolean active);
    void (*idle)(void);
    /* One line for the bottom status placard. Optional; the Workshop
       falls back to a quiet default. */
    void (*status_text)(char *out, long cap);
    /* Semantic content the module draws by hand. Optional; child controls
       remain Control Manager facts and must not be repeated here. */
    void (*describe_scene)(const WorkshopSceneWriter *writer);
    /* "What is selected on me, as plain text." Answers Edit>Copy, which
       is greyed on a page that leaves this NULL - honest, because a page
       with nothing worth handing someone should not pretend otherwise.

       The MODULE answers, not a focused field: this window has no
       keyboard-focus machinery, so "the selection" is whatever the page
       itself decides is worth copying, which for most pages is the whole
       page as text.

       Contract: write at most `cap - 1` bytes plus a terminator into the
       CALLER's buffer and return the length written (0 = nothing to
       copy, which the Workshop treats as a refusal and leaves the scrap
       alone). The buffer is the caller's so a page never has to own one,
       and length-capped so a page with a long scrollback cannot decide
       how much memory this costs.

       Deliberate: that signature is also a wire payload. A future
       cross-device copy - this Mac's selection landing on the other
       Mac's clipboard - reads exactly this, so a page implementing it
       for the local scrap has already served the wire half. Text only;
       no PICT, no styles, no flavor negotiation. */
    long (*copy_text)(char *out, long cap);
} WorkshopModuleOps;

typedef enum {
    kWorkshopModuleTierCore = 1,
    kWorkshopModuleTierExperimental = 2,
    kWorkshopModuleTierDebug = 3
} WorkshopModuleTier;

typedef const WorkshopModuleOps *(*WorkshopModuleOpsFactory)(void);
typedef const struct WorkshopModuleDefinition
    *(*WorkshopModuleDefinitionFactory)(void);

/* One statically linked module definition. Placement remains the person's
   rail order; maturity, future domain grouping and product admission are
   independent metadata. A definition owns all copy and construction wiring
   needed to add the page to the Workshop. */
typedef struct WorkshopModuleDefinition {
    WorkshopModuleID page_id;
    const char *stable_id;
    const char *title;
    const char *blurb;
    const char *pending;
    const char *sidebar_subtitle;
    short icon_id;
    WorkshopModuleTier tier;
    const char *const *domains;
    short domain_count;
    Boolean has_feature;
    NowProductFeatureID feature_id;
    WorkshopModuleOpsFactory ops_factory;
} WorkshopModuleDefinition;

/* Runtime state is paired with its definition in one slot. The definition
   and ops pointers are established together at window construction; created
   becomes true only after the transaction in workshop_construct succeeds. */
typedef struct WorkshopModuleInstance {
    const WorkshopModuleDefinition *definition;
    const WorkshopModuleOps *ops;
    Boolean admitted;
    const char *unavailable_reason;
    int created;
} WorkshopModuleInstance;

#endif /* NOW_WORKSHOP_MODULE_H */
