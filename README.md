# supermicro_kvm_shim

Gets the KVM-over-IP console working on an old Supermicro IPMI board
whose iKVM console is a ~2010 Java applet that no modern JVM will run
-- plus a small toolkit of `ipmitool` commands for maintaining this
kind of old, flaky BMC in general.

## Why the console is broken

`http://<bmc>/title_app.asp` embeds `nn.pp.rc.RemoteConsoleApplet`
(Raritan/Peppercon "lara" KVM applet, the same tech Dell iDRAC6 and HP
iLO2 licensed). Its jars (`rc.jar`, `drvredir.jar`, `rcsoftkbd.jar`)
are signed with `MD5withRSA` on a 1024-bit key, under a cert that
expired **2008-05-06**. Every JDK since ~8u40 hard-disables MD5 for
jar signature verification, so the applet loads unsigned/sandboxed (or
not at all) in any current browser or JRE -- nothing to do with your
browser's Java plugin being missing, that's been true for a decade
regardless.

The actual KVM data channel is plain TCP on port 443 (`SSL=off` in the
applet params -- 443 is just used as a firewall-friendly port number),
so there's no legacy-TLS fight to have there.

## How the shim fixes it

Runs a current OpenJDK 8 (`appletviewer`, removed in JDK 11+) inside a
container, against a **local mirror** of the applet jars that
`login_and_launch.py` rebuilds fresh on every login:

- Strips all `META-INF/` signing metadata from all three jars, so
  every class loads under one consistent, unsigned identity (nothing
  is lost -- permissions come from `security/all.policy`'s
  codebase-scoped grant, not the signer).
- Splices in three binary-patched classes in their place:
  - **`nn.pp.rc.bm`** (full source rewrite, `patch/nn/pp/rc/bm.java`)
    -- the original nulls out its owning `PopupMenu`'s label, which
    trips a null-label bug in `sun.awt.X11.XPopupMenuPeer.
    getCaptionSize()` on every click, crashing the click handler
    before it can hand focus to the console canvas.
  - **`nn.pp.rc.RemoteConsoleApplet.a()`** (in-place bytecode patch,
    see `patch_remote_console_applet()` in `login_and_launch.py`) --
    this one 8-byte, branch-free method is `return
    getCodeBase().getHost()`, which is how the applet picks the
    actual RFB connection target. Since codebase now points at our
    local mirror instead of the BMC, it's rewritten in place to
    `return getParameter("REAL_HOST")` instead -- same method length,
    no other class-file offsets move.
  - **`nn.pp.rc.af`**'s locale selection (in-place bytecode patch, see
    `patch_af_locale()`) -- it picks the keyboard scancode-translator
    class via `Component.getLocale()`, which resolves to `en_US`
    regardless of `-Duser.language`/`LANG`/`LC_ALL` (it isn't sourced
    from `Locale.getDefault()`). This firmware never shipped a
    translator for `en_US` (only `en_GB`, `de`, `fr`, `ja`, `no`,
    `sv`, `de_CH`, `fr_CH`), so `KbdFactory` fell back to the generic
    translator. The `getLocale()` call site is rewritten to `getstatic
    java.util.Locale.UK` instead -- same 4-byte length, nothing else
    shifts.
- `security/java.security.overrides` -- re-enables MD5/legacy jar
  signature algorithms *only inside this container's JVM*.
- `security/all.policy` -- grants the applet `AllPermission`, since
  its signer can never chain-validate to a trusted root anyway (dead
  self-issued Peppercon CA) and it needs raw-socket + AWT access the
  default sandbox denies.
- Xvfb (with a real X core font path -- `sun.awt.X11.XPopupMenuPeer`
  needs one for caption sizing, a missing path was an earlier crash
  cause) + x11vnc + noVNC -- runs the applet headlessly and exposes it
  as a normal VNC/web console.
- `entrypoint.sh` loops forever: if the console window closes or the
  BMC session times out, it re-logs-in, rebuilds the jar mirror, and
  relaunches automatically.

