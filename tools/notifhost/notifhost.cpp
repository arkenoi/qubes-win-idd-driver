// notifhost.exe - user-session toast helper for QWT. Two jobs, selected by mode:
//
// DEFAULT (legacy interceptor, experimental, not launched by anything today): renders each
// incoming toast as a NORMAL bordered GDI window (redirected, PrintWindow-capturable) so the
// agent can map it like any guest window. Kept for de-slice experiments.
//
// --bridge (DESIGN-toast-bridge.md, Proposal C phase A0): resident notification bridge.
// Toasts from ALLOWLISTED apps (HKLM gui-agent config, NotifyBridgeAllow REG_MULTI_SZ of
// AUMIDs) are read via UserNotificationListener and forwarded over ONE long-lived
// qubes.Notifications connection to the dom0-native notification service; their Windows
// banner is suppressed (per-AUMID ShowBanner=0, prior state recorded and restored) so the
// toast does not also map as an override-redirect window in dom0. dom0 dismissal is echoed
// back as RemoveNotification (guest Notification Center stays in sync). Everything else -
// every non-allowlisted app, and every toast while the bridge is unhealthy or disconnected -
// takes today's window path untouched: fail-open is the design invariant. Launched and
// supervised by the SYSTEM gui-agent via Task Scheduler (/ru user /it, wgcbroker pattern),
// gated by registry "NotifyBridge" / qubesdb /qubes-service/notify-bridge, default OFF.
// P3a shadow instrumentation (MEASURE-ONLY, DESIGN-toast-bridge.md 3.4.1): every new toast
// is additionally acquired through the HYBRID fail-open ladder (tier 1: an ETW SIGNAL
// {AUMID, notificationId, tag, group} from the ring - fed over ONE-WAY read-only IPC by the
// separate --etw-proxy process, NO ETW/TDH code runs in this user-session bridge - answered
// by ONE TARGETED wpndatabase read for the payload, keyed by notificationId with an
// AUMID+tag+group+arrival-window fallback; tier 2: the wpndatabase.db correlate when no
// signal exists, on an OFF-THREAD worker paced by a WAL file-watch; tier 3: none -> window;
// see the P3-ETW section) and
// dry-run classified (CLASSIFY + SUPPAPI lines in bridge.log), and each forward's dom0 ack
// round-trip is timed (FWD_RTT) to size the Phase-3 deferred-map hold budget. None of this
// can change which toasts banner or forward - the A0 routing is byte-for-byte unchanged.
// Toast DETECTION is push-first: UserNotificationListener.NotificationChanged gates the
// expensive center listing, with a bounded 30 s floor pass as the can-never-lose-a-toast
// safety net; the loop still wakes every 2 s for the supervisor heartbeat contract.
//
// --relay <pipe> (internal): the qrexec-side end of the bridge's long-lived connection.
// qrexec-client-vm does NOT wire the caller's stdio to the vchan - it hands a command line
// to qrexec-agent, which spawns THIS mode in the interactive session with stdin/stdout on
// the data vchan. It splices that stdio to the resident bridge's named pipe and exits when
// either side closes (guest/qubes-updates-relay.cs splice shape).
//
// --dump-aumids: print AUMID + title of every toast currently in the Notification Center
// (allowlist authoring aid; the listener exposes AppInfo.AppUserModelId).
//
// --dump-wpndb [N] (P3a probe, DESIGN-toast-bridge.md 3.4.1): read-only dump of the WNS
// platform database %LocalAppData%\Microsoft\Windows\Notifications\wpndatabase.db via the
// IN-BOX System32 winsqlite3.dll - prints the schema the Phase-3 classifier relies on, then
// the latest N (default 20) rows {AUMID, ArrivalTime, Tag, Group, Payload XML}, each with
// toastclassify.h's shadow verdict. Schema-gated: a missing table/column prints a loud
// WPNDB SCHEMA MISMATCH line and exits non-zero. Runs in the interactive user session (the
// DB is per-user). The Phase-3 DECISION GATE compares this output across win10 / win11 24H2
// / win11 25H2: proceed only if the schema matches on all three and correlation is workable.
//
// --dump-etw [seconds] (P3-ETW probe): real-time ETW consumer diagnostic - starts a private
// trace session, enables the candidate notification providers, and for <seconds> (default
// 30) prints every received event's provider GUID + id/name + decoded field map, flagging
// which events carry an AUMID and/or a toast payload XML. THE instrument for the rig gate
// question "does any notification provider deliver the full payload to an UNPRIVILEGED
// consumer?" - nothing in the ladder assumes the answer; until this probe says yes on a
// guest, the ETW tier there runs state=down/miss and tier 2 (the DB) serves everything.
// Exit: 0 clean run, 5 session start access-denied (needs Performance Log Users membership
// or elevation - itself a decisive gate datum), 6 other session-start failure, 7 consumer
// open failure. Runs the consumer INLINE in this process - it is a hand diagnostic run
// under whatever token invokes it; the resident bridge itself never runs ETW code.
//
// --etw-proxy [--client-sid <SID>] (P3-ETW acquisition proxy): the LEAST-PRIVILEGE home of
// the bridge's real-time ETW consumer - a PURE CONSUMER under the two-context split
// (DESIGN-p3-classifier-impl.md secs 10.18/10.19). The SYSTEM agent
// (agent/gui-agent/etwproxy.c) is the session CONTROLLER: it starts QubesToastBridgeEtw,
// enables the providers, and grants this process's account TRACELOG_ACCESS_REALTIME on
// the session GUID (EventAccessControl) BEFORE launching us. This mode does OpenTraceW +
// ProcessTrace + TDH property location ONLY, under the dedicated qubes-etwproxy account
// whose token NEVER held Performance Log Users or SeSystemProfilePrivilege: it cannot
// (and must not) StartTrace/EnableTrace/ControlTrace, and it NEVER stops the session
// (the agent does, at park/shutdown/job-kill). It is the SERVER of a kernel-enforced
// one-way pipe (PIPE_ACCESS_OUTBOUND, DACL = the --client-sid bridge user ONLY,
// read-only) and only PUSHES payload-free SIGNAL frames {AUMID, notificationId (string +
// numeric), tag, group, FILETIME} (design 10.20.1 - the rig proved the <toast> payload is
// NEVER in ETW on Win10, so the proxy no longer materializes payload bytes at all; the
// bridge answers each signal with ONE targeted wpndatabase read for the payload); it
// reads nothing, accepts no control channel, has no stop file. Exit:
// 0 clean stop, 5 consume denied (OpenTrace/ProcessTrace ERROR_ACCESS_DENIED - the
// per-session DACL grant did not suffice on this build; the agent parks on this TRUE
// finding), 7 consumer open/thread/event failure, 8 pipe creation failure (incl. a
// squatter), 9 REFUSED: SYSTEM/admin/elevated token (the never-SYSTEM guard) or a
// DRIFTED token carrying Performance Log Users / SeSystemProfilePrivilege (running the
// hostile TDH decode with machine-wide trace capability is forbidden, and group SIDs
// cannot be shed in-process - the untrusted parse runs on a bare token or not at all).
//
// --bridge-stop: write the ProgramData stop file the resident bridge polls; it exits and
// restores every banner suppression on the way out.
//
// --restore-banners: one-shot BannerRestoreAll for the invoking user, then exit. The agent
// launches this in the user session when the bridge gate is OFF but crash-leftover ShowBanner
// markers exist (no bridge will ever start to run its own startup restore) - the restorer of
// last resort for the fail-open invariant.
//
// Wire protocol: see tools/notify-proxy/NotifyClient.cs (verified against
// qubes-notification-proxy v1.1.2) - u32 LE version handshake (server speaks first), then
// u32-LE-length-prefixed bincode-1.x fixint LE frames. The encoder here is that file's
// EncodeMessage ported to C++; replies: 0=Id 1=DBusError 2=UnknownError 3=Dismissed
// 4=ActionInvoked 5=ServerRestart.
//
// Build mirrors tools/wgcbroker (v143, /MT, C++/WinRT from the SDK, no WDK/nuget).
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <sddl.h>       // ConvertSidToStringSidW
#include <wincrypt.h>   // CryptoAPI SHA-1 (TraceLogging provider name -> GUID hash)
#include <wmistr.h>     // WNODE_HEADER (evntrace.h prerequisite)
#include <evntrace.h>   // StartTrace/EnableTraceEx2/OpenTrace/ProcessTrace (real-time ETW)
#include <evntcons.h>   // EVENT_RECORD consumer definitions
#include <tdh.h>        // TdhGetEventInformation/TdhFormatProperty (self-describing decode)
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.ApplicationModel.h>
#include <winrt/Windows.UI.Notifications.h>
#include <winrt/Windows.UI.Notifications.Management.h>
#include <string>
#include <unordered_set>
#include <unordered_map>
#include <vector>
#include <deque>
#include <cstdio>
#include <cstdarg>
#include "toastclassify.h"   // P3b pure decision-table classifier (P3a logs its verdicts)

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "tdh.lib")       // in-box Windows SDK (TDH event decoding) - no WDK/nuget
#pragma comment(lib, "windowsapp.lib")

using namespace winrt;
using namespace winrt::Windows::UI::Notifications;
using namespace winrt::Windows::UI::Notifications::Management;

static HANDLE g_agent = nullptr;
static DWORD  g_agentPid = 0;
static DWORD  g_mySession = 0;

// Agent-liveness check - a BACKUP only. The agent's shutdown writes the ProgramData stop file
// (NotifBridgeRequestStop), which the main loop polls every pass; THAT is the primary channel.
// The SYNCHRONIZE handle is the cheap path but OpenProcess(SYNCHRONIZE) on the SYSTEM gui-agent
// is DENIED to this limited user token, so g_agent is normally NULL and this probe does the work.
//
// It MUST be snapshot-free. The previous implementation called CreateToolhelp32Snapshot(
// TH32CS_SNAPPROCESS) - a whole-process-table walk - on the sole worker thread every 5 s;
// bisected (2026-09-05) as the forward->dismiss regression: its variable, heavyweight latency,
// landing inside a 3-forward burst (reader thread busy, dom0 round-trips in flight), intermittently
// pushed one loop iteration past the agent supervisor's 15 s stale-heartbeat deadline, and the
// supervisor then TERMINATED the still-alive bridge via schtasks /delete (artifact-free: no WER,
// no unhandled fault, Task=Running - exactly what was observed; full PageHeap caught nothing,
// which itself argues against in-process heap corruption).
//
// OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION) + GetExitCodeProcess is a fixed-cost,
// non-allocating, non-walking probe. PROCESS_QUERY_LIMITED_INFORMATION is grantable to this
// limited token for the SYSTEM agent where SYNCHRONIZE is not (that access right exists precisely
// for cross-context liveness/name queries). EVERY failure path returns "alive" (fail-open) so the
// probe can never trigger a spurious exit; a reused PID reads as alive and is caught by the stop
// file / session-change instead. Throttled to 30 s - it is only a backup, so infrequent is fine.
static bool AgentGone()
{
    if (g_agent) return WaitForSingleObject(g_agent, 0) == WAIT_OBJECT_0;
    if (!g_agentPid) return false;
    static ULONGLONG next = 0;
    static bool gone = false;
    ULONGLONG now = GetTickCount64();
    if (gone || now < next) return gone;
    next = now + 30000;
    HANDLE h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, g_agentPid);
    if (!h) return false;                     // cannot query (denied/failed) - assume alive
    DWORD ec = STILL_ACTIVE;
    BOOL ok = GetExitCodeProcess(h, &ec);
    CloseHandle(h);
    if (!ok) return false;                    // cannot tell - assume alive
    gone = (ec != STILL_ACTIVE);
    return gone;
}

struct ToastWin { HWND hwnd; std::wstring title, body; ULONGLONG dieAt; };
static std::deque<ToastWin*> g_wins;

static LRESULT CALLBACK ToastProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    ToastWin* tw = (ToastWin*)GetWindowLongPtrW(h, GWLP_USERDATA);
    switch (m) {
    case WM_PAINT: {
        PAINTSTRUCT ps; HDC dc = BeginPaint(h, &ps);
        RECT rc; GetClientRect(h, &rc);
        HBRUSH bg = CreateSolidBrush(RGB(0x20, 0x20, 0x20));
        FillRect(dc, &rc, bg); DeleteObject(bg);
        SetBkMode(dc, TRANSPARENT); SetTextColor(dc, RGB(0xF0, 0xF0, 0xF0));
        if (tw) {
            HFONT bold = CreateFontW(22, 0, 0, 0, FW_BOLD, 0, 0, 0, DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, VARIABLE_PITCH, L"Segoe UI");
            HFONT norm = CreateFontW(18, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
                OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY, VARIABLE_PITCH, L"Segoe UI");
            RECT tr = { 14, 12, rc.right - 14, 44 };
            HGDIOBJ old = SelectObject(dc, bold);
            DrawTextW(dc, tw->title.c_str(), -1, &tr, DT_LEFT | DT_END_ELLIPSIS | DT_SINGLELINE);
            SelectObject(dc, norm);
            RECT br = { 14, 48, rc.right - 14, rc.bottom - 12 };
            DrawTextW(dc, tw->body.c_str(), -1, &br, DT_LEFT | DT_WORDBREAK | DT_END_ELLIPSIS);
            SelectObject(dc, old); DeleteObject(bold); DeleteObject(norm);
        }
        EndPaint(h, &ps); return 0;
    }
    case WM_LBUTTONUP: DestroyWindow(h); return 0;   // click to dismiss
    case WM_NCDESTROY:
        if (tw) { for (auto it = g_wins.begin(); it != g_wins.end(); ++it) if (*it == tw) { g_wins.erase(it); break; } delete tw; }
        return 0;
    }
    return DefWindowProcW(h, m, w, l);
}

static void ShowToast(std::wstring const& title, std::wstring const& body)
{
    static const wchar_t* cls = L"QwtToastHost";
    static bool reg = false;
    if (!reg) {
        WNDCLASSW wc{}; wc.lpfnWndProc = ToastProc; wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = cls; wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
        wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
        RegisterClassW(&wc); reg = true;
    }
    int W = 400, H = 130, margin = 24;
    int sw = GetSystemMetrics(SM_CXSCREEN), sh = GetSystemMetrics(SM_CYSCREEN);
    // stack toward the bottom-right, above any already-open toast windows
    int y = sh - H - margin - (int)g_wins.size() * (H + 12);
    // Override-redirect + unmovable, toast-like (owner request): a bare WS_POPUP with no caption
    // is classified override-redirect by the agent (IsPopup), so dom0 maps it borderless and the
    // user cannot drag it. It is a plain GDI window (has a redirection surface), so it is captured
    // by the normal slice OR by the broker (unlike shell CoreWindows) - it just must not be a
    // shell CoreWindow. WS_EX_NOACTIVATE keeps focus off it (toast semantics); click dismisses.
    HWND h = CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_TOOLWINDOW, cls, L"Notification",
        WS_POPUP | WS_VISIBLE,
        sw - W - margin, y, W, H, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!h) return;
    ToastWin* tw = new ToastWin{ h, title, body, GetTickCount64() + 12000 };
    SetWindowLongPtrW(h, GWLP_USERDATA, (LONG_PTR)tw);
    g_wins.push_back(tw);
    ShowWindow(h, SW_SHOWNA); UpdateWindow(h);
}

static std::wstring FirstTexts(UserNotification const& un)
{
    std::wstring title, body;
    try {
        auto vis = un.Notification().Visual();
        auto bind = vis.GetBinding(KnownNotificationBindings::ToastGeneric());
        if (bind) {
            auto els = bind.GetTextElements();
            uint32_t i = 0;
            for (auto const& e : els) { if (i == 0) title = e.Text().c_str(); else { if (!body.empty()) body += L"\n"; body += e.Text().c_str(); } i++; }
        }
    } catch (...) {}
    if (title.empty()) title = L"Notification";
    return title + L"\x1f" + body;   // 0x1f separates title from body
}

// ==================== bridge mode (DESIGN-toast-bridge.md phase A0) ====================

static std::wstring StateDir()
{
    wchar_t pd[MAX_PATH];
    if (!GetEnvironmentVariableW(L"ProgramData", pd, RTL_NUMBER_OF(pd)))
        wcscpy_s(pd, L"C:\\ProgramData");
    std::wstring d = std::wstring(pd) + L"\\qubes-toast-bridge";
    CreateDirectoryW(d.c_str(), nullptr);
    return d;
}

// The STANDARD QWT log directory (windows-utils LogInitDefault convention, log.c:235-253):
// HKLM\Software\Invisible Things Lab\Qubes Tools : LogDir if set, else %SYSTEMDRIVE%\Qubes Logs.
// --etw-proxy routes etw-proxy.log HERE (not the bridge's qubes-toast-bridge state dir): the
// proxy runs as a different, lower-privileged account and must hold write access to its OWN log
// ONLY - never to the bridge's control surfaces (stop file, heartbeat, banner markers). The
// proxy-scoped ACE (Modify on this one log) is granted by guest/provision-etwproxy-account.ps1.
static std::wstring QwtLogDir()
{
    wchar_t buf[MAX_PATH];
    HKEY k;
    if (!RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"Software\\Invisible Things Lab\\Qubes Tools",
                       0, KEY_READ | KEY_WOW64_64KEY, &k))
    {
        DWORD cb = sizeof(buf), type = 0;
        LONG r = RegQueryValueExW(k, L"LogDir", nullptr, &type, (BYTE*)buf, &cb);
        RegCloseKey(k);
        if (r == ERROR_SUCCESS && (type == REG_SZ || type == REG_EXPAND_SZ) &&
            cb >= sizeof(wchar_t) && buf[0])
        {
            buf[cb / sizeof(wchar_t) < RTL_NUMBER_OF(buf) ? cb / sizeof(wchar_t) : RTL_NUMBER_OF(buf) - 1] = 0;
            std::wstring d(buf);
            if (type == REG_EXPAND_SZ)
            {
                wchar_t ex[MAX_PATH];
                if (ExpandEnvironmentStringsW(d.c_str(), ex, RTL_NUMBER_OF(ex))) d = ex;
            }
            return d;
        }
    }
    // Default: %SYSTEMDRIVE%\Qubes Logs (LOG_DEFAULT_DIR). Derive the system drive from the
    // system directory (e.g. "C:\Windows\System32" -> "C:\").
    wchar_t sysdir[MAX_PATH];
    if (GetSystemDirectoryW(sysdir, RTL_NUMBER_OF(sysdir)) && sysdir[1] == L':')
    {
        std::wstring d(sysdir, 3);   // "C:\"
        d += L"Qubes Logs";
        return d;
    }
    return L"C:\\Qubes Logs";
}

static std::string Utf8(std::wstring const& w)
{
    if (w.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n > 0 ? n : 0, 0);
    if (n > 0) WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

// Log file basename: bridge.log for every user-session mode; --etw-proxy switches to its
// own file BEFORE its first BLog (it runs under a different account - the state dir's ACLs
// may deny it bridge.log, and interleaving two accounts' writers would be noise anyway).
static const wchar_t* g_logName = L"\\bridge.log";
// --etw-proxy sets this to the STANDARD QWT LogDir (QwtLogDir()) BEFORE its first BLog, so its
// log lands in the standard location rather than the bridge's state dir. Empty = use StateDir().
static std::wstring g_logDirOverride;

static void BLog(const wchar_t* fmt, ...)
{
    static std::wstring path;
    if (path.empty()) path = (g_logDirOverride.empty() ? StateDir() : g_logDirOverride) + g_logName;
    wchar_t line[2048];
    SYSTEMTIME st; GetLocalTime(&st);
    int off = swprintf(line, RTL_NUMBER_OF(line), L"%02u:%02u:%02u ", st.wHour, st.wMinute, st.wSecond);
    va_list ap; va_start(ap, fmt);
    vswprintf(line + off, RTL_NUMBER_OF(line) - off - 2, fmt, ap);
    va_end(ap);
    wcscat_s(line, L"\r\n");
    // rotate at ~1 MB so a chatty failure can never eat the disk
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &fad) && fad.nFileSizeLow > 1024 * 1024)
        MoveFileExW(path.c_str(), (path + L".old").c_str(), MOVEFILE_REPLACE_EXISTING);
    HANDLE f = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                           OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (f == INVALID_HANDLE_VALUE) return;
    std::string u = Utf8(line);
    DWORD wr; WriteFile(f, u.data(), (DWORD)u.size(), &wr, nullptr);
    CloseHandle(f);
}

// DIAGNOSTIC (2026-09-05 silent-vanish localization): last-chance crash breadcrumb. Under
// /EHsc catch(...) sees only C++ exceptions; an SEH fault (AV etc.) bypasses every guard and
// killed the process with no log line. This filter logs the code+address+thread before the
// process dies. A __fastfail/heap-corruption fail-fast BYPASSES even this filter - so a vanish
// with NO CRASH line and NO guard line is itself a signal (memory-safety class). Process still
// terminates (fail-open: the agent supervisor relaunches on the stale heartbeat, and the next
// start's BannerRestoreAll undoes any standing suppression).
static LONG WINAPI BridgeCrashFilter(EXCEPTION_POINTERS* ep)
{
    if (ep && ep->ExceptionRecord)
        BLog(L"CRASH code=0x%08lX addr=%p tid=%lu (unhandled - terminating)",
             ep->ExceptionRecord->ExceptionCode,
             ep->ExceptionRecord->ExceptionAddress,
             GetCurrentThreadId());
    else
        BLog(L"CRASH (no exception record) tid=%lu (unhandled - terminating)",
             GetCurrentThreadId());
    return EXCEPTION_EXECUTE_HANDLER;
}

// --- config -------------------------------------------------------------------------------

// DEFAULT allowlist - the conservative seed used when NotifyBridgeAllow is unset. The
// classification IS the list, and fail-open protects UNKNOWN apps but NOT a wrongly-listed one
// (a mis-listed real-choice app would be suppressed-and-lossy), so every default entry must be
// an app whose toasts are reliably INFORMATIONAL (click-to-open or dismiss-only) - never a real
// choice. Exact AUMID match (case-insensitive), so these are the packaged apps' PFN!AppId and
// the well-known system pseudo-AUMIDs. Stock on Win10/11; an app that is not installed simply
// never fires (harmless). Verify/extend per real guest with `notifhost --dump-aumids`.
//
// DELIBERATELY EXCLUDED (real choice -> MUST stay on the window path, do NOT add):
//   Windows.SystemToast.WindowsUpdate.Notification  (Restart now / Pick a time)
//   Microsoft.YourPhone_8wekyb3d8bbwe!App           (Phone Link quick-reply text box)
//   *.Outlook / Calendar / reminder senders          (Snooze + interval selection)
//   Microsoft.Windows.Explorer                       (the catch-all shell sender; also the
//                                                     acceptance control for a real-choice toast)
static const wchar_t* const DEFAULT_ALLOW[] = {
    L"Microsoft.ScreenSketch_8wekyb3d8bbwe!App",       // Snipping Tool: "screenshot saved" (open)
    L"Microsoft.WindowsCamera_8wekyb3d8bbwe!App",      // Camera: photo/video saved
    L"Microsoft.Windows.Photos_8wekyb3d8bbwe!App",     // Photos: import / edit complete
    L"Windows.SystemToast.SecurityAndMaintenance",     // Security & Maintenance status (click-to-open)
    L"Windows.SystemToast.BackupReminder",             // "back up your files" status
};

// Allowlist of AUMIDs whose toasts are bridged: REG_MULTI_SZ "NotifyBridgeAllow" under the
// gui-agent's config key. If the value is set (non-empty) it is authoritative; if it is ABSENT
// the conservative DEFAULT_ALLOW seed is used (so the bridge does something sensible out of the
// box when gated on). To bridge NOTHING, use service.legacy-toasts / disable notify-bridge -
// those are the "no bridge" controls; the allowlist is "which apps", not the on/off switch.
static std::vector<std::wstring> ReadAllowlist()
{
    std::vector<std::wstring> out;
    HKEY k;
    if (!RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Invisible Things Lab\\Qubes Tools\\gui-agent",
                       0, KEY_READ | KEY_WOW64_64KEY, &k))
    {
        DWORD type = 0, cb = 0;
        if (!RegQueryValueExW(k, L"NotifyBridgeAllow", nullptr, &type, nullptr, &cb) &&
            type == REG_MULTI_SZ && cb > 2)
        {
            std::vector<wchar_t> buf(cb / sizeof(wchar_t) + 2, 0);
            if (!RegQueryValueExW(k, L"NotifyBridgeAllow", nullptr, &type, (BYTE*)buf.data(), &cb))
                for (const wchar_t* p = buf.data(); *p; p += wcslen(p) + 1)
                    out.emplace_back(p);
        }
        RegCloseKey(k);
    }
    if (out.empty())
    {
        for (const wchar_t* a : DEFAULT_ALLOW) out.emplace_back(a);
        BLog(L"allowlist unset - using the compiled DEFAULT_ALLOW seed (%u apps)", (UINT)out.size());
    }
    return out;
}

