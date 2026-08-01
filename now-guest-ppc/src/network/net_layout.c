#include "net_layout.h"

#include <stdio.h>
#include <string.h>

static void put(char *out, long cap, const char *s)
{
    if (out == NULL || cap <= 0) {
        return;
    }
    out[0] = '\0';
    if (s != NULL) {
        strncpy(out, s, (size_t)(cap - 1));
        out[cap - 1] = '\0';
    }
}

const char *now_net_section_title(NetSection section)
{
    switch (section) {
    case kNetSectionLink:        return "This Connection";
    case kNetSectionInet:        return "TCP/IP";
    case kNetSectionPorts:       return "Ports";
    case kNetSectionConnections: return "Connections";
    case kNetSectionCount:       break;
    }
    return "";
}

const char *now_net_section_blurb(NetSection section)
{
    switch (section) {
    case kNetSectionLink:
        return "The link to the other Mac. Measured here, not asked for.";
    case kNetSectionInet:
        return "How this Mac is addressed on its network.";
    case kNetSectionPorts:
        return "The network hardware this Mac has, and where it sits.";
    case kNetSectionConnections:
        return "What this Mac is talking to.";
    case kNetSectionCount:
        break;
    }
    return "";
}

short now_net_section_rows(NetSection section, const NetFacts *facts)
{
    if (facts == NULL) {
        return 0;
    }
    switch (section) {
    case kNetSectionLink:
        /* Peer, port, uptime, in, out — and resets only when there have
           been some. A row reading "Resets 0" invites a person to wonder
           what reset; its absence says nothing has. */
        if (facts->link.state != kNetFactPresent) {
            return 0;
        }
        return (short)(5 + (facts->link.resets > 0 ? 1 : 0));

    case kNetSectionInet:
        if (facts->inet.state != kNetFactPresent) {
            return 0;
        }
        /* Address, netmask, broadcast are always there once the call
           succeeded. The rest are counted only when present, because
           this page's whole argument is that an absent gateway is a
           fact rather than a zero. */
        return (short)(3
                       + (facts->inet.has_gateway ? 1 : 0)
                       + (facts->inet.has_dns ? 1 : 0)
                       + (facts->inet.has_hw ? 1 : 0)
                       + (facts->inet.has_mtu ? 1 : 0)
                       + (facts->inet.domain[0] != '\0' ? 1 : 0));

    case kNetSectionPorts:
        if (facts->ports_state != kNetFactPresent) {
            return 0;
        }
        return facts->port_count;

    case kNetSectionConnections:
        /* Never any rows. The section is one sentence, permanently, and
           that is the honest shape of it. */
        return 0;

    case kNetSectionCount:
        break;
    }
    return 0;
}

const char *now_net_button_title(NetSection section, const NetFacts *facts)
{
    if (facts == NULL) {
        return NULL;
    }
    switch (section) {
    case kNetSectionInet:
    case kNetSectionPorts:
        /* Only offered when Open Transport is actually there. A Refresh
           button on a Mac with no OT is a control that cannot work, and
           this page refuses to draw one. */
        if (facts->ot == kNetFactNoOT) {
            return NULL;
        }
        return "Refresh";
    case kNetSectionLink:
        /* Ours already and updated as it changes; nothing to ask for. */
        return NULL;
    case kNetSectionConnections:
        /* THE POINT. Nothing can be asked, so nothing is offered. A
           greyed Refresh here would suggest the answer is one retry
           away. */
        return NULL;
    case kNetSectionCount:
        break;
    }
    return NULL;
}

