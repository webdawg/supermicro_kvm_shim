#!/usr/bin/env python3
"""
Logs into an old Supermicro/Peppercon IPMI web UI, pulls the live
Remote-Console applet parameters (including a fresh SESSION_ID), and
writes a local HTML file that appletviewer launches against a LOCAL
mirror of the applet jars (served by a plain http.server on
127.0.0.1:8765 -- see entrypoint.sh), rather than the BMC directly.

Why a local mirror instead of just pointing codebase at the BMC (the
obvious, simpler thing, and what earlier revisions of this script
did): this firmware's rc.jar/rcsoftkbd.jar ship the nn.pp.rckbd
locale-specific keyboard scancode translators (e.g.
KeyTranslator109pc_en_US) with signing metadata that's inconsistent
with the rest of the nn.pp.rckbd package. AppletClassLoader's sealed-
package check refuses to load them (SecurityException: "signer
information does not match..."), silently falling back to a generic
translator that never actually forwards scancodes -- keystrokes reach
the console's own KeyListener (confirmed via its keyboard debug
overlay) but never reach the remote machine. The fix is to strip the
jars' signatures entirely so every class loads under one consistent
(unsigned) identity -- which requires serving our own copy.

That in turn breaks the RFB connection, because
nn.pp.rc.RemoteConsoleApplet.a() -- the method that supplies the
"remoteHost" used for the actual socket connect -- is `return
getCodeBase().getHost()`, not the REAL_HOST applet param. Pointing
codebase at a local mirror makes every connect attempt target
127.0.0.1 and fail with "Connection refused". So RemoteConsoleApplet
gets one small binary patch too: that one 8-byte, branch-free method
is rewritten in place to `return getParameter("REAL_HOST")` instead
(see patch_remote_console_applet() below) -- a pure instruction swap,
same method length, no other class-file offsets change.
"""
import io
import os
import re
import struct
import sys
import zipfile
import requests

BMC_HOST = os.environ["BMC_HOST"]
BMC_USER = os.environ["BMC_USER"]
BMC_PASS = os.environ["BMC_PASS"]
BMC_SCHEME = os.environ.get("BMC_SCHEME", "http")
OUT_HTML = os.environ.get("OUT_HTML", "/work/console.html")
JAR_DIR = os.environ.get("JAR_DIR", "/work/jars")
PATCH_CLASSES = os.environ.get("PATCH_CLASSES", "/opt/shim/patch-classes")
LOCAL_CODEBASE = os.environ.get("LOCAL_CODEBASE", "http://127.0.0.1:8765/")
JARS = ["rc.jar", "drvredir.jar", "rcsoftkbd.jar"]

BASE = f"{BMC_SCHEME}://{BMC_HOST}"


def login():
    s = requests.Session()
    s.verify = False
    # The image-submit login button requires action_login.x/.y or this
    # old GoAhead-Webs CGI silently re-renders the login form instead
    # of redirecting.
    resp = s.post(
        f"{BASE}/auth.asp",
        data={
            "login": BMC_USER,
            "password": BMC_PASS,
            "action_login.x": "50",
            "action_login.y": "10",
        },
        headers={"Referer": f"{BASE}/auth.asp"},
        timeout=10,
        allow_redirects=True,
    )
    if "pp_session_id" not in s.cookies.get_dict():
        raise RuntimeError("login did not yield a session cookie -- check BMC_USER/BMC_PASS")
    return s


def fetch_applet_params(s):
    resp = s.get(f"{BASE}/title_app.asp", timeout=10)
    resp.raise_for_status()
    html = resp.text
    if "<applet" not in html:
        raise RuntimeError("title_app.asp did not contain an <applet> block (session invalid?)")

    applet_tag = re.search(r'code="([^"]+)"', html).group(1)
    params = re.findall(r'<param\s+name="([^"]+)"\s+value="([^"]*)"', html)
    return applet_tag, params


# ---------------------------------------------------------------------
# nn.pp.rc.RemoteConsoleApplet.a() binary patch
# ---------------------------------------------------------------------

_CP_TAG_FIXED_SIZE = {
    3: 4, 4: 4,            # Integer, Float
    5: 8, 6: 8,            # Long, Double (take 2 constant-pool slots)
    7: 2,                  # Class
    8: 2,                  # String
    9: 4, 10: 4, 11: 4,    # Fieldref, Methodref, InterfaceMethodref
    12: 4,                 # NameAndType
    15: 3,                 # MethodHandle
    16: 2,                 # MethodType
    18: 4,                 # InvokeDynamic
}


