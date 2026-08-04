// ddaprobe - Qubes Windows display performance: Desktop Duplication scoping probe.
//
// Answers Track B's pivotal question (CLAUDE.md Phase 0.6 / Phase 1B):
//   For every DXGI output, is DXGI_OUTDUPL_DESC::DesktopImageInSystemMemory TRUE?
//   agent/gui-agent/capture.c:176-183 HARD-FAILS when it is FALSE, so any change that
//   moves the desktop off the Basic Display Adapter (e.g. an IddCx monitor becoming
//   primary) must keep that flag TRUE or the whole QWT capture path dies.
//
// Also answers the Track A question CLAUDE.md flags as UNVERIFIED: the in-code note at
// capture.c:441 says move rects "seem to always be empty when testing". This probe counts
// GetFrameMoveRects results per frame, so we get evidence instead of folklore.
//
// The device/output selection deliberately mirrors gui-agent/capture.c
// (GetAdapter/GetOutput/GetDevice: EnumAdapters1 -> EnumOutputs -> first AttachedToDesktop
// output, D3D11CreateDevice with D3D_DRIVER_TYPE_UNKNOWN and the same feature level list)
// so that what ddaprobe measures is what the agent will experience.
//
// Build: MSVC v143, /MT, Windows SDK 10. See ddaprobe.vcxproj.
// Run:   ddaprobe.exe [frames] [max_seconds] [options]     (see Usage() below)
//
// Output: a human-readable report on stdout, then a line "=== DDAPROBE JSON ===" followed
// by exactly one single-line JSON object. guest/deploy-and-test.ps1 slurps all of stdout
// into its own '=== RESULT ===' JSON, so stdout is kept clean and marker-delimited.
//
// STATUS: UNCOMPILED on the dev qube (no MSVC on Linux). Only well-established
// DXGI 1.2 / D3D11 APIs are used.

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX

#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdarg.h>

#include <string>
#include <vector>
#include <algorithm>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "advapi32.lib")

// *** INVERTED SCRATCH BUILD (branch scratch/ddaprobe-inverted, experiment 0b) ***
// This binary deliberately reports the OPPOSITE of DXGI's DesktopImageInSystemMemory
// at the two points where the flag enters the data model, to prove the FALSE reporting
// path (JSON, summary, agent_capture_would_work, exit code) can actually fire.
// NEVER deploy as the real instrument. NEVER merge this branch.
#define DDAPROBE_VERSION "1.0-INVERTED"

// ---------------------------------------------------------------- small helpers

template <typename T>
static void SafeRelease(T*& p)
{
    if (p)
    {
        p->Release();
        p = nullptr;
    }
}

static LARGE_INTEGER g_qpcFreq;

static double NowMs()
{
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return (double)t.QuadPart * 1000.0 / (double)g_qpcFreq.QuadPart;
}

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

