# Contributing to New Old World

This project talks to hardware most people do not have. That shapes what
contribution looks like here more than any style rule does, so start with
the honest version of what you can and cannot do without a classic Mac on
your desk.

## What you can do without vintage hardware

Most of the tree, as it turns out.

**`scripts/test-all` is the one command.** It runs everything below in
order, cheapest first, and stops at the first failure naming it.

- **The host application** is an ordinary Swift package plus an Xcode
  project. `scripts/test-host` runs the suites and both build systems on
  any recent macOS. No guest required.
- **The native guest tests** compile the guests' pure logic with the host
  `cc` and run it here — frame codecs, JSON, layout arithmetic, command
  parsing, file lists. `scripts/test-native` runs both guests' suites in
  one command. No guest required.
- **The contract** (`contract/asyncapi.yaml`) is a text file, and it is
  where a behaviour change starts.
- **`tools/fakeguest.py`** exercises the host against a hand-written peer.
  Read its header before quoting a result from it: it proves the harness
  reacts correctly to a peer that behaves a stated way, and proves nothing
  whatever about a real guest.

## What needs an emulator

The guests are real Mac applications and need a real Mac OS to run. QEMU
covers most of it — `scripts/q800-68k` boots a Quadra 800 for NOW-68K, and
the PowerPC guest runs under an OS 9 emulator. Emulator results are worth
having and are labelled as such; see below.

## What needs metal

Timing, MacTCP behaviour under load, and anything about a specific
machine's limits. If you do not have the hardware, say so and stop at
emulator-verified — that is a complete and useful contribution. Do not
guess past the evidence you have.

## The three rules that matter most

Everything else is in [AGENTS.md](AGENTS.md), which is the full working
convention document and applies to human and agent contributors alike.
These three are the ones a new contributor breaks first.

### 1. A behaviour change starts in the contract

`contract/asyncapi.yaml` defines every message. If a verb needs a field,
the contract gains it first, then both halves. A field one side sends and
the other has never heard of is the defect class that has cost this
project the most.

State a limit **once**, where both sides read it.

### 2. Verification is a status, not an adjective

Three levels, and every claim says which one it means:

- **Builds** — proves nothing about behaviour.
- **Tested** — the suites pass.
- **Metal-verified** — someone watched it work on the real machine.

Never write "works" for something in the first two categories. Most of
the surprises in this project came from code that looked obviously
correct and had never run on real hardware.

### 3. A test you have not watched fail proves nothing

Verify a new guard by mutation: reintroduce the bug and check that the
test names it. A test that constructs the message it then parses tests
one half twice.

New native tests must be added to `scripts/test-native`'s manifest, which
fails the run if a test file is not listed. A test nobody runs reads as
coverage in a directory listing and proves nothing.

## Pull requests

- **Small and reviewable beats finished and enormous.** A change that
  does one thing, with its test and its doc update, lands. A branch that
  reworks four subsystems does not.
- **Update the ledger.** [docs/open-issues.md](docs/open-issues.md)
  tracks what is broken and what is unverified. Arcs that went *well*
  update it too — "we shipped it and here is what we still do not know"
  is the useful half.
- **Update `docs/contract-coverage.md` in the same commit** as any change
  to what a guest serves. Derive it with the `grep` commands in the file;
  do not hand-edit a row from memory.
- **Say what you did not verify.** A PR that names its own gaps is worth
  more than one that implies coverage it does not have.

## Where notes go

`docs/` is published and deliberate. `docs/local/` is gitignored scratch
space — session notes, investigation logs, raw output, plans that are not
commitments yet. Use it freely; see
[docs/local/README.md](docs/local/README.md) for how a note graduates
from one to the other.

## Set up the hooks once

    tools/setup-hooks

It points git at `.githooks`, which is repo-local config every worktree
inherits. Two refusals live there: a direct commit on `main`, and a commit
that changes the resident extension without baking it into the shared QEMU
stage image first (`scripts/bake-ext-image`). Both are overridable —
`TBT_ALLOW_MAIN=1`, `TBT_DEFER_EXT_BAKE=1` with a written reason — because
enforcement is the floor and not the rule. See AGENTS.md.

## Local machine configuration

Nothing about your network belongs in a commit. Addresses, credentials
and toolchain paths come from environment variables — see
[docs/lab-setup.md](docs/lab-setup.md) and copy `.env.lab.example` to
`.env.lab`, which is gitignored.

## Code style

There is no formatter config, deliberately: match the density and idiom
of the file you are editing. Both dialects share one rule — **comments
say why, not what.** A comment restating the line above it is noise; a
comment explaining why the obvious approach was wrong is why this
codebase is legible.