// Seed the per-user listener consent ONLY when it has never been set (same value the Settings
// toggle writes; proven sufficient for an unpackaged reader on this guest). An
// explicit value - crucially "Deny" - is the user's decision and is left untouched: re-seeding
// Allow over a Deny would (a) override a user who deliberately turned notification access off
// and (b) defeat the fail-open selftest, since the agent relaunches this process ~1/min and each
// launch would re-grant. The authoritative health check is GetAccessStatus afterwards - on Deny
// the bridge exits WITHOUT having suppressed anything (fail-open).
static void EnsureConsent()
{
    HKEY k;
    if (RegCreateKeyExW(HKEY_CURRENT_USER,
        L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\userNotificationListener",
        0, nullptr, 0, KEY_READ | KEY_SET_VALUE, nullptr, &k, nullptr))
        return;
    wchar_t cur[16] = { 0 }; DWORD cb = sizeof(cur), type = 0;
    LONG r = RegQueryValueExW(k, L"Value", nullptr, &type, (BYTE*)cur, &cb);
    if (r != ERROR_SUCCESS || type != REG_SZ || cur[0] == 0)   // ABSENT/empty only - never over an explicit value
    {
        RegSetValueExW(k, L"Value", 0, REG_SZ, (const BYTE*)L"Allow", 6 * sizeof(wchar_t));
        BLog(L"consent seeded Allow (was unset)");
    }
    else if (_wcsicmp(cur, L"Allow") != 0)
        BLog(L"consent is '%s' (explicit) - respecting it, not re-seeding", cur);
    RegCloseKey(k);
}

// --- ShowBanner lifecycle -----------------------------------------------------------------
// Suppression is LAZY - applied to an AUMID only after its first SUCCESSFUL forward while the
// connection is up - and the pre-existing value is recorded in a marker file first, so every
// exit path (and the next start, after a crash) can restore the user's setting. This is the
// P.6 top-risk mitigation, strengthened: a bridge that never forwards never suppresses, so a
// dead/failing bridge can never leave an allowlisted app bannerless-and-unforwarded.
//
// Markers are SID-scoped. HKCU is per-user but %ProgramData% is machine-wide, so a marker from
// user A must never be restored into user B's hive; the SID in the filename keeps each user's
// restore set separate (BannerRestoreAll globs only the current SID).

static ULONGLONG Fnv1a64(std::string const& s)
{
    ULONGLONG h = 1469598103934665603ULL;
    for (unsigned char c : s) { h ^= c; h *= 1099511628211ULL; }
    return h;
}

static std::wstring CurrentUserSid()
{
    HANDLE tok = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok)) return L"unknown";
    DWORD cb = 0; GetTokenInformation(tok, TokenUser, nullptr, 0, &cb);
    std::vector<BYTE> buf(cb ? cb : 1);
    std::wstring out = L"unknown";
    if (cb && GetTokenInformation(tok, TokenUser, buf.data(), cb, &cb))
    {
        LPWSTR s = nullptr;
        if (ConvertSidToStringSidW(((TOKEN_USER*)buf.data())->User.Sid, &s) && s)
        { out = s; LocalFree(s); }
    }
    CloseHandle(tok);
    return out;
}

// Marker basename glob for the current user (shared by MarkerPath and BannerRestoreAll).
static std::wstring MarkerPrefix()
{
    return L"\\banner-" + std::to_wstring(Fnv1a64(Utf8(CurrentUserSid()))) + L"-";
}

static std::wstring MarkerPath(std::wstring const& aumid)
{
    wchar_t tail[48];
    swprintf(tail, RTL_NUMBER_OF(tail), L"%016llx.prev", Fnv1a64(Utf8(aumid)));
    return StateDir() + MarkerPrefix() + tail;
}

static std::wstring BannerKey(std::wstring const& aumid)
{
    return L"Software\\Microsoft\\Windows\\CurrentVersion\\Notifications\\Settings\\" + aumid;
}

// Suppress ONE AUMID's banner (lazy: called after its first successful forward), recording the
// prior state in a SID-scoped marker so it can be restored on any exit path or a later start.
static void BannerApplyOne(std::wstring const& a)
{
    std::wstring marker = MarkerPath(a);
    if (GetFileAttributesW(marker.c_str()) == INVALID_FILE_ATTRIBUTES)
    {
        // record prior state: "absent", "0" or "1" (second line; first line = AUMID)
        std::wstring prior = L"absent";
        HKEY k;
        if (!RegOpenKeyExW(HKEY_CURRENT_USER, BannerKey(a).c_str(), 0, KEY_READ, &k))
        {
            DWORD v = 0, cb = sizeof(v), type = 0;
            if (!RegQueryValueExW(k, L"ShowBanner", nullptr, &type, (BYTE*)&v, &cb) && type == REG_DWORD)
                prior = v ? L"1" : L"0";
            RegCloseKey(k);
        }
        std::string body = Utf8(a + L"\n" + prior + L"\n");
        HANDLE f = CreateFileW(marker.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                               FILE_ATTRIBUTE_NORMAL, nullptr);
        if (f != INVALID_HANDLE_VALUE)
        { DWORD wr; WriteFile(f, body.data(), (DWORD)body.size(), &wr, nullptr); CloseHandle(f); }
    }
    HKEY k;
    if (!RegCreateKeyExW(HKEY_CURRENT_USER, BannerKey(a).c_str(), 0, nullptr, 0,
                         KEY_SET_VALUE, nullptr, &k, nullptr))
    {
        DWORD zero = 0;
        RegSetValueExW(k, L"ShowBanner", 0, REG_DWORD, (const BYTE*)&zero, sizeof(zero));
        RegCloseKey(k);
    }
    BLog(L"ShowBanner=0 for %s (after first successful forward)", a.c_str());
}

