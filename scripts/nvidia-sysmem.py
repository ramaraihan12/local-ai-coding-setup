"""
nvidia-sysmem.py - check / set NVIDIA "CUDA - Sysmem Fallback Policy" (DRS setting 0x10ECECC9)

Purpose
  Sets "CUDA - Sysmem Fallback Policy" = 1 ("Prefer No Sysmem Fallback") on exactly three NVIDIA
  driver profiles, so CUDA reports out-of-memory instead of silently spilling VRAM into
  (much slower) system RAM:
    1. user-created profile for %AI_ROOT%\\llama.cpp\\llama-server.exe
    2. user-created profile for %AI_ROOT%\\llama.cpp\\llama-bench.exe
    3. NVIDIA predefined profile "Ollama" (ollama.exe, "ollama app.exe")
  AI_ROOT defaults to C:\\AI, like the PowerShell scripts. The Base/global profile and every other
  setting are never touched. Uses NVAPI DRS through ctypes (C:\\Windows\\System32\\nvapi64.dll), the
  same calls as NVIDIA Profile Inspector.
  The two llama.cpp entries must already exist: add both .exe files once in NVIDIA Control Panel >
  Manage 3D settings > Program Settings > Add. This script never creates profiles.

Usage
  python -I nvidia-sysmem.py            same as --check (read-only)
  python -I nvidia-sysmem.py --check    print the current value for the 3 profiles + Base profile
  python -I nvidia-sysmem.py --apply    set value 1 on the 3 profiles, save once, then re-check
  Running processes (llama-server, Ollama) only pick the change up after they are restarted.
  If --apply reports a privilege error, it prints the elevated command to run.

Rollback
  - Copy C:\\ProgramData\\NVIDIA Corporation\\Drs\\ somewhere safe before the first --apply; to undo,
    copy nvdrsdb0.bin / nvdrsdb1.bin / nvdrssel.bin back, or
  - NVIDIA Control Panel > Manage 3D settings > Program Settings > pick the program >
    "CUDA - Sysmem Fallback Policy" = "Use global setting (Driver Default)" (value 0) > Apply.

Verified references
  - Function IDs: NVIDIA nvapi_interface.h (github.com/NVIDIA/nvapi) and Profile Inspector NvapiDrsWrapper.cs.
    NvAPI_DRS_SetSetting 0x577DD202, NvAPI_DRS_SaveSettings 0xFCBC7E14, NvAPI_DRS_GetSetting 0x73BF8338, ...
    0x10ECECC9 is an *internal* setting (absent from the public available-ID list), so like Profile
    Inspector we fall back to the internal SetSetting/GetSetting variants (0x8A2CF5F5 / 0xEA99498D,
    each with extra 0-valued args) when the public call rejects the ID.
  - NVDRS_SETTING_V1 (nvapi.h, #pragma pack(4)): version, wchar settingName[2048], settingId, settingType,
    settingLocation, isCurrentPredefined, isPredefinedValid, 2 x 4100-byte value unions = 12320 bytes;
    NVDRS_SETTING_VER = sizeof | (1 << 16).
  - Values (Profile Inspector CustomSettingNames.xml / driver EnumAvailableSettingValues):
    0 = driver default, 1 = Prefer No Sysmem Fallback, 2 = Prefer Sysmem Fallback.
"""
import argparse
import ctypes as C
import os
import sys

SYSMEM_ID = 0x10ECECC9
TARGET_VALUE = 1
SYSMEM_VALS = {0: "Driver default (Use the recommended setting)",
               1: "Prefer No Sysmem Fallback",
               2: "Prefer Sysmem Fallback"}
LOC = {0: "current profile", 1: "global profile", 2: "base profile", 3: "default"}

LLAMA_DIR = os.path.normpath(os.path.join(os.environ.get("AI_ROOT") or r"C:\AI", "llama.cpp"))