int now_net_row(NetSection section, const NetFacts *facts, short index,
                char *label, long label_cap, char *value, long value_cap)
{
    if (facts == NULL || label == NULL || value == NULL) {
        return 0;
    }
    put(label, label_cap, "");
    put(value, value_cap, "");
    if (index < 0 || index >= now_net_section_rows(section, facts)) {
        return 0;
    }

    if (section == kNetSectionLink) {
        switch (index) {
        case 0:
            put(label, label_cap, "Peer");
            put(value, value_cap, facts->link.peer);
            return 1;
        case 1: {
            char buf[24];
            put(label, label_cap, "Port");
            snprintf(buf, sizeof buf, "%lu", facts->link.port);
            put(value, value_cap, buf);
            return 1;
        }
        case 2: {
            char buf[24];
            put(label, label_cap, "Up");
            now_net_format_uptime(facts->link.up_ticks, buf, (long)sizeof buf);
            put(value, value_cap, buf);
            return 1;
        }
        case 3: {
            char buf[24];
            put(label, label_cap, "Received");
            snprintf(buf, sizeof buf, "%lu bytes", facts->link.bytes_in);
            put(value, value_cap, buf);
            return 1;
        }
        case 4: {
            char buf[24];
            put(label, label_cap, "Sent");
            snprintf(buf, sizeof buf, "%lu bytes", facts->link.bytes_out);
            put(value, value_cap, buf);
            return 1;
        }
        default: {
            char buf[24];
            put(label, label_cap, "Resets");
            snprintf(buf, sizeof buf, "%lu", facts->link.resets);
            put(value, value_cap, buf);
            return 1;
        }
        }
    }

    if (section == kNetSectionInet) {
        short at = 0;
        const NetInterface *in = &facts->inet;

        if (index == at++) {
            put(label, label_cap, "Address");
            put(value, value_cap, in->address);
            return 1;
        }
        if (index == at++) {
            put(label, label_cap, "Subnet mask");
            put(value, value_cap, in->netmask);
            return 1;
        }
        if (index == at++) {
            put(label, label_cap, "Broadcast");
            put(value, value_cap, in->broadcast);
            return 1;
        }
        if (in->has_gateway && index == at++) {
            put(label, label_cap, "Router");
            put(value, value_cap, in->gateway);
            return 1;
        }
        if (in->has_dns && index == at++) {
            put(label, label_cap, "Name server");
            put(value, value_cap, in->dns);
            return 1;
        }
        if (in->has_hw && index == at++) {
            put(label, label_cap, "Hardware address");
            put(value, value_cap, in->hw_address);
            return 1;
        }
        if (in->has_mtu && index == at++) {
            char buf[24];
            put(label, label_cap, "MTU");
            snprintf(buf, sizeof buf, "%lu bytes", in->mtu);
            put(value, value_cap, buf);
            return 1;
        }
        if (in->domain[0] != '\0' && index == at++) {
            put(label, label_cap, "Domain");
            put(value, value_cap, in->domain);
            return 1;
        }
        return 0;
    }

    if (section == kNetSectionPorts) {
        const NetPort *p;

        if (index >= facts->port_count) {
            return 0;
        }
        p = &facts->ports[index];
        put(label, label_cap, p->name[0] != '\0' ? p->name : "(unnamed)");
        /* The slot is what makes a port a piece of HARDWARE rather than
           a name, so it leads the value when there is one. */
        if (p->slot[0] != '\0') {
            char buf[kNetNameMax + 24];
            snprintf(buf, sizeof buf, "%s  slot %s",
                     p->device[0] != '\0' ? p->device : "-", p->slot);
            put(value, value_cap, buf);
        } else {
            put(value, value_cap, p->device[0] != '\0' ? p->device : "-");
        }
        return 1;
    }

    return 0;
}

void now_net_status_text(const NetFacts *facts, char *out, long cap)
{
    if (out == NULL || cap <= 0) {
        return;
    }
    out[0] = '\0';
    if (facts == NULL) {
        return;
    }
    if (facts->ot == kNetFactNoOT) {
        put(out, cap, "Open Transport not available");
        return;
    }
    if (facts->inet.state == kNetFactPresent) {
        char buf[96];
        snprintf(buf, sizeof buf, "%s  ·  %d port%s",
                 facts->inet.address, (int)facts->port_count,
                 facts->port_count == 1 ? "" : "s");
        put(out, cap, buf);
        return;
    }
    if (facts->inet.state == kNetFactRefused) {
        put(out, cap, "TCP/IP is not configured on this Mac");
        return;
    }
    put(out, cap, "Not measured yet");
}

void now_net_layout_compute(const Rect *body, const NetFacts *facts,
                            NetLayout *out)
{
    short y;
    int i;

    if (body == NULL || out == NULL) {
        return;
    }
    memset(out, 0, sizeof *out);

    out->canvas.top = body->top;
    out->canvas.left = body->left;
    out->canvas.bottom = body->bottom;
    out->canvas.right = (short)(body->right - kNetScrollBarWidth);

    out->scrollbar.top = body->top;
    out->scrollbar.left = out->canvas.right;
    out->scrollbar.bottom = body->bottom;
    out->scrollbar.right = body->right;

    y = kNetMargin;
    for (i = 0; i < (int)kNetSectionCount; ++i) {
        NetSectionLayout *s = &out->sections[i];
        short rows = now_net_section_rows((NetSection)i, facts);
        short inner;
        const char *btn = now_net_button_title((NetSection)i, facts);

        /* Title, blurb, then either rows or the one sentence a section
           shows when it has none. Every section has a body: the
           Connections card is nothing BUT a body, and a layout that gave
           it zero height would silently delete the page's most important
           statement. */
        inner = (short)(kNetTitleHeight + kNetLineHeight);
        if (rows > 0) {
            inner = (short)(inner + rows * kNetRowHeight);
        } else {
            inner = (short)(inner + kNetLineHeight * 2);
        }

        s->card.top = y;
        s->card.left = (short)(out->canvas.left + kNetMargin);
        s->card.right = (short)(out->canvas.right - kNetMargin);
        s->card.bottom = (short)(y + inner + kNetCardInset * 2);

        s->title.top = (short)(s->card.top + kNetCardInset);
        s->title.left = (short)(s->card.left + kNetCardInset);
        s->title.right = (short)(s->card.right - kNetCardInset);
        s->title.bottom = (short)(s->title.top + kNetTitleHeight);

        if (btn != NULL) {
            s->button.right = (short)(s->card.right - kNetCardInset);
            s->button.left = (short)(s->button.right - kNetButtonWidth);
            s->button.top = s->title.top;
            s->button.bottom = (short)(s->button.top + kNetButtonHeight);
            /* The title must not run under the button. */
            if (s->title.right > s->button.left - 8) {
                s->title.right = (short)(s->button.left - 8);
            }
        }

        s->body.left = s->title.left;
        s->body.right = (short)(s->card.right - kNetCardInset);
        s->body.top = (short)(s->title.bottom + kNetLineHeight);
        s->body.bottom = (short)(s->card.bottom - kNetCardInset);

        y = (short)(s->card.bottom + kNetSectionGap);
    }
    out->content_height = (short)(y - kNetSectionGap + kNetMargin);
}