// Restores every suppression this user's markers record. A marker found at STARTUP is positive
// evidence of a suppression gap (the previous instance died without restoring, so ShowBanner=0
// stood while nobody was forwarding); the optional out-param reports those AUMIDs so the caller
// can avoid silently baselining away a toast that fired bannerless in that gap.
static void BannerRestoreAll(std::vector<std::wstring>* restoredAumids = nullptr)
{
    // SID-scoped: restore ONLY this user's markers, never another user's HKCU state.
    std::wstring pat = StateDir() + MarkerPrefix() + L"*.prev";
    WIN32_FIND_DATAW fd;
    HANDLE fh = FindFirstFileW(pat.c_str(), &fd);
    if (fh == INVALID_HANDLE_VALUE) return;
    do {
        std::wstring marker = StateDir() + L"\\" + fd.cFileName;
        HANDLE f = CreateFileW(marker.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                               OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (f == INVALID_HANDLE_VALUE) continue;
        char buf[2048] = { 0 }; DWORD rd = 0;
        ReadFile(f, buf, sizeof(buf) - 1, &rd, nullptr);
        CloseHandle(f);
        // parse "aumid\nprior\n" (utf8)
        std::string s(buf, rd);
        size_t nl = s.find('\n');
        if (nl == std::string::npos) { DeleteFileW(marker.c_str()); continue; }
        std::string a8 = s.substr(0, nl);
        std::string prior = s.substr(nl + 1);
        while (!prior.empty() && (prior.back() == '\n' || prior.back() == '\r')) prior.pop_back();
        int wn = MultiByteToWideChar(CP_UTF8, 0, a8.c_str(), (int)a8.size(), nullptr, 0);
        std::wstring aumid(wn > 0 ? wn : 0, 0);
        if (wn > 0) MultiByteToWideChar(CP_UTF8, 0, a8.c_str(), (int)a8.size(), &aumid[0], wn);
        if (!aumid.empty())
        {
            if (prior == "absent")
                RegDeleteKeyValueW(HKEY_CURRENT_USER, BannerKey(aumid).c_str(), L"ShowBanner");
            else
            {
                HKEY k;
                if (!RegCreateKeyExW(HKEY_CURRENT_USER, BannerKey(aumid).c_str(), 0, nullptr, 0,
                                     KEY_SET_VALUE, nullptr, &k, nullptr))
                {
                    DWORD v = (prior == "1") ? 1 : 0;
                    RegSetValueExW(k, L"ShowBanner", 0, REG_DWORD, (const BYTE*)&v, sizeof(v));
                    RegCloseKey(k);
                }
            }
            BLog(L"ShowBanner restored (%hs) for %s", prior.c_str(), aumid.c_str());
            if (restoredAumids) restoredAumids->push_back(aumid);
        }
        DeleteFileW(marker.c_str());
    } while (FindNextFileW(fh, &fd));
    FindClose(fh);
}

// --- wire codec (ported from NotifyClient.cs, bincode 1.x fixint LE) ----------------------

static void PutU32(std::vector<BYTE>& v, uint32_t x)
{ v.push_back((BYTE)x); v.push_back((BYTE)(x >> 8)); v.push_back((BYTE)(x >> 16)); v.push_back((BYTE)(x >> 24)); }
static void PutU64(std::vector<BYTE>& v, uint64_t x)
{ PutU32(v, (uint32_t)x); PutU32(v, (uint32_t)(x >> 32)); }
static uint32_t GetU32(const BYTE* b) { return b[0] | (b[1] << 8) | (b[2] << 16) | ((uint32_t)b[3] << 24); }
static uint64_t GetU64(const BYTE* b) { return GetU32(b) | ((uint64_t)GetU32(b + 4) << 32); }

// Message { id: u64, Notification::V1 { ... } }, framed with a u32 LE length prefix.
static std::vector<BYTE> EncodeNotifyFrame(uint64_t seq, std::string const& summary, std::string const& body)
{
    std::vector<BYTE> m;
    PutU64(m, seq);             // Message.id (echoed as `sequence` in replies)
    PutU32(m, 0);               // Notification enum tag: 0 = V1
    m.push_back(0);             // suppress_sound = false
    m.push_back(0);             // transient = false
    m.push_back(0);             // resident = false
    m.push_back(0);             // urgency: Option None
    PutU32(m, 0);               // replaces_id: 0 = new notification
    PutU64(m, summary.size()); m.insert(m.end(), summary.begin(), summary.end());
    PutU64(m, body.size());    m.insert(m.end(), body.begin(), body.end());
    PutU64(m, 0);               // actions: count 0 (phase 2 adds ["default","Open"])
    m.push_back(0);             // category: Option None
    PutU32(m, 0xFFFFFFFFu);     // expire_timeout: i32 -1 = server default
    m.push_back(0);             // image: Option None
    std::vector<BYTE> f;
    PutU32(f, (uint32_t)m.size());
    f.insert(f.end(), m.begin(), m.end());
    return f;
}

// ==================== P3a probe: wpndatabase.db shadow classifier (MEASURE-ONLY) ==========
// NOW TIER 2 of the acquisition ladder (see the P3-ETW section below): WpnCorrelate is
// the ETW-DOWN fallback - it runs only when NO ETW signal exists for a toast (tier
// down/off, or the providers were silent for this app), and remains the floor above
// "none -> window". When a signal DOES exist, the worker instead answers it with the
// precise targeted read (WpnTargetedRead), which reuses this section's helpers
// (kWpnSelectSql, WpnOpen, WpnFirstTextW, ...). Since the 2026-09-05 proxy refactor all
// of it runs ONLY on the off-thread shadow worker (never the poll thread), and its retry
// pacing is event-driven when the WAL file-watch is armed. Nothing else in this section
// changed semantics.
// DESIGN-toast-bridge.md Phase 3 / 3.4.1. Everything in this section OBSERVES and LOGS;
// none of it may influence which toasts banner or forward - the A0 routing stays
// byte-for-byte unchanged (ShadowClassify is called before the unchanged skip/forward
// decision, writes bridge.log, and swallows every exception so it cannot even feed the poll
// loop's failStreak). Fail-open at every step, mirroring what Phase-3 ROUTING would do:
// no winsqlite3, unreadable DB, schema mismatch, WAL contention, correlation ambiguity,
// undecodable/unparseable payload => shadow verdict "window".
//
// Data source (design 3.2): %LocalAppData%\Microsoft\Windows\Notifications\wpndatabase.db,
// read-only, via the IN-BOX System32 winsqlite3.dll (ships since Win10 1803), loaded
// dynamically - zero new dependencies, matching the build rule at the top of this file.
// Expected forensics-documented shape (the schema gate is preparing kWpnSelectSql - any
// missing table/column fails the prepare):
//   Notification(Id, HandlerId, Type, Payload, Tag, "Group", ArrivalTime, ...)
//     JOIN NotificationHandler(RecordId, PrimaryId /*AUMID*/, ...) ON HandlerId = RecordId
// ArrivalTime is a UTC FILETIME int64; Payload holds the full toast XML - the only
// cross-app source of <actions>/<input>/activationType (the listener cannot see them).

struct sqlite3;
struct sqlite3_stmt;
#define WPN_SQLITE_OK            0
#define WPN_SQLITE_ROW           100
#define WPN_SQLITE_DONE          101
#define WPN_SQLITE_OPEN_READONLY 0x00000001
#define WPN_SQLITE_TRANSIENT     ((void(__cdecl*)(void*))(intptr_t)-1)

struct WpnSql
{
    HMODULE dll;
    int (__cdecl* open_v2)(const char*, sqlite3**, int, const char*);
    int (__cdecl* close_v2)(sqlite3*);
    int (__cdecl* prepare_v2)(sqlite3*, const char*, int, sqlite3_stmt**, const char**);
    int (__cdecl* step)(sqlite3_stmt*);
    int (__cdecl* finalize)(sqlite3_stmt*);
    int (__cdecl* bind_text)(sqlite3_stmt*, int, const char*, int, void(__cdecl*)(void*));
    int (__cdecl* bind_int64)(sqlite3_stmt*, int, long long);
    const void* (__cdecl* column_blob)(sqlite3_stmt*, int);
    int (__cdecl* column_bytes)(sqlite3_stmt*, int);
    long long (__cdecl* column_int64)(sqlite3_stmt*, int);
    const char* (__cdecl* errmsg)(sqlite3*);
    int (__cdecl* busy_timeout)(sqlite3*, int);
};

// Bind the sqlite subset once. System32-only load path (LOAD_LIBRARY_SEARCH_SYSTEM32) so a
// planted winsqlite3.dll next to the exe can never be picked up. NULL = no DLL / missing
// export -> every caller fails open.
static WpnSql* WpnSqlGet()
{
    static WpnSql s = {};
    static bool tried = false;
    if (tried) return s.dll ? &s : nullptr;
    tried = true;
    s.dll = LoadLibraryExW(L"winsqlite3.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32);
    if (!s.dll) return nullptr;
#define WPNSQL_BIND(f) s.f = (decltype(s.f))(void*)GetProcAddress(s.dll, "sqlite3_" #f)
    WPNSQL_BIND(open_v2); WPNSQL_BIND(close_v2); WPNSQL_BIND(prepare_v2); WPNSQL_BIND(step);
    WPNSQL_BIND(finalize); WPNSQL_BIND(bind_text); WPNSQL_BIND(bind_int64);
    WPNSQL_BIND(column_blob); WPNSQL_BIND(column_bytes); WPNSQL_BIND(column_int64);
    WPNSQL_BIND(errmsg); WPNSQL_BIND(busy_timeout);
#undef WPNSQL_BIND
    if (!(s.open_v2 && s.close_v2 && s.prepare_v2 && s.step && s.finalize && s.bind_text &&
          s.bind_int64 && s.column_blob && s.column_bytes && s.column_int64 && s.errmsg &&
          s.busy_timeout))
    { FreeLibrary(s.dll); s.dll = nullptr; return nullptr; }
    return &s;
}

// Every column Phase 3 relies on, in one SELECT - preparing it IS the schema gate.
static const char* const kWpnSelectSql =
    "SELECT n.Id, h.PrimaryId, n.ArrivalTime, n.Tag, n.\"Group\", n.Payload, n.Type "
    "FROM Notification n JOIN NotificationHandler h ON n.HandlerId = h.RecordId ";

static std::wstring WpnDbPath()
{
    wchar_t la[MAX_PATH] = { 0 };
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", la, RTL_NUMBER_OF(la))) return L"";
    return std::wstring(la) + L"\\Microsoft\\Windows\\Notifications\\wpndatabase.db";
}

// Read-only open + short busy timeout: ShellExperienceHost holds the DB in WAL mode, so a
// locked moment must stall us briefly (250 ms), never wedge the poll thread.
static sqlite3* WpnOpen(WpnSql* q, std::string* err)
{
    std::wstring p = WpnDbPath();
    if (p.empty()) { if (err) *err = "no LOCALAPPDATA"; return nullptr; }
    sqlite3* db = nullptr;
    if (q->open_v2(Utf8(p).c_str(), &db, WPN_SQLITE_OPEN_READONLY, nullptr) != WPN_SQLITE_OK)
    {
        if (err) *err = (db && q->errmsg(db)) ? q->errmsg(db) : "open failed";
        if (db) q->close_v2(db);
        return nullptr;
    }
    q->busy_timeout(db, 250);
    return db;
}

static std::string WpnColStr(WpnSql* q, sqlite3_stmt* st, int col)
{
    const void* b = q->column_blob(st, col);
    int n = b ? q->column_bytes(st, col) : 0;
    return n > 0 ? std::string((const char*)b, (size_t)n) : std::string();
}

// Payload bytes -> wide, for the correlation text match only (UTF-8 default, BOMs honored).
// toastclassify.h has its own strict decoder for the VERDICT; a miss here merely downgrades
// corr to text-mismatch, which routes fail-open anyway.
static std::wstring WpnPayloadToW(std::string const& b)
{
    if (b.size() >= 2 && (unsigned char)b[0] == 0xFF && (unsigned char)b[1] == 0xFE)
    {
        std::wstring w((b.size() - 2) / 2, 0);
        if (!w.empty()) memcpy(&w[0], b.data() + 2, w.size() * sizeof(wchar_t));
        return w;
    }
    size_t off = (b.size() >= 3 && (unsigned char)b[0] == 0xEF &&
                  (unsigned char)b[1] == 0xBB && (unsigned char)b[2] == 0xBF) ? 3 : 0;
    int wn = MultiByteToWideChar(CP_UTF8, 0, b.data() + off, (int)(b.size() - off), nullptr, 0);
    std::wstring w(wn > 0 ? (size_t)wn : 0, 0);
    if (wn > 0) MultiByteToWideChar(CP_UTF8, 0, b.data() + off, (int)(b.size() - off), &w[0], wn);
    return w;
}

static std::wstring WpnTrimW(std::wstring const& s)
{
    size_t b = s.find_first_not_of(L" \t\r\n");
    if (b == std::wstring::npos) return L"";
    size_t e = s.find_last_not_of(L" \t\r\n");
    return s.substr(b, e - b + 1);
}

static std::wstring WpnUnescapeW(std::wstring const& s)
{
    static const struct { const wchar_t* e; size_t n; wchar_t c; } T[] = {
        { L"&amp;", 5, L'&' }, { L"&lt;", 4, L'<' }, { L"&gt;", 4, L'>' },
        { L"&quot;", 6, L'"' }, { L"&apos;", 6, L'\'' },
    };
    std::wstring o; o.reserve(s.size());
    for (size_t i = 0; i < s.size(); )
    {
        bool hit = false;
        if (s[i] == L'&')
            for (auto const& t : T)
                if (s.compare(i, t.n, t.e) == 0) { o += t.c; i += t.n; hit = true; break; }
        if (!hit) o += s[i++];
    }
    return o;
}

// First <text> element's inner text - the payload-side equivalent of the listener's first
// GetTextElements entry. Lightweight scan (named entities only): a decode miss downgrades
// corr to text-mismatch, never a wrong "ok".
static std::wstring WpnFirstTextW(std::wstring const& x)
{
    size_t i = 0;
    while ((i = x.find(L"<text", i)) != std::wstring::npos)
    {
        size_t after = i + 5;
        if (after >= x.size()) return L"";
        wchar_t c = x[after];
        if (c != L' ' && c != L'\t' && c != L'\r' && c != L'\n' && c != L'/' && c != L'>')
        { i = after; continue; }                          // "<textbox..." etc: not <text>
        size_t gt = x.find(L'>', after);
        if (gt == std::wstring::npos) return L"";
        if (x[gt - 1] == L'/') { i = gt + 1; continue; }  // self-closed: no content
        size_t close = x.find(L"</text", gt + 1);
        if (close == std::wstring::npos) return L"";
        return WpnTrimW(WpnUnescapeW(x.substr(gt + 1, close - gt - 1)));
    }
    return L"";
}

struct WpnCorr
{
    const char* corr;     // ok|text-mismatch|ambiguous|notfound|schema-mismatch|
                          // no-winsqlite3|no-listener-key|db-fail (static strings)
    std::string payload;  // the correlated row's Payload bytes (only on ok/text-mismatch)
    DWORD latencyMs;      // listener event -> row in hand (or give-up), retries included
};

// Correlate one listener toast to its wpndatabase row: AUMID + ArrivalTime window + first
// <text> match (design 3.2 - the DB shares no key with the listener). Bounded WAL retry:
// a just-arrived row may still sit in the -wal, so up to kWpnAttempts attempts. Retry
// pacing is PUSH-FIRST: when walEvt (the ReadDirectoryChangesW watcher's "wpndatabase.db*
// just changed" event, see WalWatchThread) is supplied, each retry waits on IT with a
// bounded kWpnWalWaitMs timeout instead of sleeping blind; without a watcher it falls back
// to the blind kWpnRetrySleepMs sleep. Worst case ~1550 ms (3 opens at the 250 ms busy cap
// + 2 waits at 400 ms) - which since the 2026-09-05 refactor runs ONLY on the off-thread
// shadow worker, so it can no longer sum across a toast burst toward the supervisor's 15 s
// stale-heartbeat deadline (the AgentGone lesson above). ANY ambiguity biases to window:
// >1 text match, or >1 candidate row none of which text-matches.
static WpnCorr WpnCorrelate(std::wstring const& aumid, long long creationFt,
                            std::wstring const& title, HANDLE walEvt = nullptr)
{
    const int       kWpnAttempts = 3;
    const DWORD     kWpnRetrySleepMs = 150;
    const DWORD     kWpnWalWaitMs = 400;
    const long long kWpnWindowFt = 60LL * 10000000LL;     // +/- 60 s in FILETIME ticks
    ULONGLONG t0 = GetTickCount64();
    WpnCorr r{ "notfound", std::string(), 0 };
    auto done = [&](const char* c) { r.corr = c; r.latencyMs = (DWORD)(GetTickCount64() - t0); return r; };
    static int schemaState = 0;                           // 0 unknown, 1 ok, 2 mismatch (per process)
    if (schemaState == 2) return done("schema-mismatch");
    WpnSql* q = WpnSqlGet();
    if (!q) return done("no-winsqlite3");
    if (aumid.empty() || creationFt == 0) return done("no-listener-key");
    std::string aumid8 = Utf8(aumid);
    std::wstring want = WpnTrimW(title);
    std::string sql = std::string(kWpnSelectSql) +
        "WHERE h.PrimaryId = ?1 COLLATE NOCASE AND n.Type = 'toast' "
        "AND n.ArrivalTime BETWEEN ?2 AND ?3 ORDER BY n.ArrivalTime DESC LIMIT 16";
    for (int att = 0; att < kWpnAttempts; att++)
    {
        if (att)
        {
            // Event-driven when the WAL watcher is armed (the row we are waiting for lands
            // as a -wal append, which fires walEvt), bounded so a missed change can never
            // wedge the worker; blind sleep only when no watcher exists (fail-open pacing).
            if (walEvt) WaitForSingleObject(walEvt, kWpnWalWaitMs);
            else Sleep(kWpnRetrySleepMs);
        }
        std::string err;
        sqlite3* db = WpnOpen(q, &err);
        if (!db) { r.corr = "db-fail"; continue; }        // transient lock: retry, else report
        sqlite3_stmt* st = nullptr;
        if (q->prepare_v2(db, sql.c_str(), -1, &st, nullptr) != WPN_SQLITE_OK)
        {
            // Missing table/column: THE schema gate. Permanent for this process, loud once.
            BLog(L"WPNDB SCHEMA MISMATCH: %hs (shadow classifier disabled for this run, fail-open)",
                 q->errmsg(db));
            schemaState = 2;
            q->close_v2(db);
            return done("schema-mismatch");
        }
        schemaState = 1;
        q->bind_text(st, 1, aumid8.c_str(), -1, WPN_SQLITE_TRANSIENT);
        q->bind_int64(st, 2, creationFt - kWpnWindowFt);
        q->bind_int64(st, 3, creationFt + kWpnWindowFt);
        std::vector<std::string> rows;
        int rc;
        while ((rc = q->step(st)) == WPN_SQLITE_ROW && rows.size() < 16)
            rows.push_back(WpnColStr(q, st, 5));
        q->finalize(st);
        q->close_v2(db);
        if (rc != WPN_SQLITE_DONE && rc != WPN_SQLITE_ROW) { r.corr = "db-fail"; continue; }  // busy/IO: retry
        if (rows.empty()) { r.corr = "notfound"; continue; }                                  // -wal lag: retry
        std::vector<size_t> match;
        for (size_t i = 0; i < rows.size(); i++)
            if (!want.empty() && WpnFirstTextW(WpnPayloadToW(rows[i])) == want) match.push_back(i);
        if (match.size() == 1) { r.payload = rows[match[0]]; return done("ok"); }
        if (match.size() > 1) return done("ambiguous");
        if (rows.size() == 1) { r.payload = rows[0]; return done("text-mismatch"); }
        return done("ambiguous");
    }
    return done(r.corr);                                  // last failure class: db-fail or notfound
}

// Compact grep-safe signal token from the classifier's static reason, e.g.
// "row3:time-critical-scenario-reminder-alarm-incomingcall".
static std::wstring WpnSignalSlug(ToastClass const& k)
{
    std::wstring s = L"row" + std::to_wstring(k.row) + L":";
    bool dash = false;
    for (const wchar_t* p = k.reason; p && *p; p++)
    {
        wchar_t c = *p;
        if (c >= L'A' && c <= L'Z') c = (wchar_t)(c + 32);
        if ((c >= L'a' && c <= L'z') || (c >= L'0' && c <= L'9')) { s += c; dash = false; }
        else if (!dash && s.back() != L':') { s += L'-'; dash = true; }
    }
    while (!s.empty() && s.back() == L'-') s.pop_back();
    return s;
}

// ==================== P3-ETW: push acquisition tier (HYBRID ladder, MEASURE-ONLY) ========
// The Phase-3 acquisition LADDER (design 10.20 - the 2026-09-05 rig verdict: the 732-event
// broadcap over these exact provider GUIDs + mask proved the notification providers emit
// {AppUserModelId, notificationId, tag, group, timing} but NEVER the <toast> payload XML,
// so ETW is a SIGNAL and wpndatabase is the payload source). Per new toast, in order:
//   tier 1  ETW signal        - push: {AUMID, notificationId (string + numeric), tag,
//           + targeted read     group, event FILETIME} captured AT SOURCE by the
//                               LEAST-PRIVILEGE --etw-proxy process (separate token, below)
//                               and pushed over a one-way pipe into an in-memory ring here.
//                               EtwTierLookup is a non-blocking ring scan returning up to 4
//                               candidate SIGNALS (never a payload); the shadow worker then
//                               answers each with ONE TARGETED wpndatabase read - primary
//                               key n.Id = notificationId (cross-checked against the signal
//                               AUMID), fallback AUMID + tag/group + eventFt-anchored
//                               arrival window - and classifies the row's payload.
//   tier 2  WpnCorrelate      - the wpndatabase.db correlate above (bounded, WAL-watch-
//                               paced retry) when NO signal exists for the toast (tier
//                               down/off/silent) - the ETW-DOWN fallback, unchanged.
//   tier 3  none              - shadow verdict "window" (today's exact behaviour).
// Every rung degrades on ANY gap - proxy not running, pipe absent/closed, no wpndb row for
// a signal, id/AUMID mismatch, ambiguity - and a bridge verdict is only ever EARNED by a
// clean acquisition: corr in {id-ok, sig-unique} on tier 1, corr=ok on tier 2.
//
// PRIVILEGE SPLIT (the 2026-09-05 refactor): the ETW consumer + TDH decode parse
// attacker-influenceable event data (any same-session process can emit events under a
// user-mode provider GUID, and provider-emitted bytes are arbitrary). That code NO LONGER
// RUNS in --bridge. It lives ONLY in `notifhost --etw-proxy`, a separate PURE-CONSUMER
// process the agent launches under the dedicated bare qubes-etwproxy account (no groups,
// no privileges - consume is authorized solely by the agent's per-session DACL grant;
// NEVER SYSTEM, never admin, never the interactive user; see DESIGN-p3-classifier-impl.md
// secs 10.10-10.19). A parser bug there buys an attacker that no-network, non-admin token
// plus a WRITE-ONLY pipe - not SYSTEM, and not this session. The IPC is one-way BY
// CONSTRUCTION: the proxy is the pipe SERVER created PIPE_ACCESS_OUTBOUND (the kernel
// refuses client->server data on the server handle), DACL admitting ONLY the bridge
// user's SID, so a compromised user-session bridge cannot drive the proxy (there is no
// channel to drive), and a compromised proxy can only push forged records into a
// MEASURE-ONLY shadow classifier whose worst outcome is a fail-open "window" verdict.
//
// HEARTBEAT-SAFE by construction (the AgentGone/CreateToolhelp32Snapshot lesson, top of
// file: variable latency in the hot loop once pushed an iteration past the supervisor's
// 15 s deadline and got the live bridge TERMINATED). The poll thread's ONLY acquisition
// work is a fixed-cost enqueue to the shadow worker; the pipe read loop blocks its own
// thread, the DB reads (WpnTargetedRead / WpnCorrelate) block the worker, and
// EtwTierLookup is a critical-section-guarded
// deque scan (the IPC thread holds that lock for a push_back only, microseconds). No
// acquisition failure can feed failStreak/FATAL: every fault parks a tier in down/dead and
// the ladder falls through.
//
// MEASURE-ONLY: nothing in this section is reachable from the forward/skip routing; its
// only bridge-mode consumer is the shadow worker, which logs. Seen-to-fail hooks
// (autonomy rule 5), compile-time, test builds only:
//   P3AQ_DEFECT_HOTWAIT - acquisition back on the poll thread + a deliberate 1.5 s stall;
//                         the harness's heartbeat-cadence detector must then FAIL.
//   P3AQ_DEFECT_ROUTE   - acquisition state gates the A0 forward/skip routing; the
//                         routing-invariance detector must then FAIL.

#if defined(P3AQ_DEFECT_HOTWAIT) && defined(P3AQ_DEFECT_ROUTE)
#error define at most one P3AQ_DEFECT_* switch
#endif

#define ETW_STATE_OFF      0   // never armed (non-bridge modes)
#define ETW_STATE_STARTING 1
#define ETW_STATE_LIVE     2   // proxy pipe connected, records flowing into the ring
#define ETW_STATE_DOWN     3   // pipe absent/closed; IPC thread reconnect pending
#define ETW_STATE_DEAD     4   // permanent for this run (thread create failed / threw / stop)

// RAII critical-section guard (review must-fix): LeaveCriticalSection on EVERY exit path,
// including a throw between an Enter and its Leave - the previous bare pair in the event
// callback leaked the lock if push_back threw, deadlocking the next ring lookup forever.
// EVERY g_etw/g_px/g_shadow lock take in this file goes through this guard.
struct CsGuard
{
    CRITICAL_SECTION* cs;
    explicit CsGuard(CRITICAL_SECTION* c) : cs(c) { EnterCriticalSection(cs); }
    ~CsGuard() { LeaveCriticalSection(cs); }
    CsGuard(CsGuard const&) = delete;
    CsGuard& operator=(CsGuard const&) = delete;
};

// One-way wire protocol, proxy -> bridge, over a byte pipe. 'QTS1' SIGNAL frame (design
// 10.20.1; replaces the 'QTE1' payload frame - the payload field is DELETED because the
// payload is not in ETW on Win10, proven by the 732-event broadcap). One frame per
// AUMID-bearing event, little-endian, every length bound-checked on receive:
//   off  0  u32 magic 'QTS1'
//        4  u32 aumidBytes    (UTF-16LE, <= 1024; 0 allowed only when notifIdNum != 0)
//        8  u32 notifIdBytes  (UTF-16LE raw string form, <= 64; may be 0)
//       12  u32 tagBytes      (UTF-16LE, <= 256; may be 0)
//       16  u32 groupBytes    (UTF-16LE, <= 256; may be 0)
//       20  u64 notifIdNum    (the notificationId as an integer when its TDH intype was
//                              integral or the string is all-decimal; 0 = no id join)
//       28  u64 eventFiletime (EVENT_RECORD FILETIME)
//       36  aumid | notifId | tag | group bytes, in that order
#define ETW_WIRE_MAGIC        0x31535451u          // 'Q','T','S','1' read LE
#define ETW_WIRE_HDR_BYTES    36u
#define ETW_MAX_AUMID_BYTES   1024u
#define ETW_MAX_NOTIF_BYTES   64u
#define ETW_MAX_TAG_BYTES     256u
#define ETW_MAX_GROUP_BYTES   256u
#define ETW_MAX_FRAME_BYTES   2048u                // total frame cap (down from 64 KB: no payload)
static const wchar_t* const kEtwProxyPipe = L"\\\\.\\pipe\\qubes-toast-etw";

struct EtwToastRec                          // one SIGNAL (design 10.20.1) - never a payload
{
    std::wstring aumid, notifId, tag, group;   // whatever the event actually carried
    uint64_t notifIdNum;                    // 0 = "does not join by id"
    long long eventFt;                      // EVENT_RECORD FILETIME (no RAW_TIMESTAMP mode)
    ULONGLONG tick;                         // receipt tick, for pruning
};

static struct
{
    bool armed = false;                     // EtwTierStart ran (bridge mode only)
    volatile LONG state = ETW_STATE_OFF;
    HANDLE thread = nullptr, stopEvt = nullptr;   // the IPC client thread
    CRITICAL_SECTION lock;                  // guards ring (valid once armed); CsGuard only
    std::deque<EtwToastRec> ring;           // newest at back; capped 64 entries / 120 s /
                                            // per-field byte caps (checked on receive)
    volatile LONG recTotal = 0, recBad = 0; // IPC records accepted / rejected
} g_etw;

static const wchar_t* const kEtwBridgeSession = L"QubesToastBridgeEtw";   // STARTED/OWNED by the
                                                                          // SYSTEM agent (shared
                                                                          // contract with
                                                                          // etwproxy.c
                                                                          // ETWPROXY_SESSION_NAME
                                                                          // - change both or
                                                                          // neither); --etw-proxy
                                                                          // only OpenTraceW's it
static const wchar_t* const kEtwDumpSession   = L"QubesToastEtwDump";     // owned by --dump-etw

// Candidate notification providers - since the 2026-09-05 broadcap, two are RIG-PROVEN
// signal sources on Win10 19045: {EB3540F2} Shell.NotificationController (29 AUMID hits)
// and {88CD9180} PushNotifications-Platform (5 hits) - they carry {AppUserModelId,
// notificationId, tag, group, timing}, NEVER the payload. hashName=true marks a
// TraceLogging provider whose GUID is derived from the name at runtime (the standard
// EventSource/TraceLogging name hash); if such a name is actually manifest-registered the
// hash yields a GUID nobody writes to = zero events, harmless. --dump-etw confirms per
// guest which carry the SIGNAL fields unprivileged; extend this table from its output,
// never from blog posts.
struct EtwProv { const wchar_t* name; GUID guid; bool hashName; };
static EtwProv g_etwProviders[] = {
    { L"Microsoft-Windows-PushNotifications-Platform",
      { 0x88CD9180, 0x4491, 0x4640, { 0xB5, 0x71, 0xE3, 0xBE, 0xE2, 0x52, 0x79, 0x43 } }, false },
    { L"Microsoft.Windows.Shell.NotificationController", {}, true },
    { L"Microsoft-Windows-Notifications",                {}, true },
    { L"Microsoft.Windows.Notifications.WpnCore",        {}, true },
    { L"Microsoft.Windows.Notifications.WpnApps",        {}, true },
};

// TraceLogging provider name -> GUID (the EventSource hash): SHA-1 over a fixed namespace
// GUID + the UPPERCASED provider name in UTF-16BE; the first 16 digest bytes are read the
// way .NET Guid(byte[]) reads them (Data1..Data3 little-endian) with the high nibble of
// digest byte 7 (Data3's high byte) forced to 5. SHA-1 via already-linked advapi32
// CryptoAPI - no new dependency.
static bool EtwNameToGuid(const wchar_t* name, GUID* out)
{
    static const BYTE ns[16] = { 0x48, 0x2C, 0x2D, 0xB2, 0xC3, 0x90, 0x47, 0xC8,
                                 0x87, 0xF8, 0x1A, 0x15, 0xBF, 0xC1, 0x30, 0xFB };
    std::vector<BYTE> data(ns, ns + 16);
    for (const wchar_t* p = name; *p; p++)
    {
        wchar_t c = *p;
        if (c >= L'a' && c <= L'z') c = (wchar_t)(c - 32);   // provider names are ASCII
        data.push_back((BYTE)(c >> 8));                      // UTF-16 BIG-endian
        data.push_back((BYTE)(c & 0xFF));
    }
    BYTE dig[20]; DWORD dl = sizeof(dig);
    HCRYPTPROV cp = 0; HCRYPTHASH h = 0; bool ok = false;
    if (CryptAcquireContextW(&cp, nullptr, nullptr, PROV_RSA_FULL, CRYPT_VERIFYCONTEXT))
    {
        if (CryptCreateHash(cp, CALG_SHA1, 0, 0, &h) &&
            CryptHashData(h, data.data(), (DWORD)data.size(), 0) &&
            CryptGetHashParam(h, HP_HASHVAL, dig, &dl, 0) && dl >= 16)
            ok = true;
        if (h) CryptDestroyHash(h);
        CryptReleaseContext(cp, 0);
    }
    if (!ok) return false;
    out->Data1 = (DWORD)dig[0] | ((DWORD)dig[1] << 8) | ((DWORD)dig[2] << 16) | ((DWORD)dig[3] << 24);
    out->Data2 = (USHORT)((USHORT)dig[4] | ((USHORT)dig[5] << 8));
    out->Data3 = (USHORT)((USHORT)dig[6] | ((USHORT)((dig[7] & 0x0F) | 0x50) << 8));
    memcpy(out->Data4, dig + 8, 8);
    return true;
}

static std::wstring GuidStr(GUID const& g)
{
    wchar_t b[48];
    swprintf(b, RTL_NUMBER_OF(b), L"{%08lX-%04hX-%04hX-%02X%02X-%02X%02X%02X%02X%02X%02X}",
             g.Data1, g.Data2, g.Data3, g.Data4[0], g.Data4[1], g.Data4[2], g.Data4[3],
             g.Data4[4], g.Data4[5], g.Data4[6], g.Data4[7]);
    return b;
}

static void EtwIso(long long ft, char* out /*>=40 chars*/)
{
    strcpy_s(out, 40, "?");
    FILETIME f;
    f.dwLowDateTime = (DWORD)((ULONGLONG)ft & 0xFFFFFFFFull);
    f.dwHighDateTime = (DWORD)((ULONGLONG)ft >> 32);
    SYSTEMTIME s;
    if (FileTimeToSystemTime(&f, &s))
        sprintf_s(out, 40, "%04u-%02u-%02uT%02u:%02u:%02u.%03uZ",
                  s.wYear, s.wMonth, s.wDay, s.wHour, s.wMinute, s.wSecond, s.wMilliseconds);
}

// Best-effort stop of a named session. A real-time session is KERNEL state that outlives a
// crashed process; a leftover would make StartTrace fail ERROR_ALREADY_EXISTS forever, so
// EtwSessionStart stops-by-name first, unconditionally (not-found is the normal case).
static void EtwSessionStop(const wchar_t* name)
{
    size_t cb = sizeof(EVENT_TRACE_PROPERTIES) + (wcslen(name) + 1) * sizeof(wchar_t);
    std::vector<BYTE> buf(cb, 0);
    EVENT_TRACE_PROPERTIES* p = (EVENT_TRACE_PROPERTIES*)buf.data();
    p->Wnode.BufferSize = (ULONG)cb;
    p->LoggerNameOffset = sizeof(EVENT_TRACE_PROPERTIES);
    ControlTraceW(0, name, p, EVENT_TRACE_CONTROL_STOP);
}

static ULONG EtwSessionStart(const wchar_t* name, TRACEHANDLE* out)
{
    size_t cb = sizeof(EVENT_TRACE_PROPERTIES) + (wcslen(name) + 1) * sizeof(wchar_t);
    std::vector<BYTE> buf(cb, 0);
    EVENT_TRACE_PROPERTIES* p = (EVENT_TRACE_PROPERTIES*)buf.data();
    p->Wnode.BufferSize = (ULONG)cb;
    p->Wnode.Flags = WNODE_FLAG_TRACED_GUID;
    p->Wnode.ClientContext = 1;            // QPC precision; the consumer still receives
                                           // FILETIME (no PROCESS_TRACE_MODE_RAW_TIMESTAMP)
    p->LogFileMode = EVENT_TRACE_REAL_TIME_MODE;
    p->BufferSize = 64;                    // KB/buffer - notification traffic is tiny
    // L2 FIX (design 10.20.4, the measured events=0): a real-time session delivers to
    // ProcessTrace on BUFFER FLUSH. With 64 KB buffers per CPU and ~200 B sparse
    // notification events, no buffer ever fills inside an observation window, so the
    // callback received NOTHING - while the file-mode logman capture of the SAME
    // GUIDs+mask got its 732 events because file sessions flush all buffers to the ETL
    // at stop. FlushTimer=1 forces a per-second flush => <= 1 s delivery. The agent-side
    // session start (etwproxy.c EtwCtlSessionStart) needs the SAME fix - change both.
    p->FlushTimer = 1;
    p->LoggerNameOffset = sizeof(EVENT_TRACE_PROPERTIES);
    EtwSessionStop(name);                  // reap a crashed prior run's leftover
    *out = 0;
    return StartTraceW(out, name, p);
}

// MatchAnyKeyword ~0 + TRACE_LEVEL_VERBOSE takes everything each provider offers
// (TraceLogging events often carry keyword 0, which a narrow mask would drop). Enabling a
// GUID nothing registers SUCCEEDS (events just never arrive), so a failure here is a hard
// ETW error, not "provider absent".
static int EtwEnableProviders(TRACEHANDLE session, int logMode)   // 0=BLog 1=stdout 2=both
{
    int enabled = 0;
    for (auto& pv : g_etwProviders)
    {
        GUID g = pv.guid;
        if (pv.hashName && !EtwNameToGuid(pv.name, &g))
        {
            if (logMode) printf("ETWPROV name=%ls guid=<hash-failed> enable=skip\n", pv.name);
            if (logMode != 1) BLog(L"ETW provider %s: name-hash failed - skipped", pv.name);
            continue;
        }
        ULONG rc = EnableTraceEx2(session, &g, EVENT_CONTROL_CODE_ENABLE_PROVIDER,
                                  TRACE_LEVEL_VERBOSE, ~0ULL, 0, 0, nullptr);
        // The per-provider EnableTraceEx2 RC line is the "is this token sufficient" datum
        // the rig gate greps for (Performance Log Users sufficiency, secs 10.16/10.18).
        if (logMode)
            printf("ETWPROV name=%ls guid=%ls src=%s enable=%lu\n", pv.name,
                   GuidStr(g).c_str(), pv.hashName ? "name-hash" : "manifest", rc);
        if (logMode != 1)
            BLog(L"ETW provider %s guid=%s enable=%lu", pv.name, GuidStr(g).c_str(), rc);
        if (rc == ERROR_SUCCESS) enabled++;
    }
    return enabled;
}

// Per-delivery buffer instrumentation (design 10.20.4 hardening): logs BuffersRead /
// EventsLost so "no events" is distinguishable as "no deliveries at all" (pacing/session
// problem) vs "deliveries with zero events" (provider silence). Rate-bounded: always on
// loss, else first 3 deliveries and every 100th. Both stdout (the --dump-etw / proxy
// console) and BLog. Returning TRUE continues ProcessTrace.
static volatile LONG g_etwBufCount = 0;
static ULONG WINAPI EtwBufferCb(PEVENT_TRACE_LOGFILEW lf)
{
    LONG n = InterlockedIncrement(&g_etwBufCount);
    if (lf && (lf->EventsLost > 0 || n <= 3 || (n % 100) == 0))
    {
        printf("ETWBUF delivery=%ld buffers_read=%lu events_lost=%lu\n",
               n, lf->BuffersRead, lf->EventsLost);
        BLog(L"ETWBUF delivery=%ld buffers_read=%lu events_lost=%lu",
             n, lf->BuffersRead, lf->EventsLost);
    }
    return TRUE;
}

// The real-time consume setup (verified correct per design 10.20.4: LoggerName - not
// LogFileName - plus REAL_TIME|EVENT_RECORD and the record callback; the events=0 datum
// was delivery pacing, fixed by FlushTimer above, not this struct).
static TRACEHANDLE EtwOpen(const wchar_t* name, PEVENT_RECORD_CALLBACK cb)
{
    EVENT_TRACE_LOGFILEW lf = {};
    lf.LoggerName = const_cast<LPWSTR>(name);
    lf.ProcessTraceMode = PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD;
    lf.EventRecordCallback = cb;
    lf.BufferCallback = EtwBufferCb;
    return OpenTraceW(&lf);
}

// --- defensive TDH decode -----------------------------------------------------------------
// TraceLogging events are self-describing; TdhGetEventInformation handles both them and
// manifest events. We do NOT know which fields (if any) carry the payload - decode whatever
// is there into a name/value list, then harvest heuristically, and treat every failure as
// "this event carries nothing" (the ladder degrades; nothing throws past the callback).

struct EtwField { std::wstring name, value; };
struct EtwDecoded
{
    GUID provider; USHORT id; ULONG pid; long long ft;
    std::wstring eventName;
    std::vector<EtwField> fields;
    std::wstring aumid, payload, notifId;   // heuristic harvest (empty = not carried)
};

static std::wstring EtwTiString(TRACE_EVENT_INFO* ti, ULONG off)
{
    return off ? std::wstring((const wchar_t*)((BYTE*)ti + off)) : std::wstring();
}

static bool EtwDecode(EVENT_RECORD* er, EtwDecoded* out)
{
    out->provider = er->EventHeader.ProviderId;
    out->id = er->EventHeader.EventDescriptor.Id;
    out->pid = er->EventHeader.ProcessId;
    out->ft = er->EventHeader.TimeStamp.QuadPart;    // FILETIME: no RAW_TIMESTAMP mode set
    ULONG sz = 0;
    ULONG rc = TdhGetEventInformation(er, 0, nullptr, nullptr, &sz);
    if (rc != ERROR_INSUFFICIENT_BUFFER || sz == 0 || sz > 1024 * 1024)
        return false;                                // WPP/undecodable/absurd: skip
    std::vector<BYTE> buf(sz);
    TRACE_EVENT_INFO* ti = (TRACE_EVENT_INFO*)buf.data();
    if (TdhGetEventInformation(er, 0, nullptr, ti, &sz) != ERROR_SUCCESS) return false;
    // TraceLogging carries the event name in EventNameOffset (a union member that is only
    // meaningful for DecodingSourceTlg); manifest events use Task/Opcode names.
    if ((int)ti->DecodingSource == 3 /*DecodingSourceTlg*/ && ti->EventNameOffset)
        out->eventName = EtwTiString(ti, ti->EventNameOffset);
    if (out->eventName.empty()) out->eventName = EtwTiString(ti, ti->TaskNameOffset);
    if (out->eventName.empty()) out->eventName = EtwTiString(ti, ti->OpcodeNameOffset);

    ULONG pointerSize = (er->EventHeader.Flags & EVENT_HEADER_FLAG_32_BIT_HEADER) ? 4 : 8;
    ULONG nProps = ti->TopLevelPropertyCount;
    if (nProps > 64) nProps = 64;                    // adversarial bound
    for (ULONG i = 0; i < nProps; i++)
    {
        EVENT_PROPERTY_INFO const& epi = ti->EventPropertyInfoArray[i];
        EtwField f;
        f.name = EtwTiString(ti, epi.NameOffset);
        f.value = L"<undecoded>";
        if (epi.Flags & (PropertyStruct | PropertyParamCount))
            f.value = L"<struct-or-array:skipped>";
        else
        {
            PROPERTY_DATA_DESCRIPTOR pdd = {};
            pdd.PropertyName = (ULONGLONG)((BYTE*)ti + epi.NameOffset);
            pdd.ArrayIndex = (ULONG)-1;
            ULONG psz = 0;
            ULONG src = TdhGetPropertySize(er, 0, nullptr, 1, &pdd, &psz);
            if (src == ERROR_SUCCESS && psz == 0)
                f.value = L"";
            else if (src == ERROR_SUCCESS && psz <= 0xFFFF)
            {
                std::vector<BYTE> raw(psz);
                if (TdhGetProperty(er, 0, nullptr, 1, &pdd, psz, raw.data()) == ERROR_SUCCESS)
                {
                    USHORT propLen = (epi.Flags & PropertyParamLength) ? 0 : epi.length;
                    ULONG need = 0; USHORT used = 0;
                    ULONG frc = TdhFormatProperty(ti, nullptr, pointerSize,
                        epi.nonStructType.InType, epi.nonStructType.OutType,
                        propLen, (USHORT)psz, raw.data(), &need, nullptr, &used);
                    if (frc == ERROR_INSUFFICIENT_BUFFER && need > 0 && need < 4 * 1024 * 1024)
                    {
                        std::vector<wchar_t> fb(need / sizeof(wchar_t) + 2, 0);
                        need = (ULONG)((fb.size() - 1) * sizeof(wchar_t));
                        if (TdhFormatProperty(ti, nullptr, pointerSize,
                                epi.nonStructType.InType, epi.nonStructType.OutType,
                                propLen, (USHORT)psz, raw.data(), &need, fb.data(), &used)
                            == ERROR_SUCCESS)
                            f.value = fb.data();
                    }
                    if (f.value == L"<undecoded>")   // TDH could not render: bounded hex
                    {
                        std::wstring hx = L"hex:";
                        for (ULONG k = 0; k < psz && k < 48; k++)
                        { wchar_t d[4]; swprintf(d, RTL_NUMBER_OF(d), L"%02X", raw[k]); hx += d; }
                        if (psz > 48) hx += L"...";
                        f.value = hx;
                    }
                }
            }
        }
        out->fields.push_back(std::move(f));
    }
    return true;
}

static std::wstring EtwLower(std::wstring s)
{
    for (auto& c : s) if (c >= L'A' && c <= L'Z') c = (wchar_t)(c + 32);
    return s;
}

// Field-map heuristics: which decoded fields look like {AUMID, payload XML, notification
// id}. Deliberately liberal on the payload (a value that IS toast XML counts whatever its
// field is called) and conservative on the AUMID (must be a markup-free string under an
// aumid-ish name) - a wrong harvest can at most cause an ETW miss/text-mismatch, which
// degrades to the DB rung, never a wrong bridge verdict (the classifier + title match still
// gate that).
static void EtwHarvest(EtwDecoded* d)
{
    for (auto const& fld : d->fields)
    {
        std::wstring n = EtwLower(fld.name);
        std::wstring v = WpnTrimW(fld.value);
        if (d->payload.empty())
        {
            if (_wcsnicmp(v.c_str(), L"<toast", 6) == 0) d->payload = v;
            else if ((n.find(L"payload") != std::wstring::npos ||
                      n.find(L"xml") != std::wstring::npos) &&
                     v.find(L"<toast") != std::wstring::npos) d->payload = v;
        }
        if (d->aumid.empty() && !v.empty() && v.size() < 512 &&
            v.find(L'<') == std::wstring::npos &&
            (n.find(L"aumid") != std::wstring::npos ||
             n.find(L"appusermodelid") != std::wstring::npos ||
             n.find(L"appid") != std::wstring::npos ||
             n.find(L"primaryid") != std::wstring::npos))
            d->aumid = v;
        if (d->notifId.empty() && v.size() < 64 &&
            (n.find(L"notificationid") != std::wstring::npos || n == L"id" ||
             n.find(L"trackingid") != std::wstring::npos))
            d->notifId = v;
    }
}

// --- the bridge-side IPC client (tier-1 feeder) -------------------------------------------
// The bridge runs NO ETW code. This thread connects READ-ONLY to the --etw-proxy pipe and
// mirrors its pushed frames into the ring; while the pipe is absent/closed the tier reads
// state=down and the ladder serves everything from the DB rung (fail-open). The frames come
// from a MORE-privileged process, but are validated as if hostile anyway (a squatter can
// own the pipe name first - it then gains exactly the forged-event power a same-session
// process already has, sec 10.8.1: worst case a fail-open "window" verdict). Pipe
// appearance has no push notification API, so reconnect is a bounded backoff - the one
// place a wait loop survives, capped at 60 s (the ConnUp precedent below).

static std::wstring EtwWireToW(std::vector<BYTE> const& b)   // UTF-16LE wire field, defensive
{
    if (b.size() < 2 || (b.size() & 1)) return L"";
    std::wstring w(b.size() / 2, 0);
    memcpy(&w[0], b.data(), b.size());
    while (!w.empty() && w.back() == 0) w.pop_back();
    return w;
}

static bool EtwIpcReadN(HANDLE pipe, void* buf, DWORD n)
{
    BYTE* p = (BYTE*)buf; DWORD done = 0;
    while (done < n)
    {
        DWORD got = 0;
        if (!ReadFile(pipe, p + done, n - done, &got, nullptr) || got == 0) return false;
        done += got;
    }
    return true;
}

// One 'QTS1' signal frame -> ring. FALSE = EOF or protocol violation (bad magic, a cap
// exceeded - a header desync): the caller drops the connection (a desynced byte stream
// cannot be re-synced safely; reconnect restarts clean). A well-framed record that merely
// carries nothing usable (no AUMID and no numeric id) is counted recBad and SKIPPED with
// the connection kept - it is not a desync.
static bool EtwIpcReadRecord(HANDLE pipe)
{
    BYTE hdr[ETW_WIRE_HDR_BYTES];
    if (!EtwIpcReadN(pipe, hdr, sizeof(hdr))) return false;
    if (GetU32(hdr) != ETW_WIRE_MAGIC) return false;
    uint32_t na = GetU32(hdr + 4), nn = GetU32(hdr + 8);
    uint32_t nt = GetU32(hdr + 12), ng = GetU32(hdr + 16);
    uint64_t idn = GetU64(hdr + 20);
    long long ft = (long long)GetU64(hdr + 28);
    if (na > ETW_MAX_AUMID_BYTES || nn > ETW_MAX_NOTIF_BYTES ||
        nt > ETW_MAX_TAG_BYTES || ng > ETW_MAX_GROUP_BYTES ||
        (ULONGLONG)ETW_WIRE_HDR_BYTES + na + nn + nt + ng > ETW_MAX_FRAME_BYTES)
    { InterlockedIncrement(&g_etw.recBad); return false; }   // byte caps: treat as desync
    std::vector<BYTE> aumid(na), notif(nn), tag(nt), group(ng);
    if ((na && !EtwIpcReadN(pipe, aumid.data(), na)) ||
        (nn && !EtwIpcReadN(pipe, notif.data(), nn)) ||
        (nt && !EtwIpcReadN(pipe, tag.data(), nt)) ||
        (ng && !EtwIpcReadN(pipe, group.data(), ng))) return false;
    std::wstring la = EtwWireToW(aumid), ln = EtwWireToW(notif);
    std::wstring lt = EtwWireToW(tag), lg = EtwWireToW(group);
    if (la.empty() && idn == 0)                               // joins by neither aumid nor id
    { InterlockedIncrement(&g_etw.recBad); return true; }     // skip, keep conn
    LONG n = InterlockedIncrement(&g_etw.recTotal);
    {
        CsGuard g(&g_etw.lock);              // RAII: no lock leak if push_back throws (must-fix)
        g_etw.ring.push_back({ la, ln, lt, lg, idn, ft, GetTickCount64() });
        while (g_etw.ring.size() > 64) g_etw.ring.pop_front();
    }
    if (n <= 50 || (n % 20) == 0)            // human-rate log even if the proxy goes chatty
        BLog(L"ETW SIG #%ld aumid=%s idnum=%llu notif=%s tag=%s group=%s", n,
             la.empty() ? L"-" : la.c_str(), (ULONGLONG)idn,
             ln.empty() ? L"-" : ln.c_str(), lt.empty() ? L"-" : lt.c_str(),
             lg.empty() ? L"-" : lg.c_str());
    return true;
}

static DWORD WINAPI EtwIpcThread(LPVOID)
{
    try
    {
        static const DWORD bo[] = { 2000, 5000, 15000, 60000 };   // bounded reconnect backoff
        int idx = 0;
        bool loggedDown = false;
        for (;;)
        {
            if (WaitForSingleObject(g_etw.stopEvt, 0) == WAIT_OBJECT_0) return 0;
            HANDLE pipe = CreateFileW(kEtwProxyPipe, GENERIC_READ, 0, nullptr,
                                      OPEN_EXISTING, 0, nullptr);
            if (pipe == INVALID_HANDLE_VALUE)
            {
                InterlockedExchange(&g_etw.state, ETW_STATE_DOWN);
                if (!loggedDown)   // once per outage, not once per attempt
                {
                    BLog(L"ETW IPC proxy pipe absent (%lu) - tier down, DB fallback (reconnect pending)",
                         GetLastError());
                    loggedDown = true;
                }
                if (WaitForSingleObject(g_etw.stopEvt, bo[idx < 3 ? idx : 3]) == WAIT_OBJECT_0)
                    return 0;
                idx++;
                continue;
            }
            idx = 0; loggedDown = false;
            ULONG spid = 0;
            GetNamedPipeServerProcessId(pipe, &spid);
            InterlockedExchange(&g_etw.state, ETW_STATE_LIVE);
            BLog(L"ETW IPC connected server_pid=%lu - push tier armed", spid);
            while (EtwIpcReadRecord(pipe))
                if (WaitForSingleObject(g_etw.stopEvt, 0) == WAIT_OBJECT_0) break;
            CloseHandle(pipe);
            if (WaitForSingleObject(g_etw.stopEvt, 0) == WAIT_OBJECT_0) return 0;
            InterlockedExchange(&g_etw.state, ETW_STATE_DOWN);
            BLog(L"ETW IPC disconnected (recs=%ld bad=%ld) - tier down, DB fallback, reconnecting",
                 g_etw.recTotal, g_etw.recBad);
        }
    }
    catch (...)
    {
        InterlockedExchange(&g_etw.state, ETW_STATE_DEAD);
        BLog(L"ETW IPC thread threw - tier disabled for this run, DB fallback");
    }
    return 0;
}

// Spawns the IPC client thread and returns immediately - the poll loop never waits on the
// acquisition tier. NO ETW session is created here or anywhere else in --bridge.
static void EtwTierStart()
{
    InitializeCriticalSection(&g_etw.lock);
    g_etw.stopEvt = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!g_etw.stopEvt) { InterlockedExchange(&g_etw.state, ETW_STATE_DEAD); return; }
    g_etw.armed = true;
    InterlockedExchange(&g_etw.state, ETW_STATE_DOWN);   // down until the proxy pipe answers
    g_etw.thread = CreateThread(nullptr, 0, EtwIpcThread, nullptr, 0, nullptr);
    if (!g_etw.thread)
    {
        InterlockedExchange(&g_etw.state, ETW_STATE_DEAD);
        BLog(L"ETW IPC thread create failed %lu - tier disabled, DB fallback", GetLastError());
    }
}

static void EtwTierStop()
{
    if (!g_etw.armed) return;
    SetEvent(g_etw.stopEvt);
    if (g_etw.thread)
    {
        CancelSynchronousIo(g_etw.thread);         // unblock a parked pipe ReadFile
        WaitForSingleObject(g_etw.thread, 3000);   // bounded: a wedged read never wedges exit
        CloseHandle(g_etw.thread);
        g_etw.thread = nullptr;
    }
    InterlockedExchange(&g_etw.state, ETW_STATE_DEAD);
}

// Rung 1 (called from the shadow worker; safe from any thread): NON-BLOCKING ring scan
// returning up to 4 candidate SIGNALS - never a payload (design 10.20.2). A candidate is
// a ring entry with AUMID equality (case-insensitive, as the allowlist matches) inside a
// +/-60 s FILETIME window against the listener CreationTime (when both timestamps exist).
// Newest first; duplicate signals (a re-emitted event: same id/notifId/tag/group) are
// collapsed. The payload acquisition happens AFTER this, on the shadow worker, as ONE
// targeted wpndatabase read per candidate (WpnTargetedRead below). Returns:
//   "sig-hit"   >=1 candidate signal out - the worker runs the targeted read
//   "sig-none"  tier live but no signal for this toast (provider silent for this app,
//               listener AUMID empty, or outside the time window) - DB rung serves
//   "down"      tier armed but not live (proxy absent / pipe closed / thread dead)
//   "off"       never armed (non-bridge modes)
// ETW is push: by the time the listener notices a toast, its event was delivered long ago -
// so there is deliberately NO wait here. Waiting would reintroduce exactly the variable
// latency class this tier exists to remove (the AgentGone lesson).
static const char* EtwTierLookup(std::wstring const& aumid, long long creationFt,
                                 std::vector<EtwToastRec>* out)
{
    const long long kEtwFtWindow = 60LL * 10000000LL;   // +/- 60 s in FILETIME ticks
    if (!g_etw.armed) return "off";
    if (g_etw.state != ETW_STATE_LIVE) return "down";
    if (aumid.empty()) return "sig-none";
    ULONGLONG now = GetTickCount64();
    {
        CsGuard g(&g_etw.lock);                          // RAII (review must-fix)
        while (!g_etw.ring.empty() && now - g_etw.ring.front().tick > 120000)
            g_etw.ring.pop_front();
        for (auto it = g_etw.ring.rbegin(); it != g_etw.ring.rend() && out->size() < 4; ++it)
        {
            if (it->aumid.empty() || _wcsicmp(it->aumid.c_str(), aumid.c_str()) != 0) continue;
            if (creationFt && it->eventFt &&
                (it->eventFt - creationFt > kEtwFtWindow || creationFt - it->eventFt > kEtwFtWindow))
                continue;
            bool dup = false;                            // re-emitted event: same identity
            for (auto const& c : *out)
                if (c.notifIdNum == it->notifIdNum && c.notifId == it->notifId &&
                    c.tag == it->tag && c.group == it->group) { dup = true; break; }
            if (!dup) out->push_back(*it);
        }
    }
    return out->empty() ? "sig-none" : "sig-hit";
}

// The tier-1 payload acquisition (design 10.20.2): ONE targeted wpndatabase read per
// candidate signal, on the SHADOW WORKER only (never the poll thread - heartbeat rule).
// PRIMARY id join (plausible-not-proven until the rig confirms per 10.20.5: the ETW
// notificationId is numeric and wpndb Notification.Id is the integer PK that --dump-wpndb
// prints as `ROW id=`): WHERE n.Id = notifIdNum AND n.Type='toast'. The returned row is
// cross-checked h.PrimaryId == the listener AUMID (NOCASE) - never trust a row the id
// reached but the app does not own - and first-<text> vs the listener title as an
// ADVISORY check: a text mismatch logs and falls through to the signal fallback rather
// than earning corr=id-ok. FALLBACK (id absent/no row after retries/mismatch): AUMID
// (NOCASE) + Type='toast' + ArrivalTime in eventFt +/- 60 s, narrowed by Tag/"Group" when
// the signal carried them, LIMIT 16 - exactly one row => sig-unique; several => the
// existing first-<text>-vs-title disambiguation; still >1 => sig-ambiguous => WINDOW,
// never guess. RACE: the ETW event fires at emission while WNS commits the row
// asynchronously, so ZERO rows on attempt 1 is the EXPECTED case - served by the bounded
// WAL-watch retry (3 attempts, walEvt-paced, worst ~1.5 s, worker thread only). For an
// id-bearing signal the fallback query runs only on the FINAL attempt: while the row is
// still uncommitted, an arrival-window query could match an OLDER same-app row and a
// lone stale row would read as sig-unique - the id path must exhaust its retries first.
// corr out: id-ok | id-aumid-mismatch | id-norow | sig-unique | sig-ambiguous |
// sig-norow | db-fail (payload only on id-ok / sig-unique; everything else fails open).
struct WpnTarget
{
    const char* corr;
    std::string payload;   // only on id-ok / sig-unique
    DWORD latencyMs;
};

static WpnTarget WpnTargetedRead(std::vector<EtwToastRec> const& sigs,
                                 std::wstring const& aumid, std::wstring const& title,
                                 HANDLE walEvt)
{
    const int   kAttempts = 3;
    const DWORD kRetrySleepMs = 150, kWalWaitMs = 400;
    const long long kFtWindow = 60LL * 10000000LL;        // +/- 60 s in FILETIME ticks
    ULONGLONG t0 = GetTickCount64();
    WpnTarget r{ "sig-norow", std::string(), 0 };
    auto done = [&](const char* c) { r.corr = c; r.latencyMs = (DWORD)(GetTickCount64() - t0); return r; };
    WpnSql* q = WpnSqlGet();
    if (!q) return done("db-fail");
    std::string aumid8 = Utf8(aumid);
    std::wstring want = WpnTrimW(title);
    bool anyId = false, sawMismatch = false, sawIdNoRow = false, sawDbFail = false;
    for (auto const& s : sigs) if (s.notifIdNum) anyId = true;
    for (int att = 0; att < kAttempts; att++)
    {
        if (att)
        {
            if (walEvt) WaitForSingleObject(walEvt, kWalWaitMs);   // WAL-append paced, bounded
            else Sleep(kRetrySleepMs);
        }
        std::string err;
        sqlite3* db = WpnOpen(q, &err);
        if (!db) { sawDbFail = true; continue; }          // transient lock: retry
        bool lastAtt = (att == kAttempts - 1);
        for (auto const& s : sigs)                        // newest first (ring scan order)
        {
            bool tryFallback = (s.notifIdNum == 0);       // id-less: fallback every attempt
            if (s.notifIdNum)
            {
                std::string sql = std::string(kWpnSelectSql) +
                    "WHERE n.Id = ?1 AND n.Type = 'toast'";
                sqlite3_stmt* st = nullptr;
                if (q->prepare_v2(db, sql.c_str(), -1, &st, nullptr) != WPN_SQLITE_OK)
                {
                    BLog(L"WPNDB SCHEMA MISMATCH (targeted): %hs - fail-open", q->errmsg(db));
                    q->close_v2(db);
                    return done("db-fail");
                }
                q->bind_int64(st, 1, (long long)s.notifIdNum);
                int rc = q->step(st);
                if (rc == WPN_SQLITE_ROW)
                {
                    std::string rowAumid = WpnColStr(q, st, 1);
                    std::string rowPayload = WpnColStr(q, st, 5);
                    q->finalize(st);
                    if (_stricmp(rowAumid.c_str(), aumid8.c_str()) != 0)
                    {
                        // never trust a row the id reached but the app doesn't own
                        sawMismatch = true;
                        tryFallback = true;               // row committed: race is over
                    }
                    else
                    {
                        // advisory text check: mismatch logs + falls through, never id-ok
                        if (!want.empty() &&
                            WpnFirstTextW(WpnPayloadToW(rowPayload)) != want)
                        {
                            BLog(L"WPNTGT id=%llu advisory text mismatch - falling to signal fallback",
                                 (ULONGLONG)s.notifIdNum);
                            tryFallback = true;
                        }
                        else
                        {
                            q->close_v2(db);
                            r.payload = std::move(rowPayload);
                            return done("id-ok");
                        }
                    }
                }
                else
                {
                    q->finalize(st);
                    if (rc != WPN_SQLITE_DONE) sawDbFail = true;   // busy/IO: retry
                    else { sawIdNoRow = true; tryFallback = lastAtt; }   // WAL race: retry id first
                }
            }
            if (!tryFallback) continue;
            // signal fallback: AUMID + eventFt-anchored window (+ tag/group when carried)
            std::string sql = std::string(kWpnSelectSql) +
                "WHERE h.PrimaryId = ?1 COLLATE NOCASE AND n.Type = 'toast' "
                "AND n.ArrivalTime BETWEEN ?2 AND ?3";
            int next = 4;
            int tagIdx = 0, grpIdx = 0;
            if (!s.tag.empty())   { tagIdx = next++; sql += " AND n.Tag = ?4"; }
            if (!s.group.empty())
            {
                grpIdx = next++;
                sql += (grpIdx == 4) ? " AND n.\"Group\" = ?4" : " AND n.\"Group\" = ?5";
            }
            sql += " ORDER BY n.ArrivalTime DESC LIMIT 16";
            sqlite3_stmt* st = nullptr;
            if (q->prepare_v2(db, sql.c_str(), -1, &st, nullptr) != WPN_SQLITE_OK)
            {
                BLog(L"WPNDB SCHEMA MISMATCH (targeted-fallback): %hs - fail-open", q->errmsg(db));
                q->close_v2(db);
                return done("db-fail");
            }
            q->bind_text(st, 1, aumid8.c_str(), -1, WPN_SQLITE_TRANSIENT);
            q->bind_int64(st, 2, s.eventFt - kFtWindow);
            q->bind_int64(st, 3, s.eventFt + kFtWindow);
            std::string tag8 = Utf8(s.tag), grp8 = Utf8(s.group);
            if (tagIdx) q->bind_text(st, tagIdx, tag8.c_str(), -1, WPN_SQLITE_TRANSIENT);
            if (grpIdx) q->bind_text(st, grpIdx, grp8.c_str(), -1, WPN_SQLITE_TRANSIENT);
            std::vector<std::string> rows;
            int rc;
            while ((rc = q->step(st)) == WPN_SQLITE_ROW && rows.size() < 16)
                rows.push_back(WpnColStr(q, st, 5));
            q->finalize(st);
            if (rc != WPN_SQLITE_DONE && rc != WPN_SQLITE_ROW) { sawDbFail = true; continue; }
            if (rows.size() == 1)
            {
                q->close_v2(db);
                r.payload = std::move(rows[0]);
                return done("sig-unique");
            }
            if (rows.size() > 1)
            {
                std::vector<size_t> match;
                for (size_t i = 0; i < rows.size(); i++)
                    if (!want.empty() && WpnFirstTextW(WpnPayloadToW(rows[i])) == want)
                        match.push_back(i);
                q->close_v2(db);
                if (match.size() == 1)
                {
                    r.payload = std::move(rows[match[0]]);
                    return done("sig-unique");
                }
                return done("sig-ambiguous");             // never guess -> window
            }
            // 0 rows: WAL race - next attempt retries
        }
        q->close_v2(db);
    }
    if (sawMismatch) return done("id-aumid-mismatch");
    if (sawIdNoRow) return done("id-norow");
    if (sawDbFail) return done("db-fail");
    return done(anyId ? "id-norow" : "sig-norow");
}

// --- --dump-etw: the rig's payload-availability instrument --------------------------------

static volatile LONG g_etwDumpEvents = 0, g_etwDumpPayload = 0, g_etwDumpAumid = 0;

static void CALLBACK EtwDumpEventCb(EVENT_RECORD* er)
{
    try
    {
        InterlockedIncrement(&g_etwDumpEvents);
        char iso[40];
        EtwIso(er->EventHeader.TimeStamp.QuadPart, iso);
        EtwDecoded d;
        if (!EtwDecode(er, &d))
        {
            printf("ETWEVT t=%s provider=%ls pid=%lu id=%u name=<undecodable> payload=0 aumid=0 fields=0\n",
                   iso, GuidStr(er->EventHeader.ProviderId).c_str(),
                   er->EventHeader.ProcessId, er->EventHeader.EventDescriptor.Id);
            return;
        }
        EtwHarvest(&d);
        if (!d.payload.empty()) InterlockedIncrement(&g_etwDumpPayload);
        if (!d.aumid.empty()) InterlockedIncrement(&g_etwDumpAumid);
        printf("ETWEVT t=%s provider=%ls pid=%lu id=%u name=%ls payload=%d aumid=%d fields=%u\n",
               iso, GuidStr(d.provider).c_str(), d.pid, d.id,
               d.eventName.empty() ? L"-" : d.eventName.c_str(),
               d.payload.empty() ? 0 : 1, d.aumid.empty() ? 0 : 1, (UINT)d.fields.size());
        for (auto const& fld : d.fields)
            printf("ETWFIELD %ls=%ls\n", fld.name.c_str(), fld.value.c_str());
    }
    catch (...) { printf("ETWEVT <callback threw>\n"); }
}

static DWORD WINAPI EtwDumpProcessThread(LPVOID p)
{
    TRACEHANDLE h = *(TRACEHANDLE*)p;
    // The rc IS the thread exit code: --etw-proxy reads it with GetExitCodeThread to tell
    // a consume denial (ERROR_ACCESS_DENIED -> its exit 5, the grant-insufficiency datum)
    // from a clean externally-ended trace. Discarding it here once let a denied consumer
    // masquerade as a clean exit 0.
    return ProcessTrace(&h, 1, nullptr, nullptr);
}

// Subscribe to every candidate provider, print each event's full decoded field map for N
// seconds, and summarize: did ANY event carry a toast payload / an AUMID? This output IS
// the rig gate's ETW-viability evidence (payload_events=0 => the ladder will live on the DB
// rung on this guest; exit 5 => not even a session is possible unprivileged).
static int DumpEtwMain(int seconds)
{
    if (seconds <= 0) seconds = 30;
    printf("ETWDUMP session=%ls seconds=%d\n", kEtwDumpSession, seconds);
    TRACEHANDLE sess = 0;
    ULONG rc = EtwSessionStart(kEtwDumpSession, &sess);
    if (rc == ERROR_ACCESS_DENIED)
    {
        printf("ETWDUMP FAIL access-denied: real-time session start needs Performance Log "
               "Users membership or elevation (this IS a gate datum: the bridge's user-"
               "session ETW tier would be down on this guest)\n");
        return 5;
    }
    if (rc != ERROR_SUCCESS) { printf("ETWDUMP FAIL StartTrace error %lu\n", rc); return 6; }
    int en = EtwEnableProviders(sess, 1);
    TRACEHANDLE cons = (en > 0) ? EtwOpen(kEtwDumpSession, EtwDumpEventCb)
                                : INVALID_PROCESSTRACE_HANDLE;
    if (cons == INVALID_PROCESSTRACE_HANDLE || cons == 0)
    {
        printf("ETWDUMP FAIL OpenTrace error %lu (enabled=%d)\n", GetLastError(), en);
        EtwSessionStop(kEtwDumpSession);
        return 7;
    }
    HANDLE t = CreateThread(nullptr, 0, EtwDumpProcessThread, &cons, 0, nullptr);
    if (!t)
    {
        printf("ETWDUMP FAIL consumer thread create %lu\n", GetLastError());
        CloseTrace(cons);
        EtwSessionStop(kEtwDumpSession);
        return 7;
    }
    printf("ETWDUMP listening... (fire toasts now, e.g. guest\\fire-demo-toast.ps1)\n");
    Sleep((DWORD)seconds * 1000);
    EtwSessionStop(kEtwDumpSession);       // ends the session; ProcessTrace returns
    WaitForSingleObject(t, 5000);
    // Surface ProcessTrace's rc (design 10.20.4 hardening): a silently-failing
    // ProcessTrace printed events=0 indistinguishable from provider silence - the very
    // ambiguity that let the Layer-2 consume bug masquerade as "no events on this guest".
    DWORD ptrc = (DWORD)-1;
    GetExitCodeThread(t, &ptrc);           // EtwDumpProcessThread returns ProcessTrace's rc
    CloseHandle(t);
    CloseTrace(cons);
    printf("ETWDUMP processtrace rc=%lu%s\n", ptrc,
           ptrc == STILL_ACTIVE ? " (thread still draining)" : "");
    printf("ETWDUMP done events=%ld payload_events=%ld aumid_events=%ld\n",
           g_etwDumpEvents, g_etwDumpPayload, g_etwDumpAumid);
    // HYBRID-era reading (design 10.20): the tier needs a SIGNAL, not a payload -
    // aumid_events>0 makes the signal + targeted-read tier viable; payload-bearing
    // events would exceed the proven Win10 behaviour (payload is NOT in ETW there).
    printf("ETWDUMP verdict: %s\n",
           g_etwDumpPayload > 0
           ? "payload XML observed (exceeds the Win10 broadcap finding) - signal tier viable"
           : (g_etwDumpAumid > 0
              ? "AUMID signals observed, no payload (the proven Win10 shape) - signal + targeted wpndb read viable"
              : "NO signal-bearing events - the ladder will serve this guest from the DB rung"));
    return 0;
}

// ==================== --etw-proxy: the least-privilege acquisition process ================
// ALL real-time ETW consumption and TDH parsing of attacker-influenceable event data for
// the bridge lives HERE, a PURE CONSUMER the SYSTEM agent launches under the dedicated
// bare qubes-etwproxy account - session control (StartTrace/EnableTraceEx2/stop) and the
// per-session EventAccessControl grant are AGENT-side, agent/gui-agent/etwproxy.c
// (two-context split; as-implemented record + deltas vs the design prose: secs
// 10.18/10.19). Threat model: a parser bug in TDH or this code hands
// the attacker THIS token - not admin, not SYSTEM, no user profile, no network role -
// plus a WRITE-ONLY pipe whose sole listener is a measure-only fail-open classifier.
// Structure:
//   * pipe SERVER, PIPE_ACCESS_OUTBOUND: the kernel refuses reads on the server handle -
//     one-way by construction, not by discipline. nMaxInstances=1 + FIRST_PIPE_INSTANCE;
//     DACL admits ONLY the --client-sid SID (the bridge user; the agent never connects).
//     Without --client-sid the DACL is empty = deny everyone, i.e. locked shut: the
//     bridge tier just reads down and the ladder serves the DB rung.
//   * NO input surface: no reads, no control channel, no stop file (a ProgramData stop
//     file would be a user-writable control into a differently-privileged process). It
//     stops when its ETW session is stopped externally, on console ctrl, or when the
//     agent terminates it.
//   * MINIMAL parsing: TdhGetEventInformation to locate properties BY NAME, raw property
//     bytes via TdhGetProperty - NAME-GATED to the four signal fields {AUMID,
//     notificationId, tag, group}, each markup-rejected and length-capped. No
//     TdhFormatProperty, no XML parse, and NO payload handling at all (design 10.20.1:
//     the payload is not in ETW on Win10 and is never materialized here; the defensive
//     payload parse stays in toastclassify.h on the bridge side, fed by its targeted
//     wpndatabase read).
// Exit codes (header comment at top of file): 0/5/7/8/9.

static struct
{
    CRITICAL_SECTION lock;                  // guards q; CsGuard only
    std::deque<std::vector<BYTE>> q;        // encoded wire frames; capped 64
    HANDLE evt = nullptr, stopEvt = nullptr, wrEvt = nullptr;
    volatile LONG captured = 0, dropped = 0, sent = 0;
} g_px;

struct PxRec
{
    std::wstring aumid, notifId, tag, group;   // the SIGNAL metadata - never a payload
    uint64_t notifIdNum = 0;                   // 0 = "does not join by id"
    long long ft = 0;
};

// The old PxLooksLikeToastXml payload SELECTOR, INVERTED into a REJECT (design 10.20.1):
// the rig proved the payload is never in ETW on Win10, so the proxy must not materialize
// payload bytes at all - any markup-bearing property value is skipped, never copied. A
// legitimate AUMID / notification id / tag / group never contains markup, so rejection
// can only fail open (missing field -> the bridge ladder degrades toward the DB rung).
static bool PxLooksLikeMarkup(std::wstring const& v)
{
    return v.find(L'<') != std::wstring::npos || v.find(L'>') != std::wstring::npos;
}

// "notificationId as an integer": PxRawToName renders integral intypes (psz 4/8) as
// decimal, so one all-decimal parse covers BOTH spec cases (integral intype, or a string
// that is all-decimal). Non-decimal / empty / oversized -> 0 = "does not join by id".
static uint64_t PxAllDecimalToU64(std::wstring const& v)
{
    if (v.empty() || v.size() > 20) return 0;
    uint64_t n = 0;
    for (wchar_t c : v)
    {
        if (c < L'0' || c > L'9') return 0;
        n = n * 10 + (uint64_t)(c - L'0');
    }
    return n;
}

// Raw property bytes -> short identifier string (AUMID / notif-id fields only; the payload
// is never run through this). String intypes copy; 4/8-byte scalars print as decimal.
static std::wstring PxRawToName(const BYTE* raw, ULONG psz, USHORT inType)
{
    if (inType == TDH_INTYPE_UNICODESTRING || inType == TDH_INTYPE_COUNTEDSTRING)
    {
        std::wstring w(psz / 2, 0);
        if (!w.empty()) memcpy(&w[0], raw, w.size() * sizeof(wchar_t));
        while (!w.empty() && w.back() == 0) w.pop_back();
        return w;
    }
    if (inType == TDH_INTYPE_ANSISTRING || inType == TDH_INTYPE_COUNTEDANSISTRING)
    {
        std::string s((const char*)raw, psz);
        while (!s.empty() && s.back() == 0) s.pop_back();
        int wn = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
        std::wstring w(wn > 0 ? (size_t)wn : 0, 0);
        if (wn > 0) MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], wn);
        return w;
    }
    if (psz == 4) { wchar_t t[16]; swprintf(t, 16, L"%lu", *(const ULONG*)raw); return t; }
    if (psz == 8) { wchar_t t[24]; swprintf(t, 24, L"%llu", *(const unsigned long long*)raw); return t; }
    return L"";
}