// DXGI_OUTPUT_DESC::DeviceName and DXGI_ADAPTER_DESC1::Description are fixed-size WCHAR
// arrays that are documented as null-terminated but let's not bet the run on it.
static std::string WFixed(const wchar_t* w, size_t cap)
{
    std::vector<wchar_t> buf(cap + 1, L'\0');
    memcpy(buf.data(), w, cap * sizeof(wchar_t));
    buf[cap] = L'\0';
    return W2U(buf.data());
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
static std::string JNum(double v)
{
    if (v != v)                       // NaN guard
        return "null";
    return Fmt("%.4f", v);
}
static std::string JHex(HRESULT hr) { return Fmt("\"0x%08X\"", (unsigned)hr); }

// Symbolic names for the HRESULTs we actually care about. Printing the symbol avoids the
// trap the agent falls into: win_perror2() runs FormatMessage(FROM_SYSTEM) on the HRESULT,
// which renders 0x887A0026 as "The keyed mutex was abandoned." even though winerror.h
// defines 0x887A0026 as DXGI_ERROR_ACCESS_LOST (= "recreate the duplication interface").
// That is the error already seen in the live gui-agent log at seamless/resolution change.
static const char* HrName(HRESULT hr)
{
    switch ((unsigned)hr)   // unsigned is 32-bit on both LLP64 and LP64; unsigned long is NOT
    {
    case 0x00000000U: return "S_OK";
    case 0x80004005U: return "E_FAIL";
    case 0x80070005U: return "E_ACCESSDENIED";
    case 0x8007000EU: return "E_OUTOFMEMORY";
    case 0x80070057U: return "E_INVALIDARG";
    case 0x80004001U: return "E_NOTIMPL";
    case 0x887A0001U: return "DXGI_ERROR_INVALID_CALL";
    case 0x887A0002U: return "DXGI_ERROR_NOT_FOUND";
    case 0x887A0003U: return "DXGI_ERROR_MORE_DATA";
    case 0x887A0004U: return "DXGI_ERROR_UNSUPPORTED";
    case 0x887A0005U: return "DXGI_ERROR_DEVICE_REMOVED";
    case 0x887A0006U: return "DXGI_ERROR_DEVICE_HUNG";
    case 0x887A0007U: return "DXGI_ERROR_DEVICE_RESET";
    case 0x887A0020U: return "DXGI_ERROR_DRIVER_INTERNAL_ERROR";
    case 0x887A0021U: return "DXGI_ERROR_NONEXCLUSIVE";
    case 0x887A0022U: return "DXGI_ERROR_NOT_CURRENTLY_AVAILABLE";
    case 0x887A0023U: return "DXGI_ERROR_REMOTE_CLIENT_DISCONNECTED";
    case 0x887A0026U: return "DXGI_ERROR_ACCESS_LOST";
    case 0x887A0027U: return "DXGI_ERROR_WAIT_TIMEOUT";
    case 0x887A0028U: return "DXGI_ERROR_SESSION_DISCONNECTED";
    case 0x887A0029U: return "DXGI_ERROR_RESTRICT_TO_OUTPUT_STALE";
    case 0x887A002AU: return "DXGI_ERROR_CANNOT_PROTECT_CONTENT";
    case 0x887A002BU: return "DXGI_ERROR_ACCESS_DENIED";
    case 0x887A002CU: return "DXGI_ERROR_NAME_ALREADY_EXISTS";
    case 0x887A002DU: return "DXGI_ERROR_SDK_COMPONENT_MISSING";
    default: return "UNKNOWN";
    }
}

// FormatMessage text, for cross-checking against what the agent logs.
static std::string HrText(HRESULT hr)
{
    wchar_t* msg = nullptr;
    DWORD n = FormatMessageW(FORMAT_MESSAGE_ALLOCATE_BUFFER | FORMAT_MESSAGE_FROM_SYSTEM |
                                 FORMAT_MESSAGE_IGNORE_INSERTS,
                             nullptr, (DWORD)hr, 0, (LPWSTR)&msg, 0, nullptr);
    std::string s;
    if (n && msg)
        s = W2U(msg);
    if (msg)
        LocalFree(msg);
    while (!s.empty() && (s.back() == '\n' || s.back() == '\r' || s.back() == ' '))
        s.pop_back();
    return s;
}

static const char* FeatureLevelName(D3D_FEATURE_LEVEL fl)
{
    switch ((unsigned)fl)
    {
    case 0xb100: return "11_1";
    case 0xb000: return "11_0";
    case 0xa100: return "10_1";
    case 0xa000: return "10_0";
    case 0x9300: return "9_3";
    case 0x9200: return "9_2";
    case 0x9100: return "9_1";
    default: return "?";
    }
}

static const char* FormatName(DXGI_FORMAT f)
{
    switch ((int)f)
    {
    case DXGI_FORMAT_B8G8R8A8_UNORM: return "B8G8R8A8_UNORM";
    case DXGI_FORMAT_R8G8B8A8_UNORM: return "R8G8B8A8_UNORM";
    case DXGI_FORMAT_R10G10B10A2_UNORM: return "R10G10B10A2_UNORM";
    case DXGI_FORMAT_R16G16B16A16_FLOAT: return "R16G16B16A16_FLOAT";
    default: return "other";
    }
}

static const char* RotationName(DXGI_MODE_ROTATION r)
{
    switch ((int)r)
    {
    case DXGI_MODE_ROTATION_IDENTITY: return "identity";
    case DXGI_MODE_ROTATION_ROTATE90: return "rotate90";
    case DXGI_MODE_ROTATION_ROTATE180: return "rotate180";
    case DXGI_MODE_ROTATION_ROTATE270: return "rotate270";
    default: return "unspecified";
    }
}

static long long RectArea(const RECT& r)
{
    long long w = (long long)r.right - (long long)r.left;
    long long h = (long long)r.bottom - (long long)r.top;
    if (w < 0) w = 0;
    if (h < 0) h = 0;
    return w * h;
}

// ---------------------------------------------------------------- statistics

struct Stats
{
    size_t n = 0;
    double vmin = 0.0, vmean = 0.0, vmedian = 0.0, vp95 = 0.0, vmax = 0.0;
};

static Stats ComputeStats(std::vector<double> v)
{
    Stats s;
    s.n = v.size();
    if (v.empty())
        return s;
    std::sort(v.begin(), v.end());
    s.vmin = v.front();
    s.vmax = v.back();
    double sum = 0.0;
    for (size_t i = 0; i < v.size(); i++)
        sum += v[i];
    s.vmean = sum / (double)v.size();
    s.vmedian = (v.size() % 2) ? v[v.size() / 2]
                               : 0.5 * (v[v.size() / 2 - 1] + v[v.size() / 2]);
    size_t idx = (size_t)((double)(v.size() - 1) * 0.95 + 0.5);
    if (idx >= v.size())
        idx = v.size() - 1;
    s.vp95 = v[idx];
    return s;
}

static std::string JStats(const Stats& s)
{
    return "{\"n\":" + Fmt("%zu", s.n) +
           ",\"min_ms\":" + JNum(s.vmin) +
           ",\"mean_ms\":" + JNum(s.vmean) +
           ",\"median_ms\":" + JNum(s.vmedian) +
           ",\"p95_ms\":" + JNum(s.vp95) +
           ",\"max_ms\":" + JNum(s.vmax) + "}";
}

// ---------------------------------------------------------------- environment

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

    // OS build from the registry (RtlGetVersion needs ntdll linkage; this is enough).
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

// Desktop Duplication needs a thread bound to an interactive desktop. qrexec/qubes.VMShell
// lands in the interactive console session (session 1 on win-idd-test, per
// mgmt/PROVISION-LOG.md), so this is normally a no-op; it is a rescue path for the case
// where DuplicateOutput comes back E_ACCESSDENIED / SESSION_DISCONNECTED.
static bool AttachToInputDesktop(std::string* what)
{
    HDESK desk = OpenInputDesktop(0, FALSE,
                                  GENERIC_READ | DESKTOP_CREATEWINDOW | DESKTOP_SWITCHDESKTOP);
    if (!desk)
    {
        *what = Fmt("OpenInputDesktop failed, GetLastError=%lu", GetLastError());
        return false;
    }
    if (!SetThreadDesktop(desk))
    {
        *what = Fmt("SetThreadDesktop failed, GetLastError=%lu", GetLastError());
        CloseDesktop(desk);
        return false;
    }
    // Deliberately leaked: the thread keeps using it for the rest of this short-lived run.
    *what = "attached to input desktop: " + UserObjectName(desk);
    return true;
}

// ---------------------------------------------------------------- options

struct Options
{
    unsigned frames = 100;      // target number of SUCCESSFUL AcquireNextFrame calls
    double   max_seconds = 30;  // wall-clock cap on the capture loop, per output
    unsigned timeout_ms = 100;  // AcquireNextFrame timeout
    int      only_output = -1;  // global output index to probe, -1 = all attached
    bool     do_map = true;     // exercise MapDesktopSurface once per output
    bool     quiet = false;     // suppress the human table, JSON only
    std::string json_path;      // also write the JSON object to this file
};

static void Usage()
{
    fprintf(stderr,
        "ddaprobe " DDAPROBE_VERSION " - Desktop Duplication scoping probe (Qubes win-idd)\n"
        "\n"
        "Usage: ddaprobe.exe [frames] [max_seconds] [options]\n"
        "  frames         target successful AcquireNextFrame calls per output (default 100)\n"
        "  max_seconds    wall-clock cap on the capture loop per output (default 30)\n"
        "\n"
        "Options:\n"
        "  --timeout MS   AcquireNextFrame timeout in ms (default 100)\n"
        "  --output N     probe only global output index N (default: every attached output)\n"
        "  --no-map       skip the MapDesktopSurface probe\n"
        "  --json FILE    also write the JSON object to FILE\n"
        "  --quiet        suppress the human-readable table (JSON only)\n"
        "  --help         this text\n"
        "\n"
        "Exit codes: 0 = at least one output duplicated; 1 = no output could be duplicated;\n"
        "            2 = bad arguments. The JSON block is emitted on 0 and 1.\n");
}

// ---------------------------------------------------------------- per-output probe

struct ProbeResult
{
    // identity
    int adapter_index = 0;
    int output_index = 0;
    int global_index = 0;
    std::string adapter_desc;
    std::string device_name;
    bool attached = false;
    RECT coords = { 0, 0, 0, 0 };
    DXGI_MODE_ROTATION rotation = DXGI_MODE_ROTATION_UNSPECIFIED;

    // IDXGIOutput1 (required for duplication)
    bool output1_ok = false;
    HRESULT output1_hr = E_PENDING;      // E_PENDING = call not made (was falsely S_OK)

    // device
    bool device_ok = false;
    HRESULT device_hr = E_PENDING;
    D3D_FEATURE_LEVEL feature_level = (D3D_FEATURE_LEVEL)0;

    // duplication
    bool dupl_ok = false;
    HRESULT dupl_hr = E_PENDING;
    bool desktop_image_in_system_memory = false;   // *** THE Track B question ***
    bool sysmem_ever_false = false;                // did it ever flip during the run?
    unsigned mode_changes = 0;                     // observed across re-duplications
    UINT mode_width = 0, mode_height = 0;
    UINT refresh_num = 0, refresh_den = 0;
    DXGI_FORMAT mode_format = DXGI_FORMAT_UNKNOWN;
    DXGI_MODE_SCANLINE_ORDER scanline = DXGI_MODE_SCANLINE_ORDER_UNSPECIFIED;
    DXGI_MODE_ROTATION dupl_rotation = DXGI_MODE_ROTATION_UNSPECIFIED;

    // MapDesktopSurface probe (what capture.c does to obtain the grantable pointer)
    bool map_attempted = false;
    bool map_ok = false;
    HRESULT map_hr = E_PENDING;
    int map_pitch = 0;
    bool map_ptr_nonnull = false;

    // loop counters
    unsigned iterations = 0;
    unsigned acquired = 0;
    unsigned timeouts = 0;
    unsigned errors = 0;
    unsigned access_lost = 0;
    unsigned reduplications = 0;
    unsigned reduplication_failures = 0;
    unsigned presented_frames = 0;     // LastPresentTime != 0
    unsigned mouse_only_frames = 0;    // acquired but LastPresentTime == 0
    unsigned pointer_shape_updates = 0;
    unsigned long long accumulated_frames = 0;
    double elapsed_ms = 0.0;

    // metadata
    unsigned metadata_errors = 0;
    HRESULT last_metadata_hr = E_PENDING;
    unsigned long long dirty_rect_total = 0;
    unsigned long long move_rect_total = 0;      // *** the "always empty?" question ***
    unsigned frames_with_dirty = 0;
    unsigned frames_with_move = 0;
    unsigned max_dirty_in_frame = 0;
    unsigned max_move_in_frame = 0;
    long long dirty_area_total = 0;
    long long move_area_total = 0;
    unsigned long long metadata_bytes_total = 0;

    // latency samples
    Stats acquire_stats;      // successful acquires only
    Stats timeout_stats;      // how long a timeout actually blocks
    std::vector<HRESULT> distinct_errors;
};

static bool CreateDeviceForAdapter(IDXGIAdapter1* adapter, ID3D11Device** dev,
                                   D3D_FEATURE_LEVEL* flOut, HRESULT* hrOut)
{
    // Same list as gui-agent/capture.c GetDevice().
    static const D3D_FEATURE_LEVEL levels[] = {
        D3D_FEATURE_LEVEL_11_1,
        D3D_FEATURE_LEVEL_11_0,
        D3D_FEATURE_LEVEL_10_1,
        D3D_FEATURE_LEVEL_10_0,
        D3D_FEATURE_LEVEL_9_1,
    };

    *dev = nullptr;
    HRESULT hr = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0,
                                   levels, ARRAYSIZE(levels), D3D11_SDK_VERSION,
                                   dev, flOut, nullptr);
    if (FAILED(hr))
    {
        // Runtimes without 11_1 support reject the whole array; retry from 11_0.
        SafeRelease(*dev);
        hr = D3D11CreateDevice(adapter, D3D_DRIVER_TYPE_UNKNOWN, nullptr, 0,
                               levels + 1, ARRAYSIZE(levels) - 1, D3D11_SDK_VERSION,
                               dev, flOut, nullptr);
    }
    *hrOut = hr;
    return SUCCEEDED(hr) && (*dev != nullptr);
}

