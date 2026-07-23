#!/usr/bin/env python3
"""Generate NOW Software-module preview scenes for platinum-carbonlib.

The Workshop is one window (744x478 content, the real kWorkshopStd*), a
custom rail on the left and the module page on the right. Geometry mirrors
workshop_layout.h; columns are space-padded because the preview font is a
fixed 6px/char uppercase planning font, so char position == pixel column.
"""
import json
import os

OUT = os.path.dirname(os.path.abspath(__file__))

# Content 744x478 (kWorkshopStd*). The renderer wraps it in a 20px title
# bar + 1px borders, so the OUTER window is 746x499; centre on 800x600.
WIN = {"x": 27, "y": 50, "width": 746, "height": 499,
       "title": "New Old World", "active": True}

RAIL_W = 160          # kWorkshopRailWide
HDR_H = 38            # kWorkshopHeaderHeight
STATUS_TOP = 455      # content.bottom(478) - kWorkshopStatusHeight(23)

DB_X, DB_W = 172, 558          # list panel inside the body
DB_Y, DB_H = 84, 304
COL0 = DB_X + 5                # databrowser text origin (x+5)

# Column char offsets -> pixels (6px/char). name<=22, kind 9, size 6.
def col_px(ch):
    return COL0 + ch * 6

def row(name, kind, size, state=""):
    return f"{name[:22]:<22} {kind:<9}  {size:>6}  {state}".rstrip()


def frame(selected_module=5):
    """The Workshop chrome shared by every Software-page state."""
    return [
        # --- the rail (custom-drawn in the app; a list approximates the
        # framed panel + selected-row highlight). Blank row 6 stands in
        # for the 1px divider above the pinned Logs/Connection pair.
        {"id": "rail", "type": "list", "x": 6, "y": 6, "width": 148,
         "height": 466,
         "items": ["Screenshots", "Files", "Console", "Processes",
                   "Hardware", "Software", "", "Logs", "Connection"],
         "selected": selected_module},
        # --- module header placard
        {"id": "title", "type": "label", "x": RAIL_W + 12, "y": 9,
         "text": "Software"},
        {"id": "blurb", "type": "label", "x": RAIL_W + 12, "y": 22,
         "width": 300, "text": "What is installed, and starting it"},
        {"id": "machine", "type": "label", "x": 636, "y": 9,
         "text": "Macintosh HD"},
        {"id": "hdr_rule", "type": "separator", "x": RAIL_W, "y": HDR_H - 1,
         "width": 744 - RAIL_W},
        # --- domain selector (a popup menu in the app; button stands in)
        {"id": "show_lbl", "type": "label", "x": RAIL_W + 16, "y": 52,
         "text": "Show:"},
        # --- column headers (the Data Browser draws these itself, with a
        # sort arrow on Name; labels approximate them)
        {"id": "h_name", "type": "label", "x": col_px(0), "y": 72,
         "text": "Name"},
        {"id": "h_kind", "type": "label", "x": col_px(23), "y": 72,
         "text": "Kind"},
        {"id": "h_size", "type": "label", "x": col_px(34), "y": 72,
         "text": "Size"},
        {"id": "h_state", "type": "label", "x": col_px(42), "y": 72,
         "text": "State"},
        # --- bottom status placard rule
        {"id": "status_rule", "type": "separator", "x": 0, "y": STATUS_TOP,
         "width": 744},
    ]


def popup(text):
    return {"id": "domain", "type": "button", "x": RAIL_W + 52, "y": 47,
            "width": 168, "height": 20, "text": text}


def detail(text):
    return {"id": "detail", "type": "label", "x": RAIL_W + 16, "y": 396,
            "width": 552, "text": text}


def status(text):
    return {"id": "status", "type": "label", "x": RAIL_W + 16, "y": 461,
            "width": 540, "text": text}


def buttons(launch=True, front=True, quit_=True, launch_default=True,
            rescan="Rescan"):
    y = 420
    return [
        {"id": "launch", "type": "button", "x": RAIL_W + 16, "y": y,
         "width": 84, "height": 22, "text": "Launch",
         "default": launch_default, "disabled": not launch},
        {"id": "front", "type": "button", "x": RAIL_W + 108, "y": y,
         "width": 118, "height": 22, "text": "Bring to Front",
         "default": front and not launch_default, "disabled": not front},
        {"id": "quit", "type": "button", "x": RAIL_W + 234, "y": y,
         "width": 64, "height": 22, "text": "Quit", "disabled": not quit_},
        {"id": "rescan", "type": "button", "x": 652, "y": y,
         "width": 84, "height": 22, "text": rescan},
    ]