// TDH-locate the SIGNAL metadata {AUMID, notificationId (string + numeric), tag, group}
// in one event; raw bytes only, NAME-GATED: a property whose name matches none of the
// wanted fields is never even fetched, so payload bytes are never materialized in this
// process (design 10.20.1 - the untrusted-parse surface SHRINKS: metadata fields only,
// each markup-rejected and length-capped). Every failure path returns false = "this
// event carries nothing" - the ladder in the bridge degrades. Emission rule: an event is
// worth a frame iff it carries an AUMID or a numeric notificationId (the old
// !payload.empty() rule was ZERO frames forever on Win10 - the latent proxy-killer).
static bool PxHarvest(EVENT_RECORD* er, PxRec* out)
{
    out->ft = er->EventHeader.TimeStamp.QuadPart;    // FILETIME (no RAW_TIMESTAMP mode)
    ULONG sz = 0;
    ULONG rc = TdhGetEventInformation(er, 0, nullptr, nullptr, &sz);
    if (rc != ERROR_INSUFFICIENT_BUFFER || sz == 0 || sz > 1024 * 1024) return false;
    std::vector<BYTE> buf(sz);
    TRACE_EVENT_INFO* ti = (TRACE_EVENT_INFO*)buf.data();
    if (TdhGetEventInformation(er, 0, nullptr, ti, &sz) != ERROR_SUCCESS) return false;
    ULONG nProps = ti->TopLevelPropertyCount;
    if (nProps > 64) nProps = 64;                    // adversarial bound
    for (ULONG i = 0; i < nProps; i++)
    {
        EVENT_PROPERTY_INFO const& epi = ti->EventPropertyInfoArray[i];
        if (epi.Flags & (PropertyStruct | PropertyParamCount)) continue;
        std::wstring name = EtwLower(EtwTiString(ti, epi.NameOffset));
        // name gate FIRST - unwanted fields (incl. anything payload-shaped) never fetched
        bool wantAumid = out->aumid.empty() &&
            (name.find(L"aumid") != std::wstring::npos ||
             name.find(L"appusermodelid") != std::wstring::npos ||
             name.find(L"appid") != std::wstring::npos ||
             name.find(L"primaryid") != std::wstring::npos);
        bool wantNotif = out->notifId.empty() && out->notifIdNum == 0 &&
            (name.find(L"notificationid") != std::wstring::npos || name == L"id" ||
             name.find(L"trackingid") != std::wstring::npos);
        bool wantTag   = out->tag.empty() && name.find(L"tag") != std::wstring::npos;
        bool wantGroup = out->group.empty() && name.find(L"group") != std::wstring::npos;
        if (!wantAumid && !wantNotif && !wantTag && !wantGroup) continue;
        PROPERTY_DATA_DESCRIPTOR pdd = {};
        pdd.PropertyName = (ULONGLONG)((BYTE*)ti + epi.NameOffset);
        pdd.ArrayIndex = (ULONG)-1;
        ULONG psz = 0;
        if (TdhGetPropertySize(er, 0, nullptr, 1, &pdd, &psz) != ERROR_SUCCESS ||
            psz == 0 || psz > ETW_MAX_AUMID_BYTES)   // metadata-sized values only, AT SOURCE
            continue;
        std::vector<BYTE> raw(psz);
        if (TdhGetProperty(er, 0, nullptr, 1, &pdd, psz, raw.data()) != ERROR_SUCCESS) continue;
        std::wstring v = PxRawToName(raw.data(), psz, epi.nonStructType.InType);
        if (v.empty() || PxLooksLikeMarkup(v)) continue;   // markup: REJECT, never copy
        if (wantAumid && v.size() * sizeof(wchar_t) <= ETW_MAX_AUMID_BYTES)
            out->aumid = v;
        else if (wantNotif)
        {
            out->notifIdNum = PxAllDecimalToU64(v);        // 0 = does not join by id
            if (v.size() * sizeof(wchar_t) <= ETW_MAX_NOTIF_BYTES) out->notifId = v;
        }
        else if (wantTag && v.size() * sizeof(wchar_t) <= ETW_MAX_TAG_BYTES)
            out->tag = v;
        else if (wantGroup && v.size() * sizeof(wchar_t) <= ETW_MAX_GROUP_BYTES)
            out->group = v;
    }
    return !out->aumid.empty() || out->notifIdNum != 0;
}

