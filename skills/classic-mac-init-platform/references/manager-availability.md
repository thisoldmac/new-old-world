# Manager and Context Matrix

## Availability

| Facility | Minimum or variability | INIT guidance |
|---|---|---|
| Gestalt Manager | System 6.0.4 | Trap-probe where older ROM/system combinations are possible; query capabilities rather than deriving them from version |
| SysEnvirons | Earlier compatibility path | Use only for documented environment fields; do not treat it as a complete feature inventory |
| Notification Manager | System 6.0 | Preferred way to defer user notification until startup interaction is available |
| Time Manager | Original manager in Plus ROM; revised manager in System 6.0.3; extended manager in System 7 | Query `gestaltTimeMgrVersion`; use only routines present in the selected profile |
| Deferred Task Manager | Not universal before System 7; absent on some Plus and SE System 6 configurations | Trap-probe `_DTInstall`; deferred tasks remain interrupt context |
| Process Manager | System 7 API | Do not call while INITs are being loaded; its eventual system presence does not establish current startup context |
| Folder Manager / `FindFolder` | Native System 7 facility | On System 6, use proven older File Manager techniques; do not assume MPW or THINK glue exists in Retro68 |
| Shutdown Manager | Present in the System 6 era | Retain callback code/state in system heap; use only System 6-compatible flags; reinstall one-shot procedures when required |
| Vertical Retrace Manager | ROM/Toolbox-era facility | Keep VBL work bounded and allocation-free; test exact hardware timing |

## Notification Manager

The notification record must remain static or otherwise nonrelocatable. Every referenced string, icon, sound, and response routine must remain valid. A response routine receives no application A5 setup. Use `nmMark = 0` for system-level or detached tasks unless a documented application mark is meaningful.

## Time Manager

Time Manager tasks execute at interrupt time. Do not call the Memory Manager directly or indirectly. If the Gestalt selector is unavailable, assume only the original manager. Do not use extended routines on a System 6 target.

## Deferred Task Manager

A deferred task is one-shot and remains subject to interrupt restrictions. Install it only when the trap is present. Reinstall deliberately if repeated execution is required.

## Shutdown Manager

Keep procedure code and state resident. Combined shutdown flags are a System 7-and-later feature. System 6 does not provide the same Apple-event shutdown coordination. Treat shutdown callbacks as one-shot where documented.

## Cooperative follow-up

If work requires application APIs, networking initialization, dialogs, or extensive file I/O, arrange for a later normal application or control panel to perform it. An INIT should install the minimum boot-time primitive and leave higher-level work to the environment that owns it.
