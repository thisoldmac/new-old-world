# Census metal spike

**One question:** can this Carbon app reach the census probes that are
**not** Carbon-clean — the InterfaceLib managers (ADB, SCSI) and the
low-memory tables (drive queue, unit table, SysParm PRAM)?

It decides slice 2's probe list. Slice 1 shipped the Carbon-clean set
(Overview, Identity, Selectors, Video, Volumes). Everything with
character on a PowerBook — the drivers, the ADB devices, the disks the
SCSI/ATA buses carry, the PRAM — lives behind one of these two doors,
and this asks the machine in front of us whether they open.

## Why a symbol probe (and why not just call them)

`CountADBs`, `GetIndADB`, the SCSI Manager — the headers declare them
only as **68K inline traps**. A CFM app that calls one directly makes a
**strong import**: if the machine's InterfaceLib does not export it, the
app aborts at launch with an opaque system dialog. That is the Open
Transport trap this project already paid for once.

`GetSharedLibrary("InterfaceLib")` + `FindSymbol` answer by **name**,
resolving against the PowerPC fragment without calling anything or laying
out a struct — so the probe cannot wedge or fail to launch. `CountADBs`
alone, once resolved, is then called **through its pointer** (a runtime
call, not an import) because it takes no arguments, does no bus I/O, and
its count is the definitive ADB answer.

The low-memory tables are not in this toolchain's Carbon headers at all
(that is *why* `drives`/`drivers`/`pram` were held back). They are plain
fixed-address reads — `0x030A` (drive queue head), `0x011C`/`0x01D2`
(unit table base and count), `0x01F8` (the 20-byte SysParm PRAM copy) —
which the spike **performs**. A read-only walk of a table the OS
maintains is exactly what the real probe would do.

The SCSI bus is **never selected or INQUIRY'd**. That is active bus I/O,
gated on `gestaltHardwareAttr` and attended in the real probe; the spike
only asks whether the SCSI Manager's entry points exist.

## What it reports

- CarbonLib and System versions.
- ADB Manager, SCSI Manager v1, and SCSI Manager 4.3 async: which entry
  points InterfaceLib exports to CFM.
- `CountADBs()` called through its resolved pointer — the live device
  count.
- The drive queue walked, the unit table counted, the SysParm 20 bytes
  dumped — each proving its probe by doing it.
- A verdict, one line per slice-2 probe.

On screen, and to **`Census Spike Report`** on the desktop so the answer
leaves the machine as text.

## Deploy

Build with the guest's RetroCarbon toolchain (see repo README's Build
section, pointed at `spikes/census-metal` instead of `guest`). It links
strongly against nothing unusual — the whole point is that the risky
symbols are resolved at runtime — so it launches on any OS 9 machine.
Send it to the PowerBook under its own name (`now-census-spike`), run it,
read the desktop report.

## The verdict

_(pending first run on the PB1400c)_