// ProcessTrace callback (proxy). Exception-tight; queues one encoded 'QTS1' SIGNAL frame
// per AUMID-or-id-bearing event and never blocks (a full queue drops the OLDEST - the
// bridge tier misses that toast's signal and its ladder degrades: fail-open, never a
// wedged consumer).
static void CALLBACK EtwProxyEventCb(EVENT_RECORD* er)
{
    try
    {
        PxRec r;
        if (!PxHarvest(er, &r)) return;      // emission rule: !aumid.empty() || notifIdNum
        std::vector<BYTE> f;
        f.reserve(ETW_WIRE_HDR_BYTES +
                  (r.aumid.size() + r.notifId.size() + r.tag.size() + r.group.size()) * 2);
        PutU32(f, ETW_WIRE_MAGIC);
        PutU32(f, (uint32_t)(r.aumid.size() * sizeof(wchar_t)));
        PutU32(f, (uint32_t)(r.notifId.size() * sizeof(wchar_t)));
        PutU32(f, (uint32_t)(r.tag.size() * sizeof(wchar_t)));
        PutU32(f, (uint32_t)(r.group.size() * sizeof(wchar_t)));
        PutU64(f, r.notifIdNum);
        PutU64(f, (uint64_t)r.ft);
        auto putw = [&f](std::wstring const& s) {
            f.insert(f.end(), (const BYTE*)s.data(), (const BYTE*)(s.data() + s.size()));
        };
        putw(r.aumid); putw(r.notifId); putw(r.tag); putw(r.group);
        LONG n = InterlockedIncrement(&g_px.captured);
        {
            CsGuard g(&g_px.lock);           // RAII (review must-fix applies here too)
            g_px.q.push_back(std::move(f));
            while (g_px.q.size() > 64) { g_px.q.pop_front(); InterlockedIncrement(&g_px.dropped); }
        }
        SetEvent(g_px.evt);
        if (n <= 50 || (n % 20) == 0)        // human-rate log
            BLog(L"ETWPROXY SIG #%ld aumid=%s idnum=%llu notif=%s tag=%s group=%s", n,
                 r.aumid.empty() ? L"-" : r.aumid.c_str(), (ULONGLONG)r.notifIdNum,
                 r.notifId.empty() ? L"-" : r.notifId.c_str(),
                 r.tag.empty() ? L"-" : r.tag.c_str(),
                 r.group.empty() ? L"-" : r.group.c_str());
    }
    catch (...) {}
}

// Overlapped write with stop/session-death abort, so a connected-but-never-reading client
// can stall only the serve loop (which the agent supervises), never the ETW consumer.
static bool PxWrite(HANDLE pipe, HANDLE etwThread, const BYTE* b, DWORD n)
{
    DWORD done = 0;
    while (done < n)
    {
        OVERLAPPED ov = {}; ov.hEvent = g_px.wrEvt; ResetEvent(g_px.wrEvt);
        if (!WriteFile(pipe, b + done, n - done, nullptr, &ov) &&
            GetLastError() != ERROR_IO_PENDING) return false;
        HANDLE hs[3] = { g_px.wrEvt, g_px.stopEvt, etwThread };
        DWORD w = WaitForMultipleObjects(3, hs, FALSE, INFINITE);
        if (w != WAIT_OBJECT_0)
        {
            CancelIoEx(pipe, &ov);
            DWORD x; GetOverlappedResult(pipe, &ov, &x, TRUE);
            return false;
        }
        DWORD got = 0;
        if (!GetOverlappedResult(pipe, &ov, &got, FALSE) || got == 0) return false;
        done += got;
    }
    return true;
}

static BOOL WINAPI PxCtrlHandler(DWORD)
{
    // Pure consumer: NEVER stop the session (the SYSTEM agent owns its lifecycle). The
    // serve loop notices stopEvt and falls into teardown, whose CloseTrace ends
    // ProcessTrace (ERROR_CTX_CLOSE_PENDING: it drains and returns).
    SetEvent(g_px.stopEvt);
    return TRUE;
}

// ---- least-privilege enforcement for the --etw-proxy consumer ----------------------------
// The untrusted TDH/property decode (PxHarvest) parses attacker-influenceable event bytes.
// Three code-enforced guarantees complement the account provisioning + the architect's
// control/consume split (design sec 10.10.1 / 10.17):
//   * the never-SYSTEM/admin guard REFUSES to run under a privileged token (exit 9);
//   * the token census LOGS the group/priv set once and REFUSES (exit 9, same hard-refuse
//     class) on drift - Performance Log Users SID or SeSystemProfilePrivilege present
//     (the sec 10.17.2 residual: the consumer gains consume via the per-session DACL
//     grant ONLY; a drifted token has machine-wide trace capability that group SIDs make
//     unsheddable, so it must never reach the decode loop);
//   * EtwProxyShedAllPrivileges IRREVERSIBLY strips every privilege before the decode loop.

// Refuse to run the hostile parse under SYSTEM / admin / an elevated token. Fail CLOSED
// (a token we cannot inspect is treated as forbidden). Sets `why` to a human reason.
static bool EtwProxyTokenIsForbidden(std::wstring& why)
{
    HANDLE tok = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok))
    { why = L"OpenProcessToken(TOKEN_QUERY) failed - cannot verify the token is unprivileged"; return true; }

    bool bad = false;
    SID_IDENTIFIER_AUTHORITY nt = SECURITY_NT_AUTHORITY;

    // 1. Token user is LocalSystem (S-1-5-18)?
    DWORD cb = 0; GetTokenInformation(tok, TokenUser, nullptr, 0, &cb);
    std::vector<BYTE> ub(cb ? cb : 1);
    if (cb && GetTokenInformation(tok, TokenUser, ub.data(), cb, &cb))
    {
        PSID sys = nullptr;
        if (AllocateAndInitializeSid(&nt, 1, SECURITY_LOCAL_SYSTEM_RID, 0, 0, 0, 0, 0, 0, 0, &sys))
        {
            if (EqualSid(((TOKEN_USER*)ub.data())->User.Sid, sys))
            { bad = true; why = L"token user is LocalSystem (S-1-5-18)"; }
            FreeSid(sys);
        }
    }
    // 2. Elevated (a full-token admin process)?
    if (!bad)
    {
        TOKEN_ELEVATION el = {}; DWORD n = 0;
        if (GetTokenInformation(tok, TokenElevation, &el, sizeof(el), &n) && el.TokenIsElevated)
        { bad = true; why = L"token is elevated (TokenElevation)"; }
    }
    // 3. BUILTIN\Administrators present AND enabled in the effective token?
    if (!bad)
    {
        PSID admins = nullptr;
        if (AllocateAndInitializeSid(&nt, 2, SECURITY_BUILTIN_DOMAIN_RID,
                DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0, &admins))
        {
            BOOL isMember = FALSE;
            if (CheckTokenMembership(nullptr, admins, &isMember) && isMember)
            { bad = true; why = L"BUILTIN\\Administrators present and enabled"; }
            FreeSid(admins);
        }
    }
    CloseHandle(tok);
    return bad;
}

// Log the token's privilege + group census ONCE, and return true (= REFUSE, exit 9) if
// the token has DRIFTED: Performance Log Users SID (S-1-5-32-559) or
// SeSystemProfilePrivilege present. Under the control/consume split the consumer gains
// consume via the per-session DACL grant ONLY - either finding means this token carries
// machine-wide trace capability, and a group SID cannot be shed in-process
// (SE_GROUP_MANDATORY), so the hostile TDH decode must never run on it (design
// sec 10.17.2; secure default: refuse-on-drift, never warn-and-proceed).
static bool EtwProxyTokenCensusIsDrifted()
{
    HANDLE tok = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok))
        return true;   // fail closed: a token we cannot inspect must not run the decode

    bool profilePriv = false;
    LUID profLuid = {};
    BOOL haveProfLuid = LookupPrivilegeValueW(nullptr, L"SeSystemProfilePrivilege", &profLuid);

    DWORD cb = 0;
    GetTokenInformation(tok, TokenPrivileges, nullptr, 0, &cb);
    std::vector<BYTE> pb(cb ? cb : 1);
    if (cb && GetTokenInformation(tok, TokenPrivileges, pb.data(), cb, &cb))
    {
        TOKEN_PRIVILEGES* tp = (TOKEN_PRIVILEGES*)pb.data();
        std::wstring names;
        for (DWORD i = 0; i < tp->PrivilegeCount && i < 64; i++)
        {
            if (haveProfLuid && tp->Privileges[i].Luid.LowPart == profLuid.LowPart &&
                tp->Privileges[i].Luid.HighPart == profLuid.HighPart)
                profilePriv = true;
            wchar_t nm[64]; DWORD nl = RTL_NUMBER_OF(nm);
            if (LookupPrivilegeNameW(nullptr, &tp->Privileges[i].Luid, nm, &nl))
            { if (!names.empty()) names += L","; names += nm; }
        }
        printf("ETWPROXY token privileges (%lu): %ls\n", tp->PrivilegeCount,
               names.empty() ? L"<none>" : names.c_str());
        BLog(L"ETWPROXY token privileges (%lu): %s", tp->PrivilegeCount,
             names.empty() ? L"<none>" : names.c_str());
    }

    cb = 0;
    GetTokenInformation(tok, TokenGroups, nullptr, 0, &cb);
    std::vector<BYTE> gb(cb ? cb : 1);
    bool plu = false;
    int enabled = 0;
    if (cb && GetTokenInformation(tok, TokenGroups, gb.data(), cb, &cb))
    {
        TOKEN_GROUPS* tg = (TOKEN_GROUPS*)gb.data();
        SID_IDENTIFIER_AUTHORITY nt = SECURITY_NT_AUTHORITY;
        PSID pluSid = nullptr;
        AllocateAndInitializeSid(&nt, 2, SECURITY_BUILTIN_DOMAIN_RID,
            DOMAIN_ALIAS_RID_LOGGING_USERS, 0, 0, 0, 0, 0, 0, &pluSid);
        for (DWORD i = 0; i < tg->GroupCount; i++)
        {
            // Deliberately counts DISABLED group SIDs too: a deny-only or disabled PLU SID
            // still marks a drifted provisioning, and disabled groups can be re-enabled by
            // anything holding TOKEN_ADJUST_GROUPS - drift is drift.
            if (tg->Groups[i].Attributes & SE_GROUP_ENABLED) enabled++;
            if (pluSid && EqualSid(tg->Groups[i].Sid, pluSid)) plu = true;
        }
        if (pluSid) FreeSid(pluSid);
    }
    printf("ETWPROXY token enabled-groups=%d perf-log-users=%d se-system-profile=%d\n",
           enabled, plu ? 1 : 0, profilePriv ? 1 : 0);
    BLog(L"ETWPROXY token enabled-groups=%d perf-log-users=%d se-system-profile=%d",
         enabled, plu ? 1 : 0, profilePriv ? 1 : 0);
    CloseHandle(tok);
    if (plu || profilePriv)
    {
        printf("ETWPROXY FAIL token DRIFT: %s%spresent - refusing to run the hostile TDH "
               "decode with machine-wide trace capability (the control/consume split grants "
               "consume via the per-session DACL only; group SIDs cannot be shed - "
               "re-run guest/provision-etwproxy-account.ps1; design sec 10.17.2)\n",
               plu ? "Performance-Log-Users " : "",
               profilePriv ? "SeSystemProfilePrivilege " : "");
        BLog(L"ETWPROXY FAIL token DRIFT: %s%spresent - refusing (sec 10.17.2)",
             plu ? L"Performance-Log-Users " : L"",
             profilePriv ? L"SeSystemProfilePrivilege " : L"");
        return true;
    }
    return false;
}

// Irreversibly strip EVERY privilege from our own primary token. SE_PRIVILEGE_REMOVED (unlike
// SE_PRIVILEGE_DISABLED) cannot be re-enabled by AdjustTokenPrivileges, so once the decode
// loop runs no privilege remains for a parser bug to abuse. Belt-and-braces to the split: the
// split closes the PLU-GROUP residual (a group SID cannot be shed from a primary token); this
// closes the privilege one. Removed one-at-a-time so a single unremovable entry cannot void
// the whole batch.
static void EtwProxyShedAllPrivileges()
{
    HANDLE tok = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &tok))
    { BLog(L"ETWPROXY WARN OpenProcessToken(adjust) failed %lu - privileges NOT shed", GetLastError()); return; }

    DWORD cb = 0;
    GetTokenInformation(tok, TokenPrivileges, nullptr, 0, &cb);
    std::vector<BYTE> buf(cb ? cb : 1);
    if (cb && GetTokenInformation(tok, TokenPrivileges, buf.data(), cb, &cb))
    {
        TOKEN_PRIVILEGES* tp = (TOKEN_PRIVILEGES*)buf.data();
        int removed = 0;
        for (DWORD i = 0; i < tp->PrivilegeCount; i++)
        {
            TOKEN_PRIVILEGES one = {};
            one.PrivilegeCount = 1;
            one.Privileges[0] = tp->Privileges[i];
            one.Privileges[0].Attributes = SE_PRIVILEGE_REMOVED;
            if (AdjustTokenPrivileges(tok, FALSE, &one, 0, nullptr, nullptr) &&
                GetLastError() == ERROR_SUCCESS)
                removed++;
        }
        printf("ETWPROXY privileges shed: %d of %lu removed (SE_PRIVILEGE_REMOVED - irreversible)\n",
               removed, tp->PrivilegeCount);
        BLog(L"ETWPROXY privileges shed: %d of %lu removed (irreversible) - decode loop runs unprivileged",
             removed, tp->PrivilegeCount);
    }
    else
        BLog(L"ETWPROXY WARN could not read token privileges %lu - none shed", GetLastError());
    CloseHandle(tok);
}

