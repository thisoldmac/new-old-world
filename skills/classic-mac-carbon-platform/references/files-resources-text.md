# Files, Resource Forks, and Text

## Use Native File Semantics

Prefer `FSRef` plus Unicode File Manager APIs for new internal logic when the runtime probe permits them. Keep bounded `FSSpec`/Pascal-name adapters for older APIs. Never route production HFS/HFS+ behavior through POSIX paths or `std::filesystem` without target evidence.

State explicitly:

- volume/directory identity;
- data, resource, or named fork;
- create/open permissions and sharing;
- Finder type, creator, and flags;
- name encoding and maximum length;
- error mapping and partial-I/O behavior;
- replacement/atomicity policy.

## Availability Splits

In the inspected Universal Interfaces:

- core FSRef/Unicode calls including `FSMakeFSRefUnicode`, `FSCreateFileUnicode`, `FSGetCatalogInfo`, and `FSOpenFork` are annotated CarbonLib 1.0+;
- `FSOpenResFile` and `FSCreateResFile` are annotated CarbonLib 1.1+;
- `FSCreateResourceFile` and `FSOpenResourceFile` named-fork APIs are annotated CarbonLib 1.3+.

Still query `gestaltFSAttr` and `gestaltResourceMgrAttr`, then check actual results. Mac OS 8.6 plus CarbonLib 1.6 remains a required probe row because Apple's HFS Plus release statement and header annotations do not by themselves resolve runtime support.

## Forks and Finder Metadata

A classic file can have a data fork and resource fork. Finder type, creator, flags, and dates are metadata, not filename extensions. A complete copy contract names every required component.

For an application, verify at minimum:

- data fork contains the PEF;
- resource fork exists and parses;
- type is `APPL` and creator matches the project;
- `cfrg`, `carb`, `SIZE`, and project resources are present and consistent;
- the receiver reconstructed metadata rather than merely exposing an AppleDouble sidecar.

## Encoding Boundaries

Keep these domains separate:

- wire/storage protocol text: declared encoding, normally UTF-8;
- HFS+ names: `UniChar`/UTF-16 through FS APIs;
- classic Pascal strings: explicit MacRoman or active system-script encoding;
- `OSType`/four-character codes: fixed bytes, not localized strings.

The compiler's UTF-8 execution character set does not make a UTF-8 literal valid input to a classic Pascal-string Toolbox API. A GCC `\p` literal supplies length layout only. Use Text Encoding Converter/Unicode Converter and handle unavailable converters and unmappable text.

Script encodings can vary by OS release. Do not assume the same byte-to-Unicode mapping across the full target range.

## File-Transfer Design

When a protocol transfers files, define whether it transfers:

- only data;
- both forks;
- Finder metadata;
- names and encoding;
- dates and flags;
- empty forks and partial failures.

Prefer a versioned manifest and explicit byte lengths/hashes. Never serialize host filesystem metadata structures directly.
