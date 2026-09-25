# supermicro_kvm_shim

**Get a browser-based KVM console working on an old Supermicro IPMI
board whose remote console is a ~2010 Java applet that no modern JVM
will run.**

No modern browser, no Java plugin, no legacy VM required on your end
— just Docker. Runs the original, unmodified BMC firmware's applet
inside a container against a patched, current JVM, and exposes the
console as plain noVNC in your browser.

```
docker compose up --build
# open http://localhost:6080/vnc.html
```

---

## Contents

- [Why this exists](#why-this-exists)
- [Quick start](#quick-start)
- [How it works](#how-it-works)
- [BMC maintenance toolkit](#bmc-maintenance-toolkit)
- [Known issue: keyboard input](#known-issue-keyboard-input-doesnt-reach-the-remote-console)
- [Troubleshooting](#troubleshooting)
- [Project layout](#project-layout)

## Why this exists

Old Supermicro (and Dell iDRAC6, HP iLO2 — same Raritan/Peppercon
"lara" KVM-over-IP tech, OEM'd across several vendors) IPMI boards
serve their remote console as a Java applet:
`nn.pp.rc.RemoteConsoleApplet`, loaded via `title_app.asp`. Its jars
(`rc.jar`, `drvredir.jar`, `rcsoftkbd.jar`) are signed with
`MD5withRSA` on a 1024-bit key, under a certificate that **expired
2008-05-06**. Every JDK since ~8u40 hard-disables MD5 for jar
signature verification, so the applet fails to load — unsigned,
sandboxed, or outright rejected — in any current browser or JRE. This
has nothing to do with a missing browser Java plugin; that's been true
for a decade regardless of browser.

The actual KVM data channel turns out to be plain TCP on port 443
(`SSL=off` in the applet's own params — 443 is just used as a
firewall-friendly port number), so at least there's no legacy-TLS
fight to have on top of everything else.

## Quick start

1. **Docker** — installed, daemon running, your user in the `docker`
   group.
2. **Credentials** — copy `.env.example` to `.env` and fill in
   `BMC_HOST` / `BMC_USER` / `BMC_PASS` for your device. `.env` is
   gitignored; never commit real credentials.
3. **Run it:**
   ```
   docker compose up --build
   ```
4. **Open the console:**
   - Browser: `http://localhost:6080/vnc.html` (noVNC — works from
     any device, no client install)
   - Or a real VNC client: `localhost:5900`

Runs on `network_mode: host`, since the BMC typically sits on an
IPMI-only management subnet (e.g. `10.0.99.0/24`) that the default
Docker bridge network has no route to.

The container loops forever: if the console window closes or the BMC
session times out, it re-logs-in and relaunches automatically. No
babysitting required.

## How it works

Runs a current OpenJDK 8 (`appletviewer`, removed in JDK 11+) inside a
container, against a **local mirror** of the applet jars that
`login_and_launch.py` rebuilds fresh on every login. All patches
operate on raw class-file bytes — no decompiler, no bundled
third-party source. Each one locates what it needs (methods, fields,
classes) by resolving the constant-pool `Class`/`NameAndType`/`Utf8`
chain **by name**, not by hardcoded index, so they keep working across
firmware/jar revisions as long as the method shapes don't change.

<details>
<summary><b>1. Strip the (dead, expired) jar signatures</b></summary>

<br>

All `META-INF/` signing metadata is stripped from all three jars, so
every class loads under one consistent, unsigned identity. Nothing is
lost by doing this — permissions come from `security/all.policy`'s
codebase-scoped grant, not the signer, and the signer's certificate
chain could never validate against a trusted root anyway (it's a dead,
self-issued Peppercon CA).

`security/java.security.overrides` additionally re-enables MD5/legacy
jar signature algorithms, but *only* inside this container's own JVM.

</details>

<details>
<summary><b>2. Patch <code>nn.pp.rc.bm</code> — a popup-menu crash on every click</b></summary>

<br>

Full source rewrite, `patch/nn/pp/rc/bm.java`. The original nulls out
its owning `PopupMenu`'s label, which trips a null-label bug in
`sun.awt.X11.XPopupMenuPeer.getCaptionSize()` — crashing the click
handler before it can ever hand focus to the console canvas. Every
single click in the console was silently dying here.

</details>

<details>
<summary><b>3. Patch <code>RemoteConsoleApplet.a()</code> — fix the connection target</b></summary>

<br>

In-place bytecode patch, see `patch_remote_console_applet()` in
`login_and_launch.py`. This one 8-byte, branch-free method is
literally `return getCodeBase().getHost()` — how the applet picks its
actual RFB connection target. Since codebase now points at our local
jar mirror instead of the real BMC, it's rewritten in place to `return
getParameter("REAL_HOST")` instead. Same method length; no other
class-file offsets move.

</details>

<details>
<summary><b>4. Patch <code>nn.pp.rc.af</code> — fix keyboard-locale resolution</b></summary>

<br>

In-place bytecode patch, see `patch_af_locale()`. It picks the
keyboard scancode-translator class via `Component.getLocale()`, which
resolves to `en_US` regardless of `-Duser.language` / `LANG` /
`LC_ALL` — it isn't sourced from `Locale.getDefault()` at all. This
firmware never shipped a translator for `en_US` (only `en_GB`, `de`,
`fr`, `ja`, `no`, `sv`, `de_CH`, `fr_CH`), so `KbdFactory` silently
fell back to a generic translator. The `getLocale()` call site is
rewritten to `getstatic java.util.Locale.UK` instead — same 4-byte
length, nothing else shifts.

</details>

<details>
<summary><b>5. Xvfb + x11vnc + noVNC — headless display, browser-exposed</b></summary>

<br>

Xvfb needs a real X core font path — `sun.awt.X11.XPopupMenuPeer`
needs one for caption sizing, and a missing path was itself an earlier
crash cause before patch #2 above was found. x11vnc + noVNC turn that
headless display into a normal browser-accessible console.

</details>

## BMC maintenance toolkit

`tools/bmc-tools.sh` (baked into the image, `ipmitool` included) is a
grab-bag of commands for maintaining this kind of old BMC in general —
not just for the KVM console:

```
docker compose exec kvm-shim bmc-tools.sh <command>
```

| Command | What it does |
|---|---|
| `status` | Chassis power status |
| `info` | BMC firmware/device info |
| `lan` | BMC's own network config |
| `users` | IPMI user list |
| `fru` | Hardware inventory |
| `sensors` | Live sensor readings |
| `power on\|off\|cycle\|reset\|soft` | Host server power control (confirms before anything but `on`) |
| `sel list` / `sel clear` | System Event Log |
| `reset-bmc` / `reset-bmc-warm` | Cold/warm-reset the **BMC chip only** — does not reboot the host server |
| `sol` | Serial-over-LAN text console |
| `sol-deactivate` | Force-clear a stuck SOL session |
| `raw ...` | Anything else, passed straight to `ipmitool` |

## Known issue: keyboard input doesn't reach the remote console

Video is fully solid. Keyboard is not, and the evidence increasingly
points to a **server-side** problem rather than anything fixable from
this client:

- Keystrokes are correctly captured as AWT `KeyEvent`s on the
  console's canvas (confirmed via the console's own keyboard-debug
  overlay) — focus is fine.
- Correctly-formed, protocol-legal keyboard packets
  (`nn.pp.rc.bl.writeKeyboardEvent`, msg-type `0x04` + scancode byte)
  are sent and cleanly ACKed by the BMC (confirmed via `tcpdump`).
- The **soft/on-screen keyboard** (pure mouse clicks — no Java
  key-translation involved at all) also produces no reaction, which
  rules out anything client-side translation-related.
- A **fourth binary patch**, `patch_rfbhandler_keylog()` (see below),
  let us log the real computed scancode for every keystroke and
  override it live for testing. The shipped translator's press/release
  polarity turned out to be backwards from standard PS/2 Set 1 (bit 7
  set on *press*, not release), and its base scancode is consistently
  one less than the standard table. Neither fixing polarity alone,
  fixing the off-by-one alone, fixing both together, nor swapping in
  USB HID Usage IDs or PS/2 Set 2 values changes the outcome.
- Tested under a genuinely period-correct JVM too — a real Java 6
  (Zulu, contemporaneous with this firmware's ~2010 last-touched date)
  rig lives in `java6-test/`. Identical failure, ruling out modern-JVM
  incompatibility entirely.
- Only one TCP connection ever exists (to `:443`) — this firmware
  doesn't use the older split video/HID-port (5900/5901) scheme some
  other Supermicro generations had, so that's not it either.
- **Strongest single data point:** even the BMC's own pre-programmed
  Ctrl+Alt+Delete hotkey — firmware-defined bytes, not computed by any
  of our code — produces zero reaction. This eliminates "our scancode
  value or polarity is wrong" as an explanation entirely, since those
  bytes require no guessing at all.

Supermicro's own support history has multiple reports of exactly this
shape (video works, keyboard doesn't), fixed by a BMC/iKVM reset or,
in some cases, a full AC power cycle of the board — see `tools/
bmc-tools.sh reset-bmc` above. If that doesn't help, check BIOS USB
settings (Legacy USB Support / USB Keyboard Support) and consider a
BMC firmware update. Full investigation notes and next steps live in
[`NEXT_STEPS.md`](NEXT_STEPS.md).

<details>
<summary><b>Scancode sweep tooling</b></summary>

<br>

`patch_rfbhandler_keylog()` patches `nn.pp.rc.RFBHandler_01_16.a(byte)`
— the single choke point every computed scancode byte passes through
before hitting the wire — to log every real value in real time
(`docker compose logs -f`, plain integers, one per keystroke) instead
of inferring them from packet hex dumps.

It also supports a live override for fast iteration without a
container rebuild: write a hex byte to `/work/scancode_override`
inside the running container, then kill the `appletviewer` process to
force a reconnect (the entrypoint's loop re-logs-in and re-patches the
jar fresh every time, picking up the new value in ~10-15s). The
override is polarity-aware — it detects press vs. release at runtime
from the *original* computed byte's own bit 7, and emits the override
value with correct standard-PS/2 polarity for whichever one it is,
rather than sending one fixed byte for both (which can't distinguish
"value is wrong" from "polarity is wrong"):

```
docker exec supermicro_kvm_shim bash -c 'echo 0a > /work/scancode_override'
docker exec supermicro_kvm_shim pkill appletviewer
# wait ~10-15s for reconnect, then test a keypress
```

Empty/missing file (or `rm /work/scancode_override`) reverts to
logging-only, no override.

For an unattended full sweep across a value range, see
`tools/scancode_sweep.sh` — it automates the set/reconnect/test/
pixel-diff cycle above end to end.

</details>

## Troubleshooting

- **Login failing** — check the container logs (`docker compose logs
  -f`); `login_and_launch.py` prints the specific HTTP/auth failure.
- **Applet loads but immediately errors / blank window** — the BMC
  session may have gone stale between fetch and launch; the loop
  retries automatically within a few seconds.
- **`appletviewer: command not found`** — a very new Temurin 8 patch
  release trimmed it (shouldn't happen within JDK 8, but if it does,
  pin `eclipse-temurin:8u402-b06-jdk` or similar in the `Dockerfile`'s
  `FROM` line).
- **A binary patch raises `RuntimeError` on login** — the firmware's
  jar contents changed shape (an update, or a different unit) enough
  that a resolved method/field/bytecode pattern no longer matches.
  Check the error message — each patch names exactly what it couldn't
  find.

## Project layout

```
.
├── Dockerfile              Main image: OpenJDK 8 + Xvfb/x11vnc/noVNC + ipmitool
├── docker-compose.yml       kvm-shim (default) + kvm-shim-java6 (profile: java6)
├── entrypoint.sh            Login/patch/launch loop
├── login_and_launch.py      All four binary patches + jar mirroring + login
├── patch/nn/pp/rc/bm.java   Full source rewrite for patch #2
├── security/                java.security.overrides, all.policy
├── tools/
│   ├── bmc-tools.sh         ipmitool grab-bag (see above)
│   └── scancode_sweep.sh    Unattended keyboard scancode sweep
├── java6-test/              Parallel period-correct Java 6 test rig
└── NEXT_STEPS.md            Session handoff / investigation notes
```