static int EtwProxyMain(const wchar_t* clientSid)
{
    // --etw-proxy logs to the STANDARD QWT log dir (QwtLogDir: registry LogDir else
    // %SYSTEMDRIVE%\Qubes Logs), NOT the bridge's qubes-toast-bridge state dir. Set BEFORE
    // the first BLog. The proxy holds a Modify ACE on THIS log only (provisioning script) and
    // no write access to the bridge's control surfaces.
    g_logDirOverride = QwtLogDir();
    CreateDirectoryW(g_logDirOverride.c_str(), nullptr);   // best-effort; provisioning pre-creates + ACEs
    g_logName = L"\\etw-proxy.log";

    // NEVER-SYSTEM/ADMIN GUARD (code-enforced, complements the privilege drop below): the
    // untrusted TDH/property decode must never run as SYSTEM/admin/elevated. --dump-etw is the
    // sanctioned SYSTEM diagnostic; --etw-proxy is the ship posture and must be the
    // least-privilege qubes-etwproxy account only (design sec 10.10.1 / 10.17). Refuse loudly.
    std::wstring why;
    if (EtwProxyTokenIsForbidden(why))
    {
        printf("ETWPROXY FAIL refusing to run the untrusted ETW/TDH parse under a privileged "
               "token: %ls (this path must be the least-privilege qubes-etwproxy account only)\n",
               why.c_str());
        BLog(L"ETWPROXY FAIL never-SYSTEM guard tripped: %s - refusing", why.c_str());
        return 9;
    }

    InitializeCriticalSection(&g_px.lock);
    g_px.evt = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    g_px.stopEvt = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_px.wrEvt = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HANDLE connEvt = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!g_px.evt || !g_px.stopEvt || !g_px.wrEvt || !connEvt)
    { printf("ETWPROXY FAIL event create %lu\n", GetLastError()); return 7; }
    std::wstring tok = CurrentUserSid();
    printf("ETWPROXY start token=%ls client_sid=%ls\n", tok.c_str(),
           clientSid ? clientSid : L"<none>");
    BLog(L"ETWPROXY start token=%s client_sid=%s", tok.c_str(),
         clientSid ? clientSid : L"<none>");
    // TOKEN-DRIFT REFUSE (secure default, same hard-refuse class as the guard above): a
    // consumer token carrying Performance Log Users or SeSystemProfilePrivilege has
    // machine-wide trace capability that cannot be shed (group SIDs are mandatory), so it
    // must never reach the decode loop. The census logs the group/priv set once either way.
    if (EtwProxyTokenCensusIsDrifted())
        return 9;

    // --- PURE CONSUMER: the SYSTEM agent (agent/gui-agent/etwproxy.c) is the session
    //     CONTROLLER - it already started QubesToastBridgeEtw (kEtwBridgeSession ==
    //     etwproxy.c's ETWPROXY_SESSION_NAME, a change-both-or-neither contract), enabled
    //     the providers, and granted this account TRACELOG_ACCESS_REALTIME on the session
    //     GUID (EventAccessControl) before launching us. This process holds NO session
    //     control by design: no StartTrace, no EnableTrace, no ControlTrace - OpenTraceW
    //     by logger name is everything it does with the session.
    TRACEHANDLE cons = EtwOpen(kEtwBridgeSession, EtwProxyEventCb);
    if (cons == INVALID_PROCESSTRACE_HANDLE || cons == 0)
    {
        DWORD gle = GetLastError();
        if (gle == ERROR_ACCESS_DENIED)
        {
            // The consume-denied datum: the per-session DACL grant did not authorize
            // real-time consumption on this build. The agent parks the tier on exit 5.
            printf("ETWPROXY FAIL OpenTrace/ProcessTrace denied - per-session DACL grant "
                   "insufficient\n");
            BLog(L"ETWPROXY FAIL OpenTrace/ProcessTrace denied - per-session DACL grant insufficient");
            return 5;
        }
        printf("ETWPROXY FAIL OpenTrace %lu (agent-started session absent?)\n", gle);
        BLog(L"ETWPROXY FAIL OpenTrace %lu (agent-started session absent?)", gle);
        return 7;
    }
    SetConsoleCtrlHandler(PxCtrlHandler, TRUE);

    // The pipe (needs no privilege). OUTBOUND = kernel-enforced one-way (this handle CANNOT
    // read); protected DACL (D:P - no inherited ACEs can widen it) admitting ONLY the bridge
    // user's SID, read-only (FR) - no SYSTEM ACE. The --client-sid is round-tripped through
    // ConvertStringSidToSidW / ConvertSidToStringSidW BEFORE it is spliced into the SDDL, so a
    // crafted --client-sid can neither inject SDDL text nor overflow the buffer; the CANONICAL
    // form is what gets spliced. No valid SID => DACL D:P (deny everyone): the pipe is locked
    // shut and the bridge tier stays down (fail-open). FIRST_PIPE_INSTANCE so a later squatter
    // cannot shadow us (and a squatter that got the name first => loud exit 8, not serve beside).
    wchar_t sddl[256];
    PSID psid = nullptr; LPWSTR canon = nullptr;
    bool sidOk = false;
    if (clientSid && *clientSid && ConvertStringSidToSidW(clientSid, &psid))
    {
        if (IsValidSid(psid) && ConvertSidToStringSidW(psid, &canon)) sidOk = true;
        LocalFree(psid);
    }
    if (sidOk)
        swprintf(sddl, RTL_NUMBER_OF(sddl), L"D:P(A;;FR;;;%s)", canon);
    else
    {
        wcscpy_s(sddl, L"D:P");
        if (clientSid && *clientSid)
        {
            printf("ETWPROXY WARN --client-sid '%ls' is not a valid SID - pipe DACL empty "
                   "(deny everyone), bridge tier stays down\n", clientSid);
            BLog(L"ETWPROXY WARN --client-sid invalid - pipe DACL empty (deny everyone)");
        }
        else
        {
            printf("ETWPROXY WARN no --client-sid: pipe DACL empty - nobody can connect (bridge tier stays down)\n");
            BLog(L"ETWPROXY WARN no --client-sid: pipe DACL empty - nobody can connect");
        }
    }
    if (canon) LocalFree(canon);

    SECURITY_ATTRIBUTES sa = { sizeof(sa) };
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1,
                                                              &sa.lpSecurityDescriptor, nullptr))
    {
        printf("ETWPROXY FAIL SDDL %lu\n", GetLastError());
        CloseTrace(cons);   // never the session - the agent owns it
        return 8;
    }
    HANDLE pipe = CreateNamedPipeW(kEtwProxyPipe,
        PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_WAIT, 1, 128 * 1024, 0, 0, &sa);
    LocalFree(sa.lpSecurityDescriptor);
    if (pipe == INVALID_HANDLE_VALUE)
    {
        printf("ETWPROXY FAIL CreateNamedPipe %lu (squatter holding the name?)\n", GetLastError());
        BLog(L"ETWPROXY FAIL CreateNamedPipe %lu", GetLastError());
        CloseTrace(cons);   // never the session - the agent owns it
        return 8;
    }

    // === PRIVILEGE DROP =====================================================================
    // OpenTrace and the pipe DACL are done; nothing left needs any privilege (the bare
    // qubes-etwproxy token should hold none to begin with - the split's whole point).
    // Irreversibly strip EVERY privilege from our token BEFORE the ProcessTrace/PxHarvest
    // decode loop consumes one attacker-influenceable byte. If real-time consumption is
    // refused despite the agent's per-session DACL grant, ProcessTrace returns
    // ERROR_ACCESS_DENIED and this process exits 5 => the agent parks on a TRUE finding
    // (design sec 10.16.3b's datum under the split). (The architect's control/consume split
    // is what closes the PLU-GROUP residual sec 10.17.2; this in-process drop is its
    // belt-and-braces.)
    EtwProxyShedAllPrivileges();

    HANDLE etwThread = CreateThread(nullptr, 0, EtwDumpProcessThread, &cons, 0, nullptr);
    if (!etwThread)
    {
        printf("ETWPROXY FAIL consumer thread %lu\n", GetLastError());
        BLog(L"ETWPROXY FAIL consumer thread %lu", GetLastError());
        CloseTrace(cons);   // never the session - the agent owns it
        CloseHandle(pipe);
        return 7;
    }
    printf("ETWPROXY LIVE session=%ls pipe=%ls (pure consumer: session/providers/grant "
           "are agent-owned)\n", kEtwBridgeSession, kEtwProxyPipe);
    BLog(L"ETWPROXY LIVE session=%s pipe=%s (pure consumer)", kEtwBridgeSession, kEtwProxyPipe);

    // Serve loop: wait for the (single) client, push frames, on client loss disconnect
    // and wait again. Ends when the ETW session dies (etwThread signaled) or on ctrl/stop.
    int exitCode = 0;
    for (;;)
    {
        OVERLAPPED ov = {}; ov.hEvent = connEvt; ResetEvent(connEvt);
        BOOL c = ConnectNamedPipe(pipe, &ov);
        DWORD ce = c ? ERROR_PIPE_CONNECTED : GetLastError();
        if (ce == ERROR_IO_PENDING)
        {
            HANDLE hs[3] = { connEvt, g_px.stopEvt, etwThread };
            DWORD w = WaitForMultipleObjects(3, hs, FALSE, INFINITE);
            if (w != WAIT_OBJECT_0)
            {
                CancelIoEx(pipe, &ov);
                DWORD x; GetOverlappedResult(pipe, &ov, &x, TRUE);
                break;
            }
            DWORD x;
            if (!GetOverlappedResult(pipe, &ov, &x, FALSE) &&
                GetLastError() != ERROR_PIPE_CONNECTED)
            { BLog(L"ETWPROXY connect completion failed %lu", GetLastError()); break; }
        }
        else if (ce != ERROR_PIPE_CONNECTED)
        { BLog(L"ETWPROXY ConnectNamedPipe failed %lu", ce); exitCode = 8; break; }
        ULONG cp = 0;
        GetNamedPipeClientProcessId(pipe, &cp);
        BLog(L"ETWPROXY CLIENT connected pid=%lu", cp);
        bool clientOk = true;
        while (clientOk)
        {
            HANDLE hs[3] = { g_px.evt, g_px.stopEvt, etwThread };
            if (WaitForMultipleObjects(3, hs, FALSE, INFINITE) != WAIT_OBJECT_0)
            { clientOk = false; break; }             // stop / session death
            for (;;)
            {
                std::vector<BYTE> f;
                {
                    CsGuard g(&g_px.lock);
                    if (g_px.q.empty()) break;
                    f = std::move(g_px.q.front());
                    g_px.q.pop_front();
                }
                if (!PxWrite(pipe, etwThread, f.data(), (DWORD)f.size()))
                { BLog(L"ETWPROXY client write failed - disconnecting"); clientOk = false; break; }
                InterlockedIncrement(&g_px.sent);
            }
        }
        DisconnectNamedPipe(pipe);
        if (WaitForSingleObject(g_px.stopEvt, 0) == WAIT_OBJECT_0 ||
            WaitForSingleObject(etwThread, 0) == WAIT_OBJECT_0) break;
    }

    // Pure-consumer teardown: NEVER stop the session - the SYSTEM agent owns its whole
    // lifecycle (park/shutdown stop it; job-kill + the agent's next-launch stop-by-name
    // reap cover every crash path). Closing OUR consumer handle is what ends ProcessTrace
    // (ERROR_CTX_CLOSE_PENDING = success: it drains and returns; process exit covers a
    // straggler past the bounded wait).
    CloseTrace(cons);
    WaitForSingleObject(etwThread, 5000);
    DWORD ptrc = (DWORD)-1;
    GetExitCodeThread(etwThread, &ptrc);   // EtwDumpProcessThread returns ProcessTrace's rc
    CloseHandle(etwThread);
    CloseHandle(pipe);
    if (ptrc == ERROR_ACCESS_DENIED)
    {
        // ProcessTrace itself was refused: real-time consumption is denied despite the
        // agent's per-session DACL grant. This must surface as the consume-denied exit so
        // the agent parks on a TRUE finding - never a masquerading clean exit 0.
        printf("ETWPROXY FAIL OpenTrace/ProcessTrace denied - per-session DACL grant "
               "insufficient\n");
        BLog(L"ETWPROXY FAIL OpenTrace/ProcessTrace denied - per-session DACL grant insufficient");
        exitCode = 5;
    }
    printf("ETWPROXY stop rc=%d captured=%ld sent=%ld dropped=%ld\n",
           exitCode, g_px.captured, g_px.sent, g_px.dropped);
    BLog(L"ETWPROXY stop rc=%d captured=%ld sent=%ld dropped=%ld",
         exitCode, g_px.captured, g_px.sent, g_px.dropped);
    return exitCode;
}

// ==========================================================================================

// Shadow-classify ONE new toast and BLog EXACTLY one CLASSIFY line (plus one SUPPAPI line):
//   CLASSIFY id=%u src=%s etw=%s verdict=%s row_latency=%lums signals=%s corr=%s
//     src      which ladder rung actually produced the payload: etw-sig (targeted wpndb
//              read answering an ETW signal) | db (the ETW-down WpnCorrelate rung) | none
//     etw      rung-1 outcome: sig-hit|sig-none|down|off - measures ETW SIGNAL
//              availability per toast; the rig gate's ETW-viability number comes from
//              this field (all-down/all-sig-none = tier not viable, DB rung serving)
//     verdict  what Phase-3 per-toast ROUTING would decide; "bridge" only on a CLEAN
//              acquisition (corr in {id-ok, sig-unique, ok}) - every failure class
//              (mismatch, ambiguous, norow, ...) is fail-open "window"
//     signals  rowN:<reason-slug> from toastclassify.h's decision-table match ("none" when
//              no payload XML was obtained)
//     corr     tier-1 targeted-read outcome (id-ok|id-aumid-mismatch|id-norow|sig-unique|
//              sig-ambiguous|sig-norow|db-fail); otherwise the DB rung's WpnCorr class,
//              plus probe-threw
//   SUPPAPI id=%u template=%s hints=%s
//     the supported-API windfall probe: what the ToastGeneric binding exposes beyond
//     GetTextElements (Template()/Hints()) - if a hint ever surfaces actions, Phase 3
//     could drop both acquisition rungs entirely.
//
// SPLIT since 2026-09-05 (heartbeat-safety refactor): ShadowClassify (poll thread) only
// dedupes, logs SUPPAPI, captures {id, aumid, title, creationFt} - all cheap WinRT reads
// that already happen on that thread - and enqueues; ShadowWorkerThread (off-thread) runs
// the acquisition ladder (EtwTierLookup ring scan -> WpnTargetedRead answering a signal,
// or WpnCorrelate as the ETW-down fallback, both WAL-watch paced) and emits the CLASSIFY
// line ASYNCHRONOUSLY. The poll thread's per-toast cost is now a fixed-size enqueue: the
// DB reads' ~1050-1550 ms worst case can no longer stack across a burst toward the
// supervisor's 15 s heartbeat deadline. MEASURE-ONLY and exception-tight at every layer:
// nothing here can feed failStreak/FATAL or touch the A0 routing.

struct ShadowJob { uint32_t id = 0; std::wstring aumid, title; long long creationFt = 0; };

static struct
{
    CRITICAL_SECTION lock;                  // guards q; CsGuard only
    std::deque<ShadowJob> q;                // capped 32; overflow drops the OLDEST (logged)
    HANDLE evt = nullptr, stopEvt = nullptr;
    HANDLE worker = nullptr, walWatch = nullptr;
    HANDLE walEvt = nullptr;                // auto-reset: "wpndatabase.db* just changed"
    bool armed = false;
} g_shadow;

// Push replacement for WpnCorrelate's blind retry sleep (owner directive: prefer push over
// poll): watch the notification store's directory and signal walEvt whenever
// wpndatabase.db* changes - a fresh toast's row lands as a -wal append, which is exactly
// the moment a retry becomes worth making. Fail-open: if the watch cannot arm (or dies),
// walEvt simply never fires and the worker's bounded waits time out into the same pacing
// the old blind retry had. This thread signals; it never reads file content.
static DWORD WINAPI WalWatchThread(LPVOID)
{
    wchar_t la[MAX_PATH] = { 0 };
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", la, RTL_NUMBER_OF(la))) return 0;
    std::wstring dir = std::wstring(la) + L"\\Microsoft\\Windows\\Notifications";
    HANDLE h = CreateFileW(dir.c_str(), FILE_LIST_DIRECTORY,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                           OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (h == INVALID_HANDLE_VALUE)
    { BLog(L"WALWATCH unavailable (%lu) - timed-retry fallback", GetLastError()); return 0; }
    BLog(L"WALWATCH armed dir=%s", dir.c_str());
    std::vector<BYTE> buf(8192);
    for (;;)
    {
        if (WaitForSingleObject(g_shadow.stopEvt, 0) == WAIT_OBJECT_0) break;
        DWORD ret = 0;
        if (!ReadDirectoryChangesW(h, buf.data(), (DWORD)buf.size(), FALSE,
                FILE_NOTIFY_CHANGE_LAST_WRITE | FILE_NOTIFY_CHANGE_SIZE |
                FILE_NOTIFY_CHANGE_FILE_NAME, &ret, nullptr, nullptr))
            break;                           // cancelled at shutdown / dir gone
        // Any change to wpndatabase.db / -wal / -shm counts; a buffer overflow (ret==0,
        // "changes lost") counts too - over-signaling only wakes a retry early.
        bool hit = (ret == 0);
        for (BYTE* p = buf.data();
             !hit && ret && p + sizeof(FILE_NOTIFY_INFORMATION) <= buf.data() + ret; )
        {
            FILE_NOTIFY_INFORMATION* fi = (FILE_NOTIFY_INFORMATION*)p;
            if (fi->FileNameLength >= 14 * sizeof(wchar_t) &&
                _wcsnicmp(fi->FileName, L"wpndatabase.db", 14) == 0)
                hit = true;
            if (!fi->NextEntryOffset) break;
            p += fi->NextEntryOffset;
        }
        if (hit) SetEvent(g_shadow.walEvt);
    }
    CloseHandle(h);
    return 0;
}

// The acquisition ladder for ONE toast + the CLASSIFY line. Runs on the shadow worker
// (or, under P3AQ_DEFECT_HOTWAIT only, back on the poll thread as the seen-to-fail proof).
static void ShadowClassifyWork(ShadowJob const& j)
{
    try
    {
        // tier 1 ETW signal (non-blocking ring scan) + ONE targeted wpndb read per
        // candidate -> tier 2 wpndatabase correlate (the ETW-down fallback, bounded,
        // WAL-watch paced) -> tier 3 none. Fail-open at every rung; a "bridge" verdict is
        // earned only by a clean acquisition + classifier match: corr in {id-ok,
        // sig-unique} on tier 1, corr=ok on tier 2 (design 10.20.2).
        ULONGLONG t0 = GetTickCount64();
        const char* src = "none";                     // etw-sig|db|none
        const char* corr = "none";
        const wchar_t* verdict = L"window";           // fail-open default (tier 3)
        std::wstring signals = L"none";
        std::vector<EtwToastRec> sigs;
        const char* etw = EtwTierLookup(j.aumid, j.creationFt, &sigs);
        if (strcmp(etw, "sig-hit") == 0)
        {
            // A signal EXISTS for this toast: the targeted read answers it - and owns the
            // outcome. On any non-clean corr (norow, mismatch, ambiguous, db-fail) the
            // verdict stays the fail-open window WITHOUT falling to WpnCorrelate: the DB
            // rung is the ETW-DOWN fallback, not a second guess at a row the precise
            // signal-keyed read already failed to pin (rig drill 10.20.5#5 asserts
            // exactly this: fire+purge-the-row => corr=id-norow => window, not db).
            WpnTarget t = WpnTargetedRead(sigs, j.aumid, j.title, g_shadow.walEvt);
            corr = t.corr;
            if (!t.payload.empty())                   // only on id-ok / sig-unique
            {
                src = "etw-sig";
                ToastClass k = ClassifyToastXmlBytes(t.payload.data(), t.payload.size());
                signals = WpnSignalSlug(k);
                if (strcmp(t.corr, "id-ok") == 0 || strcmp(t.corr, "sig-unique") == 0)
                    verdict = ToastRouteName(k.route);
            }
        }
        else                                          // no signal (sig-none/down/off): DB rung
        {
            WpnCorr c = WpnCorrelate(j.aumid, j.creationFt, j.title, g_shadow.walEvt);
            corr = c.corr;
            if (!c.payload.empty())
            {
                src = "db";
                ToastClass k = ClassifyToastXmlBytes(c.payload.data(), c.payload.size());
                signals = WpnSignalSlug(k);
                if (strcmp(c.corr, "ok") == 0)        // only a clean correlation may say "bridge"
                    verdict = ToastRouteName(k.route);
            }
        }
        BLog(L"CLASSIFY id=%u src=%hs etw=%hs verdict=%s row_latency=%lums signals=%s corr=%hs",
             j.id, src, etw, verdict, (DWORD)(GetTickCount64() - t0), signals.c_str(), corr);
    }
    catch (...)
    {
        BLog(L"CLASSIFY id=%u src=none etw=probe-threw verdict=window row_latency=0ms signals=none corr=probe-threw", j.id);
    }
}

static DWORD WINAPI ShadowWorkerThread(LPVOID)
{
    for (;;)
    {
        HANDLE hs[2] = { g_shadow.stopEvt, g_shadow.evt };
        if (WaitForMultipleObjects(2, hs, FALSE, INFINITE) == WAIT_OBJECT_0) return 0;
        for (;;)
        {
            ShadowJob j;
            {
                CsGuard g(&g_shadow.lock);
                if (g_shadow.q.empty()) break;
                j = std::move(g_shadow.q.front());
                g_shadow.q.pop_front();
            }
            ShadowClassifyWork(j);
            if (WaitForSingleObject(g_shadow.stopEvt, 0) == WAIT_OBJECT_0) return 0;
        }
    }
}

static void ShadowWorkerStart()
{
    InitializeCriticalSection(&g_shadow.lock);
    g_shadow.evt = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    g_shadow.stopEvt = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_shadow.walEvt = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!g_shadow.evt || !g_shadow.stopEvt || !g_shadow.walEvt)
    { BLog(L"SHADOW event create failed %lu - CLASSIFY lines disabled this run", GetLastError()); return; }
    g_shadow.worker = CreateThread(nullptr, 0, ShadowWorkerThread, nullptr, 0, nullptr);
    g_shadow.walWatch = CreateThread(nullptr, 0, WalWatchThread, nullptr, 0, nullptr);
    g_shadow.armed = (g_shadow.worker != nullptr);
    if (!g_shadow.armed)
        BLog(L"SHADOW worker create failed %lu - CLASSIFY lines disabled this run", GetLastError());
}

static void ShadowWorkerStop()
{
    if (g_shadow.stopEvt) SetEvent(g_shadow.stopEvt);
    if (g_shadow.walWatch)
    {
        CancelSynchronousIo(g_shadow.walWatch);        // unblock ReadDirectoryChangesW
        WaitForSingleObject(g_shadow.walWatch, 3000);  // bounded joins throughout
        CloseHandle(g_shadow.walWatch);
        g_shadow.walWatch = nullptr;
    }
    if (g_shadow.worker)
    {
        WaitForSingleObject(g_shadow.worker, 3000);
        CloseHandle(g_shadow.worker);
        g_shadow.worker = nullptr;
    }
    g_shadow.armed = false;
}

