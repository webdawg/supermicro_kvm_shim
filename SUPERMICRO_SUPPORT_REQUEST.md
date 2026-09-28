# Supermicro support request — AOC-IPMI20-E USB keyboard enumeration bug

Sent 2026-09-28. Asking whether a USB-1.1-forcing (or otherwise fixed)
firmware revision exists for this board's IPMI module, analogous to
[Supermicro FAQ 11530](https://www.supermicro.com/en/support/faqs/faq.php?faq=11530)'s
fix for the X7DBU/SIMSO+ combo. See README.md's "Known issue" section
for full background. No response yet.

---

**Subject:** AOC-IPMI20-E (X7DB8) — virtual KVM keyboard fails OS-side USB enumeration; USB 1.1-forcing firmware available?

**Hardware:**
- Motherboard: Supermicro X7DB8
- IPMI module: AOC-IPMI20-E (add-on card)
- BMC manufacturer/chipset: Peppercon AG, Device ID 34, Product ID 4
- Current BMC/IPMI firmware revision: 1.64
- Host OS: FreeBSD 13.1 (TrueNAS CORE)

**Symptom:**
The remote KVM console's virtual keyboard produces no input once the
host OS has booted — video and mouse both work correctly, but no
keystrokes (from the Java remote console, its soft/on-screen keyboard,
or the BMC's own hardcoded Ctrl+Alt+Delete hotkey) reach the OS. The
same virtual keyboard works correctly during BIOS/POST through the
same remote console — the failure begins specifically once the OS
takes over.

**Diagnosis (done directly on the host via SSH, bypassing the console):**
`dmesg` shows the BMC's virtual USB HID device failing FreeBSD's own
USB enumeration at boot, on the onboard EHCI/USB2.0 controller:

```
usb_alloc_device: set address 2 failed (USB_ERR_IOERROR, ignored)
usbd_setup_device_desc: getting device descriptor at addr 2 failed, USB_ERR_IOERROR
usbd_req_re_enumerate: addr=2, set address failed! (USB_ERR_IOERROR, ignored)
[repeats ~5-6 times]
ugen3.2: <Unknown > at usbus3 (disconnected)
uhub_reattach_port: could not allocate new device
```

It never resolves a vendor/product ID — a full enumeration failure,
not a driver mismatch. This is consistent with the device failing a
full OS-level USB enumeration while BIOS's much simpler legacy USB
keyboard polling tolerates it.

**Request:**
I found Supermicro FAQ #11530, describing an identical bug class on
the X7DBU board with a SIMSO+ IPMI module (BMC firmware 1.59–1.63),
where the virtual HID device's USB 2.0 negotiation failed under the
OS's USB2 stack. The fix was a special firmware build
(`ugsim163-USB1-1.bin`) forcing that module's virtual USB device down
to USB 1.1.

Is there an equivalent USB-1.1-forcing (or otherwise fixed) firmware
revision available for the **AOC-IPMI20-E** module used on the X7DB8?
Current firmware is 1.64.