# The only three profiles this script may modify.
TARGETS = [
    {"label": "llama-server", "app": os.path.join(LLAMA_DIR, "llama-server.exe")},
    {"label": "llama-bench", "app": os.path.join(LLAMA_DIR, "llama-bench.exe")},
    {"label": "Ollama", "profile": "Ollama", "contains": "ollama.exe"},
]

UNI = 2048  # NVAPI_UNICODE_STRING_MAX
NVAPI_OK = 0
NVAPI_INVALID_USER_PRIVILEGE = -137
NVAPI_SETTING_NOT_FOUND = -160
NVAPI_ACCESS_DENIED = -175
PRIV_ERRORS = (NVAPI_INVALID_USER_PRIVILEGE, NVAPI_ACCESS_DENIED)
NVDRS_DWORD_TYPE = 0


class NvError(Exception):
    def __init__(self, what, rc):
        super().__init__(f"{what} failed: {err(rc)}")
        self.rc = rc


class PROFILE(C.Structure):
    _fields_ = [("version", C.c_uint32), ("profileName", C.c_wchar * UNI),
                ("gpuSupport", C.c_uint32), ("isPredefined", C.c_uint32),
                ("numOfApps", C.c_uint32), ("numOfSettings", C.c_uint32)]


class APP4(C.Structure):
    _fields_ = [("version", C.c_uint32), ("isPredefined", C.c_uint32),
                ("appName", C.c_wchar * UNI), ("userFriendlyName", C.c_wchar * UNI),
                ("launcher", C.c_wchar * UNI), ("fileInFolder", C.c_wchar * UNI),
                ("bits", C.c_uint32), ("commandLine", C.c_wchar * UNI)]


class SETTING(C.Structure):  # NVDRS_SETTING_V1
    _fields_ = [("version", C.c_uint32), ("settingName", C.c_wchar * UNI),
                ("settingId", C.c_uint32), ("settingType", C.c_int32),
                ("settingLocation", C.c_int32), ("isCurrentPredefined", C.c_uint32),
                ("isPredefinedValid", C.c_uint32),
                ("predefinedValue", C.c_ubyte * 4100), ("currentValue", C.c_ubyte * 4100)]


assert C.sizeof(SETTING) == 12320 and C.sizeof(PROFILE) == 4116 and C.sizeof(APP4) == 20492
SETTING_VER = C.sizeof(SETTING) | (1 << 16)
PROFILE_VER = C.sizeof(PROFILE) | (1 << 16)
APP_VER = C.sizeof(APP4) | (4 << 16)

H = C.c_void_p
_dll = C.CDLL(os.path.join(os.environ.get("SystemRoot", r"C:\Windows"), "System32", "nvapi64.dll"))
_qi = _dll.nvapi_QueryInterface
_qi.restype = C.c_void_p
_qi.argtypes = [C.c_uint32]


def _fn(fid, *argtypes):
    p = _qi(fid)
    return C.CFUNCTYPE(C.c_int32, *argtypes)(p) if p else None


Initialize = _fn(0x0150E828)
GetErrorMessage = _fn(0x6C2D048C, C.c_int32, C.c_char_p)
GetDriverVersion = _fn(0x2926AAAD, C.POINTER(C.c_uint32), C.c_char_p)
CreateSession = _fn(0x0694D52E, C.POINTER(H))
DestroySession = _fn(0xDAD9CFF8, H)
LoadSettings = _fn(0x375DBD6B, H)
SaveSettings = _fn(0xFCBC7E14, H)
FindApplicationByName = _fn(0xEEE566B2, H, C.c_wchar_p, C.POINTER(H), C.POINTER(APP4))
FindProfileByName = _fn(0x7E4A9A0B, H, C.c_wchar_p, C.POINTER(H))
GetProfileInfo = _fn(0x61CD6FD6, H, H, C.POINTER(PROFILE))
EnumApplications = _fn(0x7FA2173A, H, H, C.c_uint32, C.POINTER(C.c_uint32), C.POINTER(APP4))
GetBaseProfile = _fn(0xDA8466A0, H, C.POINTER(H))
GetCurrentGlobalProfile = _fn(0x617BFF9F, H, C.POINTER(H))
GetSettingPub = _fn(0x73BF8338, H, H, C.c_uint32, C.POINTER(SETTING))
GetSettingInt = _fn(0xEA99498D, H, H, C.c_uint32, C.POINTER(SETTING), C.POINTER(C.c_uint32))
SetSettingPub = _fn(0x577DD202, H, H, C.POINTER(SETTING))
SetSettingInt = _fn(0x8A2CF5F5, H, H, C.POINTER(SETTING), C.c_uint32, C.c_uint32)