// Poll-thread side: dedupe + SUPPAPI + capture + FIXED-COST enqueue. Never blocks on
// acquisition (the heartbeat contract); every throw swallowed.
static void ShadowClassify(UserNotification const& un, uint32_t id, std::wstring const& aumid)
{
    try
    {
        static std::unordered_set<uint32_t> logged;   // poll-thread only ("exactly one line")
        if (logged.size() > 1000) logged.clear();     // bound; a re-log after clear is harmless
        if (!logged.insert(id).second) return;        // retried (unforwarded) toast: already logged
        try
        {
            auto bind = un.Notification().Visual().GetBinding(KnownNotificationBindings::ToastGeneric());
            if (bind)
            {
                std::wstring hints;
                for (auto const& kv : bind.Hints())
                { hints += kv.Key().c_str(); hints += L'='; hints += kv.Value().c_str(); hints += L';'; }
                BLog(L"SUPPAPI id=%u template=%s hints=%s", id, bind.Template().c_str(),
                     hints.empty() ? L"-" : hints.c_str());
            }
            else BLog(L"SUPPAPI id=%u template=<no-toastgeneric-binding> hints=-", id);
        }
        catch (...) { BLog(L"SUPPAPI id=%u template=<threw> hints=-", id); }

        long long creationFt = 0;
        try { creationFt = un.CreationTime().time_since_epoch().count(); } catch (...) {}
        auto tb = FirstTexts(un);
        ShadowJob j{ id, aumid, tb.substr(0, tb.find(L'\x1f')), creationFt };
#if defined(P3AQ_DEFECT_HOTWAIT)
        // DEFECT (seen-to-fail, autonomy rule 5): acquisition back on the poll thread plus
        // a deliberate stall, so a 3-toast burst pushes a pass past the harness's
        // heartbeat-cadence bound. The detector must FAIL on this build or it is decoration.
        Sleep(1500);
        ShadowClassifyWork(j);
#else
        if (!g_shadow.armed) return;                  // no worker: shadow tier silent (measure-only)
        bool overflow = false;
        {
            CsGuard g(&g_shadow.lock);
            if (g_shadow.q.size() >= 32) { g_shadow.q.pop_front(); overflow = true; }
            g_shadow.q.push_back(std::move(j));
        }
        if (overflow) BLog(L"SHADOWQ overflow - oldest job dropped (measure-only)");
        SetEvent(g_shadow.evt);
#endif
    }
    catch (...)
    {
        BLog(L"CLASSIFY id=%u src=none etw=enqueue-threw verdict=window row_latency=0ms signals=none corr=probe-threw", id);
    }
}

// --dump-wpndb [N]: the 3.4.1 probe artifact - schema + latest N rows, each with the shadow
// verdict, on stdout (narrow stream throughout; %ls converts in place). Exit: 0 ok, 2 no
// winsqlite3, 3 cannot open, 4 SCHEMA MISMATCH - non-zero so a harness can gate on it.
static int DumpWpnDbMain(int limit)
{
    WpnSql* q = WpnSqlGet();
    if (!q) { printf("WPNDB FAIL: winsqlite3.dll unavailable\n"); return 2; }
    std::string err;
    sqlite3* db = WpnOpen(q, &err);
    if (!db)
    { printf("WPNDB FAIL: cannot open %s: %s\n", Utf8(WpnDbPath()).c_str(), err.c_str()); return 3; }
    printf("WPNDB path=%s\n", Utf8(WpnDbPath()).c_str());
    sqlite3_stmt* st = nullptr;
    if (q->prepare_v2(db, "SELECT name, sql FROM sqlite_master WHERE type='table' ORDER BY name",
                      -1, &st, nullptr) == WPN_SQLITE_OK)
    {
        while (q->step(st) == WPN_SQLITE_ROW)
        {
            std::string name = WpnColStr(q, st, 0);
            printf("TABLE %s\n", name.c_str());
            if (name == "Notification" || name == "NotificationHandler")
                printf("SCHEMA %s\n", WpnColStr(q, st, 1).c_str());
        }
        q->finalize(st);
    }
    std::string sql = std::string(kWpnSelectSql) + "ORDER BY n.ArrivalTime DESC LIMIT ?1";
    st = nullptr;
    if (q->prepare_v2(db, sql.c_str(), -1, &st, nullptr) != WPN_SQLITE_OK)
    {
        printf("WPNDB SCHEMA MISMATCH: %s (need Notification{Id,HandlerId,Type,Payload,Tag,Group,"
               "ArrivalTime} join NotificationHandler{RecordId,PrimaryId})\n", q->errmsg(db));
        q->close_v2(db);
        return 4;
    }
    q->bind_int64(st, 1, limit > 0 ? limit : 20);
    int rows = 0;
    while (q->step(st) == WPN_SQLITE_ROW)
    {
        rows++;
        long long nid = q->column_int64(st, 0);
        std::string aumid = WpnColStr(q, st, 1);
        long long arrival = q->column_int64(st, 2);
        std::string tag = WpnColStr(q, st, 3), grp = WpnColStr(q, st, 4);
        std::string payload = WpnColStr(q, st, 5), type = WpnColStr(q, st, 6);
        char iso[40] = "?";
        FILETIME ft;
        ft.dwLowDateTime = (DWORD)((unsigned long long)arrival & 0xFFFFFFFFull);
        ft.dwHighDateTime = (DWORD)((unsigned long long)arrival >> 32);
        SYSTEMTIME sy;
        if (FileTimeToSystemTime(&ft, &sy))
            sprintf_s(iso, "%04u-%02u-%02uT%02u:%02u:%02uZ",
                      sy.wYear, sy.wMonth, sy.wDay, sy.wHour, sy.wMinute, sy.wSecond);
        ToastClass k = ClassifyToastXmlBytes(payload.data(), payload.size());
        printf("ROW id=%lld type=%s aumid=%s arrival=%lld (%s) tag=%s group=%s verdict=%ls "
               "row=%d reason=\"%ls\"\n",
               nid, type.c_str(), aumid.c_str(), arrival, iso, tag.c_str(), grp.c_str(),
               ToastRouteName(k.route), k.row, k.reason);
        printf("PAYLOAD %s\n", payload.c_str());
    }
    q->finalize(st);
    q->close_v2(db);
    printf("WPNDB OK rows=%d\n", rows);
    return 0;
}

// --- the long-lived connection ------------------------------------------------------------
// Resident end of a named pipe; the vchan end is a --relay child spawned in this same
// session by qrexec-agent (via qrexec-client-vm). All protocol state lives here.

#define NOTIFY_MAX_FRAME 0x1000000u   // MAX_MESSAGE_SIZE, server-enforced

static HANDLE g_pipe = INVALID_HANDLE_VALUE;
static HANDLE g_rdEvt = nullptr, g_wrEvt = nullptr;   // per-direction OVERLAPPED events
static HANDLE g_connStop = nullptr;                   // manual-reset: aborts in-flight pipe i/o
static HANDLE g_reader = nullptr;
static volatile LONG g_connDead = 1;

static HANDLE g_ackEvt = nullptr;                     // auto-reset; sends are sequential
static volatile ULONGLONG g_awaitSeq = 0;
static volatile LONG g_awaitOk = 0;                   // 1 acked, 0 failed

struct CorrEntry { uint64_t seq; uint32_t guestId; uint32_t dom0Id; ULONGLONG born; };
static CRITICAL_SECTION g_corrLock;
static std::vector<CorrEntry> g_corr;                 // small: capped, human-rate
static std::vector<uint32_t> g_pendingDismiss;        // guest ids queued by the reader thread

static void MarkConnDead() { InterlockedExchange(&g_connDead, 1); }

static BOOL PipeXfer(BOOL rd, void* buf, DWORD n, DWORD timeoutMs)
{
    BYTE* b = (BYTE*)buf; DWORD done = 0;
    HANDLE evt = rd ? g_rdEvt : g_wrEvt;
    while (done < n)
    {
        OVERLAPPED ov = {}; ov.hEvent = evt; ResetEvent(evt);
        BOOL ok = rd ? ReadFile(g_pipe, b + done, n - done, nullptr, &ov)
                     : WriteFile(g_pipe, b + done, n - done, nullptr, &ov);
        if (!ok && GetLastError() != ERROR_IO_PENDING) return FALSE;
        HANDLE hs[2] = { evt, g_connStop };
        DWORD w = WaitForMultipleObjects(2, hs, FALSE, timeoutMs);
        if (w != WAIT_OBJECT_0)
        {
            CancelIoEx(g_pipe, &ov);
            DWORD x; GetOverlappedResult(g_pipe, &ov, &x, TRUE);
            return FALSE;
        }
        DWORD got = 0;
        if (!GetOverlappedResult(g_pipe, &ov, &got, FALSE) || got == 0) return FALSE;
        done += got;
    }
    return TRUE;
}

static DWORD WINAPI ReaderThread(LPVOID)
{
    // DIAGNOSTIC guard (2026-09-05): this thread had NO exception handler, so any C++ throw
    // here (bad_alloc in the frame vector / pendingDismiss push_back / BLog's Utf8, ...) was
    // an instant std::terminate with no log line - a prime suspect for the silent vanish.
    // Catch, log DISTINCTLY, and fail open: conn marked dead -> the main loop restores
    // banners and reconnects. Body deliberately NOT re-indented (diagnostic diff minimalism).
    try
    {
    for (;;)
    {
        BYTE hdr[4];
        if (!PipeXfer(TRUE, hdr, 4, INFINITE)) { MarkConnDead(); return 0; }
        uint32_t len = GetU32(hdr);
        if (len < 4 || len > NOTIFY_MAX_FRAME) { BLog(L"reader: bad frame len %u", len); MarkConnDead(); return 0; }
        std::vector<BYTE> p(len);
        if (!PipeXfer(TRUE, p.data(), len, 15000)) { MarkConnDead(); return 0; }
        uint32_t tag = GetU32(p.data());
        if (tag == 0 && len >= 16)                    // Id{id u32, sequence u64}
        {
            uint32_t id = GetU32(p.data() + 4);
            uint64_t seq = GetU64(p.data() + 8);
            {
                CsGuard g(&g_corrLock);   // RAII: no lock leak if anything here throws (must-fix)
                for (auto& e : g_corr) if (e.seq == seq) { e.dom0Id = id; break; }
            }
            if (seq == g_awaitSeq) { g_awaitOk = 1; SetEvent(g_ackEvt); }
        }
        else if (tag == 1 || tag == 2)                // DBusError / UnknownError
        {
            BLog(L"reader: server error tag %u", tag);
            g_awaitOk = 0; SetEvent(g_ackEvt);        // sends are sequential: it is ours
        }
        else if (tag == 3 && len >= 12)               // Dismissed{id u32, reason u32}
        {
            uint32_t id = GetU32(p.data() + 4);
            uint32_t reason = GetU32(p.data() + 8);
            // freedesktop NotificationClosed reasons: 1=expired, 2=dismissed BY THE USER,
            // 3=CloseNotification call, 4=undefined. Only a deliberate user dismissal may
            // remove the guest's Notification Center record - a bubble that merely timed
            // out must leave the guest history intact, or the bridge silently destroys
            // the user's only remaining copy of the notification.
            {
                CsGuard g(&g_corrLock);   // RAII: pendingDismiss.push_back can throw - no lock leak (must-fix)
                for (size_t i = 0; i < g_corr.size(); i++)
                    if (g_corr[i].dom0Id == id && id != 0)
                    {
                        if (reason == 2 && g_corr[i].guestId)
                            g_pendingDismiss.push_back(g_corr[i].guestId);
                        g_corr.erase(g_corr.begin() + i);   // no further replies for this id either way
                        break;
                    }
            }
            if (reason != 2) BLog(L"Dismissed id=%u reason=%u (not user-dismissed - guest record kept)", id, reason);
        }
        else if (tag == 4)                            // ActionInvoked - phase 2 consumes this
            BLog(L"reader: ActionInvoked (ignored in A0)");
        else if (tag == 5)                            // ServerRestart
        {
            BLog(L"reader: ServerRestart - reconnecting");
            MarkConnDead(); return 0;
        }
    }
    }
    catch (...)
    {
        BLog(L"READER THREAD caught exception - marking conn dead");
        MarkConnDead();
    }
    return 0;
}

static void ConnDown()
{
    SetEvent(g_connStop);
    if (g_reader) { WaitForSingleObject(g_reader, 3000); CloseHandle(g_reader); g_reader = nullptr; }
    if (g_pipe != INVALID_HANDLE_VALUE) { CloseHandle(g_pipe); g_pipe = INVALID_HANDLE_VALUE; }
    ResetEvent(g_connStop);
    // Drop the correlation table: the proxy spawns a FRESH server per qrexec connection whose
    // guest-facing id space restarts (first id is deterministically 2), so a stale entry would
    // collide with a new dom0 id after reconnect and a Dismissed{id} could RemoveNotification the
    // WRONG guest toast. Sequence numbers are ours and monotonic, but dom0 ids are per-connection.
    {
        CsGuard g(&g_corrLock);   // RAII (must-fix)
        g_corr.clear();
        g_pendingDismiss.clear();
    }
    MarkConnDead();
}

static bool ConnUp()
{
    LARGE_INTEGER pc; QueryPerformanceCounter(&pc);
    wchar_t pipeName[128];
    swprintf(pipeName, RTL_NUMBER_OF(pipeName), L"\\\\.\\pipe\\qubes-toast-bridge-%08lx%08lx",
             GetCurrentProcessId(), (ULONG)(pc.QuadPart & 0xFFFFFFFF));
    g_pipe = CreateNamedPipeW(pipeName,
        PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT, 1, 64 * 1024, 64 * 1024, 0, nullptr);
    if (g_pipe == INVALID_HANDLE_VALUE) { BLog(L"CreateNamedPipe failed %lu", GetLastError()); return false; }

    // Arm the connect BEFORE spawning the relay so its CreateFile cannot race us.
    OVERLAPPED ov = {}; ov.hEvent = g_rdEvt; ResetEvent(g_rdEvt);
    BOOL c = ConnectNamedPipe(g_pipe, &ov);
    DWORD ce = c ? ERROR_PIPE_CONNECTED : GetLastError();
    if (ce != ERROR_IO_PENDING && ce != ERROR_PIPE_CONNECTED)
    { BLog(L"ConnectNamedPipe failed %lu", ce); ConnDown(); return false; }
    // Every failure return below MUST drain the pending connect first: `ov` is stack-local,
    // and closing the pipe only *starts* an async cancel - returning while the kernel still
    // owns the OVERLAPPED corrupts this frame.
    auto abortConnect = [&]() {
        CancelIoEx(g_pipe, &ov);
        DWORD x; GetOverlappedResult(g_pipe, &ov, &x, TRUE);
    };

    // qrexec-client-vm hands the relay command line to qrexec-agent (it does NOT wire our
    // stdio); the agent spawns "<self> --relay <pipe>" in the interactive session with its
    // stdio on the data vchan. Field-splitting is on RAW '|' - never quote the whole string
    // (see NotifyClient.cs / qrexec-client-vm-arg-quoting); quotes inside field 4 are fine.
    wchar_t self[MAX_PATH] = { 0 };
    GetModuleFileNameW(nullptr, self, RTL_NUMBER_OF(self));
    std::wstring dir(self);
    size_t sl = dir.find_last_of(L'\\');
    std::wstring qcv = (sl == std::wstring::npos ? L"" : dir.substr(0, sl + 1)) + L"qrexec-client-vm.exe";
    if (GetFileAttributesW(qcv.c_str()) == INVALID_FILE_ATTRIBUTES)
        qcv = L"C:\\Program Files\\Qubes Tools\\bin\\qrexec-client-vm.exe";
    wchar_t user[64] = L"user"; DWORD ul = RTL_NUMBER_OF(user);
    GetUserNameW(user, &ul);
    wchar_t cmd[1024];
    swprintf(cmd, RTL_NUMBER_OF(cmd), L"\"%s\" @default|qubes.Notifications|%s|\"%s\" --relay %s",
             qcv.c_str(), user, self, pipeName);
    STARTUPINFOW si = { sizeof(si) }; PROCESS_INFORMATION pi = {};
    if (!CreateProcessW(nullptr, cmd, nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi))
    { BLog(L"CreateProcess(qrexec-client-vm) failed %lu", GetLastError()); abortConnect(); ConnDown(); return false; }
    CloseHandle(pi.hThread);
    WaitForSingleObject(pi.hProcess, 10000);
    DWORD ec = 1; GetExitCodeProcess(pi.hProcess, &ec);
    CloseHandle(pi.hProcess);
    if (ec != 0) { BLog(L"qrexec-client-vm exited %lu", ec); abortConnect(); ConnDown(); return false; }

    if (ce == ERROR_IO_PENDING)
    {
        // A dom0 policy refusal is invisible here (exit 0 above means "handed to the agent"
        // only) - the relay then never connects and this wait is the failure detector.
        HANDLE hs[2] = { g_rdEvt, g_connStop };
        if (WaitForMultipleObjects(2, hs, FALSE, 15000) != WAIT_OBJECT_0)
        { BLog(L"relay never connected (policy refusal? no session?)"); abortConnect(); ConnDown(); return false; }
        DWORD x;
        if (!GetOverlappedResult(g_pipe, &ov, &x, FALSE) && GetLastError() != ERROR_PIPE_CONNECTED)
        { BLog(L"pipe connect completion failed %lu", GetLastError()); ConnDown(); return false; }
    }

    // Handshake: the server speaks first (u32 LE version), we echo major + min(minor, ours=0).
    // wait-for-session can hold this until a dom0 GUI session exists - generous timeout.
    BYTE v[4];
    if (!PipeXfer(TRUE, v, 4, 30000)) { BLog(L"handshake: no server version"); ConnDown(); return false; }
    uint32_t sv = GetU32(v);
    if ((sv >> 16) != 1) { BLog(L"handshake: server major %u (want 1)", sv >> 16); ConnDown(); return false; }
    std::vector<BYTE> rep; PutU32(rep, 1u << 16);
    if (!PipeXfer(FALSE, rep.data(), 4, 10000)) { BLog(L"handshake: reply write failed"); ConnDown(); return false; }

    InterlockedExchange(&g_connDead, 0);
    g_reader = CreateThread(nullptr, 0, ReaderThread, nullptr, 0, nullptr);
    if (!g_reader) { ConnDown(); return false; }
    BLog(L"connected (server version %u.%u)", sv >> 16, sv & 0xFFFF);
    return true;
}

static uint64_t g_seq = 0;

// One notification over the held connection, ack-waited (politeness: sequential sends, the
// dom0 side is deliberately unlimited and must not be flooded). guestId 0 = not correlatable
// (coalesced burst) - dismissal for it is a no-op.
// P3a instrumentation: the full send -> dom0-ack round-trip is timed and logged on every
// exit path
//   FWD_RTT guest_id=%u seq=%llu ms=%llu ok=%d   (1 acked, 0 server-rejected,
//                                                 -1 write failed, -2 ack timeout)
// so the Phase-3 deferred-map hold budget (design 3.3, the ~250 ms hypothesis) is sized from
// measured dom0 latency, not guessed. QPC-based: GetTickCount64's ~16 ms grain would round a
// fast ack down to 0.
static bool ForwardText(std::wstring const& title, std::wstring const& body, uint32_t guestId)
{
    if (g_connDead) return false;
    uint64_t seq = ++g_seq;
    LARGE_INTEGER qf, q0, q1;
    QueryPerformanceFrequency(&qf); QueryPerformanceCounter(&q0);
    auto rtt = [&](int ok) {
        QueryPerformanceCounter(&q1);
        BLog(L"FWD_RTT guest_id=%u seq=%llu ms=%llu ok=%d", guestId, (ULONGLONG)seq,
             (ULONGLONG)((q1.QuadPart - q0.QuadPart) * 1000 / (qf.QuadPart ? qf.QuadPart : 1)), ok);
    };
    {
        CsGuard g(&g_corrLock);   // RAII: g_corr.push_back can throw - the still-live AgentGone
                                  // leak-on-throw this closes (must-fix)
        g_corr.push_back({ seq, guestId, 0, GetTickCount64() });
        while (g_corr.size() > 256) g_corr.erase(g_corr.begin());
    }

    auto frame = EncodeNotifyFrame(seq, Utf8(title.empty() ? L"Notification" : title), Utf8(body));
    g_awaitSeq = seq; g_awaitOk = 0; ResetEvent(g_ackEvt);
    if (!PipeXfer(FALSE, frame.data(), (DWORD)frame.size(), 15000)) { rtt(-1); MarkConnDead(); return false; }
    if (WaitForSingleObject(g_ackEvt, 15000) != WAIT_OBJECT_0)
    { rtt(-2); BLog(L"send seq=%llu: ack timeout", (ULONGLONG)seq); MarkConnDead(); return false; }
    rtt(g_awaitOk == 1 ? 1 : 0);
    return g_awaitOk == 1;
}

// --- bridge main --------------------------------------------------------------------------

