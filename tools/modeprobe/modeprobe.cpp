// modeprobe - Qubes Windows display performance: display-mode witness (Track B / T2, A0).
//
// PLAN-trackb-t2-modes.md section 3 A0: the project's EXTERNAL witness for display-mode
// questions - the only thing that can contradict the gui-agent's own claims about what
// mode list exists and what mode is actually current. It replaces an ad-hoc PowerShell
// probe that was already known-broken.
//
// What it does:
//   1. Enumerates every display device (EnumDisplayDevicesW loop) and for each one every
//      mode (EnumDisplaySettingsExW, iModeNum 0..) plus the CURRENT mode
//      (ENUM_CURRENT_SETTINGS).
//   2. --test WxH: ChangeDisplaySettingsExW with CDS_TEST - applies NOTHING, reports the
//      DISP_CHANGE_* verdict by name. This is how "the BDA rejects 1600x1000" is proven.
//   3. --apply WxH[@bpp[@hz]]: actually applies the mode, then RE-READS
//      ENUM_CURRENT_SETTINGS and reports what is really current (readback, never the
//      request - the agent's bug of trusting the request is exactly what A2 fixes).
//      Exit code is non-zero if readback != request.
//
// WHY --apply DOES NOT USE CDS_UPDATEREGISTRY (dynamic-only, no persistence):
//   (a) Every T2 experiment is anchored to cold-boot baselines. A registry-persisted mode
//       survives reboot and silently contaminates the NEXT experiment's baseline; a
//       dynamic change reverts to the last persisted mode on reboot, so a plain qube
//       restart is always a clean revert path - important on a guest that can go headless
//       if a bad mode lands.
//   (b) The tool is a probe, not a configurator. Persisting state would make the witness
//       itself a source of the configuration drift the plan warns about (section 6,
//       "guest configuration hygiene").
//
// Output: exactly ONE single-line JSON object on stdout - machine-parseable, no prose.
// All diagnostics/usage go to stderr. --json FILE additionally writes the same object to
// a file. Environment reporting (host/session/window station/desktop) follows
// tools/ddaprobe/ddaprobe.cpp so run-validity checks (session_id 1, WinSta0, Default)
// work identically on both tools.
//
// Exit codes:
//   0  probe ran; for --apply: readback matched the request
//   1  no display devices enumerated (broken environment)
//   2  usage error
//   3  --apply failed or readback != request
//   (--test always exits 0 when the probe itself ran: the DISP_CHANGE_* verdict is the
//    data, and a rejection is a *successful* measurement.)
//
// Build: MSVC v143, /MT, Windows SDK 10, x64. See modeprobe.vcxproj.
//
// STATUS: UNCOMPILED on the dev qube (no MSVC on Linux). Only long-stable USER32 display
// APIs are used.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <windows.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include <string>
#include <vector>
#include <algorithm>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "advapi32.lib")

#define MODEPROBE_VERSION "1.0"

// ---------------------------------------------------------------- small helpers

static std::string W2U(const wchar_t* w)
{
    if (!w || !*w)
        return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w, -1, nullptr, 0, nullptr, nullptr);
    if (n <= 1)
        return std::string();
    std::string s((size_t)(n - 1), '\0');
    WideCharToMultiByte(CP_UTF8, 0, w, -1, &s[0], n, nullptr, nullptr);
    return s;
}

static std::wstring U2W(const char* s)
{
    if (!s || !*s)
        return std::wstring();
    int n = MultiByteToWideChar(CP_UTF8, 0, s, -1, nullptr, 0);
    if (n <= 1)
        return std::wstring();
    std::wstring w((size_t)(n - 1), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, s, -1, &w[0], n);
    return w;
}