def err(rc):
    if rc == NVAPI_OK:
        return "OK"
    b = C.create_string_buffer(64)
    if GetErrorMessage:
        GetErrorMessage(rc, b)
    return f"{rc} ({b.value.decode(errors='replace') or 'unknown'})"


def check(rc, what):
    if rc != NVAPI_OK:
        raise NvError(what, rc)


def wbuf(s):
    return C.create_unicode_buffer(s, UNI)


def u32(arr):
    return int.from_bytes(bytes(arr[:4]), "little")


def profile_info(hs, hp):
    p = PROFILE(); p.version = PROFILE_VER
    check(GetProfileInfo(hs, hp, C.byref(p)), "GetProfileInfo")
    return p


def profile_apps(hs, hp):
    out, start = [], 0
    while True:
        arr = (APP4 * 16)()
        for a in arr:
            a.version = APP_VER
        n = C.c_uint32(16)
        if EnumApplications(hs, hp, start, C.byref(n), arr) != NVAPI_OK:
            break
        out.extend(arr[i].appName for i in range(n.value))
        if n.value < 16:
            break
        start += n.value
    return out


def get_setting(hs, hp, sid):
    """Returns (rc, SETTING). Internal variant first (0x10ECECC9 is an internal setting), like Profile Inspector."""
    s = SETTING(); s.version = SETTING_VER
    if GetSettingInt:
        x = C.c_uint32(0)
        rc = GetSettingInt(hs, hp, sid, C.byref(s), C.byref(x))
    else:
        rc = GetSettingPub(hs, hp, sid, C.byref(s))
    return rc, s


def set_dword(hs, hp, sid, value):
    """NvAPI_DRS_SetSetting; falls back to the internal variant if the public one rejects the ID."""
    s = SETTING(); s.version = SETTING_VER
    s.settingId = sid
    s.settingType = NVDRS_DWORD_TYPE
    s.currentValue[:4] = list(value.to_bytes(4, "little"))
    rc = SetSettingPub(hs, hp, C.byref(s))
    if rc == NVAPI_OK:
        return "public 0x577DD202"
    if rc in PRIV_ERRORS or not SetSettingInt:
        raise NvError("NvAPI_DRS_SetSetting", rc)
    first = err(rc)
    s2 = SETTING(); s2.version = SETTING_VER
    s2.settingId = sid
    s2.settingType = NVDRS_DWORD_TYPE
    s2.currentValue[:4] = list(value.to_bytes(4, "little"))
    rc2 = SetSettingInt(hs, hp, C.byref(s2), 0, 0)
    if rc2 != NVAPI_OK:
        raise NvError(f"NvAPI_DRS_SetSetting (public: {first}; internal 0x8A2CF5F5)", rc2)
    return f"internal 0x8A2CF5F5 (public returned {first})"


def describe(hs, hp):
    """(is_user_set_to_target, text)"""
    rc, s = get_setting(hs, hp, SYSMEM_ID)
    if rc == NVAPI_SETTING_NOT_FOUND:
        return False, "not set -> driver default (0 = Use the recommended setting, i.e. sysmem fallback allowed)"
    if rc != NVAPI_OK:
        return False, f"GetSetting error {err(rc)}"
    if s.settingType != NVDRS_DWORD_TYPE:
        return False, f"unexpected setting type {s.settingType}"
    v = u32(s.currentValue)
    user = s.isCurrentPredefined == 0 and s.settingLocation == 0
    src = "user-set in this profile" if user else \
        f"predefined, from {LOC.get(s.settingLocation, s.settingLocation)}"
    return (user and v == TARGET_VALUE), f"{v} = {SYSMEM_VALS.get(v, 'unknown value')}  [{src}]"


