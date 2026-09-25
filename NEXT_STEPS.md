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

**Keyboard input: still not reaching the remote console.** This is
the open problem. Extremely thoroughly investigated this session --
see README.md's "Known issue" section for the full list, but the
short version: everything on the client side checks out (focus is
fine, real protocol-legal packets are sent and ACKed, we tried
correcting an observed off-by-one + backwards polarity in the shipped
translator, tried USB HID and PS/2 Set 2 tables instead) and NONE of
it changes the outcome. The single strongest data point: even the
BMC's own **pre-programmed, firmware-defined Ctrl+Alt+Delete hotkey**
produces zero reaction -- those bytes require no guessing at all,
which eliminates "our scancode value/polarity is wrong" as an
explanation entirely. Current working theory: BMC-side USB HID
emulation to the motherboard is the actual broken component, not
anything in this client/protocol path.

## Containers currently running

- `supermicro_kvm_shim` (main, port 6080/5900) -- clean baseline, no
  override active.
- `supermicro_kvm_shim_java6` (port 6081/5901) -- the period-correct
  Java 6 test rig (`java6-test/`), used to rule out modern-JVM
  incompatibility (confirmed: identical failure under real Java 6).
  Safe to `docker compose stop kvm-shim-java6` if not needed further;
  it's just sitting there idle otherwise.

## Next steps (in the order the user wants to tackle them)

1. **User is going to check the actual host OS on the managed server**
   (TrueNAS/FreeBSD) for anything on that side that could be
   swallowing/buffering USB HID input rather than it being a BMC
   emulation failure outright -- similar in spirit to a 2025 VyOS
   report the user found, where keystrokes were arriving at the OS's
   `/dev/input/eventN` but not visibly registering. Worth checking
   `usbconfig`/`usbhid` state on the FreeBSD side if there's any way
   to get a shell (SOL, if it works independently of the KVM keyboard
   path -- untested so far this session, worth trying:
   `tools/bmc-tools.sh sol`).

2. **User is going to check BIOS settings on the motherboard itself**
   -- specifically Legacy USB Support / USB Keyboard Support. This is
   the setting from the user's own Supermicro support research
   (video-works-keyboard-doesn't is a known symptom tied to this
   setting on some boards). Can't be reached via the currently-broken
   KVM keyboard, obviously -- needs physical access, or SOL if BIOS
   has console redirection enabled.

3. **Resume the full scancode sweep** -- built and dry-run validated
   this session (`tools/scancode_sweep.sh`), but the user asked not to
   start the full run before exiting. To resume:
   ```
   tools/scancode_sweep.sh 0 127
   ```
   Takes ~30-40 minutes unattended (128 values x ~15s each: set
   override, force reconnect, screenshot before/after a keypress,
   pixel-diff them). Results land in `sweep_results/results.log`
   (repo-root-relative, gitignored) -- one line per value with an
   ImageMagick `compare -metric AE` diff count -- plus before/after
   PNGs per value. Review for any value whose diff is well above the
   blinking-cursor baseline noise (~490-500 in the dry-run of values
   0x00-0x01, for reference). Given everything else points
   server-side, low expectation this finds anything, but it's cheap to
   run to exhaustion for certainty before fully committing to the
   server-side theory.

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