All three patches operate on raw class-file bytes with no decompiler
and no bundled source -- each one locates what it needs (methods,
fields, classes) by resolving the constant-pool Class/NameAndType/Utf8
chain by name, not by hardcoded index, so they keep working across
firmware/jar revisions as long as the method shapes don't change.

## Setup

1. Docker is installed. Copy `.env.example` to `.env` and fill in
   `BMC_HOST` / `BMC_USER` / `BMC_PASS` for your device (`.env` is
   gitignored, never commit real credentials).
2. Build and run:
   ```
   docker compose up --build
   ```

## Using it

- Browser: `http://localhost:6080/vnc.html` (noVNC -- works from any
  device, no client install)
- Or a real VNC client: `localhost:5900`

Runs on `network_mode: host` since the BMC sits on an IPMI-only
management subnet (`10.0.99.0/24`) that the default docker bridge
network has no route to.

## Known issue: keyboard input doesn't reach the remote console

Video is fully solid. Keyboard is not, and it's very likely a
**server-side** problem rather than anything fixable here:

- Confirmed via the console's own keyboard-debug overlay: keystrokes
  are correctly captured as AWT `KeyEvent`s on the console's canvas
  (focus is fine).
- Confirmed via `tcpdump`: correctly-formed, protocol-legal keyboard
  packets (`nn.pp.rc.bl.writeKeyboardEvent`, msg-type `0x04` + scancode
  byte) are sent and cleanly ACKed by the BMC.
- Confirmed the **soft/on-screen keyboard** (pure mouse clicks, no
  Java key-translation involved at all) also produces no reaction --
  which rules out anything client-side translation-related.
- Confirmed even the BMC's own **pre-programmed Ctrl+Alt+Delete
  hotkey** (`HOTKEYCODE_0`, raw bytes defined by the firmware itself,
  not computed by any of our code) produces zero visible reaction.
- Only one TCP connection exists (to `:443`) -- this firmware doesn't
  use the older split video/HID-port (5900/5901) scheme some other
  Supermicro generations had, so that's not it either.

Together this points at the BMC's own USB HID emulation to the
motherboard, not the Java/RFB client path. Supermicro's own support
history has multiple reports of exactly this shape (video works,
keyboard doesn't) fixed by a BMC/iKVM reset, or in some cases a full
AC power cycle of the board. See `tools/bmc-tools.sh reset-bmc` below.
If that doesn't help, check BIOS USB settings (legacy USB support/USB
keyboard support) and consider a BMC firmware update.

## BMC maintenance toolkit

`tools/bmc-tools.sh` (baked into the image, `ipmitool` included) is a
grab-bag of commands for maintaining this kind of old BMC in general,
not just for the keyboard issue:

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
| `reset-bmc` / `reset-bmc-warm` | Cold/warm-reset the BMC chip only -- does **not** reboot the host server |
| `sol` | Serial-over-LAN text console |
| `sol-deactivate` | Force-clear a stuck SOL session |
| `raw ...` | Anything else, passed straight to `ipmitool` |

## Troubleshooting

- **Login failing**: check the container logs (`docker compose logs
  -f`) -- `login_and_launch.py` prints the specific HTTP/auth failure.
- **Applet loads but immediately errors / blank window**: the BMC
  session may have gone stale between fetch and launch; the loop will
  retry automatically within a few seconds.
- **`appletviewer: command not found`**: a very new Temurin 8 patch
  release trimmed it (shouldn't happen within JDK 8, but if it does,
  pin `eclipse-temurin:8u402-b06-jdk` or similar in the `Dockerfile`'s
  `FROM` line).
- **A binary patch starts raising `RuntimeError` on login**: the
  firmware's jar contents changed shape (an update, or a different
  unit) enough that a resolved method/field/bytecode pattern no longer
  matches. Check the error message -- each patch names exactly what it
  couldn't find.
