# Session handoff -- 2026-09-25

Context dump for picking this back up. Repo:
https://github.com/webdawg/supermicro_kvm_shim

## Current state

**Video KVM: solid, done.** `docker compose up -d` gives a fully
working remote console at `http://localhost:6080/vnc.html`. Four
firmware bugs found and binary-patched along the way (see README.md
"How the shim fixes it" and "Scancode sweep tooling" sections for the
full technical detail on each):

1. Null-label NPE in the popup-menu peer (`nn.pp.rc.bm`, full source
   rewrite in `patch/nn/pp/rc/bm.java`)
2. Codebase-host connection-target assumption
   (`nn.pp.rc.RemoteConsoleApplet.a()`, in-place bytecode patch)
3. Locale-selection call never resolving to a shipped keyboard
   translator (`nn.pp.rc.af`, in-place bytecode patch)
4. Scancode logging/override capability (`nn.pp.rc.RFBHandler_01_16.
   a(byte)`, in-place bytecode patch) -- built for the keyboard
   investigation below, not a bug fix itself

**Keyboard input: root-caused, no clean fix exists.** Confirmed via
direct SSH into the managed host (bypassing the broken keyboard path
entirely): the BMC's virtual USB HID device fails FreeBSD's own USB
enumeration outright at boot (`USB_ERR_IOERROR`, never resolves a
vendor/product ID, ends in `uhub_reattach_port: could not allocate new
device`) on the onboard EHCI controller. It works fine during BIOS/POST
because BIOS's legacy USB keyboard support is much more tolerant than a
real OS USB stack. This is a known, previously-reported issue on this
exact board generation (see README.md's "Known issue" section for full
citations) with no available firmware fix -- Supermicro's fix for the
same bug class on an older board (X7DBU/SIMSO+) required a custom
firmware build never released for this board's IPMI module. Practical
answer: manage the host over SSH, keep a genuinely wired physical
keyboard on hand for BIOS/emergency access, don't rely on the IPMI
virtual keyboard. Closed as a hardware/firmware limitation, not
something to keep chasing in this client.

## Containers currently running

- `supermicro_kvm_shim` (main, port 6080/5900) -- clean baseline, no
  override active.
- `supermicro_kvm_shim_java6` (port 6081/5901) -- the period-correct
  Java 6 test rig (`java6-test/`), used to rule out modern-JVM
  incompatibility (confirmed: identical failure under real Java 6).
  Safe to `docker compose stop kvm-shim-java6` if not needed further;
  it's just sitting there idle otherwise.

## Next steps

Keyboard investigation is closed -- see "Current state" above and
README.md's "Known issue" section. Root cause confirmed via direct SSH
into the host: hardware is a **Supermicro X7DB8** with an add-on
**AOC-IPMI20-E** IPMI module (Peppercon AG, firmware 1.64). The BMC's
virtual USB HID device fails FreeBSD's own USB enumeration at boot;
works fine under BIOS's much more tolerant legacy USB polling. No
client-side fix exists. The scancode sweep tool (`tools/
scancode_sweep.sh`) was built and dry-run validated during the
investigation but is now moot given the root cause -- not worth
running to completion.

**Update:** the failure is isolated to one specific internal USB
controller/hub (`usbus3`), not universal — a physical keyboard moved to
a different physical port (routed through a different, working UHCI
controller) works fine. Practical workaround confirmed: use a
different USB port for the physical keyboard.

Remaining open thread: a support request was sent to Supermicro (see
[`SUPERMICRO_SUPPORT_REQUEST.md`](SUPERMICRO_SUPPORT_REQUEST.md)) asking
whether a USB-1.1-forcing firmware revision exists for the AOC-IPMI20-E
module, analogous to the fix in [FAQ
11530](https://www.supermicro.com/en/support/faqs/faq.php?faq=11530)
for the X7DBU/SIMSO+ combo (same board generation, different IPMI
module). Low expectation given the module's age, but cheap to ask. No
response yet as of 2026-09-28.

## Everything else

- `tools/bmc-tools.sh` -- ipmitool grab-bag (power control, sensors,
  SEL, BMC-only resets, SOL, raw passthrough). Already used
  successfully once this session for a BMC cold-reset.
- Credentials are in `.env` (gitignored, never committed -- verified
  clean before the repo went public).
- All binary-patching code (the constant-pool-resolving,
  offset-computing approach) lives in `login_and_launch.py` and is
  fairly heavily commented with the *why* for each patch -- worth
  reading before extending it further.