def resolve(hs, t, base_handles):
    """Find the profile handle for a target and verify it is exactly the intended profile."""
    hp = H()
    if "app" in t:
        app = APP4(); app.version = APP_VER
        check(FindApplicationByName(hs, wbuf(t["app"]), C.byref(hp), C.byref(app)),
              f"FindApplicationByName({t['app']})")
        found = app.appName.replace("/", "\\").lower()
        if app.isPredefined or found != t["app"].lower():
            raise RuntimeError(f"{t['label']}: matched unexpected app entry {app.appName!r} "
                               f"(predefined={app.isPredefined}); expected user entry for {t['app']}")
        info = profile_info(hs, hp)
        if info.isPredefined:
            raise RuntimeError(f"{t['label']}: profile {info.profileName!r} is predefined, expected user-created")
    else:
        check(FindProfileByName(hs, wbuf(t["profile"]), C.byref(hp)), f"FindProfileByName({t['profile']})")
        info = profile_info(hs, hp)
        apps = [a.lower() for a in profile_apps(hs, hp)]
        if info.profileName != t["profile"] or not info.isPredefined or t["contains"] not in apps:
            raise RuntimeError(f"{t['label']}: profile {info.profileName!r} does not look like NVIDIA's "
                               f"predefined profile (apps={apps})")
    if hp.value in base_handles or info.profileName == "Base Profile":
        raise RuntimeError(f"{t['label']}: resolved to the Base/global profile - refusing")
    kind = "predefined" if info.isPredefined else "user-created"
    return hp, f"profile {info.profileName!r} ({kind}; apps: {', '.join(profile_apps(hs, hp))})"


def base_handles(hs):
    out = set()
    for f in (GetBaseProfile, GetCurrentGlobalProfile):
        h = H()
        if f(hs, C.byref(h)) == NVAPI_OK and h.value:
            out.add(h.value)
    return out


def raw_db_report():
    d = os.path.join(os.environ.get("ProgramData", r"C:\ProgramData"), "NVIDIA Corporation", "Drs")
    needle = SYSMEM_ID.to_bytes(4, "little")
    parts = []
    for name in ("nvdrsdb0.bin", "nvdrsdb1.bin"):
        try:
            with open(os.path.join(d, name), "rb") as f:
                parts.append(f"{name}: {f.read().count(needle)}x")
        except OSError as e:
            parts.append(f"{name}: unreadable ({e.strerror})")
    try:
        with open(os.path.join(d, "nvdrssel.bin"), "rb") as f:
            parts.append(f"nvdrssel.bin={f.read().hex()}")
    except OSError:
        pass
    return f"raw DB bytes {needle.hex(' ').upper()} : " + ", ".join(parts)


class Session:
    def __enter__(self):
        self.h = H()
        check(CreateSession(C.byref(self.h)), "NvAPI_DRS_CreateSession")
        try:
            check(LoadSettings(self.h), "NvAPI_DRS_LoadSettings")
        except Exception:
            DestroySession(self.h)
            raise
        return self.h

    def __exit__(self, *exc):
        rc = DestroySession(self.h)
        if rc != NVAPI_OK:
            print(f"warning: DestroySession: {err(rc)}")
        return False