def _constant_pool_end(data):
    pos = 10  # magic(4) + minor(2) + major(2) + constant_pool_count(2)
    count = struct.unpack_from(">H", data, 8)[0]
    i = 1
    while i < count:
        tag = data[pos]
        pos += 1
        if tag == 1:  # Utf8: 2-byte length prefix + bytes
            length = struct.unpack_from(">H", data, pos)[0]
            pos += 2 + length
        else:
            pos += _CP_TAG_FIXED_SIZE[tag]
        i += 2 if tag in (5, 6) else 1
    return pos, count


def _parse_constant_pool(data):
    """Return {index: (tag, value)} for every constant-pool entry.
    Utf8 values are decoded strings; Class values are the Utf8 index
    they name; ref/NameAndType values are (a, b) index tuples."""
    pos = 10
    count = struct.unpack_from(">H", data, 8)[0]
    entries = {}
    i = 1
    while i < count:
        tag = data[pos]
        pos += 1
        if tag == 1:
            length = struct.unpack_from(">H", data, pos)[0]
            text = bytes(data[pos + 2:pos + 2 + length]).decode("utf-8")
            entries[i] = (tag, text)
            pos += 2 + length
        else:
            size = _CP_TAG_FIXED_SIZE[tag]
            if tag == 7:
                entries[i] = (tag, struct.unpack_from(">H", data, pos)[0])
            elif tag in (9, 10, 11, 12):
                entries[i] = (tag, struct.unpack_from(">HH", data, pos))
            pos += size
        i += 2 if tag in (5, 6) else 1
    return entries, count


def _find_methodref_index(data, cp_end, class_utf8, name_utf8, desc_utf8):
    """Find the constant-pool index of a Methodref by resolving its
    Class/NameAndType/Utf8 chain -- avoids hardcoding indices that
    shift across firmware/jar revisions."""
    entries, _ = _parse_constant_pool(data)

    def utf8_index(text):
        for idx, val in entries.items():
            if val == (1, text):
                return idx
        return None

    cls_idx = None
    for idx, val in entries.items():
        if val[0] == 7 and entries.get(val[1], (None,))[1] == class_utf8:
            cls_idx = idx
            break
    name_idx = utf8_index(name_utf8)
    desc_idx = utf8_index(desc_utf8)
    nt_idx = None
    for idx, val in entries.items():
        if val[0] == 12 and val[1] == (name_idx, desc_idx):
            nt_idx = idx
            break
    for idx, val in entries.items():
        if val[0] == 10 and val[1] == (cls_idx, nt_idx):
            return idx
    raise RuntimeError(f"Methodref {class_utf8}.{name_utf8}:{desc_utf8} not found in constant pool")


def patch_remote_console_applet(data):
    data = bytearray(data)
    cp_end, count = _constant_pool_end(data)

    getparam_idx = _find_methodref_index(
        data, cp_end, "java/applet/Applet", "getParameter",
        "(Ljava/lang/String;)Ljava/lang/String;")
    getcodebase_idx = _find_methodref_index(
        data, cp_end, "java/applet/Applet", "getCodeBase", "()Ljava/net/URL;")
    gethost_idx = _find_methodref_index(
        data, cp_end, "java/net/URL", "getHost", "()Ljava/lang/String;")

    utf8_bytes = b"REAL_HOST"
    utf8_entry = bytes([1]) + struct.pack(">H", len(utf8_bytes)) + utf8_bytes
    utf8_index = count
    string_entry = bytes([8]) + struct.pack(">H", utf8_index)
    string_index = count + 1
    new_count = count + 2

    new_data = bytearray()
    new_data += data[0:8]
    new_data += struct.pack(">H", new_count)
    new_data += data[10:cp_end]
    new_data += utf8_entry
    new_data += string_entry
    new_data += data[cp_end:]

    old_seq = bytes([
        0x2A,
        0xB6, (getcodebase_idx >> 8) & 0xFF, getcodebase_idx & 0xFF,
        0xB6, (gethost_idx >> 8) & 0xFF, gethost_idx & 0xFF,
        0xB0,
    ])
    hay = bytes(new_data)
    idx = hay.find(old_seq)
    if idx == -1:
        raise RuntimeError("RemoteConsoleApplet.a() bytecode not found -- firmware jar changed shape")
    if hay.find(old_seq, idx + 1) != -1:
        raise RuntimeError("RemoteConsoleApplet.a() pattern is ambiguous in this jar")

    if string_index > 0xFFFF:
        raise RuntimeError("constant pool too large for a 2-byte ldc_w index")
    new_method = bytes([
        0x2A,
        0x13, (string_index >> 8) & 0xFF, string_index & 0xFF,  # ldc_w
        0xB6, (getparam_idx >> 8) & 0xFF, getparam_idx & 0xFF,  # invokevirtual
        0xB0,
    ])
    assert len(new_method) == len(old_seq) == 8
    new_data[idx:idx + 8] = new_method

    # Code attribute header (max_stack:u2, max_locals:u2,
    # code_length:u4) sits immediately before the bytecode array we
    # just found. The original body only ever has one value on the
    # stack at a time (max_stack=1); ours briefly has two (`this` and
    # the ldc_w'd string, before invokevirtual consumes both), so
    # max_stack must become >= 2 or the verifier rejects the class
    # with "Stack size too large".
    max_stack_off = idx - 8
    cur_max_stack = struct.unpack_from(">H", new_data, max_stack_off)[0]
    if cur_max_stack < 2:
        struct.pack_into(">H", new_data, max_stack_off, 2)

    return bytes(new_data)