static void NoteError(ProbeResult& r, HRESULT hr)
{
    r.errors++;
    for (size_t i = 0; i < r.distinct_errors.size(); i++)
        if (r.distinct_errors[i] == hr)
            return;
    if (r.distinct_errors.size() < 16)
        r.distinct_errors.push_back(hr);
}

static void RunCaptureLoop(ProbeResult& r, const Options& opt,
                           IDXGIOutput1* output1, ID3D11Device* device,
                           IDXGIOutputDuplication* dupl)
{
    std::vector<double> lat, tmo;
    std::vector<BYTE> meta;
    unsigned consecutive_errors = 0;
    const unsigned kHardIterCap = opt.frames * 200 + 5000;

    const double t0 = NowMs();

    while (r.acquired < opt.frames)
    {
        const double now = NowMs();
        r.elapsed_ms = now - t0;
        if (r.elapsed_ms >= opt.max_seconds * 1000.0)
            break;
        if (r.iterations >= kHardIterCap)
            break;
        r.iterations++;

        DXGI_OUTDUPL_FRAME_INFO info;
        ZeroMemory(&info, sizeof(info));
        IDXGIResource* res = nullptr;

        const double a = NowMs();
        HRESULT hr = dupl->AcquireNextFrame(opt.timeout_ms, &info, &res);
        const double dt = NowMs() - a;

        if (hr == DXGI_ERROR_WAIT_TIMEOUT)
        {
            r.timeouts++;
            tmo.push_back(dt);
            SafeRelease(res);   // defensive; DXGI leaves it null on timeout
            continue;
        }

        if (FAILED(hr))
        {
            SafeRelease(res);
            NoteError(r, hr);
            if (hr == DXGI_ERROR_ACCESS_LOST)
            {
                // Documented remedy: throw the duplication away and make a new one.
                // This is the 0x887A0026 the live gui-agent log already shows.
                r.access_lost++;
                dupl->Release();
                dupl = nullptr;
                HRESULT rhr = output1->DuplicateOutput(device, &dupl);
                r.reduplications++;
                if (FAILED(rhr) || !dupl)
                {
                    r.reduplication_failures++;
                    NoteError(r, rhr);
                    dupl = nullptr;
                    break;
                }
                // ACCESS_LOST is usually a mode / desktop-composition change, i.e. exactly
                // the seamless-switch + 5120x1440 resize that the live gui-agent log shows.
                // Re-read the desc: both the mode AND DesktopImageInSystemMemory can change.
                {
                    DXGI_OUTDUPL_DESC nd;
                    ZeroMemory(&nd, sizeof(nd));
                    dupl->GetDesc(&nd);
                    if (nd.ModeDesc.Width != r.mode_width || nd.ModeDesc.Height != r.mode_height)
                        r.mode_changes++;
                    r.mode_width = nd.ModeDesc.Width;
                    r.mode_height = nd.ModeDesc.Height;
                    r.refresh_num = nd.ModeDesc.RefreshRate.Numerator;
                    r.refresh_den = nd.ModeDesc.RefreshRate.Denominator;
                    r.mode_format = nd.ModeDesc.Format;
                    r.scanline = nd.ModeDesc.ScanlineOrdering;
                    r.dupl_rotation = nd.Rotation;
                    // INVERTED (experiment 0b): real code is (nd.DesktopImageInSystemMemory != FALSE)
                    r.desktop_image_in_system_memory = (nd.DesktopImageInSystemMemory == FALSE);
                    if (!r.desktop_image_in_system_memory)
                        r.sysmem_ever_false = true;
                }
                consecutive_errors = 0;
                continue;
            }
            if (++consecutive_errors >= 20)
                break;
            Sleep(20);
            continue;
        }

        consecutive_errors = 0;
        r.acquired++;
        lat.push_back(dt);

        if (info.LastPresentTime.QuadPart != 0)
            r.presented_frames++;
        else
            r.mouse_only_frames++;
        if (info.PointerShapeBufferSize != 0)
            r.pointer_shape_updates++;
        r.accumulated_frames += info.AccumulatedFrames;
        r.metadata_bytes_total += info.TotalMetadataBufferSize;

        // ---- metadata. Move rects MUST be read before dirty rects, and they share one
        //      buffer of TotalMetadataBufferSize bytes (move rects first).
        if (info.TotalMetadataBufferSize > 0)
        {
            if (meta.size() < info.TotalMetadataBufferSize)
                meta.resize(info.TotalMetadataBufferSize);

            UINT bufSize = info.TotalMetadataBufferSize;
            HRESULT mvhr = dupl->GetFrameMoveRects(
                bufSize, reinterpret_cast<DXGI_OUTDUPL_MOVE_RECT*>(meta.data()), &bufSize);

            if (SUCCEEDED(mvhr))
            {
                const UINT moveCount = bufSize / (UINT)sizeof(DXGI_OUTDUPL_MOVE_RECT);
                if (moveCount > 0)
                {
                    const DXGI_OUTDUPL_MOVE_RECT* mrs =
                        reinterpret_cast<const DXGI_OUTDUPL_MOVE_RECT*>(meta.data());
                    for (UINT i = 0; i < moveCount; i++)
                        r.move_area_total += RectArea(mrs[i].DestinationRect);
                    r.move_rect_total += moveCount;
                    r.frames_with_move++;
                    if (moveCount > r.max_move_in_frame)
                        r.max_move_in_frame = moveCount;
                }

                const UINT usedByMove = moveCount * (UINT)sizeof(DXGI_OUTDUPL_MOVE_RECT);
                UINT dirtySize = info.TotalMetadataBufferSize - usedByMove;
                HRESULT dhr = dupl->GetFrameDirtyRects(
                    dirtySize, reinterpret_cast<RECT*>(meta.data() + usedByMove), &dirtySize);

                if (SUCCEEDED(dhr))
                {
                    const UINT dirtyCount = dirtySize / (UINT)sizeof(RECT);
                    if (dirtyCount > 0)
                    {
                        const RECT* drs =
                            reinterpret_cast<const RECT*>(meta.data() + usedByMove);
                        for (UINT i = 0; i < dirtyCount; i++)
                            r.dirty_area_total += RectArea(drs[i]);
                        r.dirty_rect_total += dirtyCount;
                        r.frames_with_dirty++;
                        if (dirtyCount > r.max_dirty_in_frame)
                            r.max_dirty_in_frame = dirtyCount;
                    }
                }
                else
                {
                    r.metadata_errors++;
                    r.last_metadata_hr = dhr;
                }
            }
            else
            {
                r.metadata_errors++;
                r.last_metadata_hr = mvhr;
            }
        }

        // ---- MapDesktopSurface probe. Only legal while we own the frame, and only ever
        //      succeeds when DesktopImageInSystemMemory is TRUE -- this is the exact call
        //      capture.c uses to obtain the pointer it hands to
        //      XcGnttabPermitForeignAccess2, so it corroborates the flag independently.
        //      Done after the metadata reads so it cannot perturb them.
        //      Prefer a frame that actually carries desktop content (LastPresentTime != 0),
        //      which is what capture.c waits for before it maps and grants; fall back to
        //      any frame after a few so an idle desktop still yields a datapoint.
        if (opt.do_map && !r.map_attempted &&
            (info.LastPresentTime.QuadPart != 0 || r.acquired >= 5))
        {
            r.map_attempted = true;
            DXGI_MAPPED_RECT mr;
            ZeroMemory(&mr, sizeof(mr));
            HRESULT mhr = dupl->MapDesktopSurface(&mr);
            r.map_hr = mhr;
            r.map_ok = SUCCEEDED(mhr);
            if (r.map_ok)
            {
                r.map_pitch = mr.Pitch;
                r.map_ptr_nonnull = (mr.pBits != nullptr);
                dupl->UnMapDesktopSurface();
            }
        }

        SafeRelease(res);
        dupl->ReleaseFrame();
    }

    r.elapsed_ms = NowMs() - t0;
    r.acquire_stats = ComputeStats(lat);
    r.timeout_stats = ComputeStats(tmo);

    SafeRelease(dupl);
}