static std::string JEsc(const std::string& s)
{
    std::string o;
    o.reserve(s.size() + 8);
    for (size_t i = 0; i < s.size(); i++)
    {
        unsigned char c = (unsigned char)s[i];
        switch (c)
        {
        case '"':  o += "\\\""; break;
        case '\\': o += "\\\\"; break;
        case '\n': o += "\\n";  break;
        case '\r': o += "\\r";  break;
        case '\t': o += "\\t";  break;
        default:
            if (c < 0x20)
            {
                char b[8];
                sprintf_s(b, sizeof(b), "\\u%04x", (unsigned)c);
                o += b;
            }
            else
            {
                o += (char)c;
            }
        }
    }
    return o;
}

static std::string Fmt(const char* fmt, ...)
{
    char buf[1024];
    va_list ap;
    va_start(ap, fmt);
    _vsnprintf_s(buf, sizeof(buf), _TRUNCATE, fmt, ap);
    va_end(ap);
    return std::string(buf);
}

static std::string JStr(const std::string& v) { return "\"" + JEsc(v) + "\""; }
static std::string JBool(bool v) { return v ? "true" : "false"; }

static const char* DispChangeName(LONG r)
{
    switch (r)
    {
    case DISP_CHANGE_SUCCESSFUL:  return "DISP_CHANGE_SUCCESSFUL";
    case DISP_CHANGE_RESTART:     return "DISP_CHANGE_RESTART";
    case DISP_CHANGE_FAILED:      return "DISP_CHANGE_FAILED";
    case DISP_CHANGE_BADMODE:     return "DISP_CHANGE_BADMODE";
    case DISP_CHANGE_NOTUPDATED:  return "DISP_CHANGE_NOTUPDATED";
    case DISP_CHANGE_BADFLAGS:    return "DISP_CHANGE_BADFLAGS";
    case DISP_CHANGE_BADPARAM:    return "DISP_CHANGE_BADPARAM";
    case DISP_CHANGE_BADDUALVIEW: return "DISP_CHANGE_BADDUALVIEW";
    default:                      return "UNKNOWN";
    }
}

// ---------------------------------------------------------------- environment
// Same fields and same sources as tools/ddaprobe/ddaprobe.cpp GatherEnv(), so the run
// validity checks (session_id == 1, WinSta0, Default) parse identically on both tools.

struct EnvInfo
{
    std::string host, user, winsta, desktop, os_build;
    DWORD session_id = 0;
    bool elevated = false;
};

static std::string UserObjectName(HANDLE h)
{
    if (!h)
        return std::string();
    wchar_t buf[256] = { 0 };
    DWORD needed = 0;
    if (GetUserObjectInformationW(h, UOI_NAME, buf, (DWORD)sizeof(buf), &needed))
        return W2U(buf);
    return std::string();
}

static EnvInfo GatherEnv()
{
    EnvInfo e;

    wchar_t wbuf[256];
    DWORD cch = ARRAYSIZE(wbuf);
    if (GetComputerNameW(wbuf, &cch))
        e.host = W2U(wbuf);
    cch = ARRAYSIZE(wbuf);
    if (GetUserNameW(wbuf, &cch))
        e.user = W2U(wbuf);

    ProcessIdToSessionId(GetCurrentProcessId(), &e.session_id);
    e.winsta = UserObjectName(GetProcessWindowStation());
    e.desktop = UserObjectName(GetThreadDesktop(GetCurrentThreadId()));

    wchar_t build[64] = { 0 };
    DWORD cb = (DWORD)sizeof(build);
    DWORD ubr = 0, cbUbr = (DWORD)sizeof(ubr);
    if (RegGetValueW(HKEY_LOCAL_MACHINE,
                     L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion",
                     L"CurrentBuildNumber", RRF_RT_REG_SZ, nullptr, build, &cb) == ERROR_SUCCESS)
    {
        e.os_build = W2U(build);
        if (RegGetValueW(HKEY_LOCAL_MACHINE,
                         L"SOFTWARE\\Microsoft\\Windows NT\\CurrentVersion",
                         L"UBR", RRF_RT_REG_DWORD, nullptr, &ubr, &cbUbr) == ERROR_SUCCESS)
        {
            e.os_build += Fmt(".%lu", (unsigned long)ubr);
        }
    }

    HANDLE token = nullptr;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token))
    {
        TOKEN_ELEVATION el = { 0 };
        DWORD ret = 0;
        if (GetTokenInformation(token, TokenElevation, &el, (DWORD)sizeof(el), &ret))
            e.elevated = (el.TokenIsElevated != 0);
        CloseHandle(token);
    }
    return e;
}

