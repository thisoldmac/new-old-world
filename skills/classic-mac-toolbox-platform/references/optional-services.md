# Optional Services

## Four-layer gate

For every optional service, record:

1. header declaration and target macros;
2. 68K trap glue or PPC import-library requirement;
3. packaged fragment imports/resources;
4. Gestalt, version, weak-symbol, or manager-specific runtime test and fallback.

## Appearance Manager

- Query `gestaltAppearanceAttr` and require `gestaltAppearanceExists`.
- Interpret compatibility mode separately.
- Register/unregister the non-Carbon application client deliberately.
- The researched classic 68K headers emit selector traps.
- The researched RetroPPC build requires `AppearanceLib`; PEF imports must be inspected.
- Keep the classic UI path when Appearance is absent.

## Standard File and Navigation Services

- Use original Standard File as the broad fallback.
- Gate enhanced Standard File with `gestaltStandardFile58`.
- Handle the Open Documents Apple event when adopting enhanced Standard File.
- Gate Navigation Services with `NavServicesAvailable()`.
- In the researched toolchain, PPC links `NavigationLib`; 68K links `Navigation` support.
- The 68K availability probe required `--mac-single`; other segment layouts are probe-required.

## Process and high-level services

- Process Manager semantics require System 7 or MultiFinder.
- Apple events, Drag Manager, Balloon Help, and other later managers require independent capability checks.
- Express `SIZE` suspend/resume, background, activation, and high-level-event flags consistently with actual handling.

## Concurrency and I/O

- The application and Thread Manager are cooperative. Bound work and yield explicitly.
- Treat Multiprocessing Services as a later optional runtime with restricted Toolbox access.
- Keep synchronous file/network work out of interaction-critical paths or pump it through documented idle callbacks.
- Gate Open Transport, MacTCP, serial, sound, QuickTime, and other shared libraries independently; an import library is not proof of the installed component.

## Runtime fallback rule

If the facility is absent:

- use a documented baseline manager;
- disable the feature visibly;
- provide an alternate workflow;
- or raise the product's declared deployment floor.

Never continue through an unavailable glue call and hope for a graceful failure.