// ---------------------------------------------------------------- reporting

static void PrintHuman(const ProbeResult& r)
{
    printf("\n");
    printf("--- output #%d  (adapter %d, output %d) ------------------------------\n",
           r.global_index, r.adapter_index, r.output_index);
    printf("  adapter               : %s\n", r.adapter_desc.c_str());
    printf("  output device name    : %s\n", r.device_name.c_str());
    printf("  attached to desktop   : %s\n", r.attached ? "YES" : "no");
    printf("  desktop coordinates   : (%ld,%ld)-(%ld,%ld)  %ldx%ld\n",
           (long)r.coords.left, (long)r.coords.top, (long)r.coords.right, (long)r.coords.bottom,
           (long)(r.coords.right - r.coords.left), (long)(r.coords.bottom - r.coords.top));
    printf("  output rotation       : %s\n", RotationName(r.rotation));

    if (!r.attached)
    {
        printf("  (not attached - duplication not attempted)\n");
        return;
    }

    if (!r.output1_ok)
    {
        printf("  QI(IDXGIOutput1)      : FAILED 0x%08X %s (%s)\n",
               (unsigned)r.output1_hr, HrName(r.output1_hr), HrText(r.output1_hr).c_str());
        return;
    }

    if (!r.device_ok)
    {
        printf("  D3D11CreateDevice     : FAILED 0x%08X %s (%s)\n",
               (unsigned)r.device_hr, HrName(r.device_hr), HrText(r.device_hr).c_str());
        return;
    }
    printf("  D3D11 feature level   : %s\n", FeatureLevelName(r.feature_level));

    if (!r.dupl_ok)
    {
        printf("  DuplicateOutput       : FAILED 0x%08X %s (%s)\n",
               (unsigned)r.dupl_hr, HrName(r.dupl_hr), HrText(r.dupl_hr).c_str());
        return;
    }

    printf("  duplication mode      : %ux%u @ %.2f Hz, format %s, scanline %d, rot %s\n",
           r.mode_width, r.mode_height,
           r.refresh_den ? (double)r.refresh_num / (double)r.refresh_den : 0.0,
           FormatName(r.mode_format), (int)r.scanline, RotationName(r.dupl_rotation));
    printf("  *** DesktopImageInSystemMemory : %s ***%s\n",
           r.desktop_image_in_system_memory ? "TRUE" : "FALSE",
           r.desktop_image_in_system_memory
               ? "   (capture.c:176-183 OK)"
               : "   (capture.c:176-183 WOULD HARD-FAIL)");

    if (r.map_attempted)
    {
        if (r.map_ok)
            printf("  MapDesktopSurface     : OK, pitch=%d, pBits=%s\n",
                   r.map_pitch, r.map_ptr_nonnull ? "non-null" : "NULL");
        else
            printf("  MapDesktopSurface     : FAILED 0x%08X %s (%s)\n",
                   (unsigned)r.map_hr, HrName(r.map_hr), HrText(r.map_hr).c_str());
    }

    printf("\n  capture loop: %u iterations in %.1f ms\n", r.iterations, r.elapsed_ms);
    printf("    acquired frames     : %u  (presented %u, mouse-only %u, accumulated %llu)\n",
           r.acquired, r.presented_frames, r.mouse_only_frames,
           (unsigned long long)r.accumulated_frames);
    printf("    timeouts            : %u  (blocked mean %.2f ms, max %.2f ms)\n",
           r.timeouts, r.timeout_stats.vmean, r.timeout_stats.vmax);
    printf("    errors              : %u  (ACCESS_LOST %u, re-duplications %u, failed %u)\n",
           r.errors, r.access_lost, r.reduplications, r.reduplication_failures);
    if (r.mode_changes || r.sysmem_ever_false)
        printf("    mode changes        : %u   DesktopImageInSystemMemory ever FALSE: %s\n",
               r.mode_changes, r.sysmem_ever_false ? "YES" : "no");
    for (size_t i = 0; i < r.distinct_errors.size(); i++)
        printf("      seen: 0x%08X %s (%s)\n", (unsigned)r.distinct_errors[i],
               HrName(r.distinct_errors[i]), HrText(r.distinct_errors[i]).c_str());
    printf("    pointer shape updates: %u\n", r.pointer_shape_updates);

    printf("\n  AcquireNextFrame latency over %zu successful calls (ms):\n", r.acquire_stats.n);
    printf("    min %.3f   mean %.3f   median %.3f   p95 %.3f   max %.3f\n",
           r.acquire_stats.vmin, r.acquire_stats.vmean, r.acquire_stats.vmedian,
           r.acquire_stats.vp95, r.acquire_stats.vmax);

    printf("\n  frame metadata (%llu bytes total reported by DXGI):\n",
           (unsigned long long)r.metadata_bytes_total);
    printf("    dirty rects  : total %llu over %u frames (max %u/frame), area %lld px\n",
           (unsigned long long)r.dirty_rect_total, r.frames_with_dirty,
           r.max_dirty_in_frame, (long long)r.dirty_area_total);
    printf("    MOVE  rects  : total %llu over %u frames (max %u/frame), area %lld px  <== %s\n",
           (unsigned long long)r.move_rect_total, r.frames_with_move,
           r.max_move_in_frame, (long long)r.move_area_total,
           r.move_rect_total ? "NON-EMPTY: capture.c:441 note is WRONG here"
                             : "empty this run (matches capture.c:441 note)");
    if (r.acquired)
        printf("    per acquired frame: %.2f dirty, %.2f move, %.0f px dirty area\n",
               (double)r.dirty_rect_total / (double)r.acquired,
               (double)r.move_rect_total / (double)r.acquired,
               (double)r.dirty_area_total / (double)r.acquired);
    if (r.metadata_errors)
        printf("    metadata errors: %u, last 0x%08X %s\n", r.metadata_errors,
               (unsigned)r.last_metadata_hr, HrName(r.last_metadata_hr));
}

