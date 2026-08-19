# UI Verification and Sources

## Evidence labels

- **verified-document:** primary Apple documentation or exact interface declaration.
- **verified-implementation:** exact toolchain source, successful build, or inspected package.
- **verified-target:** observed on a declared OS, ROM, CPU, component, display, and memory row.
- **probe-required:** plausible or declared but missing the needed build/package/runtime observation.
- **unsupported:** excluded by the selected target.
- **unresolved:** conflicting or insufficient evidence.

## Acceptance matrix

For every claimed era, test:

- minimum OS and representative upper OS;
- real 68K, 68K-under-PPC-emulation, or native PPC as claimed;
- one-bit monochrome, low color, and intended normal depth;
- compact screen and a larger screen;
- active/inactive, enabled/disabled, focused/unfocused, pressed/default/selected states;
- keyboard-only operation, Return/default, Escape and Command-period/cancel;
- low-memory partition and allocation failures;
- Appearance absent/present/compatibility mode where claimed;
- optional file-panel service absent and present;
- nested-loop liveness during dialogs, menus, tracking, and file panels.

## Redraw torture pass

For each claimed era:

- cover and uncover windows in narrow strips and process updates while background or inactive;
- move a window partly offscreen and back;
- resize and scroll repeatedly, including click-and-hold action callbacks;
- change selection, focus, caret, control values, and status while their regions are obscured;
- switch panes after focusing editable content in the pane being hidden;
- return from menus, dialogs, tracking, and file panels after model state changed;
- compare the final display with a forced full invalidation from the same model state.

Reject stale pixels, unbalanced update handling, hidden-pane focus, duplicate manager drawing, white base-window flashes, and state that cannot be reconstructed from the model.

Do not claim compatibility from a static browser mockup, screenshot, successful compilation, or packaged artifact. A browser mockup may express composition, but final geometry and behavior must be rendered with target fonts, controls, QuickDraw, and system managers.

## Primary sources

- [Macintosh Toolbox Essentials](https://developer.apple.com/legacy/library/documentation/mac/pdf/MacintoshToolboxEssentials.pdf)
- [Introduction to Processes and Tasks](https://developer.apple.com/library/archive/documentation/mac/pdf/Processes/Intro_to_Procs_Tasks.pdf)
- [Apple Human Interface Guidelines: The Apple Desktop Interface, 1987](https://512pixels.net/downloads/files/1987-HIG.pdf)
- [Macintosh Human Interface Guidelines, 1992](https://vintageapple.org/inside_r/pdf/Human_Interface_Guidelines_1992.pdf)
- [Mac OS 8 Human Interface Guidelines](https://dev.os9.ca/techpubs/mac/pdf/HIGOS8Guidelines.pdf)
- [Inside Macintosh: Files, 1992](https://vintageapple.org/inside_r/pdf/Files_1992.pdf)

The last four links include preserved copies of Apple-authored books. Treat them as primary content hosted by mirrors, not independent secondary authority.