def browser(items, selected=None):
    c = {"id": "list", "type": "databrowser", "x": DB_X, "y": DB_Y,
         "width": DB_W, "height": DB_H, "items": items}
    if selected is not None:
        c["selected"] = selected
    return c


def scene(name, components):
    return {
        "target": "platinum-carbonlib",
        "screen": {"width": 800, "height": 600, "depth": 8},
        "application": "New Old World",
        "window": WIN,
        "components": frame() + components,
        "assets": [],
        "_name": name,
    }


APPS = [
    row("SimpleText", "APPL/ttxt", "92K", "running"),
    row("SimpleText", "APPL/ttxt", "1.1M"),
    row("Adobe Photoshop 5.0", "APPL/8BIM", "4.2M"),
    row("Sherlock 2", "APPL/fndf", "412K"),
    row("Microsoft Word", "APPL/MSWD", "5.1M", "running"),
    row("Stickies", "APPL/notz", "103K"),
    row("QuickTime Player", "APPL/TVOD", "1.0M"),
    row("Adobe Illustrator 8", "APPL/ART5", "3.0M"),
    row("Norton Utilities", "APPL/NU55", "2.4M"),
    row("Netscape Communica.", "APPL/MOSS", "10M"),
    row("Disk Copy", "APPL/dCpy", "620K"),
]

EXTS = [
    row("Apple CD/DVD Driver", "INIT/dcdr", "116K"),
    row("CarbonLib", "INIT/cbon", "3.9M"),
    row("Contextual Menu Ext", "INIT/cmnu", "74K"),
    row("Control Strip Ext", "cdev/sdev", "76K", "running"),
    row("QuickTime", "INIT/tvod", "1.8M"),
    row("Speed Doubler", "INIT/SDbl", "212K", "off"),
    row("RAM Doubler", "INIT/rmdr", "180K", "off"),
    row("After Dark", "INIT/adrk", "420K", "off"),
    row("OpenGL Engine", "shlb/ogl3", "1.2M"),
    row("Text Encoding Conv.", "INIT/encv", "560K"),
]

# --- A: hero, Applications populated, a NOT-running app selected ---------
scenes = []
scenes.append(scene("A_apps_populated", [
    popup("Applications"),
    browser(APPS, selected=2),          # Adobe Photoshop 5.0 (not running)
    detail("Adobe Photoshop 5.0   v5.0   "
           "Macintosh HD:Applications:Adobe Photoshop 5.0"),
    *buttons(launch=True, front=False, quit_=False, launch_default=True),
    status("214 applications on Macintosh HD"),
]))

# --- B: Applications sweeping in progress -------------------------------
scenes.append(scene("B_apps_sweeping", [
    popup("Applications"),
    browser(APPS[:6] + ["..."], selected=None),
    detail("Select an item to see its version and path"),
    *buttons(launch=False, front=False, quit_=False, launch_default=True,
             rescan="Stop"),
    status("Indexing Macintosh HD - 96 applications so far..."),
]))

# --- C: duplicate / version disambiguation (the running dup selected) ---
scenes.append(scene("C_duplicates", [
    popup("Applications"),
    browser(APPS, selected=1),          # the 1.1M SimpleText copy
    detail("SimpleText   v1.0.3   "
           "Macintosh HD:Utilities:Old:SimpleText   (running: no)"),
    # running=no here; the row-0 copy is the running one. Buttons: this
    # copy is not running -> Launch this exact copy.
    *buttons(launch=True, front=False, quit_=False, launch_default=True),
    status("2 copies of SimpleText - the detail line tells them apart"),
]))

# --- D: Extensions listing with disabled + running ----------------------
scenes.append(scene("D_extensions", [
    popup("Extensions"),
    browser(EXTS, selected=3),          # Control Strip (running)
    detail("Control Strip Extension   v2.0.4   "
           "System Folder:Extensions:Control Strip Extension"),
    # An extension is not "launched"; only a running one can be fronted/quit.
    *buttons(launch=False, front=True, quit_=True, launch_default=False),
    status("139 extensions - 3 disabled (off)"),
]))

for s in scenes:
    name = s.pop("_name")
    path = os.path.join(OUT, f"software_{name}.json")
    with open(path, "w") as f:
        json.dump(s, f, indent=2)
    print(path)
