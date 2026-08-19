#include <Gestalt.h>
#include <MacTypes.h>
#include <stdio.h>

typedef struct ProbeSelector {
    const char *name;
    OSType selector;
} ProbeSelector;

static void report_selector(const ProbeSelector *probe)
{
    SInt32 response = 0;
    OSErr error = Gestalt(probe->selector, &response);

    if (error == noErr) {
        printf("selector name=%s error=0 value=0x%08lx\n",
               probe->name,
               (unsigned long)response);
    } else {
        printf("selector name=%s error=%d value=unavailable\n",
               probe->name,
               (int)error);
    }
}

int main(void)
{
    static const ProbeSelector probes[] = {
        { "system-version", gestaltSystemVersion },
        { "carbon-version", gestaltCarbonVersion },
        { "file-system-attributes", gestaltFSAttr },
        { "resource-manager-attributes", gestaltResourceMgrAttr },
        { "thread-manager-attributes", gestaltThreadMgrAttr }
    };
    unsigned long index;

    printf("C9PROBE version=1 selectors=%lu\n",
           (unsigned long)(sizeof(probes) / sizeof(probes[0])));
    for (index = 0; index < (sizeof(probes) / sizeof(probes[0])); ++index) {
        report_selector(&probes[index]);
    }
    printf("C9PROBE end=1\n");
    return 0;
}