// ---------------------------------------------------------------- device/mode model

struct Mode
{
    DWORD w = 0, h = 0, bpp = 0, hz = 0;
};

static bool ModeLess(const Mode& a, const Mode& b)
{
    if (a.w != b.w) return a.w < b.w;
    if (a.h != b.h) return a.h < b.h;
    if (a.bpp != b.bpp) return a.bpp < b.bpp;
    return a.hz < b.hz;
}

static bool ModeEq(const Mode& a, const Mode& b)
{
    return a.w == b.w && a.h == b.h && a.bpp == b.bpp && a.hz == b.hz;
}

static std::string JMode(const Mode& m)
{
    return Fmt("{\"w\":%lu,\"h\":%lu,\"bpp\":%lu,\"hz\":%lu}",
               (unsigned long)m.w, (unsigned long)m.h,
               (unsigned long)m.bpp, (unsigned long)m.hz);
}

struct DeviceInfo
{
    std::wstring name_w;            // for the Win32 calls
    std::string name;               // UTF-8, for JSON
    std::string device_string;
    DWORD state_flags = 0;
    bool attached = false;
    bool primary = false;
    bool has_current = false;
    Mode current;
    std::vector<Mode> modes;        // deduplicated {w,h,bpp,hz}
    size_t raw_mode_count = 0;      // before dedup (duplicates carry orientation etc.)
};

static bool ReadCurrentMode(const wchar_t* devName, Mode* out)
{
    DEVMODEW dm;
    ZeroMemory(&dm, sizeof(dm));
    dm.dmSize = sizeof(dm);
    if (!EnumDisplaySettingsExW(devName, ENUM_CURRENT_SETTINGS, &dm, 0))
        return false;
    out->w = dm.dmPelsWidth;
    out->h = dm.dmPelsHeight;
    out->bpp = dm.dmBitsPerPel;
    out->hz = dm.dmDisplayFrequency;
    return true;
}

static std::vector<DeviceInfo> EnumerateDevices()
{
    std::vector<DeviceInfo> out;
    for (DWORD i = 0; ; i++)
    {
        DISPLAY_DEVICEW dd;
        ZeroMemory(&dd, sizeof(dd));
        dd.cb = sizeof(dd);
        if (!EnumDisplayDevicesW(nullptr, i, &dd, 0))
            break;

        DeviceInfo d;
        d.name_w = dd.DeviceName;
        d.name = W2U(dd.DeviceName);
        d.device_string = W2U(dd.DeviceString);
        d.state_flags = dd.StateFlags;
        d.attached = (dd.StateFlags & DISPLAY_DEVICE_ATTACHED_TO_DESKTOP) != 0;
        d.primary = (dd.StateFlags & DISPLAY_DEVICE_PRIMARY_DEVICE) != 0;

        for (DWORD m = 0; ; m++)
        {
            DEVMODEW dm;
            ZeroMemory(&dm, sizeof(dm));
            dm.dmSize = sizeof(dm);
            if (!EnumDisplaySettingsExW(dd.DeviceName, m, &dm, 0))
                break;
            Mode mo;
            mo.w = dm.dmPelsWidth;
            mo.h = dm.dmPelsHeight;
            mo.bpp = dm.dmBitsPerPel;
            mo.hz = dm.dmDisplayFrequency;
            d.modes.push_back(mo);
        }
        d.raw_mode_count = d.modes.size();
        std::sort(d.modes.begin(), d.modes.end(), ModeLess);
        d.modes.erase(std::unique(d.modes.begin(), d.modes.end(), ModeEq), d.modes.end());

        d.has_current = ReadCurrentMode(dd.DeviceName, &d.current);

        out.push_back(d);
    }
    return out;
}