static std::string JResult(const ProbeResult& r)
{
    std::string j = "{";
    j += "\"global_index\":" + Fmt("%d", r.global_index);
    j += ",\"adapter_index\":" + Fmt("%d", r.adapter_index);
    j += ",\"output_index\":" + Fmt("%d", r.output_index);
    j += ",\"adapter\":" + JStr(r.adapter_desc);
    j += ",\"device_name\":" + JStr(r.device_name);
    j += ",\"attached_to_desktop\":" + JBool(r.attached);
    j += ",\"desktop_coordinates\":{\"left\":" + Fmt("%ld", (long)r.coords.left) +
         ",\"top\":" + Fmt("%ld", (long)r.coords.top) +
         ",\"right\":" + Fmt("%ld", (long)r.coords.right) +
         ",\"bottom\":" + Fmt("%ld", (long)r.coords.bottom) + "}";
    j += ",\"rotation\":" + JStr(RotationName(r.rotation));

    j += ",\"output1_ok\":" + JBool(r.output1_ok);
    j += ",\"output1_hr\":" + JHex(r.output1_hr);
    j += ",\"device_ok\":" + JBool(r.device_ok);
    j += ",\"device_hr\":" + JHex(r.device_hr);
    j += ",\"device_hr_name\":" + JStr(HrName(r.device_hr));
    j += ",\"feature_level\":" + JStr(FeatureLevelName(r.feature_level));

    j += ",\"duplication_ok\":" + JBool(r.dupl_ok);
    j += ",\"duplication_hr\":" + JHex(r.dupl_hr);
    j += ",\"duplication_hr_name\":" + JStr(HrName(r.dupl_hr));
    j += ",\"duplication_hr_text\":" + JStr(HrText(r.dupl_hr));

    // *** the flag Track B lives or dies by ***
    j += ",\"desktop_image_in_system_memory\":" + JBool(r.desktop_image_in_system_memory);
    j += ",\"desktop_image_in_system_memory_ever_false\":" + JBool(r.sysmem_ever_false);
    j += ",\"mode_changes\":" + Fmt("%u", r.mode_changes);

    j += ",\"mode\":{\"width\":" + Fmt("%u", r.mode_width) +
         ",\"height\":" + Fmt("%u", r.mode_height) +
         ",\"refresh_numerator\":" + Fmt("%u", r.refresh_num) +
         ",\"refresh_denominator\":" + Fmt("%u", r.refresh_den) +
         ",\"format\":" + Fmt("%d", (int)r.mode_format) +
         ",\"format_name\":" + JStr(FormatName(r.mode_format)) +
         ",\"scanline_ordering\":" + Fmt("%d", (int)r.scanline) +
         ",\"rotation\":" + JStr(RotationName(r.dupl_rotation)) + "}";

    j += ",\"map_desktop_surface\":{\"attempted\":" + JBool(r.map_attempted) +
         ",\"ok\":" + JBool(r.map_ok) +
         ",\"hr\":" + JHex(r.map_hr) +
         ",\"hr_name\":" + JStr(HrName(r.map_hr)) +
         ",\"pitch\":" + Fmt("%d", r.map_pitch) +
         ",\"pbits_non_null\":" + JBool(r.map_ptr_nonnull) + "}";

    j += ",\"loop\":{\"iterations\":" + Fmt("%u", r.iterations) +
         ",\"acquired\":" + Fmt("%u", r.acquired) +
         ",\"timeouts\":" + Fmt("%u", r.timeouts) +
         ",\"errors\":" + Fmt("%u", r.errors) +
         ",\"access_lost\":" + Fmt("%u", r.access_lost) +
         ",\"reduplications\":" + Fmt("%u", r.reduplications) +
         ",\"reduplication_failures\":" + Fmt("%u", r.reduplication_failures) +
         ",\"presented_frames\":" + Fmt("%u", r.presented_frames) +
         ",\"mouse_only_frames\":" + Fmt("%u", r.mouse_only_frames) +
         ",\"pointer_shape_updates\":" + Fmt("%u", r.pointer_shape_updates) +
         ",\"accumulated_frames\":" + Fmt("%llu", (unsigned long long)r.accumulated_frames) +
         ",\"elapsed_ms\":" + JNum(r.elapsed_ms) + "}";

    j += ",\"acquire_latency\":" + JStats(r.acquire_stats);
    j += ",\"timeout_block\":" + JStats(r.timeout_stats);

    j += ",\"metadata\":{\"bytes_total\":" +
         Fmt("%llu", (unsigned long long)r.metadata_bytes_total) +
         ",\"dirty_rects_total\":" + Fmt("%llu", (unsigned long long)r.dirty_rect_total) +
         ",\"dirty_frames\":" + Fmt("%u", r.frames_with_dirty) +
         ",\"dirty_max_per_frame\":" + Fmt("%u", r.max_dirty_in_frame) +
         ",\"dirty_area_total_px\":" + Fmt("%lld", (long long)r.dirty_area_total) +
         ",\"move_rects_total\":" + Fmt("%llu", (unsigned long long)r.move_rect_total) +
         ",\"move_frames\":" + Fmt("%u", r.frames_with_move) +
         ",\"move_max_per_frame\":" + Fmt("%u", r.max_move_in_frame) +
         ",\"move_area_total_px\":" + Fmt("%lld", (long long)r.move_area_total) +
         ",\"move_rects_ever_nonempty\":" + JBool(r.move_rect_total > 0) +
         ",\"errors\":" + Fmt("%u", r.metadata_errors) +
         ",\"last_error_hr\":" + JHex(r.last_metadata_hr) +
         ",\"last_error_hr_name\":" + JStr(HrName(r.last_metadata_hr)) + "}";

    j += ",\"errors_seen\":[";
    for (size_t i = 0; i < r.distinct_errors.size(); i++)
    {
        if (i) j += ",";
        j += "{\"hr\":" + JHex(r.distinct_errors[i]) +
             ",\"name\":" + JStr(HrName(r.distinct_errors[i])) +
             ",\"text\":" + JStr(HrText(r.distinct_errors[i])) + "}";
    }
    j += "]";
    j += "}";
    return j;
}

