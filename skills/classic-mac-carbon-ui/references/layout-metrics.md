# Mac OS 8 Layout Metrics

These values are transcribed from the diagrams in Apple's 1997 *Mac OS 8 Human Interface Guidelines*. They are resource and mockup baselines for the Platinum UI. Preserve theme-provided natural sizes when an API supplies them.

## Global Rhythm and Type

| Element | Metric |
|---|---:|
| Minimum between clickable items | 4 px |
| Preferred clearance for focus rings | 6 px |
| Item to window or dialog edge | 4 px minimum |
| Utility-window item to edge | 1 px permitted |
| Between control groups | 16 px |
| Chicago 12 overall and resource height | 16 px |

Use the system font normally. Use the small system font only for genuinely dense or space-limited text. The HIG uses Chicago 12 metrics for the system font and Geneva 10 for the small system font. Text smaller than Chicago 12 may not localize reliably.

## Controls

| Control | Base size and spacing |
|---|---|
| Push button | 20 px high; at least 8 px horizontal text padding per side |
| Standard OK and Cancel | 58 by 20 px |
| Default ring | 3 px outside the base rectangle |
| Horizontal push buttons | 12 px apart |
| Vertical push buttons | 10 px apart |
| Button to relevant dialog edge | 12 px |
| Bevel buttons | 12 px apart horizontally |
| Bevel icon to title below | 6 px |
| Adjacent bevel titles | 12 px apart |
| Checkbox or radio glyph | 12 by 12 px |
| Glyph to label | 5 px |
| Checkbox or radio control rect | 18 px high |
| Stacked checkbox or radio visible gap | 6 px minimum |
| Pop-up | 20 px high; 18 px with small system font |
| Stacked pop-ups | 6 px apart |
| Closely related paired controls | 4 px apart |
| Edit text | 22 px high; 20 px allowed when aligning with a 20 px control |
| Stacked edit fields | 6 px apart |
| Progress indicator | 12 px high, excluding outer bevel |
| Disclosure triangle to label | 5 px, ignoring triangle shadow |
| Help bevel button | 20 by 21 px |

The checkbox or radio glyph bottom sits 2 px below the text baseline. For an icon or picture relative to a checkbox or radio, use 4 px above and 5 px at left or right.

## Labels and Grouping

| Element | Metric |
|---|---:|
| Static text height at Chicago 12 | 16 px |
| Static label to item it defines | 5 px |
| Label baseline to item below | 6 px, allowing focus ring |
| List title baseline to rule | 6 px |
| Group-box title clear space | 3 px each side minimum |
| Group-box inside side and bottom | 10 px |
| Group-box inside top | 12 px |
| Between group boxes horizontally | 10 px |
| Between group boxes vertically | 12 px |

Platinum group boxes use a two-pixel primary border: white plus dark gray. Measure nested boxes as items; the visible border can make a resource-space measurement look one pixel larger.

## Placement Notes

- Place the help button at lower left aligned with push buttons when possible; upper right is the fallback.
- Exclude focus and default rings from base alignment rectangles.
- Align by text baselines and control bodies, not by shadows.
- At 640 by 480, reduce optional content or expose it by disclosure; do not compress standard hit and spacing metrics.