static int BridgeMain()
{
    SetUnhandledExceptionFilter(BridgeCrashFilter);   // crash breadcrumb (see BridgeCrashFilter)
    HANDLE mtx = CreateMutexW(nullptr, FALSE, L"Local\\QubesToastBridgeSingleton");
    if (mtx) { DWORD w = WaitForSingleObject(mtx, 0); if (w != WAIT_OBJECT_0 && w != WAIT_ABANDONED) return 0; }
    ProcessIdToSessionId(GetCurrentProcessId(), &g_mySession);

    InitializeCriticalSection(&g_corrLock);
    g_rdEvt = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_wrEvt = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_connStop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_ackEvt = CreateEventW(nullptr, FALSE, FALSE, nullptr);

    std::wstring stopf = StateDir() + L"\\stop";
    DeleteFileW(stopf.c_str());       // a stale stop request must not kill a fresh start
    std::wstring hbf = StateDir() + L"\\heartbeat";
    // Crash leftovers from a previous instance are POSITIVE evidence of a suppression gap:
    // ShowBanner=0 stood through the supervision gap, so a toast from one of these AUMIDs that
    // fired in the gap showed no banner and was forwarded by nobody. Capture the AUMIDs before
    // the markers are discarded; the baseline below leaves those apps' center toasts UNSEEN so
    // the normal poll forwards them (a duplicate in dom0 for a pre-gap toast is the accepted
    // price - silent loss would break the fail-open invariant).
    std::vector<std::wstring> gapAumids;
    BannerRestoreAll(&gapAumids);

    init_apartment(apartment_type::multi_threaded);
    EnsureConsent();
    UserNotificationListener listener{ nullptr };
    try {
        listener = UserNotificationListener::Current();
        auto st = listener.RequestAccessAsync().get();
        if (st != UserNotificationListenerAccessStatus::Allowed)
        { BLog(L"FATAL access=%d - window path preserved, exiting", (int)st); return 2; }
    } catch (...) { BLog(L"FATAL listener init threw"); return 3; }

    auto allow = ReadAllowlist();
    {
        std::wstring joined;
        for (auto const& a : allow) { if (!joined.empty()) joined += L";"; joined += a; }
        BLog(L"BRIDGE armed allow=[%s]", joined.c_str());
    }

    // P3-ETW push tier (MEASURE-ONLY, shadow-only): the bridge runs NO ETW code - this
    // spawns the IPC client that mirrors the --etw-proxy's pushed records into the ring,
    // then the off-thread shadow worker + WAL watcher that run the acquisition ladder.
    // Placed AFTER the FATAL-exit paths above (so the Stop calls below always pair) and
    // after bridge.log is warm (BLog's static path init has run single-threaded). Every
    // failure degrades the ladder toward the window floor; none of it can block this loop
    // or feed failStreak/FATAL.
    EtwTierStart();
    ShadowWorkerStart();

    // PUSH over POLL (owner directive): toast DETECTION is event-driven. NotificationChanged
    // fires on every center change; the expensive GetNotificationsAsync listing then runs
    // only when signaled - plus a bounded 30 s FLOOR pass so a missed/dropped event can
    // never LOSE a toast (the push source is unproven per-build; the floor is the safety
    // net, not the mechanism - "retire the tight poll, not fail-open"). The loop still
    // WAKES every 2 s regardless: that cadence is the supervisor-heartbeat contract (15 s
    // stale deadline) plus the stop-file/dismissal/reconnect duties, all fixed-cost. What
    // is retired is the per-2s WinRT listing, not the wake.
    HANDLE toastEvt = CreateEventW(nullptr, FALSE, TRUE, nullptr);   // auto-reset; starts
                                                                     // signaled so the first
                                                                     // pass lists (baseline/prime)
    bool pushArmed = false;
    winrt::event_token changedTok{};
    if (toastEvt)
    {
        try
        {
            changedTok = listener.NotificationChanged(
                [toastEvt](UserNotificationListener const&, auto const&)
                { SetEvent(toastEvt); });
            pushArmed = true;
            BLog(L"PUSH NotificationChanged armed - listing runs on signal + 30 s floor");
        }
        catch (...)
        {
            BLog(L"PUSH NotificationChanged unavailable - keeping the 2 s listing floor");
        }
    }
    const DWORD kFloorMs = pushArmed ? 30000 : 2000;
    ULONGLONG nextFloorList = 0;                       // 0: first pass always lists
    bool toastSignaled = true;

    // baseline: everything already in the center predates us - never forwarded. If the FIRST read
    // throws we must NOT proceed with an empty set (that would forward the whole backlog to dom0);
    // `primed` gates forwarding until a poll has successfully seeded `seen`.
    // EXCEPTION: a toast from a suppression-gap AUMID (leftover marker above) may itself BE a gap
    // toast - already bannerless - so it is left out of the baseline and forwarded like a fresh one.
    auto inGap = [&](UserNotification const& un) -> bool {
        if (gapAumids.empty()) return false;
        std::wstring aumid;
        try { aumid = un.AppInfo().AppUserModelId().c_str(); } catch (...) {}
        if (aumid.empty()) return false;
        for (auto const& g : gapAumids) if (_wcsicmp(g.c_str(), aumid.c_str()) == 0) return true;
        return false;
    };
    std::unordered_set<uint32_t> seen;
    bool primed = false;
    try {
        for (auto const& un : listener.GetNotificationsAsync(NotificationKinds::Toast).get())
        {
            if (inGap(un)) { BLog(L"baseline: id=%u left unseen (suppression-gap AUMID)", un.Id()); continue; }
            seen.insert(un.Id());
        }
        primed = true;
    } catch (...) { BLog(L"baseline read failed - will prime on the first good poll, forwarding nothing until then"); }

    bool connected = false;                        // a connection is up (banners may be suppressed)
    std::unordered_set<std::wstring> suppressed;   // AUMIDs whose banner is currently ShowBanner=0
    // Per-toast-id count of forward attempts REJECTED BY A LIVE SERVER (reply tag 1/2: ForwardText
    // returns false without marking the connection dead). Such a rejection is deterministic - the
    // center record persists, so unbounded retry would resend at 0.5 Hz forever. Transient failures
    // (write error, ack timeout, disconnect) kill the connection and are NOT counted; that
    // fail-open retry path stays unlimited. At the cap the id is given up: marked seen + logged
    // (its guest Notification Center record remains the surviving copy).
    std::unordered_map<uint32_t, int> fwdFails;
    const int kFwdFailCap = 5;
    int failStreak = 0, backoff = 0;
    ULONGLONG nextReconnect = 0, nextConsent = 0;
    int rc = 0;

    for (;;)
    {
        // DIAGNOSTIC guard (2026-09-05) around the WHOLE iteration - AgentGone/heartbeat/
        // conn-maintenance/consent included, not just the inner poll try: a C++ throw outside
        // that inner try had no handler and killed the process silently. Log DISTINCTLY and
        // keep running (fail-open); an SEH fault still falls to BridgeCrashFilter instead
        // (/EHsc: catch(...) sees C++ throws only). Body deliberately NOT re-indented.
        try
        {
        ULONGLONG now = GetTickCount64();
        if (AgentGone()) { BLog(L"agent gone"); break; }
        if (WTSGetActiveConsoleSessionId() != g_mySession) { BLog(L"session changed"); break; }
        if (GetFileAttributesW(stopf.c_str()) != INVALID_FILE_ATTRIBUTES) { BLog(L"stop requested"); break; }

        // heartbeat for the agent supervisor (mtime is the liveness signal)
        {
            HANDLE f = CreateFileW(hbf.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                                   CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
            if (f != INVALID_HANDLE_VALUE)
            {
                char t[32]; int n = sprintf_s(t, "%llu\n", now);
                DWORD wr; WriteFile(f, t, (DWORD)n, &wr, nullptr);
                CloseHandle(f);
            }
        }

        // connection maintenance. Down => every suppression RESTORED (fail-open: allowlisted apps
        // take the window path while dom0 is unreachable) and re-suppression is EARNED again by a
        // fresh successful forward. Suppression is never applied eagerly on connect - only lazily,
        // after a forward proves the path works (see below).
        if (g_connDead)
        {
            ConnDown();   // reap the reader/pipe of a connection that died mid-flight
            if (connected || !suppressed.empty())
            {
                BannerRestoreAll(); suppressed.clear(); connected = false;
                BLog(L"connection down - banners restored, suppression cleared");
            }
            if (!allow.empty() && now >= nextReconnect)
            {
                // A fresh connection must trigger an immediate listing pass: toasts left
                // deliberately unseen while disconnected (fail-open retry) forward NOW,
                // not at the next NotificationChanged / 30 s floor.
                if (ConnUp()) { backoff = 0; connected = true; toastSignaled = true; }
                else
                {
                    static const DWORD bo[] = { 5000, 15000, 60000, 300000 };
                    nextReconnect = GetTickCount64() + bo[backoff < 3 ? backoff : 3];
                    backoff++;
                }
            }
        }

        // consent can be revoked from Settings at any time; the APIs then return empty
        // SILENTLY - poll the status and fail open loudly instead of forwarding vacuum.
        if (now >= nextConsent)
        {
            nextConsent = now + 60000;
            try {
                if (listener.GetAccessStatus() != UserNotificationListenerAccessStatus::Allowed)
                { BLog(L"FATAL consent revoked - restoring banners, exiting"); rc = 2; break; }
            } catch (...) {}
        }

        // toast listing: push-gated (NotificationChanged) with the bounded floor pass.
        // Body deliberately NOT re-indented (diff minimalism, the file's guard precedent).
        bool doList = !pushArmed || toastSignaled || now >= nextFloorList;
        if (doList)
        {
        nextFloorList = now + kFloorMs;
        toastSignaled = false;
        try
        {
            auto list = listener.GetNotificationsAsync(NotificationKinds::Toast).get();
            failStreak = 0;
            // First good poll after a failed baseline: seed `seen` with the whole current center
            // and forward NOTHING this pass (the backlog predates us). This is the legacy `primed`
            // guard, mirrored, so a failed baseline can never replay the backlog to dom0.
            // Suppression-gap AUMIDs are excepted, exactly as in the startup baseline.
            if (!primed)
            {
                for (auto const& un : list)
                {
                    if (inGap(un)) { BLog(L"prime: id=%u left unseen (suppression-gap AUMID)", un.Id()); continue; }
                    seen.insert(un.Id());
                }
                primed = true;
                BLog(L"primed on a good poll (%u pre-existing) - forwarding starts now", (UINT)seen.size());
            }
            else
            {
                struct NewToast { uint32_t id; std::wstring aumid, app, title, body; };
                std::vector<NewToast> fresh;
                for (auto const& un : list)
                {
                    uint32_t id = un.Id();
                    if (seen.count(id)) continue;
                    std::wstring aumid, app;
                    try { aumid = un.AppInfo().AppUserModelId().c_str(); } catch (...) {}
                    try { app = un.AppInfo().DisplayInfo().DisplayName().c_str(); } catch (...) {}
                    // P3a shadow probe: capture + ENQUEUE every new toast (skip and forward
                    // branches alike) BEFORE the unchanged A0 routing below. MEASURE-ONLY
                    // and now FIXED-COST on this thread: the acquisition ladder (ETW ring,
                    // then WpnCorrelate's WAL-paced retry) runs on the shadow worker, and
                    // the CLASSIFY line lands asynchronously. Dedupes internally so a
                    // retried allowlisted toast logs exactly once.
                    ShadowClassify(un, id, aumid);
                    bool listed = false;
                    for (auto const& a : allow) if (_wcsicmp(a.c_str(), aumid.c_str()) == 0) { listed = true; break; }
#if defined(P3AQ_DEFECT_ROUTE)
                    // DEFECT (seen-to-fail, autonomy rule 5): acquisition state gates the
                    // A0 routing. The routing-invariance detector (identical SENT/skip
                    // sequences for the same fixtures with the proxy up vs absent) must
                    // FAIL on this build or it is decoration.
                    if (g_etw.state != ETW_STATE_LIVE) listed = false;
#endif
                    if (!listed) { seen.insert(id); BLog(L"skip id=%u aumid=%s (window path)", id, aumid.c_str()); continue; }
                    // allowlisted: DEFER marking seen until a forward succeeds, so a failed/absent
                    // forward is retried and never silently drops a toast (P.2 fail-open invariant).
                    auto tb = FirstTexts(un);
                    size_t sep = tb.find(L'\x1f');
                    fresh.push_back({ id, aumid, app, tb.substr(0, sep),
                                      sep == std::wstring::npos ? L"" : tb.substr(sep + 1) });
                }
                // prune failure counters for ids no longer pending (forwarded, given up, or gone
                // from the center) - keeps `fwdFails` no larger than `fresh` across polls
                if (!fwdFails.empty())
                {
                    std::unordered_set<uint32_t> pending;
                    for (auto const& e : fresh) pending.insert(e.id);
                    for (auto it = fwdFails.begin(); it != fwdFails.end(); )
                    { if (pending.count(it->first)) ++it; else it = fwdFails.erase(it); }
                }
                // A rejection from a LIVE server (false + connection still up) is deterministic:
                // count it, and at the cap stop resending that id (see fwdFails above).
                auto capFailed = [&](uint32_t id) {
                    if (g_connDead) return;   // transient path: unlimited fail-open retry
                    if (++fwdFails[id] >= kFwdFailCap)
                    {
                        seen.insert(id); fwdFails.erase(id);
                        BLog(L"GIVE UP id=%u after %d server rejections - not resent (guest center record kept)",
                             id, kFwdFailCap);
                    }
                };
                // Lazy suppression: an allowlisted app is banner-suppressed ONLY after one of its
                // toasts forwards successfully. So the first toast per app double-shows (guest
                // banner + dom0), and a bridge that never forwards never suppresses - fail-open.
                auto suppressNow = [&](std::wstring const& aumid) {
                    if (!aumid.empty() && suppressed.insert(aumid).second) BannerApplyOne(aumid);
                };
                if (fresh.empty() || g_connDead)
                {
                    if (!fresh.empty())
                        BLog(L"%u allowlisted toast(s) while disconnected - left on the window path (unseen, retried)", (UINT)fresh.size());
                    // leave `fresh` UNSEEN so they forward once the connection returns
                }
                else if (fresh.size() > 3)
                {
                    // coalesce a burst into one dom0 notification (politeness rule). guestId 0 =>
                    // no dismiss-sync for coalesced items (documented A0 limit).
                    std::wstring lines;
                    for (auto const& e : fresh) { if (!lines.empty()) lines += L"\n"; lines += e.title + L": " + e.body; }
                    wchar_t sum[256];
                    swprintf(sum, RTL_NUMBER_OF(sum), L"%u notifications (%s)", (UINT)fresh.size(), fresh[0].app.c_str());
                    bool ok = ForwardText(sum, lines, 0);
                    if (ok) for (auto const& e : fresh) { seen.insert(e.id); suppressNow(e.aumid); fwdFails.erase(e.id); }
                    else for (auto const& e : fresh) capFailed(e.id);
                    BLog(L"SENT coalesced x%u: %s%s", (UINT)fresh.size(), ok ? L"OK" : L"FAIL",
                         ok ? L"" : L" (unseen, retried)");
                }
                else for (auto const& e : fresh)
                {
                    bool ok = ForwardText(e.title, e.body.empty() ? e.app : e.body, e.id);
                    if (ok) { seen.insert(e.id); suppressNow(e.aumid); fwdFails.erase(e.id); }
                    else capFailed(e.id);
                    BLog(L"SENT id=%u app='%s' title='%s': %s%s", e.id, e.app.c_str(), e.title.c_str(),
                         ok ? L"OK" : L"FAIL", ok ? L"" : L" (unseen, retried)");
                }
            }
            // bound the seen-set: INTERSECT with what is still in the center. A plain rebuild
            // from the center would re-mark ids deliberately left unseen for the fail-open
            // retry (silently cancelling it); intersection only ever DROPS ids that left the
            // center, so retry candidates stay unseen and the bound still holds (the result
            // is no larger than the center listing).
            if (seen.size() > 500)
            {
                std::unordered_set<uint32_t> keep;
                for (auto const& un : list)
                { uint32_t id = un.Id(); if (seen.count(id)) keep.insert(id); }
                seen.swap(keep);
            }
        }
        catch (...)
        {
            failStreak++;
            BLog(L"poll error (%d)", failStreak);
            if (failStreak >= 30) { BLog(L"FATAL 30 consecutive poll errors"); rc = 3; break; }
        }
        }   // doList

        // dom0 dismissals queued by the reader: keep the guest Notification Center in sync
        {
            std::vector<uint32_t> dis;
            {
                CsGuard g(&g_corrLock);   // RAII (must-fix)
                dis.swap(g_pendingDismiss);
            }
            for (uint32_t id : dis)
            {
                try { listener.RemoveNotification(id); BLog(L"dom0 dismissed -> RemoveNotification(%u)", id); }
                catch (...) { BLog(L"RemoveNotification(%u) failed", id); }
            }
        }

        // 2 s wake (heartbeat/stop/dismissal cadence), returning EARLY on a toast push -
        // detection latency is now event-bound, not poll-bound, while the wake cadence
        // the supervisor heartbeat depends on is unchanged.
        toastSignaled = toastEvt
            ? (WaitForSingleObject(toastEvt, 2000) == WAIT_OBJECT_0)
            : (Sleep(2000), false);
        }
        catch (...)
        {
            BLog(L"MAIN LOOP caught exception (continuing)");
            Sleep(2000);   // keep the normal loop pace: a hot rethrow must not spin CPU/log
            continue;
        }
    }

    if (pushArmed) { try { listener.NotificationChanged(changedTok); } catch (...) {} }
    if (toastEvt) CloseHandle(toastEvt);
    ShadowWorkerStop();   // bounded joins (worker + WAL watcher)
    EtwTierStop();        // bounded join of the IPC client; no kernel session to reap -
                          // the ETW session belongs to the SYSTEM agent (etwproxy.c) now

    // Restore unconditionally: any marker this (or a crashed prior) instance wrote must be undone
    // on every exit path, whether or not we think a suppression is currently standing.
    BannerRestoreAll();
    ConnDown();
    DeleteFileW(stopf.c_str());
    DeleteFileW(hbf.c_str());        // dead bridge must read as dead, not as freshly alive
    BLog(L"BRIDGE stopped (rc=%d)", rc);
    return rc;
}

// --- relay mode ---------------------------------------------------------------------------
// stdio = the data vchan (we are the qrexec local endpoint); splice it to the resident
// bridge's named pipe. Exit when either direction closes - process exit closes our ends,
// which the counterpart notices as EOF/broken pipe.

// One direction of the splice. The PIPE handle is opened OVERLAPPED (see RelayMain) and is
// used concurrently by BOTH pumps (one reads it, one writes it) - so every pipe op must be
// overlapped with its OWN event, or the two directions serialize on the file object and the
// server-speaks-first handshake self-deadlocks (t2's parked ReadFile(pipe) would block t1's
// WriteFile(pipe) that must deliver the very bytes t2 is waiting for). The std handle end is
// synchronous: each std handle is touched by exactly one pump, one direction, so it never
// contends. `pipeIsSrc` says which side is the overlapped pipe.
struct RelayDir { HANDLE src, dst; BOOL pipeIsSrc; HANDLE evt; };

static BOOL RelayOne(BOOL doRead, HANDLE h, BOOL overlapped, HANDLE evt,
                     BYTE* buf, DWORD n, DWORD* done)
{
    if (!overlapped)
        return doRead ? ReadFile(h, buf, n, done, nullptr) : WriteFile(h, buf, n, done, nullptr);
    OVERLAPPED ov = {}; ov.hEvent = evt; ResetEvent(evt);   // byte pipe: Offset fields ignored
    BOOL ok = doRead ? ReadFile(h, buf, n, nullptr, &ov) : WriteFile(h, buf, n, nullptr, &ov);
    if (!ok && GetLastError() != ERROR_IO_PENDING) return FALSE;
    return GetOverlappedResult(h, &ov, done, TRUE);
}

static DWORD WINAPI RelayPump(LPVOID p)
{
    RelayDir* d = (RelayDir*)p;
    BYTE buf[16384]; DWORD n, wr;
    for (;;)
    {
        if (!RelayOne(TRUE, d->src, d->pipeIsSrc, d->evt, buf, sizeof(buf), &n) || n == 0) return 0;
        DWORD off = 0;
        while (off < n)
        {
            if (!RelayOne(FALSE, d->dst, !d->pipeIsSrc, d->evt, buf + off, n - off, &wr) || wr == 0) return 0;
            off += wr;
        }
    }
}

static int RelayMain(const wchar_t* pipeName)
{
    // OVERLAPPED so the two directions do not serialize on the one duplex handle (nMaxInstances=1
    // + FILE_FLAG_FIRST_PIPE_INSTANCE on the resident side rule out a second handle).
    HANDLE pipe = CreateFileW(pipeName, GENERIC_READ | GENERIC_WRITE, 0, nullptr,
                              OPEN_EXISTING, FILE_FLAG_OVERLAPPED, nullptr);
    if (pipe == INVALID_HANDLE_VALUE) return 1;
    HANDLE eA = CreateEventW(nullptr, TRUE, FALSE, nullptr);   // pump A's pipe-write event
    HANDLE eB = CreateEventW(nullptr, TRUE, FALSE, nullptr);   // pump B's pipe-read event
    if (!eA || !eB) return 1;
    RelayDir in2pipe = { GetStdHandle(STD_INPUT_HANDLE), pipe, FALSE, eA };   // dom0 -> resident (write pipe)
    RelayDir pipe2out = { pipe, GetStdHandle(STD_OUTPUT_HANDLE), TRUE, eB };  // resident -> dom0 (read pipe)
    HANDLE t1 = CreateThread(nullptr, 0, RelayPump, &in2pipe, 0, nullptr);
    HANDLE t2 = CreateThread(nullptr, 0, RelayPump, &pipe2out, 0, nullptr);
    if (!t1 || !t2) return 1;
    HANDLE ts[2] = { t1, t2 };
    // Either direction closing (EOF/broken pipe) ends the splice. CancelIoEx then unblocks the
    // OTHER pump if it is parked in an overlapped read/write on the pipe, so it does not hang;
    // the pump parked on a std handle instead is reclaimed by process exit (this is the top of
    // the relay process). Bounded join so a stuck pump can never wedge the exit.
    WaitForMultipleObjects(2, ts, FALSE, INFINITE);
    CancelIoEx(pipe, nullptr);
    WaitForMultipleObjects(2, ts, TRUE, 2000);
    CloseHandle(t1); CloseHandle(t2);
    CloseHandle(eA); CloseHandle(eB);
    CloseHandle(pipe);
    return 0;
}

// --- allowlist authoring aid --------------------------------------------------------------

static int DumpMain()
{
    init_apartment(apartment_type::multi_threaded);
    EnsureConsent();
    try {
        auto listener = UserNotificationListener::Current();
        if (listener.RequestAccessAsync().get() != UserNotificationListenerAccessStatus::Allowed)
        { wprintf(L"access denied\n"); return 2; }
        for (auto const& un : listener.GetNotificationsAsync(NotificationKinds::Toast).get())
        {
            std::wstring aumid, app;
            try { aumid = un.AppInfo().AppUserModelId().c_str(); } catch (...) {}
            try { app = un.AppInfo().DisplayInfo().DisplayName().c_str(); } catch (...) {}
            auto tb = FirstTexts(un);
            wprintf(L"id=%u aumid=%s app=%s title=%s\n", un.Id(), aumid.c_str(), app.c_str(),
                    tb.substr(0, tb.find(L'\x1f')).c_str());
        }
    } catch (...) { wprintf(L"listener error\n"); return 3; }
    return 0;
}

// ==========================================================================================

int wmain(int argc, wchar_t** argv)
{
    SetUnhandledExceptionFilter(BridgeCrashFilter);   // every mode: crash leaves a breadcrumb
    const wchar_t* relayPipe = nullptr;
    const wchar_t* clientSid = nullptr;
    bool bridge = false, dump = false, stop = false, restore = false, dumpdb = false, dumpetw = false;
    bool etwproxy = false;
    int dumpdbN = 20, dumpEtwSecs = 30;
    for (int i = 1; i < argc; i++)
    {
        if (_wcsicmp(argv[i], L"--agent-pid") == 0 && i + 1 < argc)
        {
            DWORD pid = (DWORD)_wtoi64(argv[++i]);
            // The handle open normally FAILS (SYSTEM agent vs limited token) - keep the PID
            // for AgentGone()'s snapshot fallback either way.
            if (pid) { g_agentPid = pid; g_agent = OpenProcess(SYNCHRONIZE, FALSE, pid); }
        }
        else if (_wcsicmp(argv[i], L"--relay") == 0 && i + 1 < argc) relayPipe = argv[++i];
        else if (_wcsicmp(argv[i], L"--bridge") == 0) bridge = true;
        else if (_wcsicmp(argv[i], L"--bridge-stop") == 0) stop = true;
        else if (_wcsicmp(argv[i], L"--restore-banners") == 0) restore = true;
        else if (_wcsicmp(argv[i], L"--dump-aumids") == 0) dump = true;
        else if (_wcsicmp(argv[i], L"--dump-wpndb") == 0)
        {
            dumpdb = true;
            if (i + 1 < argc && argv[i + 1][0] >= L'0' && argv[i + 1][0] <= L'9')
                dumpdbN = _wtoi(argv[++i]);
        }
        else if (_wcsicmp(argv[i], L"--dump-etw") == 0)
        {
            dumpetw = true;
            if (i + 1 < argc && argv[i + 1][0] >= L'0' && argv[i + 1][0] <= L'9')
                dumpEtwSecs = _wtoi(argv[++i]);
        }
        else if (_wcsicmp(argv[i], L"--etw-proxy") == 0) etwproxy = true;
        else if (_wcsicmp(argv[i], L"--client-sid") == 0 && i + 1 < argc) clientSid = argv[++i];
    }
    if (etwproxy) return EtwProxyMain(clientSid);
    if (relayPipe) return RelayMain(relayPipe);
    if (dumpdb) return DumpWpnDbMain(dumpdbN);
    if (dumpetw) return DumpEtwMain(dumpEtwSecs);
    if (stop)
    {
        std::wstring f = StateDir() + L"\\stop";
        HANDLE h = CreateFileW(f.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                               FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h != INVALID_HANDLE_VALUE) { DWORD wr; WriteFile(h, "stop", 4, &wr, nullptr); CloseHandle(h); }
        return 0;
    }
    if (restore)
    {
        // One-shot restorer of last resort: undo every ShowBanner suppression this user's
        // markers record and exit. Launched by the agent (in the user session - markers are
        // SID-scoped HKCU state) when the bridge gate is OFF and a crashed bridge may have
        // left markers behind: with the gate off no bridge will ever start to run its own
        // startup BannerRestoreAll, so without this pass those apps stay bannerless forever.
        // Registry/file work only - no COM, no listener consent needed.
        BLog(L"RESTORE one-shot (--restore-banners)");
        BannerRestoreAll();
        return 0;
    }
    if (dump) return DumpMain();
    if (bridge) return BridgeMain();

    // ---- legacy in-guest toast interceptor (default mode) ----
    // single instance per session
    HANDLE mtx = CreateMutexW(nullptr, FALSE, L"Local\\QubesNotifHostSingleton");
    if (mtx) { DWORD w = WaitForSingleObject(mtx, 0); if (w != WAIT_OBJECT_0 && w != WAIT_ABANDONED) return 0; }
    ProcessIdToSessionId(GetCurrentProcessId(), &g_mySession);

    init_apartment(apartment_type::multi_threaded);
    UserNotificationListener listener{ nullptr };
    try {
        listener = UserNotificationListener::Current();
        auto st = listener.RequestAccessAsync().get();
        if (st != UserNotificationListenerAccessStatus::Allowed) return 2;
    } catch (...) { return 3; }

    std::unordered_set<uint32_t> seen;
    bool primed = false;
    ULONGLONG nextPoll = 0;
    MSG msg;
    for (;;) {
        // exit conditions
        if (AgentGone()) break;
        if (WTSGetActiveConsoleSessionId() != g_mySession) break;

        ULONGLONG now = GetTickCount64();
        if (now >= nextPoll) {
            nextPoll = now + 800;
            try {
                auto list = listener.GetNotificationsAsync(NotificationKinds::Toast).get();
                for (auto const& un : list) {
                    uint32_t id = un.Id();
                    if (seen.insert(id).second && primed) {   // only NEW toasts after priming
                        auto tb = FirstTexts(un);
                        auto sep = tb.find(L'\x1f');
                        ShowToast(tb.substr(0, sep), sep == std::wstring::npos ? L"" : tb.substr(sep + 1));
                    }
                }
                primed = true;   // first pass seeds `seen` with pre-existing toasts (no backlog spam)
            } catch (...) {}
        }
        // auto-expire windows
        for (auto* tw : std::vector<ToastWin*>(g_wins.begin(), g_wins.end()))
            if (now >= tw->dieAt && IsWindow(tw->hwnd)) DestroyWindow(tw->hwnd);
        // pump
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        MsgWaitForMultipleObjects(0, nullptr, FALSE, 200, QS_ALLINPUT);
    }
    return 0;
}