// ---------------------------------------------------------------- main

int main(int argc, char** argv)
{
    QueryPerformanceFrequency(&g_qpcFreq);
    if (g_qpcFreq.QuadPart == 0)
        g_qpcFreq.QuadPart = 1;

    Options opt;
    int positional = 0;
    for (int i = 1; i < argc; i++)
    {
        const char* a = argv[i];
        if (_stricmp(a, "--help") == 0 || _stricmp(a, "-h") == 0 || _stricmp(a, "/?") == 0)
        {
            Usage();
            return 2;
        }
        else if (_stricmp(a, "--timeout") == 0 && i + 1 < argc)
        {
            opt.timeout_ms = (unsigned)strtoul(argv[++i], nullptr, 10);
        }
        else if (_stricmp(a, "--output") == 0 && i + 1 < argc)
        {
            opt.only_output = (int)strtol(argv[++i], nullptr, 10);
        }
        else if (_stricmp(a, "--json") == 0 && i + 1 < argc)
        {
            opt.json_path = argv[++i];
        }
        else if (_stricmp(a, "--no-map") == 0)
        {
            opt.do_map = false;
        }
        else if (_stricmp(a, "--quiet") == 0)
        {
            opt.quiet = true;
        }
        else if (a[0] == '-')
        {
            fprintf(stderr, "ddaprobe: unknown option '%s'\n", a);
            Usage();
            return 2;
        }
        else if (positional == 0)
        {
            opt.frames = (unsigned)strtoul(a, nullptr, 10);
            positional++;
        }
        else if (positional == 1)
        {
            opt.max_seconds = strtod(a, nullptr);
            positional++;
        }
        else
        {
            fprintf(stderr, "ddaprobe: too many positional arguments\n");
            Usage();
            return 2;
        }
    }
    if (opt.frames == 0) opt.frames = 1;
    if (opt.max_seconds <= 0.0) opt.max_seconds = 30.0;
    if (opt.timeout_ms == 0) opt.timeout_ms = 1;

    const EnvInfo env = GatherEnv();

    if (!opt.quiet)
    {
        printf("ddaprobe " DDAPROBE_VERSION " - Desktop Duplication scoping probe\n");
        printf("  host=%s user=%s session=%lu elevated=%s\n",
               env.host.c_str(), env.user.c_str(), (unsigned long)env.session_id,
               env.elevated ? "yes" : "no");
        printf("  winsta=%s desktop=%s os_build=%s\n",
               env.winsta.c_str(), env.desktop.c_str(), env.os_build.c_str());
        printf("  frames=%u max_seconds=%.1f timeout_ms=%u map=%s\n",
               opt.frames, opt.max_seconds, opt.timeout_ms, opt.do_map ? "yes" : "no");
        if (env.session_id == 0)
            printf("  WARNING: session 0 - Desktop Duplication will fail. Run from an\n"
                   "           interactive session (qtest run lands in console session 1).\n");
        fflush(stdout);
    }

    std::string desktop_attach_note;
    std::vector<ProbeResult> results;
    std::string factory_error;
    HRESULT factory_hr = S_OK;

    IDXGIFactory1* factory = nullptr;
    factory_hr = CreateDXGIFactory1(__uuidof(IDXGIFactory1), (void**)&factory);
    if (FAILED(factory_hr) || !factory)
    {
        factory_error = Fmt("CreateDXGIFactory1 failed 0x%08X %s",
                            (unsigned)factory_hr, HrName(factory_hr));
        if (!opt.quiet)
            printf("\nFATAL: %s\n", factory_error.c_str());
    }
    else
    {
        int global = 0;
        for (UINT ai = 0; ; ai++)
        {
            IDXGIAdapter1* adapter = nullptr;
            HRESULT ehr = factory->EnumAdapters1(ai, &adapter);
            if (ehr == DXGI_ERROR_NOT_FOUND)
                break;
            if (FAILED(ehr) || !adapter)
            {
                SafeRelease(adapter);
                break;
            }

            DXGI_ADAPTER_DESC1 adesc;
            ZeroMemory(&adesc, sizeof(adesc));
            std::string adapterName = "<unknown>";
            if (SUCCEEDED(adapter->GetDesc1(&adesc)))
                adapterName = WFixed(adesc.Description, 128);

            for (UINT oi = 0; ; oi++)
            {
                IDXGIOutput* output = nullptr;
                HRESULT ohr = adapter->EnumOutputs(oi, &output);
                if (ohr == DXGI_ERROR_NOT_FOUND)
                    break;
                if (FAILED(ohr) || !output)
                {
                    SafeRelease(output);
                    break;
                }

                ProbeResult r;
                r.adapter_index = (int)ai;
                r.output_index = (int)oi;
                r.global_index = global++;
                r.adapter_desc = adapterName;

                DXGI_OUTPUT_DESC odesc;
                ZeroMemory(&odesc, sizeof(odesc));
                if (SUCCEEDED(output->GetDesc(&odesc)))
                {
                    r.device_name = WFixed(odesc.DeviceName, 32);
                    r.attached = (odesc.AttachedToDesktop != FALSE);
                    r.coords = odesc.DesktopCoordinates;
                    r.rotation = odesc.Rotation;
                }

                const bool skip = (opt.only_output >= 0 && opt.only_output != r.global_index);

                if (r.attached && !skip)
                {
                    IDXGIOutput1* output1 = nullptr;
                    r.output1_hr = output->QueryInterface(__uuidof(IDXGIOutput1),
                                                          (void**)&output1);
                    r.output1_ok = (SUCCEEDED(r.output1_hr) && output1 != nullptr);
                    if (r.output1_ok)
                    {
                        ID3D11Device* device = nullptr;
                        r.device_ok = CreateDeviceForAdapter(adapter, &device,
                                                             &r.feature_level, &r.device_hr);
                        if (r.device_ok && device)
                        {
                            IDXGIOutputDuplication* dupl = nullptr;
                            r.dupl_hr = output1->DuplicateOutput(device, &dupl);

                            // Rescue path: not on an interactive desktop.
                            if ((r.dupl_hr == E_ACCESSDENIED ||
                                 r.dupl_hr == DXGI_ERROR_SESSION_DISCONNECTED) &&
                                desktop_attach_note.empty())
                            {
                                std::string note;
                                if (AttachToInputDesktop(&note))
                                    r.dupl_hr = output1->DuplicateOutput(device, &dupl);
                                desktop_attach_note = note;
                            }

                            if (SUCCEEDED(r.dupl_hr) && dupl)
                            {
                                r.dupl_ok = true;

                                DXGI_OUTDUPL_DESC ddesc;
                                ZeroMemory(&ddesc, sizeof(ddesc));
                                dupl->GetDesc(&ddesc);
                                // INVERTED (experiment 0b): real code is (... != FALSE)
                                r.desktop_image_in_system_memory =
                                    (ddesc.DesktopImageInSystemMemory == FALSE);
                                if (!r.desktop_image_in_system_memory)
                                    r.sysmem_ever_false = true;
                                r.mode_width = ddesc.ModeDesc.Width;
                                r.mode_height = ddesc.ModeDesc.Height;
                                r.refresh_num = ddesc.ModeDesc.RefreshRate.Numerator;
                                r.refresh_den = ddesc.ModeDesc.RefreshRate.Denominator;
                                r.mode_format = ddesc.ModeDesc.Format;
                                r.scanline = ddesc.ModeDesc.ScanlineOrdering;
                                r.dupl_rotation = ddesc.Rotation;

                                // RunCaptureLoop takes ownership of dupl (it may replace
                                // it after ACCESS_LOST) and releases it before returning.
                                RunCaptureLoop(r, opt, output1, device, dupl);
                                dupl = nullptr;
                            }
                            else
                            {
                                SafeRelease(dupl);
                            }
                        }
                        SafeRelease(device);
                    }
                    SafeRelease(output1);
                }

                if (!skip)
                {
                    results.push_back(r);
                    if (!opt.quiet)
                    {
                        PrintHuman(r);
                        fflush(stdout);
                    }
                }

                SafeRelease(output);
            }
            SafeRelease(adapter);
        }
        SafeRelease(factory);
    }

    // ---- summary
    bool any_attached = false, any_dupl = false;
    bool all_sysmem = true, any_sysmem = false, any_move = false;
    int primary_idx = -1;
    // agent_idx = the output gui-agent/capture.c would actually pick: it keeps ONLY
    // adapter 0 (capture.c:60-68 "first adapter contains primary desktop") and takes the
    // FIRST AttachedToDesktop output on it (GetOutput, capture.c:105-149). The capture.c:
    // 176-183 abort verdict must be evaluated on THAT output, not ANDed over every output
    // on every adapter - otherwise a second adapter (e.g. a future QubesIDD) whose flag is
    // FALSE would produce a false FAIL while the agent would be perfectly fine.
    int agent_idx = -1;
    for (size_t i = 0; i < results.size(); i++)
    {
        const ProbeResult& r = results[i];
        if (r.attached)
        {
            any_attached = true;
            if (r.coords.left == 0 && r.coords.top == 0 && primary_idx < 0)
                primary_idx = r.global_index;
            if (r.adapter_index == 0 && agent_idx < 0)
                agent_idx = (int)i;
        }
        if (r.dupl_ok)
        {
            any_dupl = true;
            if (r.desktop_image_in_system_memory) any_sysmem = true; else all_sysmem = false;
            if (r.move_rect_total > 0) any_move = true;
        }
    }
    if (!any_dupl)
        all_sysmem = false;

    // THE Phase 1B verdict: agent's chosen output duplicated AND has the sysmem flag.
    bool agent_ok = (agent_idx >= 0) && results[agent_idx].dupl_ok &&
                    results[agent_idx].desktop_image_in_system_memory;
    int agent_output_index = (agent_idx >= 0) ? results[agent_idx].global_index : -1;

    if (!opt.quiet)
    {
        printf("\n=== SUMMARY ===\n");
        printf("  outputs reported             : %zu\n", results.size());
        printf("  any output attached          : %s\n", any_attached ? "yes" : "no");
        printf("  any output duplicated        : %s\n", any_dupl ? "yes" : "no");
        printf("  primary output (0,0)         : %d\n", primary_idx);
        printf("  agent's chosen output        : %d (adapter 0, first attached)\n", agent_output_index);
        printf("  DesktopImageInSystemMemory   : all=%s any=%s\n",
               all_sysmem ? "TRUE" : "false", any_sysmem ? "TRUE" : "false");
        printf("  -> capture.c:176-183 verdict : %s\n",
               agent_ok ? "PASS (agent capture path survives on its chosen output)"
                        : "FAIL (agent would abort on its chosen output)");
        printf("  move rects ever non-empty    : %s\n", any_move ? "YES" : "no");
        if (!desktop_attach_note.empty())
            printf("  desktop attach               : %s\n", desktop_attach_note.c_str());
        printf("\n");
    }

    // ---- JSON
    std::string j = "{";
    j += "\"tool\":\"ddaprobe-INVERTED\",\"inverted\":true,\"version\":\"" DDAPROBE_VERSION "\"";
    j += ",\"host\":" + JStr(env.host);
    j += ",\"user\":" + JStr(env.user);
    j += ",\"session_id\":" + Fmt("%lu", (unsigned long)env.session_id);
    j += ",\"elevated\":" + JBool(env.elevated);
    j += ",\"window_station\":" + JStr(env.winsta);
    j += ",\"desktop\":" + JStr(env.desktop);
    j += ",\"os_build\":" + JStr(env.os_build);
    j += ",\"desktop_attach_note\":" + JStr(desktop_attach_note);
    j += ",\"options\":{\"frames\":" + Fmt("%u", opt.frames) +
         ",\"max_seconds\":" + JNum(opt.max_seconds) +
         ",\"timeout_ms\":" + Fmt("%u", opt.timeout_ms) +
         ",\"only_output\":" + Fmt("%d", opt.only_output) +
         ",\"map_probe\":" + JBool(opt.do_map) + "}";
    j += ",\"factory_hr\":" + JHex(factory_hr);
    j += ",\"factory_error\":" + JStr(factory_error);
    j += ",\"outputs\":[";
    for (size_t i = 0; i < results.size(); i++)
    {
        if (i) j += ",";
        j += JResult(results[i]);
    }
    j += "]";
    j += ",\"summary\":{\"output_count\":" + Fmt("%zu", results.size()) +
         ",\"any_attached\":" + JBool(any_attached) +
         ",\"any_duplicated\":" + JBool(any_dupl) +
         ",\"primary_output_index\":" + Fmt("%d", primary_idx) +
         ",\"agent_output_index\":" + Fmt("%d", agent_output_index) +
         ",\"desktop_image_in_system_memory_all\":" + JBool(all_sysmem) +
         ",\"desktop_image_in_system_memory_any\":" + JBool(any_sysmem) +
         ",\"agent_capture_would_work\":" + JBool(agent_ok) +
         ",\"move_rects_ever_nonempty\":" + JBool(any_move) + "}";
    j += "}";

    printf("=== DDAPROBE JSON ===\n%s\n", j.c_str());
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
            fprintf(stderr, "ddaprobe: could not write %s\n", opt.json_path.c_str());
        }
    }

    return any_dupl ? 0 : 1;
}