def patch_af_locale(data):
    # nn.pp.rc.af picks the keyboard scancode-translator locale via
    # this.getLocale() (Component.getLocale(), inherited from
    # whatever locale appletviewer's own top-level Frame resolved at
    # native/AWT-toolkit init -- it comes out "en_US" regardless of
    # -Duser.language/-Duser.country or LANG/LC_ALL, none of which
    # this code path ever consults). This firmware ships no
    # KeyTranslator_en_US/_en, only _en_GB (+ de, fr, ja, no, sv,
    # de_CH, fr_CH), so KbdFactory silently falls back to a generic
    # translator that sends real, correctly-ACKed packets (confirmed
    # via tcpdump) with scancode=0 -- a no-op the BMC correctly
    # ignores. That's the entire reason typed/soft-keyboard keys never
    # reach the remote screen despite everything else working.
    #
    # getLocale() succeeds on its first call in practice, so the
    # loop's Locale.US fallback (used only if getLocale() throws on
    # all 10 retries) never actually executes -- patching that
    # wouldn't help. Instead this replaces the call site itself:
    # `aload_0; invokevirtual Component.getLocale()` (4 bytes) becomes
    # `getstatic java.util.Locale.UK; nop` (4 bytes) -- same stack
    # effect (pushes one Locale), same length, nothing else in the
    # method shifts.
    data = bytearray(data)
    cp_end, count = _constant_pool_end(data)
    entries, _ = _parse_constant_pool(data)

    getlocale_idx = _find_methodref_index(
        data, cp_end, "java/awt/Component", "getLocale", "()Ljava/util/Locale;")

    locale_class_idx = None
    for idx, val in entries.items():
        if val[0] == 7 and entries.get(val[1], (None,))[1] == "java/util/Locale":
            locale_class_idx = idx
            break
    if locale_class_idx is None:
        raise RuntimeError("java/util/Locale Class entry not found in constant pool")

    def find_utf8(text):
        for idx, val in entries.items():
            if val == (1, text):
                return idx
        return None

    desc_idx = find_utf8("Ljava/util/Locale;")
    if desc_idx is None:
        raise RuntimeError("Ljava/util/Locale; Utf8 not found in constant pool")

    new_entries = []
    uk_utf8_idx = find_utf8("UK")
    if uk_utf8_idx is None:
        uk_utf8_idx = count + len(new_entries)
        new_entries.append(bytes([1]) + struct.pack(">H", 2) + b"UK")

    nt_idx = None
    for idx, val in entries.items():
        if val[0] == 12 and val[1] == (uk_utf8_idx, desc_idx):
            nt_idx = idx
            break
    if nt_idx is None:
        nt_idx = count + len(new_entries)
        new_entries.append(bytes([12]) + struct.pack(">HH", uk_utf8_idx, desc_idx))

    fieldref_idx = None
    for idx, val in entries.items():
        if val[0] == 9 and val[1] == (locale_class_idx, nt_idx):
            fieldref_idx = idx
            break
    if fieldref_idx is None:
        fieldref_idx = count + len(new_entries)
        new_entries.append(bytes([9]) + struct.pack(">HH", locale_class_idx, nt_idx))

    new_count = count + len(new_entries)
    if new_count > 0xFFFF:
        raise RuntimeError("constant pool too large")

    new_data = bytearray()
    new_data += data[0:8]
    new_data += struct.pack(">H", new_count)
    new_data += data[10:cp_end]
    for entry in new_entries:
        new_data += entry
    new_data += data[cp_end:]

    old_seq = bytes([
        0x2A,
        0xB6, (getlocale_idx >> 8) & 0xFF, getlocale_idx & 0xFF,
    ])
    hay = bytes(new_data)
    idx = hay.find(old_seq)
    if idx == -1:
        raise RuntimeError("af.getLocale() call site not found -- firmware jar changed shape")
    if hay.find(old_seq, idx + 1) != -1:
        raise RuntimeError("af.getLocale() call site pattern is ambiguous in this jar")

    if fieldref_idx > 0xFFFF:
        raise RuntimeError("constant pool too large for a 2-byte getstatic index")
    new_call = bytes([
        0xB2, (fieldref_idx >> 8) & 0xFF, fieldref_idx & 0xFF,  # getstatic Locale.UK
        0x00,  # nop, pads to the same 4-byte length as aload_0+invokevirtual
    ])
    assert len(new_call) == len(old_seq) == 4
    new_data[idx:idx + 4] = new_call

    return bytes(new_data)