def do_check():
    ok_all = True
    with Session() as hs:
        bh = base_handles(hs)
        for t in TARGETS:
            try:
                hp, desc = resolve(hs, t, bh)
            except (NvError, RuntimeError) as e:
                print(f"  {t['label']:<13} ERROR: {e}")
                ok_all = False
                continue
            ok, txt = describe(hs, hp)
            ok_all &= ok
            print(f"  {t['label']:<13} {desc}\n  {'':<13} -> {txt}")
        hb = H()
        if GetBaseProfile(hs, C.byref(hb)) == NVAPI_OK:
            _, txt = describe(hs, hb)
            print(f"  {'Base profile':<13} -> {txt}")
    print("  " + raw_db_report())
    return ok_all


def do_apply():
    with Session() as hs:
        bh = base_handles(hs)
        resolved = [(t, *resolve(hs, t, bh)) for t in TARGETS]  # all-or-nothing: resolve first
        changed = 0
        for t, hp, desc in resolved:
            ok, txt = describe(hs, hp)
            if ok:
                print(f"  {t['label']:<13} already {txt} - skipped")
                continue
            how = set_dword(hs, hp, SYSMEM_ID, TARGET_VALUE)
            ok, txt = describe(hs, hp)  # read back from the session before saving
            if not ok:
                raise RuntimeError(f"{t['label']}: read-back after SetSetting gave '{txt}' - not saving")
            print(f"  {t['label']:<13} SetSetting via {how}: OK -> {txt}")
            changed += 1
        if changed:
            check(SaveSettings(hs), "NvAPI_DRS_SaveSettings")
            print(f"  NvAPI_DRS_SaveSettings: OK ({changed} profile(s) changed)")
        else:
            print("  nothing to change, SaveSettings not called")


def elevated_hint():
    py = sys.executable
    script = os.path.abspath(__file__)
    print("\nPrivilege error - run this once in PowerShell (accept the UAC prompt):")
    print(f"""  Start-Process "{py}" -Verb RunAs -Wait -ArgumentList '-I','"{script}"','--apply'""")
    print("then verify (non-elevated):")
    print(f'  & "{py}" -I "{script}" --check')


def main():
    ap = argparse.ArgumentParser(description="Check/set NVIDIA CUDA Sysmem Fallback Policy (0x10ECECC9) "
                                             "for llama-server, llama-bench and Ollama profiles.")
    g = ap.add_mutually_exclusive_group()
    g.add_argument("--check", action="store_true", help="read-only report (default)")
    g.add_argument("--apply", action="store_true", help="set value 1 (Prefer No Sysmem Fallback) and save")
    args = ap.parse_args()

    rc = Initialize()
    if rc != NVAPI_OK:
        print(f"NvAPI_Initialize failed: {err(rc)}")
        return 1
    ver, branch = C.c_uint32(0), C.create_string_buffer(64)
    drv = ""
    if GetDriverVersion and GetDriverVersion(C.byref(ver), branch) == NVAPI_OK:
        drv = f"  (driver {ver.value // 100}.{ver.value % 100:02d}, {branch.value.decode(errors='replace')})"
    print(f"NVIDIA DRS - CUDA Sysmem Fallback Policy 0x{SYSMEM_ID:08X}{drv}")

    if args.apply:
        print("APPLY:")
        try:
            do_apply()
        except NvError as e:
            print(f"  FAILED: {e}  (no changes were saved)")
            if e.rc in PRIV_ERRORS:
                elevated_hint()
                return 2
            return 1
        except (RuntimeError, OSError) as e:
            print(f"  FAILED: {e}  (no changes were saved)")
            return 1
        print("CHECK after apply:")
        ok = do_check()
        print("RESULT:", "all 3 profiles = 1 (Prefer No Sysmem Fallback), user-set" if ok else "NOT all set - see above")
        print("Note: restart llama-server / Ollama for the change to take effect.")
        return 0 if ok else 1

    print("CHECK (read-only):")
    try:
        ok = do_check()
    except NvError as e:
        print(f"  FAILED: {e}")
        return 1
    print("RESULT:", "all 3 profiles = 1 (Prefer No Sysmem Fallback), user-set" if ok else "NOT all set to 1")
    return 0 if ok else 3


if __name__ == "__main__":
    sys.exit(main())