static std::string JDevice(const DeviceInfo& d)
{
    std::string j = "{";
    j += "\"device_name\":" + JStr(d.name);
    j += ",\"device_string\":" + JStr(d.device_string);
    j += ",\"state_flags\":" + Fmt("\"0x%08lX\"", (unsigned long)d.state_flags);
    j += ",\"attached\":" + JBool(d.attached);
    j += ",\"primary\":" + JBool(d.primary);
    j += ",\"current\":" + (d.has_current ? JMode(d.current) : std::string("null"));
    j += ",\"raw_mode_count\":" + Fmt("%zu", d.raw_mode_count);
    j += ",\"mode_count\":" + Fmt("%zu", d.modes.size());
    j += ",\"modes\":[";
    for (size_t i = 0; i < d.modes.size(); i++)
    {
        if (i) j += ",";
        j += JMode(d.modes[i]);
    }
    j += "]}";
    return j;
}

// ---------------------------------------------------------------- options

struct Options
{
    bool do_test = false;
    bool do_apply = false;
    bool do_solo = false;       // --solo WxH: target device primary at WxH, all others detached
    Mode req;                   // requested w/h always; bpp/hz 0 = "not specified"
    bool req_has_bpp = false;
    bool req_has_hz = false;
    std::string device;         // --device NAME (UTF-8), empty = primary
    std::string json_path;      // also write the JSON object to this file
};

static void Usage()
{
    fprintf(stderr,
        "modeprobe " MODEPROBE_VERSION " - display-mode witness (Qubes win-idd, T2/A0)\n"
        "\n"
        "Usage: modeprobe.exe [options]\n"
        "  (no action)          enumerate devices + modes, emit JSON, exit 0\n"
        "\n"
        "Options:\n"
        "  --test WxH           CDS_TEST the size on the target device; applies nothing.\n"
        "                       The DISP_CHANGE_* verdict is reported in JSON; exit 0\n"
        "                       either way (a rejection is a successful measurement).\n"
        "  --apply WxH[@bpp[@hz]]\n"
        "                       apply the mode DYNAMICALLY (no registry persistence,\n"
        "                       reverts on reboot), then re-read ENUM_CURRENT_SETTINGS\n"
        "                       and report the readback. Exit 3 if readback != request.\n"
        "  --solo WxH           topology assertion: make --device primary at WxH at (0,0)\n"
        "                       and DETACH every other display. Uses CDS_UPDATEREGISTRY on\n"
        "                       purpose (unlike --apply): the single-display topology must\n"
        "                       survive a reboot. Requires --device.\n"
        "  --device NAME        target device for --test/--apply/--solo (e.g. \\\\.\\DISPLAY2);\n"
        "                       default is the primary device.\n"
        "  --json FILE          also write the JSON object to FILE\n"
        "  --help               this text\n"
        "\n"
        "stdout carries exactly one single-line JSON object; diagnostics go to stderr.\n");
}

// Accepts "1600x1000", "1600x1000@32", "1600x1000@32@60".
static bool ParseSizeSpec(const char* s, Options* o)
{
    unsigned w = 0, h = 0, bpp = 0, hz = 0;
    int n = sscanf_s(s, "%ux%u@%u@%u", &w, &h, &bpp, &hz);
    if (n < 2 || w == 0 || h == 0)
        return false;
    o->req.w = w;
    o->req.h = h;
    if (n >= 3) { o->req.bpp = bpp; o->req_has_bpp = true; }
    if (n >= 4) { o->req.hz = hz;  o->req_has_hz = true; }
    return true;
}

// ---------------------------------------------------------------- main

