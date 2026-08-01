/* Probe: does this Retro68 toolchain's Carbon.h declare, and accept a
   real call to, the Data Browser CONTAINER surface (as opposed to the
   flat kDataBrowserListView surface already proven on the PB1400c,
   spikes/databrowser)? Compile-only (-c): proves declaration and call
   signature, nothing about what the real machine's CarbonLib exports.
   See docs/local/drive-tree-probe.md for the reasoning this feeds. */

#include <Carbon.h>

static OSStatus probe_item_data(ControlRef browser, DataBrowserItemID item,
                                DataBrowserPropertyID property,
                                DataBrowserItemDataRef data,
                                Boolean changeValue)
{
    (void)browser;
    (void)item;
    (void)data;
    if (changeValue) {
        return errDataBrowserPropertyNotSupported;
    }
    switch (property) {
    case kDataBrowserItemIsContainerProperty:
    case kDataBrowserContainerIsOpenableProperty:
    case kDataBrowserContainerIsClosableProperty:
    case kDataBrowserContainerIsSortableProperty:
        /* A real implementation calls SetDataBrowserItemDataBooleanValue
           here; the probe only needs the property IDs to exist and
           the switch to compile. */
        return noErr;
    default:
        return errDataBrowserPropertyNotSupported;
    }
}

static void probe_item_notify(ControlRef browser, DataBrowserItemID item,
                              DataBrowserItemNotification message)
{
    (void)browser;
    (void)item;
    switch (message) {
    case kDataBrowserContainerOpened:
    case kDataBrowserContainerClosing:
    case kDataBrowserContainerClosed:
        /* A real implementation would lazily fetch children here on
           Opened — the tree's equivalent of drive_request(). */
        break;
    default:
        break;
    }
}

void probe_container_calls(ControlRef browser, WindowRef owner)
{
    DataBrowserItemDataUPP data_upp;
    DataBrowserItemNotificationUPP notify_upp;
    DataBrowserItemID root_container = 1;
    DataBrowserItemID child_ids[2];
    OSStatus err;

    (void)owner;

    /* Same real-UPP discipline as files_browser_view.c: a UPP is a
       routine descriptor on this CFM runtime, never a cast. */
    data_upp = NewDataBrowserItemDataUPP(probe_item_data);
    notify_upp = NewDataBrowserItemNotificationUPP(probe_item_notify);
    if (data_upp == NULL || notify_upp == NULL) {
        if (data_upp != NULL) {
            DisposeDataBrowserItemDataUPP(data_upp);
        }
        if (notify_upp != NULL) {
            DisposeDataBrowserItemNotificationUPP(notify_upp);
        }
        return;
    }

    child_ids[0] = 2;
    child_ids[1] = 3;

    /* AddDataBrowserItems with a CONTAINER parent, not kDataBrowserNoItem
       — this is the call spikes/databrowser never made; every call it
       proved used kDataBrowserNoItem as the parent. */
    err = AddDataBrowserItems(browser, root_container, 2, child_ids,
                              kDataBrowserItemNoProperty);
    (void)err;

    /* The disclosure-triangle column, and the open/close container
       calls — none of these appear in spikes/databrowser's 22-symbol
       list either. */
    err = SetDataBrowserListViewDisclosureColumn(browser, 'titl', true);
    (void)err;
    err = OpenDataBrowserContainer(browser, root_container);
    (void)err;
    err = CloseDataBrowserContainer(browser, root_container);
    (void)err;

    DisposeDataBrowserItemDataUPP(data_upp);
    DisposeDataBrowserItemNotificationUPP(notify_upp);
}