PATCH_CLASS_FILES = ["nn/pp/rc/bm.class", "nn/pp/rc/bm$Listener.class", "nn/pp/rc/bm$1.class"]
SIGNATURE_PREFIXES = ("META-INF/",)


def fetch_and_patch_jars():
    os.makedirs(JAR_DIR, exist_ok=True)
    for jar_name in JARS:
        resp = requests.get(f"{BASE}/{jar_name}", timeout=15, verify=False)
        resp.raise_for_status()
        out_path = os.path.join(JAR_DIR, jar_name)

        with zipfile.ZipFile(io.BytesIO(resp.content)) as src, \
             zipfile.ZipFile(out_path, "w", zipfile.ZIP_DEFLATED) as dst:
            for item in src.infolist():
                # Strip all signing metadata (signature files AND the
                # manifest, which carries now-stale per-entry digests)
                # so every class loads under one consistent, unsigned
                # identity -- this is what lets the previously-
                # rejected nn.pp.rckbd locale keyboard translators
                # load. Permissions here already come from the
                # codebase-scoped policy grant (security/all.policy),
                # not the signer, so this loses nothing we rely on.
                if item.filename.startswith(SIGNATURE_PREFIXES):
                    continue
                data = src.read(item.filename)
                if jar_name == "rc.jar" and item.filename == "nn/pp/rc/RemoteConsoleApplet.class":
                    data = patch_remote_console_applet(data)
                if jar_name == "rc.jar" and item.filename == "nn/pp/rc/af.class":
                    data = patch_af_locale(data)
                if jar_name == "rc.jar" and item.filename in PATCH_CLASS_FILES:
                    continue
                dst.writestr(item, data)
            if jar_name == "rc.jar":
                for rel_path in PATCH_CLASS_FILES:
                    with open(os.path.join(PATCH_CLASSES, rel_path), "rb") as f:
                        dst.writestr(rel_path, f.read())


def write_html(applet_class, params):
    # appletviewer's HTML mini-parser mis-tokenizes value="" (emits a
    # bogus "tag requires name attribute" warning and corrupts
    # subsequent param parsing), so blank-valued params generally get
    # dropped entirely -- fine for plain getParameter() reads (null
    # and "" are treated the same).
    #
    # HOTKEY_N/HOTKEYCODE_N/HOTKEYNAME_N are the exception: the applet
    # builds three parallel arrays by counting each prefix
    # (ServerConsolePanelBase.a -> nn.pp.rc.am.<init>) and only
    # length-checks the first two against each other -- the third
    # (HOTKEYNAME_*) has NO bounds check. Dropping a blank
    # HOTKEYNAME_N makes that array shorter than the other two and
    # throws ArrayIndexOutOfBoundsException. Keep these present with a
    # single space instead, so the parser doesn't choke but the array
    # lengths still line up.
    #
    # REAL_HOST must be explicit and correct now: codebase points at
    # our local jar mirror, and the patched RemoteConsoleApplet.a()
    # reads this param directly for the actual RFB connection target.
    def out_value(name, value):
        if name == "REAL_HOST":
            return BMC_HOST
        if value != "":
            return value
        return " " if name.startswith("HOTKEY") else None

    lines = []
    for name, value in params:
        v = out_value(name, value)
        if v is not None:
            lines.append(f'      <param name="{name}" value="{v}">')
    param_lines = "\n".join(lines)
    html = f"""<html>
<body>
<applet code="{applet_class}"
        codebase="{LOCAL_CODEBASE}"
        archive="rc.jar,drvredir.jar,rcsoftkbd.jar"
        width="300" height="80">
{param_lines}
</applet>
</body>
</html>
"""
    os.makedirs(os.path.dirname(OUT_HTML), exist_ok=True)
    with open(OUT_HTML, "w") as f:
        f.write(html)


def main():
    requests.packages.urllib3.disable_warnings()
    s = login()
    applet_class, params = fetch_applet_params(s)
    fetch_and_patch_jars()
    write_html(applet_class, params)
    print(f"[login_and_launch] wrote {OUT_HTML} for {applet_class} "
          f"({len(params)} params, session live)")


if __name__ == "__main__":
    try:
        main()
    except Exception as e:
        print(f"[login_and_launch] ERROR: {e}", file=sys.stderr)
        sys.exit(1)