int main(int argc, char** argv)
{
    Options opt;
    for (int i = 1; i < argc; i++)
    {
        const char* a = argv[i];
        if (_stricmp(a, "--help") == 0 || _stricmp(a, "-h") == 0 || _stricmp(a, "/?") == 0)
        {
            Usage();
            return 2;
        }
        else if (_stricmp(a, "--test") == 0 && i + 1 < argc)
        {
            if (!ParseSizeSpec(argv[++i], &opt))
            {
                fprintf(stderr, "modeprobe: bad --test size '%s' (want WxH)\n", argv[i]);
                return 2;
            }
            opt.do_test = true;
        }
        else if (_stricmp(a, "--apply") == 0 && i + 1 < argc)
        {
            if (!ParseSizeSpec(argv[++i], &opt))
            {
                fprintf(stderr, "modeprobe: bad --apply size '%s' (want WxH[@bpp[@hz]])\n", argv[i]);
                return 2;
            }
            opt.do_apply = true;
        }
        else if (_stricmp(a, "--solo") == 0 && i + 1 < argc)
        {
            if (!ParseSizeSpec(argv[++i], &opt))
            {
                fprintf(stderr, "modeprobe: bad --solo size '%s' (want WxH)\n", argv[i]);
                return 2;
            }
            opt.do_solo = true;
        }
        else if (_stricmp(a, "--device") == 0 && i + 1 < argc)
        {
            opt.device = argv[++i];
        }
        else if (_stricmp(a, "--json") == 0 && i + 1 < argc)
        {
            opt.json_path = argv[++i];
        }
        else
        {
            fprintf(stderr, "modeprobe: unknown argument '%s'\n", a);
            Usage();
            return 2;
        }
    }
    if ((opt.do_test ? 1 : 0) + (opt.do_apply ? 1 : 0) + (opt.do_solo ? 1 : 0) > 1)
    {
        fprintf(stderr, "modeprobe: --test, --apply and --solo are mutually exclusive\n");
        return 2;
    }
    if (opt.do_solo && opt.device.empty())
    {
        fprintf(stderr, "modeprobe: --solo requires --device (refusing to guess which display survives)\n");
        return 2;
    }

    const EnvInfo env = GatherEnv();

    // Snapshot BEFORE any action: this is the mode list / current mode the action was
    // decided against. The post-apply truth lives in result.readback.
    std::vector<DeviceInfo> devices = EnumerateDevices();

    int exit_code = devices.empty() ? 1 : 0;
    std::string result_json = "null";

    if ((opt.do_test || opt.do_apply || opt.do_solo) && exit_code == 0)
    {
        // Resolve the target device: --device by name, else the primary one.
        const DeviceInfo* target = nullptr;
        if (!opt.device.empty())
        {
            std::wstring want = U2W(opt.device.c_str());
            for (size_t i = 0; i < devices.size(); i++)
            {
                if (_wcsicmp(devices[i].name_w.c_str(), want.c_str()) == 0)
                {
                    target = &devices[i];
                    break;
                }
            }
            if (!target)
            {
                fprintf(stderr, "modeprobe: device '%s' not found\n", opt.device.c_str());
                exit_code = 2;
            }
        }
        else
        {
            for (size_t i = 0; i < devices.size(); i++)
            {
                if (devices[i].primary)
                {
                    target = &devices[i];
                    break;
                }
            }
            if (!target)
            {
                fprintf(stderr, "modeprobe: no primary display device found\n");
                exit_code = 1;
            }
        }

        if (target && opt.do_solo)
        {
            // Topology assertion: target primary at WxH at (0,0), every other display
            // DETACHED. CDS_UPDATEREGISTRY throughout - unlike --apply, this single-display
            // topology is MEANT to persist across reboots (it also overwrites the stale
            // GraphicsDrivers\Configuration entries that DisplaySwitch experiments leave).
            std::string steps = "[";
            bool first = true;
            for (size_t i = 0; i < devices.size(); i++)
            {
                if (_wcsicmp(devices[i].name_w.c_str(), target->name_w.c_str()) == 0 ||
                    !devices[i].attached)
                    continue;
                DEVMODEW det;
                ZeroMemory(&det, sizeof(det));
                det.dmSize = sizeof(det);
                det.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
                det.dmPelsWidth = 0;
                det.dmPelsHeight = 0;
                LONG drc = ChangeDisplaySettingsExW(devices[i].name_w.c_str(), &det, nullptr,
                                                    CDS_UPDATEREGISTRY | CDS_NORESET, nullptr);
                if (!first) steps += ",";
                first = false;
                steps += "{\"device\":" + JStr(devices[i].name) +
                         ",\"op\":\"detach\",\"disp_change\":" + Fmt("%ld", (long)drc) + "}";
            }
            DEVMODEW pm;
            ZeroMemory(&pm, sizeof(pm));
            pm.dmSize = sizeof(pm);
            pm.dmFields = DM_POSITION | DM_PELSWIDTH | DM_PELSHEIGHT;
            pm.dmPelsWidth = opt.req.w;
            pm.dmPelsHeight = opt.req.h;
            LONG prc = ChangeDisplaySettingsExW(target->name_w.c_str(), &pm, nullptr,
                                                CDS_SET_PRIMARY | CDS_UPDATEREGISTRY | CDS_NORESET,
                                                nullptr);
            if (!first) steps += ",";
            steps += "{\"device\":" + JStr(target->name) +
                     ",\"op\":\"primary\",\"disp_change\":" + Fmt("%ld", (long)prc) + "}";
            LONG crc = ChangeDisplaySettingsExW(nullptr, nullptr, nullptr, 0, nullptr);
            steps += ",{\"op\":\"commit\",\"disp_change\":" + Fmt("%ld", (long)crc) + "}]";

            // Readback truth: re-enumerate. match = target attached+primary at WxH and
            // ZERO other attached displays. The check can fail; exit 3 when it does.
            std::vector<DeviceInfo> after = EnumerateDevices();
            int attached_others = 0;
            bool tgt_ok = false;
            Mode rb;
            bool rb_ok = false;
            for (size_t i = 0; i < after.size(); i++)
            {
                if (_wcsicmp(after[i].name_w.c_str(), target->name_w.c_str()) == 0)
                {
                    rb_ok = ReadCurrentMode(after[i].name_w.c_str(), &rb);
                    tgt_ok = after[i].attached && after[i].primary && rb_ok &&
                             rb.w == opt.req.w && rb.h == opt.req.h;
                }
                else if (after[i].attached)
                {
                    attached_others++;
                }
            }
            std::string rj = "{";
            rj += "\"action\":" + JStr("solo");
            rj += ",\"device\":" + JStr(target->name);
            rj += ",\"requested\":{\"w\":" + Fmt("%lu", (unsigned long)opt.req.w) +
                  ",\"h\":" + Fmt("%lu", (unsigned long)opt.req.h) + "}";
            rj += ",\"steps\":" + steps;
            rj += ",\"readback\":" + (rb_ok ? JMode(rb) : std::string("null"));
            rj += ",\"attached_others\":" + Fmt("%d", attached_others);
            bool match = tgt_ok && attached_others == 0;
            rj += ",\"match\":" + JBool(match);
            if (!match)
                exit_code = 3;
            rj += "}";
            result_json = rj;
        }
        else if (target)
        {
            DEVMODEW dm;
            ZeroMemory(&dm, sizeof(dm));
            dm.dmSize = sizeof(dm);
            dm.dmFields = DM_PELSWIDTH | DM_PELSHEIGHT;
            dm.dmPelsWidth = opt.req.w;
            dm.dmPelsHeight = opt.req.h;
            if (opt.req_has_bpp)
            {
                dm.dmFields |= DM_BITSPERPEL;
                dm.dmBitsPerPel = opt.req.bpp;
            }
            if (opt.req_has_hz)
            {
                dm.dmFields |= DM_DISPLAYFREQUENCY;
                dm.dmDisplayFrequency = opt.req.hz;
            }

            // --test: CDS_TEST applies nothing, the mode is only validated.
            // --apply: dwFlags = 0 changes the mode DYNAMICALLY. CDS_UPDATEREGISTRY is
            // deliberately absent - see the header comment: persistence would contaminate
            // cold-boot baselines and remove the reboot-reverts escape hatch.
            DWORD flags = opt.do_test ? CDS_TEST : 0;
            LONG rc = ChangeDisplaySettingsExW(target->name_w.c_str(), &dm, nullptr,
                                               flags, nullptr);

            std::string rj = "{";
            rj += "\"action\":" + JStr(opt.do_test ? "test" : "apply");
            rj += ",\"device\":" + JStr(target->name);
            rj += ",\"requested\":{\"w\":" + Fmt("%lu", (unsigned long)opt.req.w) +
                  ",\"h\":" + Fmt("%lu", (unsigned long)opt.req.h) +
                  ",\"bpp\":" + (opt.req_has_bpp ? Fmt("%lu", (unsigned long)opt.req.bpp)
                                                 : std::string("null")) +
                  ",\"hz\":" + (opt.req_has_hz ? Fmt("%lu", (unsigned long)opt.req.hz)
                                               : std::string("null")) + "}";
            rj += ",\"disp_change\":" + Fmt("%ld", (long)rc);
            rj += ",\"disp_change_name\":" + JStr(DispChangeName(rc));

            if (opt.do_apply)
            {
                // Readback, not the request: report what Windows actually made current.
                Mode rb;
                bool rb_ok = ReadCurrentMode(target->name_w.c_str(), &rb);
                rj += ",\"readback\":" + (rb_ok ? JMode(rb) : std::string("null"));

                bool match = rb_ok &&
                             rc == DISP_CHANGE_SUCCESSFUL &&
                             rb.w == opt.req.w && rb.h == opt.req.h &&
                             (!opt.req_has_bpp || rb.bpp == opt.req.bpp) &&
                             (!opt.req_has_hz || rb.hz == opt.req.hz);
                rj += ",\"match\":" + JBool(match);
                if (!match)
                    exit_code = 3;
            }
            rj += "}";
            result_json = rj;
        }
    }

    // ---- JSON (single line, stdout)
    std::string j = "{";
    j += "\"tool\":\"modeprobe\",\"version\":\"" MODEPROBE_VERSION "\"";
    j += ",\"host\":" + JStr(env.host);
    j += ",\"user\":" + JStr(env.user);
    j += ",\"session_id\":" + Fmt("%lu", (unsigned long)env.session_id);
    j += ",\"elevated\":" + JBool(env.elevated);
    j += ",\"window_station\":" + JStr(env.winsta);
    j += ",\"desktop\":" + JStr(env.desktop);
    j += ",\"os_build\":" + JStr(env.os_build);
    j += ",\"device_count\":" + Fmt("%zu", devices.size());
    j += ",\"devices\":[";
    for (size_t i = 0; i < devices.size(); i++)
    {
        if (i) j += ",";
        j += JDevice(devices[i]);
    }
    j += "]";
    j += ",\"result\":" + result_json;
    j += ",\"exit_code\":" + Fmt("%d", exit_code);
    j += "}";

    printf("%s\n", j.c_str());
    fflush(stdout);

    if (!opt.json_path.empty())
    {
        FILE* f = nullptr;
        if (fopen_s(&f, opt.json_path.c_str(), "wb") == 0 && f)
        {
            fwrite(j.data(), 1, j.size(), f);
            fputc('\n', f);
            fclose(f);
        }
        else
        {
            fprintf(stderr, "modeprobe: could not write %s\n", opt.json_path.c_str());
            if (exit_code == 0)
                exit_code = 1;
        }
    }

    return exit_code;
}
