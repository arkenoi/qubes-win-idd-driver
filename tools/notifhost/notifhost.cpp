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
// banner is never mapped into dom0 - the AGENT holds each toast's banner window until this
// bridge's per-notification record says bridge/window (docs/ADR-toasts.md 10, the --hold
// IPC in agent/gui-agent/toastident.h; the per-AUMID ShowBanner=0 write is retired,
// only the sweep that undoes an older version's markers remains). dom0 dismissal is echoed
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
// --resolve-activator <AUMID> / --invoke-activator <AUMID> [<arguments>]: the actionable-buttons
// route's in-guest instruments (ADR-toasts 11) - what toast activator the bridge resolves for a
// sender, and the COM activation a dom0 click performs, run by hand (see their definitions).
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
// --etw-proxy: MOVED OUT (2026-09-05, owner-chosen Option 2 - the GUI-DLL-free console
// split). The P3-ETW acquisition proxy now lives in its OWN binary, etwproxy.exe
// (tools/notifhost/etwproxy.cpp), which links NO user32/gdi32/WinRT: this exe's static
// user32+gdi32 imports (pulled in by the WinRT --bridge code below) made user32's DllMain
// connect to a window station at process init, and the bare qubes-etwproxy batch token in
// session 0 has none -> 0xC0000142 STATUS_DLL_INIT_FAILED before one proxy instruction
// (rig-measured; the same binary as SYSTEM initialized fine and reached the never-SYSTEM
// guard, isolating the imports as the sole cause). The agent launches etwproxy.exe
// directly; passing --etw-proxy HERE exits 9 loudly (never a silent no-op). The shared
// wire contract + pure-Win32 plumbing both binaries use live in qtb_shared.h.
//
// --bridge-stop: write the ProgramData stop file the resident bridge polls; it exits and
// restores every banner suppression on the way out.
//
// --restore-banners: one-shot BannerRestoreAll for the invoking user, then exit. The agent
// launches this in the user session when the bridge gate is OFF but crash-leftover ShowBanner
// markers exist (no bridge will ever start to run its own startup restore) - the restorer of
// last resort for the fail-open invariant.
//
// ACTIONABLE BUTTONS (docs/ADR-toasts.md 11, built 2026-10-07): a forwarded toast's buttons and its
// default click travel to dom0 as freedesktop actions (bridge-generated keys "default"/"bN", the
// buttons' labels), and the proxy's ActionInvoked{id, action} reply is carried out in the guest the
// way the shell would have: a protocol action launches its URI (ShellExecute as the user), a Win32
// COM-activator action CoCreates the sender's registered ToastActivatorCLSID and calls
// INotificationActivationCallback::Activate(aumid, arguments, no inputs). The classifier's row 4
// (real-choice buttons) therefore no longer means "window" by itself: toastactions.h decides from
// the XML AND the sender whether every banner button can be carried - all or nothing, never
// half-way - and only then is the toast forwarded, with its actions. Packaged (UWP) activation,
// background activation, inputs, snooze and time-critical scenarios stay on the window path. When
// a click's activation fails in the guest, the toast's hold record turns `window` (the agent
// reopens the banner if it is still displayed) and, if no banner was there to reopen, the user is
// told through a dom0 error notice. Each click runs in a short-lived child process of this exe
// (--act-exec, internal) that the bridge terminates at its bound. --resolve-activator /
// --invoke-activator are the in-guest instruments for the activation path (the dom0 click itself
// needs a human).
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
#include <wtsapi32.h>   // WTSQuerySessionInformation - who owns the interactive session
#pragma comment(lib, "wtsapi32.lib")   // linked here rather than in the vcxproj: the one call site
                                       // is NotifyHandoffToSession, so the dependency stays with it
#include <objbase.h>    // CoCreateInstance / CoInitializeEx (WIN32_LEAN_AND_MEAN leaves it out)
#include <shellapi.h>   // ShellExecuteExW - a protocol action's URI launch (WIN32_LEAN_AND_MEAN leaves it out)
// The shell headers declare the shell's IUserNotification coclass as a GLOBAL `UserNotification` - <shobjidl.h> and, measured
// in CI 37539314129, <shobjidl_core.h> too - which is ambiguous with winrt::Windows::UI::Notifications::UserNotification (C2872).
// So this file names the WinRT type through WinUserNotification (below), never unqualified.
#include <shobjidl_core.h>   // IShellLinkW / IPersistFile - the Start-menu shortcut that names a toast activator
#include <propsys.h>    // IPropertyStore - System.AppUserModel.ID / ToastActivatorCLSID on that shortcut
#include <shlobj_core.h>     // SHGetFolderPathW(CSIDL_PROGRAMS / CSIDL_COMMON_PROGRAMS)
#include <NotificationActivationCallback.h>   // INotificationActivationCallback - the shell's own activation call
#pragma comment(lib, "shell32.lib")    // ShellExecuteExW, SHGetFolderPathW
#pragma comment(lib, "ole32.lib")      // CoCreateInstance / PropVariantClear / CLSIDFromString
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
#include <memory>       // shared_ptr: the activator lookup's hand-off outlives whichever thread finishes last
#include <algorithm>    // stable_sort: id-bearing signal candidates first (EtwTierLookup)
#include <cstdio>
#include <cstdarg>
#include "toastclassify.h"   // P3b pure decision-table classifier (P3a logs its verdicts)
#include "toastactions.h"    // the actionable-buttons route's pure rules: action list, table, dispatch, failure choice
#include "qtb_shared.h"      // shared with etwproxy.exe: log/BLog, wire contract, CsGuard,
                             // EtwOpen/EtwBufferCb/EtwProcessTraceThread (pure Win32 only -
                             // NOTHING GUI-adjacent may move into that header)
#include "../../agent/gui-agent/notifyerr.h"   // secondary error route: policy core shared with
#include "../../agent/gui-agent/errbox.h"       // the error window when dom0 cannot be told (docs/ADR-supervision.md 6)
                                                // the agent (wgcbroker_ipc.h include convention)
#include "../../agent/gui-agent/notifytexts.h" // this helper's own notification texts, as rows the
                                                // agent's offline render test holds to the rules
#include "../../agent/gui-agent/toastident.h"  // the toast-hold contract: identity normalization/hashes
                                                // + the per-notification record ring the agent reads

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "tdh.lib")       // in-box Windows SDK (TDH event decoding) - no WDK/nuget
#pragma comment(lib, "windowsapp.lib")

using namespace winrt;
using namespace winrt::Windows::UI::Notifications;
using namespace winrt::Windows::UI::Notifications::Management;
using WinUserNotification = winrt::Windows::UI::Notifications::UserNotification;   // see the shell-header note above

static HANDLE g_agent = nullptr;
static DWORD  g_agentPid = 0;
static DWORD  g_mySession = 0;
// REST-ZERO S4c (docs/DESIGN-rest-zero-capture.md C): the bridge sleeps without a timeout unless something it armed is
// due. The agent's liveness and our readiness travel by kernel objects the agent creates (main.c NotifIpcEnsure):
static HANDLE g_agentAlive = nullptr;   // --alive: a mutex the agent's main thread owns for its life - ABANDONED = died
static HANDLE g_readyEvt = nullptr;     // --ready: set once our pid is published, so the agent takes it on that wake
static HANDLE g_mainWake = nullptr;     // auto-reset: the reader / shadow threads queued work for the main loop
// THE TOAST-HOLD RECORDS (docs/ADR-toasts.md 10). --hold: a section the SYSTEM agent created and this bridge
// writes (one record per listed notification: content identity hashes + verdict + arrival tick, toastident.h),
// and an auto-reset event in the agent's main-loop wait array, set after every write - named <prefix>_hold and
// <prefix>_verdict from the --alive name <prefix>_alive (or given explicitly: --hold <section> --verdict <event>).
// The agent holds each toast's banner window unmapped until its record's verdict - this replaced the per-AUMID
// ShowBanner=0 write.
static TH_IPC_HEADER* g_hold = nullptr;          // nullptr: no section this run (older agent) - nothing is published
static HANDLE g_holdVerdictEvt = nullptr;
// The dom0 connection state. Defined up here (not with the pipe plumbing below) because the shadow worker's verdict
// consults it: a `bridge` verdict while dom0 is unreachable must not hold a banner that nobody will forward.
static volatile LONG g_connDead = 1;
// THE LISTING'S PUSH SOURCES besides NotificationChanged (rest-zero S4c). Measured 2026-10-01 on 26100.1742:
// NotificationChanged throws for this unpackaged process, and the notification platform does NOT write its database
// when a toast arrives (wpndatabase.db-wal untouched across 10 toasts), so the WAL watcher never fires for them - while
// the ETW tier's proxy delivered every toast's records within the second (Jev: ETW push 0.73). Each hit sets its flag and
// the main loop's wake; the loop lists, and retries a listing that found nothing new (bounded).
// The WAL watcher does NOT trigger a listing: a listing makes the platform touch its own database (wpndatabase.db-wal/-shm),
// so a watcher-triggered listing can re-trigger itself. Measured 2026-10-01 (rz2, w11-ds) with both triggers: in the 60 s
// from 30 s after a 10-toast burst this process switched 9358 times (one thread 8600); before the burst, 0-5 a minute.
static volatile LONG g_etwHit = 0;      // an ETW record naming an AUMID but NO id arrived (only while g_etwIdsSeen is 0)
// THE LISTING IS TRIGGERED BY A NOTIFICATION ID THE BRIDGE HAS NOT SEEN, not by every record (2026-10-01, w11-ds). A
// listing costs 60-400 ms and works a system thread in this process hundreds of times (a process that merely holds a
// listener woke 0 times while ours woke 9889 times in 20 s); after a 10-toast burst every record of the ~90 s tail named a
// toast already listed, or none, and each cost a listing plus two retries (~45 in 85 s, all new=0). Every toast's arrival
// carries its own id in 5+ events (ETW dump of a burst: NotificationLifetimeActivity, ProcessNewNotificationActivity,
// ToastInfo, ...; the same numbers as the listener's ids). So an id-bearing record queues its id and wakes the main loop,
// which lists only if one of them is not in `seen`; an id-less record triggers only until the first id ever arrives (a
// platform that sends no ids keeps listing on every record). Jev: this rule 0.97 over the alternatives.
static volatile LONG g_etwIdsSeen = 0;  // an ETW record carrying a notification id has arrived in this bridge's life
static SRWLOCK g_etwIdLock = SRWLOCK_INIT;
static std::vector<uint32_t> g_etwIds;  // ids from ETW records since the main loop last looked (bounded)
// A wake that asks for a listing (a verdict landed, a dismissal to apply, the push source or the connection changed).
// The ETW thread's wake does NOT: the main loop decides from the queued ids.
static volatile LONG g_listWanted = 0;

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

// The toast's text elements as the listener exposes them: text[0] -> title, text[1..] -> body joined by '\n'.
// RAW, no placeholder: the toast-hold identity (HoldPublish) must hash exactly what the banner shows, and the
// banner shows nothing for a missing title. (toastident.h folds the '\n' joins to one space, the same as the
// agent's ' '-joined UIA text blocks, so the two sides hash alike.)
static void RawTexts(WinUserNotification const& un, std::wstring& title, std::wstring& body)
{
    title.clear(); body.clear();
    try {
        auto vis = un.Notification().Visual();
        auto bind = vis.GetBinding(KnownNotificationBindings::ToastGeneric());
        if (bind) {
            auto els = bind.GetTextElements();
            uint32_t i = 0;
            for (auto const& e : els) { if (i == 0) title = e.Text().c_str(); else { if (!body.empty()) body += L"\n"; body += e.Text().c_str(); } i++; }
        }
    } catch (...) {}
}

static std::wstring FirstTexts(WinUserNotification const& un)
{
    std::wstring title, body;
    RawTexts(un, title, body);
    if (title.empty()) title = L"Notification";
    return title + L"\x1f" + body;   // 0x1f separates title from body
}

// ==================== bridge mode (DESIGN-toast-bridge.md phase A0) ====================

// StateDir / QwtLogDir / Utf8 / g_logName / g_logDirOverride / BLog / BridgeCrashFilter:
// MOVED to qtb_shared.h (2026-09-05 console split) - shared verbatim with etwproxy.exe.

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
//   Windows.SystemToast.SecurityAndMaintenance       (UAC "Click to restart this computer": the click IS
//                                                     the action - WINDOW_ONLY below, owner 2026-10-02)
static const wchar_t* const DEFAULT_ALLOW[] = {
    L"Microsoft.ScreenSketch_8wekyb3d8bbwe!App",       // Snipping Tool: "screenshot saved" (open)
    L"Microsoft.WindowsCamera_8wekyb3d8bbwe!App",      // Camera: photo/video saved
    L"Microsoft.Windows.Photos_8wekyb3d8bbwe!App",     // Photos: import / edit complete
    L"Windows.SystemToast.BackupReminder",             // "back up your files" status
};

// WINDOW-ONLY apps: never bridged, whatever the allowlist (compiled or NotifyBridgeAllow) or the per-toast classifier says.
// Owner 2026-10-02: "UAC warning 'click to restart this computer' is actionable" - "we need to pump it through actionable
// toast (o-r) way bypassing the bridge". The bridge's dom0 notifications carry no action (it sends none, and nothing here
// would turn a dom0 click into the toast's activation), so a toast whose click IS its action has to stay the guest's own
// banner, captured as an override-redirect window in dom0, where the click reaches the guest. The classifier cannot tell:
// the UAC warning has no buttons, only a launch= target, which its table calls informational (row 6). Security and
// Maintenance raises it, and its other toasts are action prompts too (turn something on, restart, fix something).
static const wchar_t* const WINDOW_ONLY[] = {
    L"Windows.SystemToast.SecurityAndMaintenance",
};
static bool WindowOnly(std::wstring const& aumid)
{
    for (const wchar_t* a : WINDOW_ONLY) if (_wcsicmp(a, aumid.c_str()) == 0) return true;
    return false;
}

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
// and (b) defeat the fail-open selftest, since Task Scheduler restarts this process on failure and
// each launch would re-grant. The authoritative health check is GetAccessStatus afterwards - on Deny
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

// --- ShowBanner lifecycle: RETIRED (docs/ADR-toasts.md 10, 2026-10-04) ------------------------
// Until 4.3.34 the bridge wrote ShowBanner=0 per AUMID (prior value recorded in a SID-scoped marker
// file, restored on every exit path and at the next start) so a forwarded toast's guest banner
// would not also map in dom0. It could not do the job: the write happened only once a toast of
// that app had forwarded, so the FIRST toast of every classifier-routed app was already on screen
// and reached dom0 twice, and it stood until the bridge exited, so a LATER interactive toast of
// the same app was shown nowhere (findings/issues.md P1). The agent now holds each toast's banner
// window unmapped until THAT toast's verdict, which it learns from the records this bridge
// publishes (the toast-hold block below). NOTHING HERE WRITES ShowBanner ANY MORE. What stays is
// BannerRestoreAll: a guest upgraded from an older version may still carry its markers, and the
// user's ShowBanner values they record are restored exactly as before (startup sweep, exit path,
// the agent's gate-off --restore-banners one-shot).
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

// CurrentUserSid: MOVED to qtb_shared.h (console split) - shared with etwproxy.exe.

// Marker basename glob for the current user (BannerRestoreAll).
static std::wstring MarkerPrefix()
{
    return L"\\banner-" + std::to_wstring(Fnv1a64(Utf8(CurrentUserSid()))) + L"-";
}

static std::wstring BannerKey(std::wstring const& aumid)
{
    return L"Software\\Microsoft\\Windows\\CurrentVersion\\Notifications\\Settings\\" + aumid;
}

// --- the toast-hold records (docs/ADR-toasts.md 10; agent/gui-agent/toastident.h) -------------
// One record per listed notification: the content identity the agent also computes from the banner's
// UI Automation text (TiIdentFromTexts over DisplayName / text[0] / text[1..]: hashes only, no text),
// the verdict as far as this bridge knows it (pending -> bridge/window), the arrival tick. Written into
// the section the agent created (--hold) and announced with a SetEvent on the agent's verdict event
// (--verdict) - the agent's main loop waits on it; nothing polls on either side. Without --hold (an
// older agent) nothing is published and the agent maps banners as before.

static void HoldOpen(const wchar_t* name)
{
    HANDLE m = OpenFileMappingW(FILE_MAP_READ | FILE_MAP_WRITE, FALSE, name);
    if (!m) { BLog(L"HOLD section %s not opened (%lu) - no records this run; the agent shows every banner it cannot decide", name, GetLastError()); return; }
    void* base = MapViewOfFile(m, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, 0);
    CloseHandle(m);   // the view keeps the section alive
    if (!base) { BLog(L"HOLD section %s not mapped (%lu)", name, GetLastError()); return; }
    if (!ThIpcValid((TH_IPC_HEADER*)base)) { BLog(L"HOLD section %s carries no valid header (mixed install?) - ignored", name); UnmapViewOfFile(base); return; }
    g_hold = (TH_IPC_HEADER*)base;
}

static void HoldSignal() { if (g_holdVerdictEvt) SetEvent(g_holdVerdictEvt); }

static void HoldStart()
{
    if (!g_hold) { BLog(L"HOLD no --hold section from the agent (mixed install?) - banners are not held for this bridge's verdicts"); return; }
    g_hold->BridgeStartTick = GetTickCount64();
    TI_STORE32(&g_hold->BridgeAlive, 1);
    HoldSignal();
    BLog(L"HOLD records live (%d slots) - the agent holds each toast's banner until its record's verdict", (int)TH_IPC_RECORDS);
}

static void HoldStop()
{
    if (!g_hold) return;
    TI_STORE32(&g_hold->BridgeAlive, 0);
    HoldSignal();
}

static const wchar_t* HoldVerdictName(LONG v)
{
    return v == TH_VERDICT_BRIDGE ? L"bridge" : v == TH_VERDICT_WINDOW ? L"window"
         : v == TH_VERDICT_FORWARDED ? L"forwarded" : L"pending";
}

// The agent's display mode (docs/ADR-toasts.md 10): TRUE in seamless mode, where the hold exists. In non-seamless/
// fullscreen mode the guest draws its banner inside the one desktop window and nothing can withhold it - forwarding a
// toast would show it twice - so every toast takes the window path while this is FALSE. Without a section (older
// agent) the mode is unknown and routing is as before.
static bool HoldSeamless()
{
    return !g_hold || TI_LOAD32(&g_hold->Seamless) != 0;
}

// Any thread - the shadow worker calls it with onlyIfPending (the ring's interlocked ops make it safe).
// onlyIfPending: the classifier's answer may never override a route the listing settled (WindowOnly app,
// allowlist, forward outcome); a `false` is the listing's own final word. Returns whether the record was
// still in the ring; *seqOut (optional) is its sequence, for the agent-mark read-back (ADR-toasts 11).
static bool HoldVerdictSeq(uint32_t id, LONG verdict, bool onlyIfPending, LONG* seqOut)
{
    if (seqOut) *seqOut = 0;
    if (!g_hold) return false;
    if (ThIpcSetVerdictSeq(g_hold, id, verdict, onlyIfPending ? TRUE : FALSE, seqOut))
    {
        HoldSignal();
        BLog(L"HOLD id=%u verdict=%s%s", id, HoldVerdictName(verdict), onlyIfPending ? L" (classifier, was pending)" : L"");
        return true;
    }
    return false;
}

static void HoldVerdict(uint32_t id, LONG verdict, bool onlyIfPending)
{
    HoldVerdictSeq(id, verdict, onlyIfPending, nullptr);
}

// The agent's word on a record (TH_AGENT_SHOWN: it maps a banner showing this toast); none without a section.
static LONG HoldAgentState(LONG seq)
{
    return g_hold ? ThIpcAgentState(g_hold, seq) : TH_AGENT_NONE;
}

// Listing thread only: once per notification id (a toast left unseen for a retry is listed again).
static void HoldPublish(WinUserNotification const& un, uint32_t id, std::wstring const& aumid, std::wstring const& app,
                        LONG verdict, UINT32 flags)
{
    static std::unordered_set<uint32_t> published;   // listing thread only
    if (!g_hold) return;
    if (published.size() > 2048) published.clear();   // bound; a re-publish after a clear is harmless (newest seq wins)
    if (!published.insert(id).second) return;
    std::wstring title, body;
    RawTexts(un, title, body);
    TOAST_IDENT ident;
    TiIdentFromTexts(app.c_str(), title.c_str(), body.c_str(), &ident);
    const LONG seq = ThIpcPublish(g_hold, id, flags, Fnv1a64(Utf8(aumid)), &ident, verdict, GetTickCount64());
    HoldSignal();
    // Hashes only, per field: the record is what the agent matches the banner's text against, and a
    // mismatch is diagnosed on the rig by comparing s/t/m here with the agent's QGATOASTHOLD/QGATOASTIDENT
    // lines (which field disagrees says whether it is the sender, the title or the body spelling).
    BLog(L"HOLD id=%u seq=%ld verdict=%s ident=%016llx s=%016llx t=%016llx m=%016llx flags=0x%x",
         id, seq, HoldVerdictName(verdict), (unsigned long long)ident.Combined,
         (unsigned long long)ident.Sender, (unsigned long long)ident.Title, (unsigned long long)ident.Message, flags);
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

// PutU32/PutU64/GetU32/GetU64: MOVED to qtb_shared.h (console split) - the same codec
// frames both the dom0 notify wire below and the proxy pipe's QTS1 frames.

// HOW LONG A FORWARDED NOTIFICATION STAYS (owner 2026-10-02: "current default timeout is too brief, consider increasing
// (and errors should stay until dismissed)"). The stock proxy hands both fields to dom0's notification daemon unchanged
// (qubes-notification-proxy lib.rs: only expire_timeout < -1 is refused; urgency becomes the freedesktop hint, no clamp).
// THE OWNER'S RULE (2026-10-06, after a forwarded reminder vanished): "errors stay. warnings are 60s. informational
// messages are 20s." An ERROR is sent with expire_timeout 0, which the freedesktop spec defines as "never expire", AND critical
// urgency, which daemons that ignore expire_timeout (GNOME) also keep until dismissed. A WARNING stays 60 s, an INFORMATIONAL
// message 20 s - a forwarded guest toast is informational. The one-shot --notify path is an error unless its caller says
// --severity warning|info: every notice it carried before the flag existed was an error, so an old caller keeps its meaning.
enum class NotifyKind { Error, Warning, Info };
static const uint32_t kInfoExpireMs = 20000;
static const uint32_t kWarningExpireMs = 60000;

// Message { id: u64, Notification::V1 { ... } }, framed with a u32 LE length prefix. `actions` is the
// freedesktop list as alternating key, label (toastactions.h ToastActFlatten); empty = no actions, the
// frame of every version before this one byte for byte.
static std::vector<BYTE> EncodeNotifyFrame(uint64_t seq, std::string const& summary, std::string const& body, NotifyKind kind,
                                           std::vector<std::string> const& actions)
{
    std::vector<BYTE> m;
    PutU64(m, seq);             // Message.id (echoed as `sequence` in replies)
    PutU32(m, 0);               // Notification enum tag: 0 = V1
    m.push_back(0);             // suppress_sound = false
    m.push_back(0);             // transient = false
    m.push_back(0);             // resident = false
    if (kind == NotifyKind::Error) { m.push_back(1); PutU32(m, 2); }   // urgency: Some(Critical) - variant index 2 (Low, Normal, Critical)
    else m.push_back(0);                                                // urgency: Option None
    PutU32(m, 0);               // replaces_id: 0 = new notification
    PutU64(m, summary.size()); m.insert(m.end(), summary.begin(), summary.end());
    PutU64(m, body.size());    m.insert(m.end(), body.begin(), body.end());
    ToastActPutVec(m, actions); // actions: Vec<String> - u64 count, then (u64 len + UTF-8) each; keys validated by the proxy
    m.push_back(0);             // category: Option None
    PutU32(m, kind == NotifyKind::Error ? 0u : kind == NotifyKind::Warning ? kWarningExpireMs : kInfoExpireMs);   // expire_timeout ms; 0 = never
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
// RUNS in --bridge. It lives ONLY in `etwproxy.exe` (its own GUI-DLL-free console binary
// since the 2026-09-05 split - see etwproxy.cpp), a separate PURE-CONSUMER
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

// CsGuard + the 'QTS1' wire protocol (ETW_WIRE_* / ETW_MAX_* / kEtwProxyPipe): MOVED to
// qtb_shared.h (console split) - ONE definition now feeds this IPC client and the
// etwproxy.exe server, so the frame layout / pipe name can no longer drift apart.

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
    HANDLE sigEvt = nullptr;                // auto-reset: "a frame just entered the ring" -
                                            // paces the shadow worker's bounded catch-up
                                            // over the session's 1 s FlushTimer delivery
} g_etw;

// kEtwBridgeSession (the agent-owned QubesToastBridgeEtw session name): MOVED to
// qtb_shared.h - etwproxy.exe OpenTraceW's it; nothing in THIS binary touches it anymore.
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

// g_etwBufCount / EtwBufferCb / EtwOpen: MOVED to qtb_shared.h (console split) - shared
// verbatim with etwproxy.exe (--dump-etw here still consumes through them).

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

// EtwTiString: MOVED to qtb_shared.h (console split).

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

// EtwLower: MOVED to qtb_shared.h (console split).

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
    if (g_etw.sigEvt) SetEvent(g_etw.sigEvt);   // wake a worker waiting out the flush pacing
    if (!la.empty())
    {
        if (idn != 0)
        {
            InterlockedExchange(&g_etwIdsSeen, 1);
            AcquireSRWLockExclusive(&g_etwIdLock);
            if (g_etwIds.size() < 512) g_etwIds.push_back((uint32_t)idn);
            ReleaseSRWLockExclusive(&g_etwIdLock);
            if (g_mainWake) SetEvent(g_mainWake);   // the main loop lists if this id is new to it (see g_etwIdsSeen)
        }
        else if (!g_etwIdsSeen)
        {
            InterlockedExchange(&g_etwHit, 1);      // no ids from this platform (yet): every record lists, as before
            if (g_mainWake) SetEvent(g_mainWake);
        }
    }
    if (EtwSigLogAllow(n))                   // every frame at human rates; 1-in-20 in a burst
        BLog(L"ETW SIG #%ld aumid=%s idnum=%llu notif=%s tag=%s group=%s", n,
             la.empty() ? L"-" : la.c_str(), (ULONGLONG)idn,
             ln.empty() ? L"-" : ln.c_str(), lt.empty() ? L"-" : lt.c_str(),
             lg.empty() ? L"-" : lg.c_str());
    return true;
}

// rest-zero M1 attribution: each long-lived thread names itself, so a per-thread wake count (restwatch / thread-who's
// GetThreadDescription) says WHICH of ours woke - the 2026-10-01 toast tail had one thread at ~128 wakes/s and no symbols
// to name it. Looked up at run time: SetThreadDescription needs Windows 10 1607.
static void NameThisThread(const wchar_t* name)
{
    typedef HRESULT (WINAPI *PFN_STD)(HANDLE, PCWSTR);
    static PFN_STD p = (PFN_STD)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "SetThreadDescription");
    if (p) p(GetCurrentThread(), name);
}

static DWORD WINAPI EtwIpcThread(LPVOID)
{
    NameThisThread(L"notifhost: etw-ipc");
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
            InterlockedExchange(&g_listWanted, 1);
            if (g_mainWake) SetEvent(g_mainWake);   // the listing now has a push source: the main loop drops its floor
            while (EtwIpcReadRecord(pipe))
                if (WaitForSingleObject(g_etw.stopEvt, 0) == WAIT_OBJECT_0) break;
            CloseHandle(pipe);
            if (WaitForSingleObject(g_etw.stopEvt, 0) == WAIT_OBJECT_0) return 0;
            InterlockedExchange(&g_etw.state, ETW_STATE_DOWN);
            BLog(L"ETW IPC disconnected (recs=%ld bad=%ld) - tier down, DB fallback, reconnecting",
                 g_etw.recTotal, g_etw.recBad);
            InterlockedExchange(&g_listWanted, 1);
            if (g_mainWake) SetEvent(g_mainWake);   // the listing may have lost its only push source: floor back on
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
    g_etw.sigEvt = CreateEventW(nullptr, FALSE, FALSE, nullptr);   // auto-reset; null-tolerated
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
// returning up to 4 candidate SIGNALS - never a payload (design 10.20.2). Candidate
// admission, strongest key first (revised 2026-09-06 from the p3a T3 rig matrix):
//   1. ID JOIN: the signal's notificationId equals the listener's toast id (rowId) - the
//      exact design-10.20.5#1 key, admitted REGARDLESS of which field carried the app
//      identity. Rig-proven necessity: the NotificationController event flavor that most
//      reliably carries the id has NO aumid-named property (its app id rides a
//      group-named one - 'SIG #80 aumid=- idnum=16 group=QubesToastfire.StartShortcut'
//      for wpndb row 16); the old aumid-only admission dropped exactly those frames and
//      degraded precise joins to sig-unique/no-listener-key.
//   2. AUMID equality (case-insensitive, as the allowlist matches) inside a +/-60 s
//      FILETIME window against the listener CreationTime - the original rule.
//   3. GROUP-as-app: the signal's aumid is empty and its group equals the listener AUMID
//      (same controller flavor when its id did not match or rowId is 0); the group copy
//      is CLEARED on admission - it is the app id, not a toast group, and must not feed
//      the targeted read's "AND n.\"Group\" = ?" narrowing.
// Newest first; duplicates (a re-emitted event: same id/notifId/tag/group) collapse;
// id-bearing candidates SORT FIRST so the 4-slot cap cannot crowd them out with idnum=0
// frames (rig-measured: one toast emits ~15-25 frames, many id-less). Returns:
//   "sig-hit"   >=1 candidate signal out - the worker runs the targeted read
//   "sig-none"  tier live but no signal for this toast (provider silent for this app,
//               no key at all, or outside the time window) - DB rung serves
//   "down"      tier armed but not live (proxy absent / pipe closed / thread dead)
//   "off"       never armed (non-bridge modes)
// ETW is push, so there is no wait HERE; but the session delivers on a 1 s FlushTimer
// (agent EtwCtlSessionStart), so the caller runs a bounded sigEvt-paced catch-up when
// this returns sig-none while the tier is live (see ShadowClassifyWork).
static const char* EtwTierLookup(uint32_t rowId, std::wstring const& aumid,
                                 long long creationFt, std::vector<EtwToastRec>* out)
{
    const long long kEtwFtWindow = 60LL * 10000000LL;   // +/- 60 s in FILETIME ticks
    if (!g_etw.armed) return "off";
    if (g_etw.state != ETW_STATE_LIVE) return "down";
    if (aumid.empty() && rowId == 0) return "sig-none";  // no key at all (bare + no id)
    ULONGLONG now = GetTickCount64();
    {
        CsGuard g(&g_etw.lock);                          // RAII (review must-fix)
        while (!g_etw.ring.empty() && now - g_etw.ring.front().tick > 120000)
            g_etw.ring.pop_front();
        for (auto it = g_etw.ring.rbegin(); it != g_etw.ring.rend() && out->size() < 4; ++it)
        {
            bool idJoin = rowId != 0 && it->notifIdNum == (uint64_t)rowId;
            bool aumidJoin = !aumid.empty() && !it->aumid.empty() &&
                             _wcsicmp(it->aumid.c_str(), aumid.c_str()) == 0;
            bool groupJoin = !aumid.empty() && it->aumid.empty() && !it->group.empty() &&
                             _wcsicmp(it->group.c_str(), aumid.c_str()) == 0;
            if (!idJoin && !aumidJoin && !groupJoin) continue;
            if (!idJoin && creationFt && it->eventFt &&   // time-gate the weaker keys only
                (it->eventFt - creationFt > kEtwFtWindow || creationFt - it->eventFt > kEtwFtWindow))
                continue;
            EtwToastRec r = *it;
            // A group that IS the app id (the controller flavor) is not a toast group and
            // must not feed the targeted read's "AND n.\"Group\" = ?" narrowing. Cleared
            // BEFORE the dup collapse so a raw and an already-cleared copy of the same
            // re-emitted event still collapse.
            if (!r.group.empty() && !aumid.empty() &&
                _wcsicmp(r.group.c_str(), aumid.c_str()) == 0)
                r.group.clear();
            bool dup = false;                            // re-emitted event: same identity
            for (auto const& c : *out)
                if (c.notifIdNum == r.notifIdNum && c.notifId == r.notifId &&
                    c.tag == r.tag && c.group == r.group) { dup = true; break; }
            if (!dup) out->push_back(std::move(r));
        }
    }
    std::stable_sort(out->begin(), out->end(),
                     [](EtwToastRec const& a, EtwToastRec const& b)
                     { return (a.notifIdNum != 0) > (b.notifIdNum != 0); });
    return out->empty() ? "sig-none" : "sig-hit";
}

// The tier-1 payload acquisition (design 10.20.2): ONE targeted wpndatabase read per
// candidate signal, on the SHADOW WORKER only (never the poll thread - heartbeat rule).
// PRIMARY id join (RIG-PROVEN 2026-09-06, p3a T3: idnum==row_id whenever both were read -
// ids 20 and 22 - so the 10.20.5 premise holds): WHERE n.Id = notifIdNum AND
// n.Type='toast'. The returned row is cross-checked for app ownership against the
// strongest available witness - the listener AUMID, else the SIGNAL's aumid (the listener
// reports unregistered-app toasts with an empty aumid), else the two-source id agreement
// signal.notifIdNum == listener rowId (the listener id comes from WinRT, not the pipe) -
// never trust a row the id reached but the app does not own; with no witness at all the
// row is refused. first-<text> vs the listener title stays an ADVISORY check: a text
// mismatch logs and falls through to the signal fallback rather than earning corr=id-ok.
// FALLBACK (id absent/no row after retries/mismatch): app key (listener aumid, else the
// signal's; NOCASE) + Type='toast' + ArrivalTime in eventFt +/- 60 s, narrowed by
// Tag/"Group" when the signal carried them, LIMIT 16 - exactly one row => sig-unique;
// several => the existing first-<text>-vs-title disambiguation; still >1 =>
// sig-ambiguous => WINDOW, never guess. RACE: the ETW event fires at emission while WNS commits the row
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

static WpnTarget WpnTargetedRead(uint32_t rowId, std::vector<EtwToastRec> const& sigs,
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
                    // App-ownership cross-check for the row the id reached, strongest
                    // available witness first (2026-09-06, from the p3a T3 bare rows):
                    //   1. the LISTENER aumid, when it has one;
                    //   2. else the SIGNAL's aumid (the listener reports unregistered-app
                    //      toasts with an EMPTY aumid - AppInfo resolution fails for them -
                    //      which used to make every id hit for those toasts unverifiable);
                    //   3. else, when the signal's id EQUALS the listener's toast id
                    //      (s.notifIdNum == rowId), accept on that two-source agreement:
                    //      the listener id comes from WinRT, not the pipe, so a forged
                    //      frame cannot steer the read to a row the platform did not
                    //      assign this very toast.
                    // With NO witness at all the row is still refused (fail-open).
                    std::string sigAumid8 = Utf8(s.aumid);
                    bool owned;
                    if (!aumid8.empty())
                        owned = _stricmp(rowAumid.c_str(), aumid8.c_str()) == 0;
                    else if (!sigAumid8.empty())
                        owned = _stricmp(rowAumid.c_str(), sigAumid8.c_str()) == 0;
                    else
                        owned = rowId != 0 && s.notifIdNum == (uint64_t)rowId;
                    if (!owned)
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
            // signal fallback: AUMID + eventFt-anchored window (+ tag/group when carried).
            // The app key is the listener aumid, else the signal's own (bare/unregistered
            // toasts have no listener aumid); with neither there is no sound window query.
            std::string keyAumid8 = !aumid8.empty() ? aumid8 : Utf8(s.aumid);
            if (keyAumid8.empty()) continue;
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
            q->bind_text(st, 1, keyAumid8.c_str(), -1, WPN_SQLITE_TRANSIENT);
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

// EtwDumpProcessThread: MOVED to qtb_shared.h as EtwProcessTraceThread (console split) -
// etwproxy.exe runs its consumer through the same thread proc.

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
    HANDLE t = CreateThread(nullptr, 0, EtwProcessTraceThread, &cons, 0, nullptr);
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
    GetExitCodeThread(t, &ptrc);           // EtwProcessTraceThread returns ProcessTrace's rc
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

// ==================== --etw-proxy: MOVED to etwproxy.exe (console split) ==================
// The entire least-privilege acquisition process - PxHarvest/EtwProxyEventCb/PxWrite, the
// one-way OUTBOUND pipe server + client-SID DACL, the never-SYSTEM guard, the token-drift
// census, EtwProxyShedAllPrivileges and EtwProxyMain - lives in tools/notifhost/etwproxy.cpp
// now, compiled into the GUI-DLL-free etwproxy.exe (no user32/gdi32/WinRT imports, so it
// can run winsta-less under the bare qubes-etwproxy batch token; the imports this binary
// carries for --bridge were the proven 0xC0000142 cause). Semantics, exit codes (0/5/7/8/9)
// and the QTS1 wire contract are unchanged; the contract itself lives in qtb_shared.h.

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

// CLASSIFIER-DRIVEN ROUTING (owner, 2026-09-23). The classifier has shipped since 5133293 in
// MEASURE-ONLY shadow: it produced a verdict per toast and the verdict was logged and discarded,
// while routing stayed byte-for-byte A0 (allowlist or window path). This is the store that lets a
// verdict decide the route.
//
// Why a store and not a wait: the poll thread must never block on acquisition (the heartbeat
// contract; P3AQ_DEFECT_HOTWAIT exists to prove a stall there breaks the harness's cadence bound).
// So the worker records id -> route, and the poll thread decides on a later pass - which costs
// nothing, because an unforwarded toast is already left unseen and re-examined every 2 s.
// Jev graded the alternatives 2026-09-23: verdict-map-retry 0.73, stay-in-shadow 0.24,
// bounded-wait 0.01, per-app-learning 0.00.
// The actionable-buttons route's impure helpers, defined with the click handling further down (the
// classification above them needs the two lookups).
static std::wstring ResolveToastActivator(std::wstring const& aumid, const wchar_t** source);
static bool AumidPackaged(WinUserNotification const& un, std::wstring const& aumid);

// The verdict and, since the actionable-buttons route (ADR-toasts 11), the ACTION PLAN that came with it: the
// dom0 actions the forward carries (toastactions.h) and the sender's resolved toast activator CLSID the click
// handler calls. Both are decided on the shadow worker with the verdict - the main thread only forwards.
struct VerdictEntry
{
    int route = ToastRouteWindow;
    int row = 0;              // the classifier's row (4 = real-choice buttons: the SENT line asserts actions went with it)
    ToastActPlan plan;        // ok with actions (possibly none) when route is bridge
    std::wstring clsid;       // "{...}" when any action is a COM activation
};
struct VerdictStore
{
    CRITICAL_SECTION lock{};
    bool init = false;
    std::unordered_map<uint32_t, VerdictEntry> route;   // id -> the verdict and its plan
    std::unordered_map<uint32_t, int> passes;           // id -> poll passes spent waiting
} g_verdict;

static void VerdictInit()
{
    if (!g_verdict.init) { InitializeCriticalSection(&g_verdict.lock); g_verdict.init = true; }
}
static void VerdictStorePut(uint32_t id, int route, ToastActPlan const& plan, std::wstring const& clsid, int row)
{
    if (!g_verdict.init) return;
    {
        CsGuard g(&g_verdict.lock);
        if (g_verdict.route.size() > 4096) { g_verdict.route.clear(); g_verdict.passes.clear(); }
        VerdictEntry& e = g_verdict.route[id];
        e.route = route; e.row = row; e.plan = plan; e.clsid = clsid;
    }
    InterlockedExchange(&g_listWanted, 1);
    if (g_mainWake) SetEvent(g_mainWake);   // a toast may be waiting for this verdict: re-list now, not on a tick
    // The agent is holding this toast's banner on the record published at listing: give it the verdict NOW,
    // from this thread, rather than after the re-listing above (the ETW tier answers within the second; the
    // listing adds its own latency). Only while the record is still pending - a settled route stands - and
    // never `bridge` while dom0 is unreachable: nobody would forward it, so the banner must show.
    HoldVerdict(id, (route == ToastRouteBridge && !g_connDead) ? TH_VERDICT_BRIDGE : TH_VERDICT_WINDOW, true);
}
// Returns true and fills *out when a verdict exists. Otherwise counts this pass: a toast whose
// verdict never arrives must NOT be deferred for ever - after kVerdictMaxPasses it takes the
// window path, which is the fail-open direction (the user sees it as a guest window, as today).
static const int kVerdictMaxPasses = 3;           // ~6 s at the 2 s poll cadence
// *passes is set to kVerdictMaxPasses when NO VERDICT CAN EVER ARRIVE (the store was never
// initialised because the shadow worker is not running), so the caller decides immediately instead
// of deferring for ever. The first version returned false without touching *passes there, which
// left such a toast undecided on every pass - deferred permanently and re-logged every 2 s. Jev
// caught it on review (preserves_fail_open 0.58, worst_defect=pass-counter-leak 0.52).
static bool VerdictLookup(uint32_t id, VerdictEntry* out, int* passes)
{
    if (!g_verdict.init) { *passes = kVerdictMaxPasses; return false; }
    CsGuard g(&g_verdict.lock);
    auto it = g_verdict.route.find(id);
    if (it != g_verdict.route.end()) { *out = it->second; return true; }
    if (g_verdict.passes.size() > 4096) g_verdict.passes.clear();   // bounded independently of route
    *passes = ++g_verdict.passes[id];
    return false;
}

// A decided toast keeps nothing: its id is marked seen by the caller and will never be looked up
// again, so leaving entries behind is pure growth.
static void VerdictForget(uint32_t id)
{
    if (!g_verdict.init) return;
    CsGuard g(&g_verdict.lock);
    g_verdict.route.erase(id);
    g_verdict.passes.erase(id);
}

struct ShadowJob
{
    uint32_t id = 0;
    std::wstring aumid, title;
    long long creationFt = 0;
    bool packaged = false;   // a packaged (PFN!App) sender: its foreground activation is UWP's, never a COM call we can make
    std::wstring payloadW;   // filled on the worker once a payload is in hand (the action plan reads it as text)
};

static struct
{
    CRITICAL_SECTION lock;                  // guards q; CsGuard only
    std::deque<ShadowJob> q;                // capped 32; overflow drops the OLDEST (logged)
    HANDLE evt = nullptr, stopEvt = nullptr;
    HANDLE worker = nullptr, walWatch = nullptr;
    HANDLE walEvt = nullptr;                // auto-reset: "wpndatabase.db* just changed"
    bool armed = false;
} g_shadow;
// The WAL watcher armed (set by WalWatchThread once its directory handle is open). It paces WpnCorrelate's retries only;
// it never triggers a listing (see g_etwHit).
static volatile LONG g_walArmed = 0;

// Push replacement for WpnCorrelate's blind retry sleep (owner directive: prefer push over
// poll): watch the notification store's directory and signal walEvt whenever
// wpndatabase.db* changes - a fresh toast's row lands as a -wal append, which is exactly
// the moment a retry becomes worth making. Fail-open: if the watch cannot arm (or dies),
// walEvt simply never fires and the worker's bounded waits time out into the same pacing
// the old blind retry had. This thread signals; it never reads file content.
static DWORD WINAPI WalWatchThread(LPVOID)
{
    NameThisThread(L"notifhost: wal-watch");
    wchar_t la[MAX_PATH] = { 0 };
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", la, RTL_NUMBER_OF(la))) return 0;
    std::wstring dir = std::wstring(la) + L"\\Microsoft\\Windows\\Notifications";
    HANDLE h = CreateFileW(dir.c_str(), FILE_LIST_DIRECTORY,
                           FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                           OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, nullptr);
    if (h == INVALID_HANDLE_VALUE)
    { BLog(L"WALWATCH unavailable (%lu) - timed-retry fallback", GetLastError()); return 0; }
    BLog(L"WALWATCH armed dir=%s", dir.c_str());
    InterlockedExchange(&g_walArmed, 1);
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
        if (hit)
            SetEvent(g_shadow.walEvt);   // NOT the listing's trigger: a listing writes this database too (see g_etwHit)
    }
    CloseHandle(h);
    return 0;
}

// The acquisition ladder for ONE toast + the CLASSIFY line. Runs on the shadow worker
// (or, under P3AQ_DEFECT_HOTWAIT only, back on the poll thread as the seen-to-fail proof).
// Defined with the activator cache further down; ShadowClassifyWork reads the cache and starts lookups (C3861 in CI 37553977560).
static ToastActActivator ActivatorResolveNow(std::wstring const& aumid, std::wstring& clsid, const wchar_t*& src);
static std::shared_ptr<ToastActLookupHandoff> ShortcutScanHandoff();

static void ShadowClassifyWork(ShadowJob& j)
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
        // THE ACTION PLAN (ADR-toasts 11), decided here with the verdict from the same payload. Row 4 (real-choice
        // buttons) is bridge ONLY if every banner button can be carried as a dom0 action; rows 5/6 are bridge as
        // before and carry what they can (protocol buttons, the default click).
        // THE ACTIVATOR LOOKUP NEVER DELAYS A ROUTE THAT DOES NOT DEPEND ON IT (guest-test regression 2026-10-07: a
        // cold 3.4 s lookup for a sender WITHOUT an activator pushed an informational toast's verdict past the listing's
        // budget and it lost forwarding). The cache is asked without blocking; a miss STARTS the lookup in the background
        // (its result warms the cache for the sender's next toast) and is awaited - within kToastActRouteLookupBudgetMs -
        // only for a toast whose route depends on it (row-4 COM buttons, ToastActRouteNeedsActivator); not done in time,
        // that toast takes the window path (the user keeps the guest's buttons). An informational toast is published at
        // once, its default click left out this time and the reason logged.
        std::wstring actClsid;
        const wchar_t* actSrc = L"not-asked";
        ToastActActivator actState = ToastActActivator::Unknown;
        ToastActPlan plan;                            // !ok, no actions, until a payload says otherwise
        plan.refusal = L"no payload (fail-open)";
        int lastRow = 0;                              // the classifier's row, carried to the SENT line's assertion
        auto decide = [&](ToastClass const& k, bool clean) {
            signals = WpnSignalSlug(k);
            lastRow = k.row;
            if (!clean) return;                       // only a clean acquisition may say "bridge" (unchanged)
            if (k.row >= 4 && k.row <= 6)
            {
                if (!j.packaged)                      // a packaged sender's foreground activation is never carried: nothing to ask
                {
                    // a registry read + a map read, never a scan on this thread (ActivatorResolveNow)
                    actState = ActivatorResolveNow(j.aumid, actClsid, actSrc);
                    if (actState == ToastActActivator::Unknown)   // the shortcut map is not built yet (the first seconds of a run)
                    {
                        const bool routeNeedsIt = ToastActRouteNeedsActivator(j.payloadW.c_str(), j.payloadW.size(), k, j.packaged);
                        auto h = ShortcutScanHandoff();
                        if (routeNeedsIt && h)
                        {
                            std::wstring ignored; const wchar_t* ignoredSrc = nullptr;
                            if (h->WaitFor(kToastActRouteLookupBudgetMs, ignored, ignoredSrc)) actState = ActivatorResolveNow(j.aumid, actClsid, actSrc);
                            if (actState == ToastActActivator::Unknown)
                            {
                                actSrc = L"budget-exceeded";
                                BLog(L"ACTIVATOR id=%u aumid=%s: the shortcut scan is not done within the %llu ms route budget - this row-4 toast "
                                     L"takes the window path (the guest's buttons stay with the user); the map serves the next toast",
                                     j.id, j.aumid.c_str(), (ULONGLONG)kToastActRouteLookupBudgetMs);
                            }
                        }
                        else
                            BLog(L"ACTIVATOR id=%u aumid=%s: the shortcut map is not built yet (%s) - NOT awaited for an informational toast "
                                 L"(its route does not depend on it; its default click is not carried this time)", j.id, j.aumid.c_str(), actSrc);
                    }
                }
                ToastActCtx ctx{ j.packaged, actState };
                plan = ToastActionsBuild(j.payloadW.c_str(), j.payloadW.size(), k, ctx);
            }
            if (k.row == 4) verdict = plan.ok ? L"bridge" : L"window";
            else verdict = ToastRouteName(k.route);
            if (k.route == ToastRouteBridge && !plan.ok)  // rows 5/6 refused (a protocol button without a URI): rule 4
                verdict = L"window";
        };
        const char* etw = EtwTierLookup(j.id, j.aumid, j.creationFt, &sigs);
        // FlushTimer catch-up (2026-09-06): the agent's session delivers to the proxy on a
        // 1 s FlushTimer (EtwCtlSessionStart), so a listener/WAL-triggered classify can
        // outrun the toast's own signal batch (rig p3a T3: com-activator informational
        // classified src=db in the very second its frames landed). Bounded and
        // event-paced - sigEvt fires per frame entering the ring - on the WORKER thread
        // only, so the heartbeat contract holds; worst added cost 2 x 800 ms before the
        // DB rung serves, comparable to that rung's own WAL retry budget.
        for (int w = 0; w < 2 && strcmp(etw, "sig-none") == 0 &&
                        g_etw.state == ETW_STATE_LIVE; w++)
        {
            if (g_etw.sigEvt) WaitForSingleObject(g_etw.sigEvt, 800);
            else Sleep(400);                          // no event: blind but still bounded
            sigs.clear();
            etw = EtwTierLookup(j.id, j.aumid, j.creationFt, &sigs);
        }
        if (strcmp(etw, "sig-hit") == 0)
        {
            // A signal EXISTS for this toast: the targeted read answers it - and owns the
            // outcome. On any non-clean corr (norow, mismatch, ambiguous, db-fail) the
            // verdict stays the fail-open window WITHOUT falling to WpnCorrelate: the DB
            // rung is the ETW-DOWN fallback, not a second guess at a row the precise
            // signal-keyed read already failed to pin (rig drill 10.20.5#5 asserts
            // exactly this: fire+purge-the-row => corr=id-norow => window, not db).
            WpnTarget t = WpnTargetedRead(j.id, sigs, j.aumid, j.title, g_shadow.walEvt);
            corr = t.corr;
            if (!t.payload.empty())                   // only on id-ok / sig-unique
            {
                src = "etw-sig";
                j.payloadW = WpnPayloadToW(t.payload);
                ToastClass k = ClassifyToastXmlBytes(t.payload.data(), t.payload.size());
                decide(k, strcmp(t.corr, "id-ok") == 0 || strcmp(t.corr, "sig-unique") == 0);
            }
        }
        else                                          // no signal (sig-none/down/off): DB rung
        {
            WpnCorr c = WpnCorrelate(j.aumid, j.creationFt, j.title, g_shadow.walEvt);
            corr = c.corr;
            if (!c.payload.empty())
            {
                src = "db";
                j.payloadW = WpnPayloadToW(c.payload);
                ToastClass k = ClassifyToastXmlBytes(c.payload.data(), c.payload.size());
                decide(k, strcmp(c.corr, "ok") == 0);  // only a clean correlation may say "bridge"
            }
        }
        // actions=: what the forward will carry ("default:com,b0:protocol"), "none", or "refused:<why>" (then a
        // row-4 toast is window). activator=: where the sender's toast activator came from, when it was asked.
        BLog(L"CLASSIFY id=%u src=%hs etw=%hs verdict=%s row_latency=%lums signals=%s corr=%hs actions=%s activator=%s%s%s",
             j.id, src, etw, verdict, (DWORD)(GetTickCount64() - t0), signals.c_str(), corr, ToastActSlug(plan).c_str(),
             actSrc, plan.defaultNote ? L" default-not-carried=" : L"", plan.defaultNote ? plan.defaultNote : L"");
        // Record exactly what was logged, so the route a later poll pass takes is the verdict an
        // operator can read in the log - not a second, separately-derived opinion.
        VerdictStorePut(j.id, (wcscmp(verdict, L"bridge") == 0) ? ToastRouteBridge : ToastRouteWindow, plan, actClsid, lastRow);
    }
    catch (...)
    {
        BLog(L"CLASSIFY id=%u src=none etw=probe-threw verdict=window row_latency=0ms signals=none corr=probe-threw actions=none activator=not-asked", j.id);
    }
}

static DWORD WINAPI ShadowWorkerThread(LPVOID)
{
    NameThisThread(L"notifhost: shadow-worker");
    // No COM apartment here, as before: this thread's work is sqlite, the ETW ring and the classifier. The toast-
    // activator lookup it asks for (ADR-toasts 11) runs on a short-lived STA thread of its own, bounded
    // (ResolveToastActivator), so nothing this thread already does changes and nothing it waits on is unbounded.
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
    VerdictInit();
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
static void ShadowClassify(WinUserNotification const& un, uint32_t id, std::wstring const& aumid)
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
        ShadowJob j;
        j.id = id; j.aumid = aumid; j.title = tb.substr(0, tb.find(L'\x1f')); j.creationFt = creationFt;
        j.packaged = AumidPackaged(un, aumid);   // a cheap WinRT read, like the aumid: the action plan needs it
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

// ==================== actionable buttons (docs/ADR-toasts.md 11) ===========================
// The impure half of toastactions.h: who the sender's toast activator is, how a click is carried
// out, and what happens when it cannot be. The pure half (which actions a toast gets, the bounded
// table, the dispatch, the choice after a failure) is in the header and in toastactions_test.cpp.
//
// PROCESSES AND THREADS (review 2026-10-07, two rounds: every wait bounded, no leak, no existing thread
// changes apartment). The Start-menu shortcuts are read ONCE per run by a lowest-priority STA thread
// started with the bridge (ShortcutScanThread); per sender the activator is a registry read plus a map
// read, on the shadow worker, never a scan; only a row-4 COM toast waits for a scan still running,
// within kToastActRouteLookupBudgetMs (ToastActLookupHandoff). A CLICK is carried out by a short-lived CHILD PROCESS
// (`notifhost --act-exec <file>`, same user and session, CreateProcess - no Task Scheduler, no /tr
// limit): ShellExecute and a CLSCTX_LOCAL_SERVER CoCreateInstance/Activate may never return, and a
// process can be terminated where a thread cannot be cancelled. The main loop spawns the child, keeps
// its handle in the wait array (its exit wakes the loop), reaps it (the exit code is the outcome) or
// TERMINATES it at kToastActClickBoundMs (the decision-3 failure, exactly once: ToastActClickLedger),
// with at most kToastActInflightMax children at once (a refused click is a failure the user is told
// about). Only the main loop sends on the dom0 connection (sends are sequential), so the error notice
// goes from there too.

// --- who answers a toast activation for this AUMID ----------------------------------------
// The shell finds a Win32 app's toast activator in two places, both read as the shell reads them:
//   1. HKCR\AppUserModelId\<AUMID>  CustomActivator = "{CLSID}"  (REG_SZ) - the ToastNotificationManagerCompat
//      scheme modern unpackaged apps use (tools/toastfire's com-activator method writes exactly this);
//   2. a Start-menu shortcut (per-user or all-users Programs folder) whose property store carries
//      System.AppUserModel.ID = the AUMID and System.AppUserModel.ToastActivatorCLSID - the classic
//      installer-written registration.
// 1. is a registry read per toast (microseconds; HKCR merges HKCU\Software\Classes over HKLM's, as the shell sees
// it; an AUMID with '\' cannot be registered there - it would nest keys). 2. is read ONCE per bridge run into a map
// (toastactions.h ToastActShortcutMap) by a thread at the lowest priority in background mode, started with the
// bridge, refreshed at most once per TTL on a miss - never per sender and never on the classifier's thread (guest
// measurement 2026-10-07: a per-sender scan beside the classifier on 2 vCPUs tripled the first toast's latency).
static const PROPERTYKEY kPkeyAppUserModelId         = { { 0x9F4C2855, 0x9F79, 0x4B39, { 0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3 } }, 5 };
static const PROPERTYKEY kPkeyToastActivatorClsid    = { { 0x9F4C2855, 0x9F79, 0x4B39, { 0xA8, 0xD0, 0xE1, 0xD4, 0x2D, 0xE1, 0xD5, 0xF3 } }, 26 };
static const int         kLnkScanMaxDepth = 4;
static const int         kLnkScanMaxFiles = 4096;   // the whole Start menu, both Programs folders (typically 50-300 shortcuts)

static CRITICAL_SECTION g_activatorLock;
static bool g_activatorLockInit = false;
static ToastActShortcutMap g_shortcutMap;
static void ActivatorLockEnsure() { if (!g_activatorLockInit) { InitializeCriticalSection(&g_activatorLock); g_activatorLockInit = true; } }

static std::wstring LowerW(std::wstring s) { for (auto& c : s) if (c >= L'A' && c <= L'Z') c = (wchar_t)(c + 32); return s; }

static bool ClsidStringValid(std::wstring const& s)
{
    CLSID c;
    return !s.empty() && s.size() <= 40 && SUCCEEDED(CLSIDFromString(s.c_str(), &c));
}

static std::wstring ActivatorFromRegistry(std::wstring const& aumid)
{
    if (aumid.find(L'\\') != std::wstring::npos) return L"";
    HKEY k;
    std::wstring key = L"AppUserModelId\\" + aumid;
    if (RegOpenKeyExW(HKEY_CLASSES_ROOT, key.c_str(), 0, KEY_QUERY_VALUE, &k) != ERROR_SUCCESS) return L"";
    wchar_t buf[64] = { 0 }; DWORD cb = sizeof(buf) - sizeof(wchar_t), type = 0;
    LSTATUS st = RegQueryValueExW(k, L"CustomActivator", nullptr, &type, (BYTE*)buf, &cb);
    RegCloseKey(k);
    if (st != ERROR_SUCCESS || type != REG_SZ) return L"";
    std::wstring s(buf);
    return ClsidStringValid(s) ? s : L"";
}

// One Programs folder, recursively, EVERY shortcut: AUMID -> ToastActivatorCLSID ("" for a shortcut carrying the
// AUMID without an activator). Bounded; `files` counts the .lnk files opened across the whole scan. Needs the
// caller's COM apartment (IShellLink is apartment-threaded).
static void ShortcutScanDir(std::wstring const& dir, int depth, int& files, std::unordered_map<std::wstring, std::wstring>& out)
{
    if (depth > kLnkScanMaxDepth || files >= kLnkScanMaxFiles) return;
    WIN32_FIND_DATAW fd;
    HANDLE fh = FindFirstFileW((dir + L"\\*").c_str(), &fd);
    if (fh == INVALID_HANDLE_VALUE) return;
    do {
        if (fd.cFileName[0] == L'.' && (fd.cFileName[1] == 0 || (fd.cFileName[1] == L'.' && fd.cFileName[2] == 0))) continue;
        std::wstring path = dir + L"\\" + fd.cFileName;
        if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY)
        {
            if (fd.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) continue;   // no junction walks
            ShortcutScanDir(path, depth + 1, files, out);
            if (files >= kLnkScanMaxFiles) break;
            continue;
        }
        size_t n = wcslen(fd.cFileName);
        if (n < 5 || _wcsicmp(fd.cFileName + n - 4, L".lnk") != 0) continue;
        if (++files > kLnkScanMaxFiles) break;
        winrt::com_ptr<IShellLinkW> link;
        if (FAILED(CoCreateInstance(__uuidof(ShellLink), nullptr, CLSCTX_INPROC_SERVER, IID_PPV_ARGS(link.put())))) continue;
        auto pf = link.try_as<IPersistFile>();
        if (!pf || FAILED(pf->Load(path.c_str(), STGM_READ))) continue;
        auto store = link.try_as<IPropertyStore>();
        if (!store) continue;
        PROPVARIANT pvId; PropVariantInit(&pvId);
        std::wstring key;
        if (SUCCEEDED(store->GetValue(kPkeyAppUserModelId, &pvId)) && pvId.vt == VT_LPWSTR && pvId.pwszVal && pvId.pwszVal[0])
            key = LowerW(pvId.pwszVal);
        PropVariantClear(&pvId);
        if (key.empty()) continue;                      // an ordinary shortcut: no AUMID
        std::wstring clsid;
        PROPVARIANT pvClsid; PropVariantInit(&pvClsid);
        if (SUCCEEDED(store->GetValue(kPkeyToastActivatorClsid, &pvClsid)) && pvClsid.vt == VT_CLSID && pvClsid.puuid)
            clsid = GuidStr(*pvClsid.puuid);
        PropVariantClear(&pvClsid);
        auto it = out.find(key);
        if (it == out.end() || (it->second.empty() && !clsid.empty())) out[key] = clsid;   // several shortcuts, one AUMID: an activator wins
    } while (FindNextFileW(fh, &fd));
    FindClose(fh);
}

static int ShortcutScanAll(std::unordered_map<std::wstring, std::wstring>& out)
{
    int files = 0;
    static const int folders[2] = { CSIDL_PROGRAMS, CSIDL_COMMON_PROGRAMS };
    for (int csidl : folders)
    {
        wchar_t p[MAX_PATH] = { 0 };
        if (FAILED(SHGetFolderPathW(nullptr, csidl, nullptr, SHGFP_TYPE_CURRENT, p)) || !p[0]) continue;
        ShortcutScanDir(p, 0, files, out);
    }
    return files;
}

// THE ONE SCAN: a thread at the lowest priority in background mode (the policy is a rule in toastactions.h, with its
// knob), its own STA; the whole map is swapped in at the end, whether or not anyone is waiting for it.
static DWORD WINAPI ShortcutScanThread(LPVOID)
{
    NameThisThread(L"notifhost: shortcut-scan");
    const ToastActScanPolicy pol = ToastActScanPolicyGet();
    if (pol.prio == ToastActScanPrio::Lowest) SetThreadPriority(GetCurrentThread(), THREAD_PRIORITY_LOWEST);
    const bool bg = pol.backgroundIo && SetThreadPriority(GetCurrentThread(), THREAD_MODE_BACKGROUND_BEGIN);
    const bool co = SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE));
    std::unordered_map<std::wstring, std::wstring> entries;
    int files = 0;
    const ULONGLONG t0 = GetTickCount64();
    try
    {
        if (co) files = ShortcutScanAll(entries);
        else BLog(L"ACTIVATOR scan: no COM apartment - the shortcut map is empty this run (registry-only lookups)");
    }
    catch (...) { BLog(L"ACTIVATOR scan threw - the map holds what was read before it"); }
    unsigned withActivator = 0;
    for (auto const& kv : entries) if (!kv.second.empty()) withActivator++;
    if (bg) SetThreadPriority(GetCurrentThread(), THREAD_MODE_BACKGROUND_END);
    if (co) CoUninitialize();
    const size_t senders = entries.size();
    {
        ActivatorLockEnsure();
        CsGuard g(&g_activatorLock);
        g_shortcutMap.EndScan(std::move(entries), GetTickCount64());
    }
    BLog(L"ACTIVATOR scan done: %d shortcut(s) read, %u sender(s) carry an AUMID, %u an activator, ms=%llu (%s%s); refreshed at most "
         L"once per %u min, on a miss", files, (UINT)senders, withActivator, GetTickCount64() - t0,
         pol.prio == ToastActScanPrio::Lowest ? L"lowest priority" : L"NORMAL priority", bg ? L", background mode" : L"",
         (UINT)(kToastActScanTtlMs / 60000));
    return 0;
}

static void ShortcutScanStart(const wchar_t* reason)
{
    ActivatorLockEnsure();
    const wchar_t* why = nullptr;
    {
        CsGuard g(&g_activatorLock);
        if (!g_shortcutMap.BeginScan(GetTickCount64(), &why)) { BLog(L"ACTIVATOR scan not started (%s): %s", reason, why); return; }
    }
    HANDLE t = CreateThread(nullptr, 0, ShortcutScanThread, nullptr, 0, nullptr);
    if (!t)
    {
        const DWORD gle = GetLastError();
        { CsGuard g(&g_activatorLock); g_shortcutMap.AbortScan(); }
        BLog(L"ACTIVATOR scan thread create failed %lu (%s) - registry-only lookups until the next attempt", gle, reason);
        return;
    }
    CloseHandle(t);   // detached: it swaps the map in and exits
    BLog(L"ACTIVATOR scan started (%s): the Start menu is read once, at the lowest priority, into the AUMID -> activator map", reason);
}

// Non-blocking, any thread: the sender's activator from the registry (read now) and the shortcut map; starts the one
// scan or refresh when the map asks for it. Known / None / Unknown (the map is not built yet).
static ToastActActivator ActivatorResolveNow(std::wstring const& aumid, std::wstring& clsid, const wchar_t*& src)
{
    const std::wstring reg = ActivatorFromRegistry(aumid);
    bool refresh = false;
    ToastActActivator st;
    {
        ActivatorLockEnsure();
        CsGuard g(&g_activatorLock);
        st = g_shortcutMap.Resolve(LowerW(aumid), reg, GetTickCount64(), clsid, src, &refresh);
    }
    if (refresh) ShortcutScanStart(st == ToastActActivator::Unknown ? L"no map yet" : L"a miss against a map older than its TTL");
    return st;
}

static std::shared_ptr<ToastActLookupHandoff> ShortcutScanHandoff()
{
    ActivatorLockEnsure();
    CsGuard g(&g_activatorLock);
    return g_shortcutMap.ScanHandoff();
}

// The sender's toast activator CLSID ("{...}") or empty, waiting up to kToastActLookupBoundMs for the scan when the map
// is not built yet - for the by-hand diagnostics (--resolve-activator / --invoke-activator) only; the classification
// never waits like this (ShadowClassifyWork). *source: registry | shortcut | shortcut-no-activator | none | timeout.
static std::wstring ResolveToastActivator(std::wstring const& aumid, const wchar_t** source)
{
    *source = L"none";
    if (aumid.empty()) return L"";
    std::wstring clsid; const wchar_t* src = L"none";
    ToastActActivator st = ActivatorResolveNow(aumid, clsid, src);
    if (st == ToastActActivator::Unknown)
    {
        auto h = ShortcutScanHandoff();
        std::wstring ignored; const wchar_t* ignoredSrc = nullptr;
        if (h && h->WaitFor(kToastActLookupBoundMs, ignored, ignoredSrc)) st = ActivatorResolveNow(aumid, clsid, src);
        if (st == ToastActActivator::Unknown)
        {
            BLog(L"ACTIVATOR the shortcut scan did not finish within %llu ms - %s unknown this time", (ULONGLONG)kToastActLookupBoundMs, aumid.c_str());
            *source = L"timeout";
            return L"";
        }
    }
    *source = src;
    return clsid;
}

// A packaged (PFN!App) sender, from the listener's AppInfo when it says so, else from the AUMID's shape.
static bool AumidPackaged(WinUserNotification const& un, std::wstring const& aumid)
{
    try { if (!un.AppInfo().PackageFamilyName().empty()) return true; } catch (...) {}
    return aumid.find(L'!') != std::wstring::npos;
}

// --- the per-notification table and the clicks in flight ---------------------------------------
static CRITICAL_SECTION g_actLock;          // guards g_actTable, g_actLedger, g_actClicks, g_actFails (initialised in BridgeMain)
static ToastActTable g_actTable;
static ToastActClickLedger g_actLedger;     // admission, the click bound, one outcome per click (toastactions.h)
static uint64_t g_actClickSeq = 0;          // click tokens

// A click in flight: the toast and key (for the outcome's log line and notice), and - once the main loop has
// spawned it - the child process carrying it out, its start tick (the bound counts from here) and the
// instruction file it reads. Admitted on the reader thread, spawned/reaped/killed on the main loop.
struct ActClickInfo
{
    ToastActEntry entry;
    std::string   key;
    HANDLE        process = nullptr;   // nullptr until spawned
    DWORD         pid = 0;
    ULONGLONG     startedAt = 0;
    std::wstring  file;
};
static std::unordered_map<uint64_t, ActClickInfo> g_actClicks;   // token -> info, while the click is unresolved

// A failed click awaiting its outcome on the main loop (toastactions.h ToastActFailChoice).
struct ActFail
{
    uint32_t  guestId;
    LONG      seq;            // the hold record turned window (0: it was gone)
    bool      recordFound;
    ULONGLONG flippedAt;
    std::wstring app, title, label, detail;
    std::string key;
    ToastActEntry entry;      // for the notice text (the action is re-found in it by key)
};
static std::vector<ActFail> g_actFails;   // g_actLock; bounded by the ledger's caps + the notice give-up

// THE FAILURE PATH (Jev 2026-10-06, 0.71), from any thread: the toast's record turns `window` - the agent reopens
// the banner if it is still displayed (rule 4 of the hold) and marks the record shown; the main loop reads that
// mark within kToastActShowBoundMs and sends the dom0 error notice when there is none.
static void ActFailQueue(ToastActEntry const& entry, std::string const& key, std::wstring const& detail, const wchar_t* how)
{
    const uint32_t id = entry.guestId;
    LONG seq = 0;
    const bool found = HoldVerdictSeq(id, TH_VERDICT_WINDOW, false, &seq);
    BLog(L"ACTION id=%u dom0=%u key=%hs %s: %s - record %s (seq %ld); the guest banner is reopened if it is still "
         L"displayed, else dom0 gets an error notice", id, entry.dom0Id, key.c_str(), how, detail.c_str(),
         found ? L"turned window" : L"gone from the ring", seq);
    ActFail f;
    f.guestId = id; f.seq = seq; f.recordFound = found; f.flippedAt = GetTickCount64();
    f.app = entry.app; f.title = entry.title; f.label = L"?"; f.detail = detail;
    f.key = key; f.entry = entry;
    for (auto const& a : f.entry.plan.actions) if (a.key == key) f.label = a.label;
    {
        CsGuard g(&g_actLock);
        if (g_actFails.size() < 32) g_actFails.push_back(std::move(f));
        else BLog(L"ACTION id=%u failure queue full - its dom0 notice is dropped (logged here instead)", id);
    }
    if (g_mainWake) SetEvent(g_mainWake);   // the main loop pumps g_actFails on every wake (no listing is asked for)
}

// --- carrying out a click (the click thread) ------------------------------------------------
struct WinToastActivator : ToastActivator
{
    static std::wstring Hr(HRESULT hr) { wchar_t b[16]; swprintf(b, RTL_NUMBER_OF(b), L"0x%08X", (unsigned)hr); return b; }
    bool Protocol(std::wstring const& uri, std::wstring& detail) override
    {
        // What the shell does for a protocol activation: open the URI as the user; no UI on failure (the
        // failure is reported through our own paths). The thread is an STA (ShellExecuteEx's requirement).
        SHELLEXECUTEINFOW sei = { sizeof(sei) };
        sei.fMask = SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
        sei.lpVerb = L"open";
        sei.lpFile = uri.c_str();
        sei.nShow = SW_SHOWNORMAL;
        if (ShellExecuteExW(&sei)) return true;
        detail = L"ShellExecute failed, Windows error " + std::to_wstring(GetLastError());
        return false;
    }
    bool Com(std::wstring const& clsid, std::wstring const& aumid, std::wstring const& args, std::wstring& detail) override
    {
        // The shell's own call for a Win32 toast activation: CoCreate the registered activator as a local
        // server (launches the app if it is not running) and Activate(aumid, arguments, inputs, count) with no
        // user input (toasts with inputs never reach this route).
        CLSID c;
        if (FAILED(CLSIDFromString(clsid.c_str(), &c))) { detail = L"activator CLSID unparseable"; return false; }
        winrt::com_ptr<INotificationActivationCallback> cb;
        HRESULT hr = CoCreateInstance(c, nullptr, CLSCTX_LOCAL_SERVER, IID_PPV_ARGS(cb.put()));
        if (FAILED(hr)) { detail = L"the sender's toast activator could not be created (CoCreateInstance " + Hr(hr) + L")"; return false; }
        hr = cb->Activate(aumid.c_str(), args.c_str(), nullptr, 0);
        if (FAILED(hr)) { detail = L"the sender's activator refused the activation (Activate " + Hr(hr) + L")"; return false; }
        return true;
    }
};

// --- the instruction file: parent -> child --------------------------------------------------------
// UTF-16LE with BOM, in the bridge's state dir: line 1 kind (protocol|com), line 2 AUMID, line 3 CLSID (empty for
// protocol), then the rest of the file verbatim = the argument (the URI, or the Activate arguments - which may
// hold anything, newlines included; nothing of ours parses it). A file rather than the command line: no quoting
// rules, no length limit, the same shape --notify-file already uses. The child deletes it after reading; the
// parent deletes it if the child never read it.
static std::wstring ActFilePath(uint64_t token)
{
    return StateDir() + L"\\act-" + std::to_wstring(GetCurrentProcessId()) + L"-" + std::to_wstring((unsigned long long)token) + L".txt";
}

static bool ActFileWrite(std::wstring const& path, ToastActEntry const& e, ToastAct const& a)
{
    std::wstring text = (a.kind == ToastActKind::Protocol ? L"protocol" : L"com");
    text += L"\n"; text += e.aumid;
    text += L"\n"; text += e.clsid;
    text += L"\n"; text += a.arg;
    std::vector<BYTE> raw; raw.push_back(0xFF); raw.push_back(0xFE);
    raw.insert(raw.end(), (const BYTE*)text.data(), (const BYTE*)text.data() + text.size() * sizeof(wchar_t));
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD wr = 0;
    const BOOL ok = WriteFile(h, raw.data(), (DWORD)raw.size(), &wr, nullptr);
    CloseHandle(h);
    return ok && wr == raw.size();
}

static bool ActFileRead(std::wstring const& path, std::wstring& kind, std::wstring& aumid, std::wstring& clsid, std::wstring& arg)
{
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    std::vector<BYTE> buf(64 * 1024);
    DWORD rd = 0;
    const BOOL ok = ReadFile(h, buf.data(), (DWORD)buf.size() - 2, &rd, nullptr);
    CloseHandle(h);
    DeleteFileW(path.c_str());   // one-shot instructions, never state
    if (!ok || rd < 2 || buf[0] != 0xFF || buf[1] != 0xFE || (rd & 1)) return false;
    std::wstring all((const wchar_t*)(buf.data() + 2), (rd - 2) / sizeof(wchar_t));
    size_t n1 = all.find(L'\n');
    if (n1 == std::wstring::npos) return false;
    size_t n2 = all.find(L'\n', n1 + 1);
    if (n2 == std::wstring::npos) return false;
    size_t n3 = all.find(L'\n', n2 + 1);
    if (n3 == std::wstring::npos) return false;
    kind = all.substr(0, n1);
    aumid = all.substr(n1 + 1, n2 - n1 - 1);
    clsid = all.substr(n2 + 1, n3 - n2 - 1);
    arg = all.substr(n3 + 1);
    return kind == L"protocol" || kind == L"com";
}

// --- the child: `notifhost --act-exec <file>` -----------------------------------------------------
// One activation, in a process of its own (same user, same session, started by the bridge with CreateProcess),
// so that an activation that never answers leaves a PROCESS the bridge terminates at the bound - not a thread it
// would carry for ever. Exit: 0 carried out, 2 the activation failed (the ACTEXEC line in bridge.log has the
// HRESULT / Windows error), 3 the instructions could not be read. The same WinToastActivator the by-hand
// --invoke-activator diagnostic uses.
static int ActExecMain(const wchar_t* file)
{
    std::wstring kind, aumid, clsid, arg;
    if (!ActFileRead(file, kind, aumid, clsid, arg))
    {
        BLog(L"ACTEXEC pid=%lu: instruction file %s unreadable or malformed - nothing activated", GetCurrentProcessId(), file);
        return (int)kToastActExitBadInput;
    }
    const bool co = SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE));
    bool ok = false;
    std::wstring detail;
    try
    {
        WinToastActivator wa;
        if (!co) detail = L"COM apartment init failed in the child";
        else ok = (kind == L"protocol") ? wa.Protocol(arg, detail) : wa.Com(clsid, aumid, arg, detail);
    }
    catch (...) { ok = false; detail = L"the activation threw"; }
    if (co) CoUninitialize();
    BLog(L"ACTEXEC pid=%lu kind=%s aumid=%s result=%s%s%s", GetCurrentProcessId(), kind.c_str(), aumid.c_str(),
         ok ? L"OK" : L"FAIL", ok ? L"" : L" detail=", ok ? L"" : detail.c_str());
    return ok ? (int)kToastActExitOk : (int)kToastActExitFailed;
}

// --- the parent: admission (reader thread), spawn / reap / kill (main loop) ------------------------

// Reader thread: dom0 invoked `key` on its notification `dom0Id`. Finds the toast in the table, admits the click
// under the ledger's cap and hands it to the main loop, which spawns the child. Everything unexpected is logged;
// a refused click is a failure (the user is told), never silence.
static void ActionInvoke(uint32_t dom0Id, std::string const& key)
{
    const wchar_t* why = nullptr;
    ToastActEntry refused;
    bool haveRefused = false;
    size_t inflight = 0;
    {
        CsGuard g(&g_actLock);
        const ULONGLONG now = GetTickCount64();
        g_actTable.Expire(now);
        const ToastActEntry* e = g_actTable.FindDom0(dom0Id);
        if (!e)
        {
            BLog(L"ACTION dom0=%u key=%hs: no forwarded toast with actions under that id (expired, dismissed, or another "
                 L"connection's id) - ignored", dom0Id, key.c_str());
            return;
        }
        const uint64_t token = ++g_actClickSeq;
        if (g_actLedger.Admit(token, now, &why))
        {
            ActClickInfo info; info.entry = *e; info.key = key;
            g_actClicks[token] = std::move(info);
        }
        else { refused = *e; haveRefused = true; }
        inflight = g_actLedger.Inflight();
    }
    if (haveRefused)
    {
        BLog(L"ACTION id=%u dom0=%u key=%hs REFUSED: %s (%u in flight) - treated as a failure",
             refused.guestId, dom0Id, key.c_str(), why ? why : L"-", (UINT)inflight);
        ActFailQueue(refused, key, why ? why : L"refused", L"REFUSED");
        return;
    }
    if (g_mainWake) SetEvent(g_mainWake);   // the main loop spawns the child on this wake
}

// Main loop: spawn the child for one admitted click. Returns false (and the caller fails the click) when it cannot.
static bool ActChildSpawn(uint64_t token, ActClickInfo& info, std::wstring& why)
{
    const ToastAct* act = nullptr;
    for (auto const& a : info.entry.plan.actions) if (a.key == info.key) act = &a;
    if (!act) { why = L"dom0 invoked an action this toast never carried"; return false; }
    info.file = ActFilePath(token);
    if (!ActFileWrite(info.file, info.entry, *act)) { why = L"the instruction file could not be written"; return false; }
    wchar_t self[MAX_PATH] = { 0 };
    GetModuleFileNameW(nullptr, self, RTL_NUMBER_OF(self));
    std::wstring cmd = L"\"" + std::wstring(self) + L"\" --act-exec \"" + info.file + L"\"";
    std::vector<wchar_t> cmdBuf(cmd.begin(), cmd.end()); cmdBuf.push_back(0);
    STARTUPINFOW si = { sizeof(si) }; PROCESS_INFORMATION pi = {};
    if (!CreateProcessW(nullptr, cmdBuf.data(), nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi))
    {
        why = L"the activation process could not be started, Windows error " + std::to_wstring(GetLastError());
        DeleteFileW(info.file.c_str());
        return false;
    }
    CloseHandle(pi.hThread);
    info.process = pi.hProcess;
    info.pid = pi.dwProcessId;
    info.startedAt = GetTickCount64();
    BLog(L"ACTION id=%u dom0=%u key=%hs kind=%s -> child pid %lu (bound %llu ms)", info.entry.guestId, info.entry.dom0Id, info.key.c_str(),
         act->kind == ToastActKind::Protocol ? L"protocol" : L"com", pi.dwProcessId, (ULONGLONG)kToastActClickBoundMs);
    return true;
}

// Main loop: the process handles of the children in flight, for the wait array (a child's exit wakes the loop).
static DWORD ActChildHandles(HANDLE* out, DWORD cap)
{
    DWORD n = 0;
    CsGuard g(&g_actLock);
    for (auto const& kv : g_actClicks)
        if (kv.second.process && n < cap) out[n++] = kv.second.process;
    return n;
}

// --- in-guest instruments for the activation path (the dom0 click itself needs a human) ------
// --resolve-activator <AUMID>: what the bridge would resolve for that sender, the way the click handler does.
//   ACTIVATOR aumid=<a> clsid=<{...}|-> source=registry|shortcut|none      exit 0 found, 2 none
// --invoke-activator <AUMID> [<arguments>]: the COM activation the click handler performs, by hand - against
//   tools/toastfire's com-activator registration this proves CoCreateInstance + Activate() end to end in the
//   guest without dom0 (toastfire records the Activate call it received).
//   INVOKE aumid=<a> clsid=<{...}> args='<args>' result=OK|FAIL detail=<why>            exit 0 ok, 2 failed
// Both run in the invoking user's session and apartment (STA, like the click thread).
static int ResolveActivatorMain(const wchar_t* aumid)
{
    const bool co = SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE));
    const wchar_t* source = L"none";
    std::wstring clsid = ResolveToastActivator(aumid, &source);
    wprintf(L"ACTIVATOR aumid=%s clsid=%s source=%s\n", aumid, clsid.empty() ? L"-" : clsid.c_str(), source);
    if (co) CoUninitialize();
    return clsid.empty() ? 2 : 0;
}

static int InvokeActivatorMain(const wchar_t* aumid, const wchar_t* args)
{
    const bool co = SUCCEEDED(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE));
    const wchar_t* source = L"none";
    std::wstring clsid = ResolveToastActivator(aumid, &source);
    if (clsid.empty())
    {
        wprintf(L"INVOKE aumid=%s clsid=- args='%s' result=FAIL detail=no toast activator registered for this AUMID (source=%s)\n", aumid, args ? args : L"", source);
        if (co) CoUninitialize();
        return 2;
    }
    WinToastActivator wa;
    std::wstring detail;
    const bool ok = wa.Com(clsid, aumid, args ? args : L"", detail);
    wprintf(L"INVOKE aumid=%s clsid=%s args='%s' result=%s detail=%s\n", aumid, clsid.c_str(), args ? args : L"",
            ok ? L"OK" : L"FAIL", ok ? L"Activate returned S_OK" : detail.c_str());
    BLog(L"INVOKE (by hand) aumid=%s clsid=%s result=%s %s", aumid, clsid.c_str(), ok ? L"OK" : L"FAIL", detail.c_str());
    if (co) CoUninitialize();
    return ok ? 0 : 2;
}

// --- the long-lived connection ------------------------------------------------------------
// Resident end of a named pipe; the vchan end is a --relay child spawned in this same
// session by qrexec-agent (via qrexec-client-vm). All protocol state lives here.

#define NOTIFY_MAX_FRAME 0x1000000u   // MAX_MESSAGE_SIZE, server-enforced

static HANDLE g_pipe = INVALID_HANDLE_VALUE;
static HANDLE g_rdEvt = nullptr, g_wrEvt = nullptr;   // per-direction OVERLAPPED events
static HANDLE g_connStop = nullptr;                   // manual-reset: aborts in-flight pipe i/o
static HANDLE g_reader = nullptr;
// g_connDead: defined with the bridge globals near the top (VerdictStorePut reads it).

static HANDLE g_ackEvt = nullptr;                     // auto-reset; sends are sequential
static volatile ULONGLONG g_awaitSeq = 0;
static volatile LONG g_awaitOk = 0;                   // 1 acked, 0 failed

struct CorrEntry { uint64_t seq; uint32_t guestId; uint32_t dom0Id; ULONGLONG born; };
static CRITICAL_SECTION g_corrLock;
static std::vector<CorrEntry> g_corr;                 // small: capped, human-rate
static std::vector<uint32_t> g_pendingDismiss;        // guest ids queued by the reader thread

static void MarkConnDead() { InterlockedExchange(&g_connDead, 1); InterlockedExchange(&g_listWanted, 1); if (g_mainWake) SetEvent(g_mainWake); }

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
    NameThisThread(L"notifhost: reader");
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
            // The actions table entry for this frame (put before the send, ADR-toasts 11) learns the proxy's id
            // HERE - the id Dismissed and ActionInvoked will carry - before anything can be invoked on it.
            { CsGuard g(&g_actLock); g_actTable.SetDom0Id(seq, id); }
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
            // The actions of a notification the user dismissed (2) or the daemon was told to close (3) can no
            // longer be invoked: its table entry goes after a short grace (the daemon's ActionInvoked for the same
            // click can arrive after its NotificationClosed). An expiry (1) keeps it: a daemon that keeps the
            // notification in a list still lets the user invoke its actions - the TTL bounds that.
            if (reason == 2 || reason == 3) { CsGuard g(&g_actLock); g_actTable.Dismiss(id, GetTickCount64()); }
            if (reason != 2) BLog(L"Dismissed id=%u reason=%u (not user-dismissed - guest record kept)", id, reason);
            else { InterlockedExchange(&g_listWanted, 1); if (g_mainWake) SetEvent(g_mainWake); }   // the main loop applies queued dismissals on its next pass
        }
        else if (tag == 4)                            // ActionInvoked{id u32, action String}: a dom0 click (ADR-toasts 11)
        {
            uint32_t id = 0; std::string key;
            if (ToastActParseInvoked(p.data(), len, id, key)) ActionInvoke(id, key);
            else BLog(L"reader: malformed ActionInvoked frame (len %u) - ignored", len);
        }
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
    {
        CsGuard g(&g_actLock);    // the actions table is keyed by the same per-connection dom0 ids
        if (g_actTable.Size()) BLog(L"ACTION table cleared on connection loss (%u toast(s) lose their dom0 actions)", (UINT)g_actTable.Size());
        g_actTable.Clear();
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
// `actions`: the freedesktop list (alternating key, label) for a toast forwarded with its buttons (ADR-toasts 11);
// *seqOut (optional) receives the frame's sequence, which the actions table keys the dom0 id by.
static bool ForwardText(std::wstring const& title, std::wstring const& body, uint32_t guestId, NotifyKind kind = NotifyKind::Info,
                        std::vector<std::string> const& actions = {}, uint64_t* seqOut = nullptr)
{
    if (g_connDead) return false;
    uint64_t seq = ++g_seq;
    if (seqOut) *seqOut = seq;
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

    auto frame = EncodeNotifyFrame(seq, Utf8(title.empty() ? L"Notification" : title), Utf8(body), kind, actions);
    g_awaitSeq = seq; g_awaitOk = 0; ResetEvent(g_ackEvt);
    if (!PipeXfer(FALSE, frame.data(), (DWORD)frame.size(), 15000)) { rtt(-1); MarkConnDead(); return false; }
    if (WaitForSingleObject(g_ackEvt, 15000) != WAIT_OBJECT_0)
    { rtt(-2); BLog(L"send seq=%llu: ack timeout", (ULONGLONG)seq); MarkConnDead(); return false; }
    rtt(g_awaitOk == 1 ? 1 : 0);
    return g_awaitOk == 1;
}

// The dom0 id the proxy gave our frame `seq` (the reader stores it from the Id reply before it signals the
// ack, so after a successful ForwardText it is in hand); 0 = not known.
static uint32_t CorrDom0Id(uint64_t seq)
{
    CsGuard g(&g_corrLock);
    for (auto const& e : g_corr) if (e.seq == seq) return e.dom0Id;
    return 0;
}

// --- the clicks (main loop): spawn, reap, kill; then the failures ------------------------------------
// 1. An admitted click not yet spawned gets its child (ActChildSpawn); a child that exited is reaped - its exit
//    code is the outcome (ToastActExitOutcome); a child still running at kToastActClickBoundMs is TERMINATED and
//    the click fails (ToastActChildDecide: Reap / Kill / Keep). The ledger makes each outcome the only one.
// 2. Pumps g_actFails: a failure whose record the agent marked shown is closed (the user has the guest's
//    buttons); one without a mark at the bound - or whose record was already gone - becomes a dom0 ERROR notice
//    (stays until dismissed) over the live connection, retried on every pass while dom0 is unreachable and given
//    up loudly after kToastActNoticeGiveUpMs.
// *nextDue is the earliest tick a child's bound or a pending failure wants a pass.
static void ActPump(ULONGLONG now, ULONGLONG* nextDue)
{
    struct Outcome { uint64_t token; ActClickInfo info; ToastActChildStep step; DWORD exitCode; bool noChild; std::wstring why; };
    std::vector<Outcome> outcomes;
    {
        CsGuard g(&g_actLock);   // held across CreateProcess/TerminateProcess: both return at once; the reader waits milliseconds at most
        for (auto it = g_actClicks.begin(); it != g_actClicks.end(); )
        {
            ActClickInfo& info = it->second;
            if (!info.process)
            {
                std::wstring why;
                if (ActChildSpawn(it->first, info, why)) { ++it; continue; }
                if (g_actLedger.Done(it->first)) outcomes.push_back({ it->first, info, ToastActChildStep::Keep, 0, true, why });   // no child: failed at once
                it = g_actClicks.erase(it);
                continue;
            }
            const bool exited = WaitForSingleObject(info.process, 0) == WAIT_OBJECT_0;
            const ToastActChildStep step = ToastActChildDecide(exited, now, info.startedAt);
            if (step == ToastActChildStep::Keep)
            {
                const ULONGLONG due = info.startedAt + kToastActClickBoundMs;
                if (*nextDue == 0 || due < *nextDue) *nextDue = due;
                ++it;
                continue;
            }
            DWORD code = 259;
            if (step == ToastActChildStep::Reap) GetExitCodeProcess(info.process, &code);
            if (step == ToastActChildStep::Kill) { TerminateProcess(info.process, 1); DeleteFileW(info.file.c_str()); }   // asynchronous: the handle is closed below, the kernel finishes it
            const bool owns = g_actLedger.Done(it->first);
            CloseHandle(info.process); info.process = nullptr;
            if (owns) outcomes.push_back({ it->first, info, step, code, false, L"" });
            else BLog(L"ACTION id=%u key=%hs: outcome already reported (a bug of ours) - not reported twice", info.entry.guestId, info.key.c_str());
            it = g_actClicks.erase(it);
        }
    }
    for (auto& o : outcomes)
    {
        const uint32_t id = o.info.entry.guestId;
        if (o.noChild)
            ActFailQueue(o.info.entry, o.info.key, o.why, L"FAILED");
        else if (o.step == ToastActChildStep::Reap)
        {
            const wchar_t* detail = L"";
            const ToastActResult r = ToastActExitOutcome(o.exitCode, &detail);
            if (r == ToastActResult::Done)
                BLog(L"ACTION id=%u dom0=%u key=%hs OK - carried out in the guest by child pid %lu", id, o.info.entry.dom0Id, o.info.key.c_str(), o.info.pid);
            else
            {
                wchar_t code[16]; swprintf(code, RTL_NUMBER_OF(code), L"0x%08X", (unsigned)o.exitCode);
                ActFailQueue(o.info.entry, o.info.key, std::wstring(detail) + L" (child pid " + std::to_wstring(o.info.pid) + L" exit " + code + L")", L"FAILED");
            }
        }
        else if (o.step == ToastActChildStep::Kill)
        {
            BLog(L"ACTION id=%u dom0=%u key=%hs TIMED OUT: child pid %lu gave no answer within %llu ms (stuck in CoCreateInstance/"
                 L"Activate/ShellExecute) - TERMINATED, reported as failed", id, o.info.entry.dom0Id, o.info.key.c_str(), o.info.pid,
                 (ULONGLONG)kToastActClickBoundMs);
            ActFailQueue(o.info.entry, o.info.key, L"the activation did not answer within " + std::to_wstring(kToastActClickBoundMs / 1000) +
                         L" s and its process was terminated", L"TIMED OUT");
        }
    }

    std::vector<ActFail> pending;
    {
        CsGuard g(&g_actLock);
        pending.swap(g_actFails);
    }
    if (pending.empty()) return;
    std::vector<ActFail> keep;
    for (auto& f : pending)
    {
        const LONG mark = f.recordFound ? HoldAgentState(f.seq) : TH_AGENT_NONE;
        const ToastActAfterFail c = ToastActFailChoice(f.recordFound, mark, !g_connDead, now, f.flippedAt);
        if (c == ToastActAfterFail::BannerShown)
        {
            BLog(L"ACTION id=%u key=%hs failure resolved: the agent reopened the guest banner (its buttons are the user's way now) "
                 L"after %llu ms", f.guestId, f.key.c_str(), now - f.flippedAt);
            continue;
        }
        if (c == ToastActAfterFail::Wait)
        {
            const ULONGLONG due = f.flippedAt + (f.recordFound ? kToastActShowBoundMs : 0);
            if (due > now && (*nextDue == 0 || due < *nextDue)) *nextDue = due;
            keep.push_back(std::move(f));
            continue;
        }
        if (c == ToastActAfterFail::GiveUp)
        {
            BLog(L"ACTION id=%u key=%hs failure UNREPORTED: dom0 unreachable for %llu ms - the notice is given up (the toast is "
                 L"in the guest's Notification Center)", f.guestId, f.key.c_str(), now - f.flippedAt);
            continue;
        }
        // Notice
        const ToastAct* act = nullptr;
        for (auto const& a : f.entry.plan.actions) if (a.key == f.key) act = &a;
        std::wstring summary, body;
        ToastActNoticeText(f.entry, act, f.detail, summary, body);
        const bool ok = ForwardText(summary, body, 0, NotifyKind::Error);
        BLog(L"ACTION id=%u key=%hs failure reported to dom0 as an error notice: %s (banner %s)", f.guestId, f.key.c_str(),
             ok ? L"OK" : L"FAIL (connection; retried)", f.recordFound ? L"gone before the correction could show it" : L"record already gone");
        if (!ok) keep.push_back(std::move(f));
    }
    if (!keep.empty())
    {
        CsGuard g(&g_actLock);
        for (auto& f : keep) g_actFails.push_back(std::move(f));
    }
}

// --- one-shot notification (--notify) ------------------------------------------------------
//
// AGENT-ORIGINATED diagnostic, not guest content: the gui-agent uses this to put a failure in
// FRONT OF THE USER when it cannot show a window at all (owner 2026-09-06 - a suppressed window
// needs "something user sees", not only a log line). It reuses the bridge's proven wire path -
// spawn a --relay child on qubes.Notifications, handshake, send one frame, wait for the ack -
// and then exits, so nothing stays resident and no banner suppression is involved.
//
// DELIBERATELY NOT gated by the notify-bridge feature: that gate governs FORWARDING THE GUEST'S
// OWN TOASTS (per-AUMID allowlist, content from apps). This message is the agent reporting its
// own inability to render, which is exactly what must not be silently swallowed. dom0 still owns
// origin labelling and sanitisation, and a dom0 policy that denies qubes.Notifications simply
// makes this fail - logged, never fatal, never retried in a loop (the agent throttles).
//
// Exit: 0 sent+acked, 3 could not connect (policy refusal / no session), 4 sent but not acked.
// Read the message from a FILE rather than the command line. The agent launches this helper
// through the Task Scheduler (NotifRunInSession), whose /tr string cannot carry quoted,
// space-bearing text without being mangled - so the agent writes the text and passes only a
// path. Line 1 = summary, the rest = body. UTF-16LE (BOM) or UTF-8. The file is deleted after
// reading: it is a one-shot message, never state.
static bool ReadNotifyFile(std::wstring const& path, std::wstring& summary, std::wstring& body)
{
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    std::vector<BYTE> buf(64 * 1024);
    DWORD rd = 0;
    BOOL ok = ReadFile(h, buf.data(), (DWORD)buf.size() - 2, &rd, nullptr);
    CloseHandle(h);
    DeleteFileW(path.c_str());
    if (!ok || rd == 0) return false;
    std::wstring all;
    if (rd >= 2 && buf[0] == 0xFF && buf[1] == 0xFE)
        all.assign((wchar_t*)(buf.data() + 2), (rd - 2) / sizeof(wchar_t));
    else
    {
        int n = MultiByteToWideChar(CP_UTF8, 0, (char*)buf.data(), (int)rd, nullptr, 0);
        if (n <= 0) return false;
        all.resize(n);
        MultiByteToWideChar(CP_UTF8, 0, (char*)buf.data(), (int)rd, &all[0], n);
    }
    while (!all.empty() && (all.back() == L'\0')) all.pop_back();
    size_t nl = all.find_first_of(L"\r\n");
    if (nl == std::wstring::npos) { summary = all; body.clear(); return !summary.empty(); }
    summary = all.substr(0, nl);
    size_t b = all.find_first_not_of(L"\r\n", nl);
    body = (b == std::wstring::npos) ? L"" : all.substr(b);
    return !summary.empty();
}

// Hand a one-shot notification to the INTERACTIVE session and return true if that was arranged.
//
// WHY THIS EXISTS - the defect it fixes made the whole error-notify route inert in the only context
// it actually ships in. ConnUp() spawns the relay through qrexec-client-vm, and qrexec-agent runs
// that relay in the interactive session; a caller sitting in session 0 never gets a connection back,
// so every send failed with "relay never connected". EVERY REAL CALLER IS IN SESSION 0: gui-agent is
// a SYSTEM service, and activate-idd.ps1 / deactivate-idd.ps1 run from the installer as SYSTEM. The
// route therefore worked only when driven by hand from a user session - which is exactly why it
// passed every ack-level test (the helper returns 'send' as soon as this process is launched, it
// does not wait) and had never once been seen to put a bubble on screen.
//
// Measured on win11-nfy 2026-09-09, same binary, same guest, same minute:
//   SYSTEM / session 0        -> "relay never connected" -> nothing on screen
//   interactive user session  -> "connected" -> FWD_RTT ok=1 -> "sent ok=1" -> bubble photographed
//
// The mechanism is the one the agent already uses to launch wgcbroker.exe (WgcLaunch in main.c):
// resolve the active console session, get its user, and schedule the task /ru <user> /it. The 8.3
// SHORT path is not decoration - the long path contains spaces and schtasks parses /tr by
// whitespace, which really does fail with "Invalid argument/option - 'Files\Qubes'".
// Defined further down (with the NOTIFYERR self-reporting code); declared here because the handoff
// writes its notify file before that point in the file.
static bool WriteSmallA(std::wstring const& path, const void* data, DWORD len);

static bool NotifyHandoffToSession(std::wstring const& summary, std::wstring const& body)
{
    DWORD mySession = 0;
    ProcessIdToSessionId(GetCurrentProcessId(), &mySession);
    DWORD active = WTSGetActiveConsoleSessionId();
    if (active == 0xFFFFFFFF) { BLog(L"NOTIFY handoff: no active console session"); return false; }

    wchar_t* user = nullptr; DWORD userLen = 0;
    if (!WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, active, WTSUserName, &user, &userLen)
        || !user || !*user)
    { if (user) WTSFreeMemory(user); BLog(L"NOTIFY handoff: no user in session %lu", active); return false; }
    std::wstring who(user); WTSFreeMemory(user);

    // THE TEST IS THE ACCOUNT, NOT THE SESSION - and getting that wrong is why the first version of
    // this fix was inert. It compared sessions and returned "already interactive" whenever they
    // matched. But qrexec-agent runs a guest command AS SYSTEM IN THE INTERACTIVE SESSION, so the
    // sessions DO match (measured on win11-nfy: MYSESSION=1, ACTIVECONSOLE=1) and the handoff
    // no-opped - while the send still failed with "relay never connected".
    //
    // The real discriminator, measured the same day: notifhost run as SYSTEM fails; run as the
    // logged-on user - same session, same binary, same minute - it connects, acks FWD_RTT ok=1 and
    // puts a bubble on the dom0 desktop. ConnUp() passes GetUserNameW() as the qrexec-client-vm
    // local-user field ("@default|qubes.Notifications|<user>|..."), so under SYSTEM that field is
    // SYSTEM and the relay spawned for it never connects back.
    //
    // So: hand off whenever this process is not already running AS the console user, whatever
    // session it is in.
    wchar_t me[256] = { 0 }; DWORD meLen = RTL_NUMBER_OF(me);
    if (!GetUserNameW(me, &meLen)) { BLog(L"NOTIFY handoff: cannot read own user (%lu)", GetLastError()); return false; }
    if (_wcsicmp(me, who.c_str()) == 0 && active == mySession)
        return false;                                 // genuinely the console user: send inline

    // Same UTF-16LE + BOM notify file the inline path reads; deleted by the reader.
    std::wstring dir = StateDir();
    std::wstring file = dir + L"\\handoff-" + std::to_wstring(GetTickCount64()) + L".txt";
    std::wstring text = summary; if (!body.empty()) { text += L"\n"; text += body; }
    std::vector<BYTE> raw; raw.push_back(0xFF); raw.push_back(0xFE);
    raw.insert(raw.end(), (const BYTE*)text.data(), (const BYTE*)text.data() + text.size() * sizeof(wchar_t));
    if (!WriteSmallA(file, raw.data(), (DWORD)raw.size()))
    { BLog(L"NOTIFY handoff: cannot write %s", file.c_str()); return false; }

    wchar_t self[MAX_PATH] = { 0 };
    GetModuleFileNameW(nullptr, self, RTL_NUMBER_OF(self));
    wchar_t shortSelf[MAX_PATH] = { 0 };
    if (!GetShortPathNameW(self, shortSelf, RTL_NUMBER_OF(shortSelf))) wcscpy_s(shortSelf, self);
    wchar_t shortFile[MAX_PATH] = { 0 };
    if (!GetShortPathNameW(file.c_str(), shortFile, RTL_NUMBER_OF(shortFile))) wcscpy_s(shortFile, file.c_str());

    // A unique task name per send: concurrent errors must not delete each other's task.
    std::wstring task = L"QwtNotifyOnce-" + std::to_wstring(GetTickCount64());
    wchar_t cmd[MAX_PATH * 3 + 256];
    swprintf(cmd, RTL_NUMBER_OF(cmd),
             L"schtasks.exe /create /tn %s /tr \"%s --notify-file %s\" /sc once /st 00:00 /ru %s /it /f",
             task.c_str(), shortSelf, shortFile, who.c_str());
    STARTUPINFOW si = { sizeof(si) }; PROCESS_INFORMATION pi = {};
    if (!CreateProcessW(nullptr, cmd, nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi))
    { BLog(L"NOTIFY handoff: schtasks /create failed %lu", GetLastError()); return false; }
    WaitForSingleObject(pi.hProcess, 15000);
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);

    swprintf(cmd, RTL_NUMBER_OF(cmd), L"schtasks.exe /run /tn %s", task.c_str());
    STARTUPINFOW si2 = { sizeof(si2) }; PROCESS_INFORMATION pi2 = {};
    if (!CreateProcessW(nullptr, cmd, nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si2, &pi2))
    { BLog(L"NOTIFY handoff: schtasks /run failed %lu", GetLastError()); return false; }
    WaitForSingleObject(pi2.hProcess, 15000);
    CloseHandle(pi2.hThread); CloseHandle(pi2.hProcess);

    // The task must be reaped, or every notification leaves one behind for ever. Give the relaunched
    // instance time to connect and send before removing its task.
    Sleep(6000);
    swprintf(cmd, RTL_NUMBER_OF(cmd), L"schtasks.exe /delete /tn %s /f", task.c_str());
    STARTUPINFOW si3 = { sizeof(si3) }; PROCESS_INFORMATION pi3 = {};
    if (CreateProcessW(nullptr, cmd, nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si3, &pi3))
    { WaitForSingleObject(pi3.hProcess, 15000); CloseHandle(pi3.hThread); CloseHandle(pi3.hProcess); }

    BLog(L"NOTIFY handoff: ran in session %lu as %s (this process is session %lu)",
         active, who.c_str(), mySession);
    return true;
}

static int NotifyOnceMain(std::wstring const& summary, std::wstring const& body, NotifyKind kind)
{
    // SESSION 0 CANNOT DELIVER. Hand off to the interactive session rather than failing there.
    if (NotifyHandoffToSession(summary, body)) return 0;

    ProcessIdToSessionId(GetCurrentProcessId(), &g_mySession);
    InitializeCriticalSection(&g_corrLock);
    InitializeCriticalSection(&g_actLock);   // the reader thread touches the actions table on Dismissed
    g_rdEvt    = CreateEventW(nullptr, TRUE,  FALSE, nullptr);
    g_wrEvt    = CreateEventW(nullptr, TRUE,  FALSE, nullptr);
    g_connStop = CreateEventW(nullptr, TRUE,  FALSE, nullptr);
    g_ackEvt   = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!g_rdEvt || !g_wrEvt || !g_connStop || !g_ackEvt) return 3;
    if (!ConnUp()) { BLog(L"NOTIFY one-shot: no connection (policy refusal? no dom0 session?)"); return 3; }
    bool ok = ForwardText(summary, body, 0, kind);   // an error stays until dismissed; --severity warning/info expire
    BLog(L"NOTIFY one-shot: sent ok=%d summary=%s", ok ? 1 : 0, summary.c_str());
    ConnDown();
    return ok ? 0 : 4;
}

// --- secondary error route: this helper's OWN faults (notifyerr.h) ------------------------
//
// The bridge has two FATAL exits that recur for the life of the guest (Task Scheduler restarts it
// on failure, up to its count, and it dies the same way each time): listener access DENIED for this
// user, and listener init throwing. Each is logged here in bridge.log and as QGANOTIFBRIDGEEXIT in
// the agent log, and nothing else ever tells a human that the bridge they turned on is doing nothing.
// So each is also reported through the same one-shot `--notify-file` path the agent uses, with
// the SAME per-boot marker files (state dir shared with notifyerr.c), so the once-per-boot rule
// holds across the restarts and across the two binaries.
//
// Gate: --notify-errors N on the command line, resolved by the agent (the single reader of the
// service.notify-errors gate); absent = off. Fail-open: nothing here can affect the exit path
// that calls it; every failure is one BLog line. A FRESH instance of this exe is spawned for the
// send rather than calling NotifyOnceMain in-process: the FATAL paths run before the bridge's
// connection state exists, and a diagnostic must not borrow the state of the thing that failed.
// SAME HONEST LIMIT as everywhere else: this rides qrexec-agent and delivers nothing without it -
// and then, or when the gate is off, THE ERROR WINDOW (errbox.h, the same pure rule QerrWindowWanted
// as the agent's notifyerr.c): the user sees it on the console session, under the same per-boot
// record, so never a storm and never a box beside a dom0 notification for one error.
static int g_notifyErrorsGate = 0;

// The box, from this user-session process (WTSSendMessage to its own session). d is the route's decision; the box is
// shown only when the pure rule says dom0 was not told. Logged either way.
static void ShowErrorBoxSelf(QerrDecision d, const char* id, const char* header, const char* text, const wchar_t* why)
{
    if (!QerrWindowWanted(d)) return;
    DWORD err = 0;
    if (QerrShowErrorBox(header, text, &err))
        BLog(L"QGAERRBOX notifhost.%S shown as an error window on the console session (%s)", id, why);
    else
        BLog(L"QGAERRBOX notifhost.%S could NOT be shown as an error window (error %lu) after %s - bridge.log is the only record", id, err, why);
}

static bool ReadSmallA(std::wstring const& path, std::string& out)
{
    HANDLE h = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                           OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    char buf[256]; DWORD rd = 0;
    BOOL ok = ReadFile(h, buf, sizeof(buf) - 1, &rd, nullptr);
    CloseHandle(h);
    if (!ok) return false;
    out.assign(buf, rd);
    return true;
}
static bool WriteSmallA(std::wstring const& path, const void* data, DWORD len)
{
    HANDLE h = CreateFileW(path.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr, CREATE_ALWAYS,
                           FILE_ATTRIBUTE_NORMAL, nullptr);
    if (h == INVALID_HANDLE_VALUE) return false;
    DWORD wr = 0;
    BOOL ok = WriteFile(h, data, len, &wr, nullptr);
    CloseHandle(h);
    return ok && wr == len;
}

// key = a row of notifytexts.h ("listener-denied", "listener-init"): the text is rendered the way
// the agent's offline render test renders it - header, line 1, the cause with this helper's exit
// code, and the technical line with this process's pid.
static void ReportErrorSelf(const char* key)
{
    const QerrText* t = QerrTextFind(key);
    if (!t) { BLog(L"NOTIFYERR no text row '%S' (a bug of ours) - not sent", key); return; }
    const char* id = t->id;
    char text[QERR_MAX_TEXT + 256], header[200];
    if (!QerrRenderText(text, sizeof(text), t, nullptr, (unsigned long)GetCurrentProcessId()) ||
        !QerrFormatHeader(header, sizeof(header), t->header, nullptr))
    { BLog(L"NOTIFYERR notifhost.%S not sent: the text did not render", id); return; }

    wchar_t pd[MAX_PATH];
    if (!GetEnvironmentVariableW(L"ProgramData", pd, RTL_NUMBER_OF(pd))) wcscpy_s(pd, L"C:\\ProgramData");
    std::wstring qdir = std::wstring(pd) + L"\\Qubes";
    std::wstring dir = qdir + L"\\notify-errors";
    CreateDirectoryW(qdir.c_str(), nullptr);
    CreateDirectoryW(dir.c_str(), nullptr);

    wchar_t wid[QERR_MAX_ID + 1] = { 0 };
    MultiByteToWideChar(CP_UTF8, 0, id, -1, wid, (int)RTL_NUMBER_OF(wid));
    std::wstring marker = dir + L"\\notifhost." + wid;
    std::wstring countPath = dir + L"\\.count";

    // The boot stamp is DERIVED here (wall clock - uptime), not the shared volatile token the agent and the
    // guest scripts use (QERR_BOOT_KEY): this bridge runs as the interactive USER (a /ru <user> /it task), and
    // minting or even opening that HKLM key for write needs SYSTEM or an elevated token - a user-context read
    // finds no token until the agent has reported something. Sharing it needs the agent to mint it at start and
    // this side to open it read-only; recorded in findings/issues.md, not done here (rz39 notification texts).
    FILETIME ft; GetSystemTimeAsFileTime(&ft);
    ULARGE_INTEGER u; u.LowPart = ft.dwLowDateTime; u.HighPart = ft.dwHighDateTime;
    long long now = (long long)(u.QuadPart / 10000000ULL) - 11644473600LL - (long long)(GetTickCount64() / 1000ULL);

    std::string s; long long mb = 0, cb = 0; unsigned cnt = 0, newCnt = 0;
    int mp = ReadSmallA(marker, s) && QerrParseMarker(s.c_str(), &mb);
    int cp = ReadSmallA(countPath, s) && QerrParseCount(s.c_str(), &cb, &cnt);
    QerrDecision d = QerrDecide(t->sev, t->component, id, text, mp, mb, cp, cb, cnt, now, &newCnt);
    if (d != QERR_SEND) { BLog(L"NOTIFYERR notifhost.%S not sent: %S", id, QerrDecisionName(d)); return; }

    char kv[64];
    if (!QerrFormatMarker(kv, sizeof(kv), now) || !WriteSmallA(marker, kv, (DWORD)strlen(kv)) ||
        !QerrFormatCount(kv, sizeof(kv), now, newCnt) || !WriteSmallA(countPath, kv, (DWORD)strlen(kv)))
    {
        // No per-boot record, so no send and no dedupe: the box once (this process reports at most twice and exits).
        BLog(L"NOTIFYERR state dir not writable - not sent (no once-per-boot record, so no send)");
        ShowErrorBoxSelf(QERR_FAIL_TRANSPORT, id, header, text, L"the state dir could not be written");
        return;
    }
    // GATED: dom0 is not told (the operator's choice), the user is - under the record just written.
    if (!g_notifyErrorsGate)
    {
        BLog(L"NOTIFYERR notifhost.%S not sent to dom0: gated - shown as a window instead", id);
        ShowErrorBoxSelf(QERR_GATED, id, header, text, L"gated");
        return;
    }

    // UTF-16LE + BOM, what ReadNotifyFile reads; a unique name per send (it is deleted after reading).
    std::wstring file = dir + L"\\out-notifhost-" + std::to_wstring(GetTickCount64()) + L".txt";
    std::wstring wtext; int n = MultiByteToWideChar(CP_UTF8, 0, text, -1, nullptr, 0);
    if (n <= 1) return;
    wtext.resize(n - 1);
    MultiByteToWideChar(CP_UTF8, 0, text, -1, &wtext[0], n);
    std::vector<BYTE> body; body.push_back(0xFF); body.push_back(0xFE);
    body.insert(body.end(), (const BYTE*)wtext.data(), (const BYTE*)wtext.data() + wtext.size() * sizeof(wchar_t));
    if (!WriteSmallA(file, body.data(), (DWORD)body.size()))
    { BLog(L"NOTIFYERR cannot write notify file - not sent"); ShowErrorBoxSelf(QERR_FAIL_TRANSPORT, id, header, text, L"the notify file could not be written"); return; }

    wchar_t self[MAX_PATH] = { 0 };
    GetModuleFileNameW(nullptr, self, RTL_NUMBER_OF(self));
    wchar_t cmd[MAX_PATH * 2 + 64];
    swprintf(cmd, RTL_NUMBER_OF(cmd), L"\"%s\" --notify-file \"%s\"", self, file.c_str());
    STARTUPINFOW si = { sizeof(si) }; PROCESS_INFORMATION pi = {};
    if (!CreateProcessW(nullptr, cmd, nullptr, nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &si, &pi))
    {
        BLog(L"NOTIFYERR CreateProcess(self --notify-file) failed %lu - not sent", GetLastError());
        ShowErrorBoxSelf(QERR_FAIL_TRANSPORT, id, header, text, L"the notify helper could not be started");
        return;
    }
    CloseHandle(pi.hThread); CloseHandle(pi.hProcess);   // fire and forget
    BLog(L"NOTIFYERR notifhost.%S sent to dom0 (#%u this boot)", id, newCnt);
}

// --- bridge main --------------------------------------------------------------------------

static int BridgeMain()
{
    NameThisThread(L"notifhost: bridge-main");
    SetUnhandledExceptionFilter(BridgeCrashFilter);   // crash breadcrumb (see BridgeCrashFilter)
    HANDLE mtx = CreateMutexW(nullptr, FALSE, L"Local\\QubesToastBridgeSingleton");
    if (mtx) { DWORD w = WaitForSingleObject(mtx, 0); if (w != WAIT_OBJECT_0 && w != WAIT_ABANDONED) return 0; }
    ProcessIdToSessionId(GetCurrentProcessId(), &g_mySession);

    InitializeCriticalSection(&g_corrLock);
    InitializeCriticalSection(&g_actLock);
    g_rdEvt = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_wrEvt = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_connStop = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_ackEvt = CreateEventW(nullptr, FALSE, FALSE, nullptr);

    std::wstring stopf = StateDir() + L"\\stop";
    DeleteFileW(stopf.c_str());       // a stale stop request must not kill a fresh start
    std::wstring hbf = StateDir() + L"\\heartbeat";
    // (Markers exist only from versions before the agent-side hold - ADR-toasts 10; this version writes none.)
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
        {
            BLog(L"FATAL access=%d - window path preserved, exiting", (int)st);
            ReportErrorSelf("listener-denied");   // notifytexts.h: "exit code 2" is this return
            return 2;
        }
    } catch (...) {
        BLog(L"FATAL listener init threw");
        ReportErrorSelf("listener-init");         // notifytexts.h: "exit code 3" is this return
        return 3;
    }

    auto allow = ReadAllowlist();
    {
        std::wstring joined;
        for (auto const& a : allow) { if (!joined.empty()) joined += L";"; joined += a; }
        BLog(L"BRIDGE armed allow=[%s]", joined.c_str());
    }

    // ADR-toasts 11: the one Start-menu scan of this run starts now, at the lowest priority, so a sender's first toast
    // normally finds the AUMID -> activator map ready; a toast listed before it is done reads the registry only.
    ShortcutScanStart(L"bridge start");

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
            BLog(L"PUSH NotificationChanged armed - listing runs on its signal and the WAL watcher's");
        }
        catch (...)
        {
            BLog(L"PUSH NotificationChanged unavailable - the ETW proxy's records drive the listing (2 s floor only while "
                 L"the proxy is not live)");
        }
    }
    // THE LISTING FLOOR (rest-zero S4c): only while the bridge has NO push source at all. With NotificationChanged armed,
    // or the ETW proxy live (the push source on 26100.1742, where the subscription throws), a listing runs on their
    // signals and never on a clock - the 30 s / 2 s floors were idle polls (owner rule: zero wakes at rest).
    const DWORD kFloorMs = 2000;
    ULONGLONG nextFloorList = 0;                       // 0: first pass always lists
    bool toastSignaled = true;
    // An ETW record can arrive before its toast is listable: a push-triggered listing that finds nothing new is retried at
    // most twice (+250 ms, +1 s), armed by the record and ended by a find - bounded, never at rest.
    int walRetries = 0;
    ULONGLONG walRetryAt = 0;
    bool lastAnyPush = false;   // the floor state last logged (LISTING lines)

    // baseline: everything already in the center predates us - never forwarded. If the FIRST read
    // throws we must NOT proceed with an empty set (that would forward the whole backlog to dom0);
    // `primed` gates forwarding until a poll has successfully seeded `seen`.
    // EXCEPTION: a toast from a suppression-gap AUMID (leftover marker above) may itself BE a gap
    // toast - already bannerless - so it is left out of the baseline and forwarded like a fresh one.
    auto inGap = [&](WinUserNotification const& un) -> bool {
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

    bool connected = false;                        // a connection is up
    // Per-toast-id count of forward attempts REJECTED BY A LIVE SERVER (reply tag 1/2: ForwardText
    // returns false without marking the connection dead). Such a rejection is deterministic - the
    // center record persists, so unbounded retry would resend at 0.5 Hz forever. Transient failures
    // (write error, ack timeout, disconnect) kill the connection and are NOT counted; that
    // fail-open retry path stays unlimited. At the cap the id is given up: marked seen + logged
    // (its guest Notification Center record remains the surviving copy).
    std::unordered_map<uint32_t, int> fwdFails;
    const int kFwdFailCap = 5;
    int failStreak = 0, backoff = 0;
    ULONGLONG nextReconnect = 0;
    int rc = 0;

    // ---- REST-ZERO S4c wake sources (docs/DESIGN-rest-zero-capture.md C) -----------------------------------------
    // This loop used to wake every 2 s for a heartbeat contract with the agent and re-read its stop file, the agent's
    // pid and the listener's consent on that tick. Each is an event now, and the loop sleeps without a timeout unless a
    // retry or a reconnect it armed is due:
    //   * the agent's death: the liveness mutex it owns is ABANDONED (--alive);
    //   * a stop request: a file-name change in the state dir (the stop file is created there);
    //   * consent revoked: a change under the listener's consent keys (HKCU and HKLM);
    //   * the console session: WM_WTSSESSION_CHANGE on a message-only window;
    //   * work from the reader / shadow threads (a dismissal, a dead connection, a verdict): g_mainWake;
    //   * a toast: NotificationChanged (toastEvt).
    // PUBLISHED ONCE: our pid for the agent ("<tick> <pid>", the format it parses - the tick lets it accept only a file
    // written after the launch it is answering), then the ready event so it takes it on that wake.
    {
        HANDLE f = CreateFileW(hbf.c_str(), GENERIC_WRITE, FILE_SHARE_READ, nullptr,
                               CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (f != INVALID_HANDLE_VALUE)
        {
            char t[48]; int n = sprintf_s(t, "%llu %lu\n", GetTickCount64(), GetCurrentProcessId());
            DWORD wr; WriteFile(f, t, (DWORD)n, &wr, nullptr);
            CloseHandle(f);
        }
        if (g_readyEvt) SetEvent(g_readyEvt);
        else BLog(L"BRIDGE no --ready from the agent (mixed install?) - it will find our pid only on its own wakes");
    }
    HoldStart();   // the toast-hold records are live from here (ADR-toasts 10)
    if (!g_agentAlive)
        BLog(L"BRIDGE no --alive from the agent (mixed install?) - the agent's death falls back to the 30 s pid probe");
    g_mainWake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    HANDLE stopChg = FindFirstChangeNotificationW(StateDir().c_str(), FALSE, FILE_NOTIFY_CHANGE_FILE_NAME);
    if (stopChg == INVALID_HANDLE_VALUE) { stopChg = nullptr; BLog(L"BRIDGE stop-dir watch failed %lu - the stop file is seen on the next wake only", GetLastError()); }
    HANDLE consentEvt = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    HKEY consentKeys[2] = { nullptr, nullptr };
    static const wchar_t* kConsentPath =
        L"Software\\Microsoft\\Windows\\CurrentVersion\\CapabilityAccessManager\\ConsentStore\\userNotificationListener";
    RegOpenKeyExW(HKEY_CURRENT_USER, kConsentPath, 0, KEY_NOTIFY, &consentKeys[0]);
    RegOpenKeyExW(HKEY_LOCAL_MACHINE, kConsentPath, 0, KEY_NOTIFY, &consentKeys[1]);
    auto armConsent = [&]() {
        for (HKEY k : consentKeys)
            if (k && consentEvt)
                RegNotifyChangeKeyValue(k, TRUE, REG_NOTIFY_CHANGE_LAST_SET | REG_NOTIFY_THREAD_AGNOSTIC, consentEvt, TRUE);
    };
    armConsent();
    if (!consentKeys[0] && !consentKeys[1]) BLog(L"BRIDGE consent keys not watchable - revocation is noticed when a listing fails");
    HWND msgWnd = nullptr;
    {
        WNDCLASSEXW wc{}; wc.cbSize = sizeof(wc); wc.lpfnWndProc = DefWindowProcW;
        wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = L"QubesToastBridgeMsg";
        RegisterClassExW(&wc);
        msgWnd = CreateWindowExW(0, L"QubesToastBridgeMsg", L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                                 GetModuleHandleW(nullptr), nullptr);
        if (!msgWnd || !WTSRegisterSessionNotification(msgWnd, NOTIFY_FOR_THIS_SESSION))
            BLog(L"BRIDGE session notification unavailable (%lu) - a console change is seen on the next wake only", GetLastError());
    }
    bool consentChanged = true;   // checked once at entry, then on every change of its keys
    bool retryPending = false;    // the last listing left a toast UNSEEN for a retry (verdict pending / forward failed)
    ULONGLONG lastListTick = 0;

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
        if (g_agentAlive)
        {
            const DWORD aw = WaitForSingleObject(g_agentAlive, 0);
            if (aw == WAIT_ABANDONED || aw == WAIT_OBJECT_0) { BLog(L"agent gone (its liveness mutex was released)"); break; }
        }
        else if (AgentGone()) { BLog(L"agent gone"); break; }
        if (WTSGetActiveConsoleSessionId() != g_mySession) { BLog(L"session changed"); break; }
        if (GetFileAttributesW(stopf.c_str()) != INVALID_FILE_ATTRIBUTES) { BLog(L"stop requested"); break; }

        // connection maintenance. Down => toasts stay on the window path (fail-open: the listing below
        // publishes `window` for every toast it cannot forward) and the connection is re-established with
        // a bounded backoff.
        //
        // NO DOUBLE NOTIFICATIONS (owner, 2026-09-13; P1 2026-10-04) and NOTHING IS LOST are both the
        // AGENT's to deliver now (docs/ADR-toasts.md 10): it maps a toast's banner only after this bridge's
        // record for that toast says `window`, never when it says `bridge`, and after 3 s regardless. This
        // loop's part is to publish each toast's record at its first listing and to keep the verdict honest:
        // `bridge` only for a toast that is being forwarded over a proven-up connection, `window` the moment
        // it cannot be (dom0 unreachable, server rejection cap, no verdict in time). The per-AUMID
        // ShowBanner=0 write that used to live here is retired - it doubled the first toast of every
        // classifier-routed app and hid later interactive ones.
        if (g_connDead)
        {
            ConnDown();   // reap the reader/pipe of a connection that died mid-flight
            if (connected)
            {
                connected = false;
                BLog(L"connection down - toasts take the window path until it is back");
            }
            if (!allow.empty() && now >= nextReconnect)
            {
                // A fresh connection must trigger an immediate listing pass: toasts left
                // deliberately unseen while disconnected (fail-open retry) forward NOW,
                // not at the next NotificationChanged / 30 s floor.
                if (ConnUp())
                {
                    backoff = 0; connected = true; toastSignaled = true;
                    BLog(L"connection up - %u allowlisted app(s); banners are held per toast by the agent (no ShowBanner writes)",
                         (UINT)allow.size());
                }
                else
                {
                    static const DWORD bo[] = { 5000, 15000, 60000, 300000 };
                    nextReconnect = GetTickCount64() + bo[backoff < 3 ? backoff : 3];
                    backoff++;
                }
            }
        }

        // consent can be revoked from Settings at any time; the APIs then return empty
        // SILENTLY - check the status whenever its consent keys change (it used to be polled every
        // 60 s) and fail open loudly instead of forwarding vacuum.
        if (consentChanged)
        {
            consentChanged = false;
            armConsent();   // one-shot notifications: re-arm before reading, so no change between is lost
            try {
                if (listener.GetAccessStatus() != UserNotificationListenerAccessStatus::Allowed)
                { BLog(L"FATAL consent revoked - restoring banners, exiting"); rc = 2; break; }
            } catch (...) {}
        }

        // toast listing: push-gated (NotificationChanged and/or the WAL watcher); the floor only without either.
        // Body deliberately NOT re-indented (diff minimalism, the file's guard precedent).
        // A live push source: NotificationChanged, or the ETW proxy's pipe (the one that works on 26100.1742). The WAL
        // watcher is neither a push source nor a trigger (measured: it does not fire for toast arrivals on that build, and
        // a listing it triggered re-triggered itself).
        const bool anyPush = pushArmed || (g_etw.state == ETW_STATE_LIVE);
        if (anyPush != lastAnyPush)
        {
            BLog(anyPush ? L"LISTING push-driven (%s) - no floor" : L"LISTING NO PUSH SOURCE (%s) - listing every 2 s until one is back",
                 pushArmed ? L"NotificationChanged" : L"ETW proxy pipe");
            lastAnyPush = anyPush;
        }
        bool pushHit = (InterlockedExchange(&g_etwHit, 0) != 0);   // an id-less record on a platform that sends no ids
        {
            std::vector<uint32_t> ids;
            AcquireSRWLockExclusive(&g_etwIdLock);
            ids.swap(g_etwIds);
            ReleaseSRWLockExclusive(&g_etwIdLock);
            for (uint32_t id : ids)
                if (!seen.count(id)) { pushHit = true; break; }   // a notification this bridge has not listed yet
        }
        if (pushHit) { walRetries = 0; walRetryAt = 0; toastSignaled = true; }
        const bool walRetryDue = (walRetryAt != 0 && now >= walRetryAt);
        const bool walTriggered = pushHit || walRetryDue;
        bool sawNew = false;
        bool doList = !anyPush || toastSignaled || walRetryDue;
        // What asked for this listing (rest-zero M1: in the ~90 s after a toast burst a system thread in this process woke
        // ~80/s; the LIST lines say how many listings ran then and why). One line per listing - none at rest.
        const wchar_t* listTrig = pushHit ? L"etw" : walRetryDue ? L"retry" : toastSignaled ? L"wake" : L"floor";
        UINT listN = 0;
        const ULONGLONG listT0 = GetTickCount64();
        if (doList)
        {
        nextFloorList = now + kFloorMs;
        toastSignaled = false;
        retryPending = false;
        lastListTick = now;
        walRetryAt = 0;
        try
        {
            auto list = listener.GetNotificationsAsync(NotificationKinds::Toast).get();
            listN = list.Size();
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
                struct NewToast
                {
                    uint32_t id; std::wstring aumid, app, title, body;
                    ToastActPlan plan;        // the classifier's action plan (ADR-toasts 11); !ok or empty = no actions
                    std::wstring clsid;       // the sender's toast activator, when any action is a COM activation
                    int row = 0;              // the classifier's row (0 = no verdict: an allowlisted toast forwarded blind)
                    bool allowlisted = false;
                };
                std::vector<NewToast> fresh;
                // NON-SEAMLESS MODE (ADR-toasts 10): the agent says whether the hold exists right now. While it does
                // not, every toast listed here takes the window path - the guest banner inside the desktop window is
                // the one copy the user gets. Logged once per change, not per toast.
                const bool seamless = HoldSeamless();
                {
                    static bool lastSeamless = true;
                    if (seamless != lastSeamless)
                    {
                        lastSeamless = seamless;
                        BLog(seamless ? L"MODE seamless - toasts are routed (the agent holds each banner for its verdict)"
                                      : L"MODE non-seamless - every toast takes the window path: the guest draws its banner inside "
                                        L"the desktop window, forwarding would double it");
                    }
                }
                for (auto const& un : list)
                {
                    uint32_t id = un.Id();
                    if (seen.count(id)) continue;
                    sawNew = true;
                    std::wstring aumid, app;
                    try { aumid = un.AppInfo().AppUserModelId().c_str(); } catch (...) {}
                    try { app = un.AppInfo().DisplayInfo().DisplayName().c_str(); } catch (...) {}
                    // The title goes into every skip line too (owner, 2026-10-02: ties the UAC A/B cell's skip line to its
                    // test toast by content, not by count), and into the forward below.
                    const std::wstring tb = FirstTexts(un);
                    const size_t sep = tb.find(L'\x1f');
                    const std::wstring title = tb.substr(0, sep);
                    // P3a shadow probe: capture + ENQUEUE every new toast (skip and forward
                    // branches alike) BEFORE the unchanged A0 routing below. MEASURE-ONLY
                    // and now FIXED-COST on this thread: the acquisition ladder (ETW ring,
                    // then WpnCorrelate's WAL-paced retry) runs on the shadow worker, and
                    // the CLASSIFY line lands asynchronously. Dedupes internally so a
                    // retried allowlisted toast logs exactly once.
                    const bool windowOnly = WindowOnly(aumid);
                    bool listed = false;
                    for (auto const& a : allow) if (_wcsicmp(a.c_str(), aumid.c_str()) == 0) { listed = true; break; }
                    // THE TOAST-HOLD RECORD (docs/ADR-toasts.md 10): published ONCE per notification id, at its first
                    // listing, with whatever this pass already settles - window-only app: window; allowlisted:
                    // bridge; otherwise pending, decided by the classifier (VerdictStorePut) or by the passes below.
                    // BEFORE the classifier is asked, so its verdict always finds the record. The agent is holding
                    // this toast's banner on it.
                    // `bridge` only for a toast that WILL be forwarded now: an allowlisted toast listed while dom0 is
                    // unreachable is left unseen for the retry, and its banner must show meanwhile (window); when the
                    // connection returns and it forwards, the record turns `forwarded` (a late second copy is the
                    // accepted price of never losing one).
                    HoldPublish(un, id, aumid, app,
                                (windowOnly || !seamless) ? TH_VERDICT_WINDOW
                                    : listed ? (g_connDead ? TH_VERDICT_WINDOW : TH_VERDICT_BRIDGE) : TH_VERDICT_PENDING,
                                (listed ? TH_REC_FLAG_ALLOWLISTED : 0u) | (windowOnly ? TH_REC_FLAG_WINDOWONLY : 0u) |
                                (app.empty() ? TH_REC_FLAG_NO_SENDER : 0u));
                    ShadowClassify(un, id, aumid);
                    if (windowOnly)
                    {
                        seen.insert(id); VerdictForget(id);
                        BLog(L"skip id=%u aumid=%s title='%s' (window path; window-only app - its click is its action)", id, aumid.c_str(), title.c_str());
                        continue;
                    }
                    if (!seamless)
                    {
                        seen.insert(id); VerdictForget(id);
                        // A toast listed earlier in seamless mode (record pending/bridge, left unseen for a retry)
                        // is settled here too, or its stale record would pre-empt banners once seamless returns.
                        HoldVerdict(id, TH_VERDICT_WINDOW, false);
                        BLog(L"skip id=%u aumid=%s title='%s' (window path; non-seamless mode)", id, aumid.c_str(), title.c_str());
                        continue;
                    }
#if defined(P3AQ_DEFECT_ROUTE)
                    // DEFECT (seen-to-fail, autonomy rule 5): acquisition state gates the
                    // A0 routing. The routing-invariance detector (identical SENT/skip
                    // sequences for the same fixtures with the proxy up vs absent) must
                    // FAIL on this build or it is decoration.
                    if (g_etw.state != ETW_STATE_LIVE) listed = false;
#endif
                    VerdictEntry ve;          // the classifier's verdict + action plan, when it has one (else window, no actions)
                    bool blind = false;       // an allowlisted toast forwarded without a verdict (the shortcut's contract, loud)
                    {
                        // THE ROUTE (toastactions.h ToastActListingDecide), allowlisted or not. An allowlisted toast is NO LONGER
                        // forwarded blind by the shortcut when the classifier has answered (guest finding 2026-10-07: a row-4
                        // toast from an allowlisted sender reached dom0 WITHOUT its buttons while the hold suppressed its banner
                        // - the choice lost, which decision 4 forbids): with its verdict it follows its plan like any toast -
                        // bridge with the plan's actions, window when the plan refuses. While the verdict is pending it waits
                        // within the listing's passes; after them, allowlisted -> forwarded without a plan (the shortcut's
                        // contract, for a classifier that cannot answer; logged loudly), otherwise -> window (ADR 2 rule 3).
                        // Every rung fails OPEN to the window path.
                        int passes = 0;
                        const bool known = VerdictLookup(id, &ve, &passes);
                        const ToastActListingRoute lr = ToastActListingDecide(listed, known, ve.route == ToastRouteBridge, ve.plan, passes, kVerdictMaxPasses);
                        if (lr == ToastActListingRoute::Window)
                        {
                            seen.insert(id); VerdictForget(id);
                            HoldVerdict(id, TH_VERDICT_WINDOW, false);   // the listing's final word (reopens an allowlisted toast's held banner)
                            if (known)
                                BLog(L"skip id=%u aumid=%s title='%s' (window path; %s verdict%s%s)", id, aumid.c_str(), title.c_str(),
                                     listed ? L"allowlisted sender, but the classifier's" : L"classifier",
                                     ve.plan.ok ? L"" : L"; actions ", ve.plan.ok ? L"" : ToastActSlug(ve.plan).c_str());
                            else
                                BLog(L"skip id=%u aumid=%s title='%s' (window path; no verdict after %d passes)", id, aumid.c_str(), title.c_str(), kVerdictMaxPasses);
                            continue;
                        }
                        if (lr == ToastActListingRoute::AwaitVerdict)
                        {
                            // No verdict yet. Leave it UNSEEN so the next pass reconsiders it; this is the same retry that
                            // already stops a failed forward from dropping a toast. Nothing blocks and nothing is lost.
                            BLog(L"await id=%u aumid=%s (%sverdict pending, pass %d/%d)", id, aumid.c_str(), listed ? L"allowlisted; " : L"", passes, kVerdictMaxPasses);
                            retryPending = true;   // re-listed when the verdict lands (g_mainWake) or on the retry deadline
                            continue;
                        }
                        if (lr == ToastActListingRoute::ForwardBlind)
                        {
                            blind = true;
                            BLog(L"ALLOWLIST id=%u aumid=%s title='%s' forwarded WITHOUT a verdict after %d passes (the classifier did not answer): "
                                 L"if this toast carries buttons they are LOST in dom0 - the allowlist is for informational senders only",
                                 id, aumid.c_str(), title.c_str(), kVerdictMaxPasses);
                        }
                        else
                            BLog(L"route id=%u aumid=%s (bridge; %s verdict; actions=%s)", id, aumid.c_str(), listed ? L"allowlisted sender, classifier" : L"classifier",
                                 ToastActSlug(ve.plan).c_str());
                        if (!listed)
                        {
                            // The verdict is kept in the store until the forward SUCCEEDS (or is given up): forgetting it
                            // here made a failed forward's retry find no verdict, wait out its passes and end as
                            // "window" without ever forwarding - every forward failure was a loss (review #2).
                            // `bridge` only over a live connection: disconnected, the forward path below leaves the
                            // toast on the window path, and flipping its record bridge->window every pass would
                            // churn the agent's hold (review N4).
                            HoldVerdict(id, g_connDead ? TH_VERDICT_WINDOW : TH_VERDICT_BRIDGE, false);
                        }
                    }
                    // DEFER marking seen until a forward succeeds, so a failed/absent forward is retried and never
                    // silently drops a toast (P.2 fail-open invariant). The plan goes with the toast - an allowlisted one's
                    // too (its default click only if the activator was already cached: the plan never waited for it).
                    NewToast nt;
                    nt.id = id; nt.aumid = aumid; nt.app = app; nt.title = title;
                    nt.body = (sep == std::wstring::npos) ? L"" : tb.substr(sep + 1);
                    nt.allowlisted = listed;
                    if (!blind) { nt.row = ve.row; if (ve.route == ToastRouteBridge && ve.plan.ok) { nt.plan = ve.plan; nt.clsid = ve.clsid; } }
                    fresh.push_back(std::move(nt));
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
                        seen.insert(id); fwdFails.erase(id); VerdictForget(id);
                        // Nobody will ever forward it: the banner is the toast's only way to the user.
                        HoldVerdict(id, TH_VERDICT_WINDOW, false);
                        BLog(L"GIVE UP id=%u after %d server rejections - not resent (guest center record kept)",
                             id, kFwdFailCap);
                    }
                };
                if (fresh.empty() || g_connDead)
                {
                    if (!fresh.empty())
                    {
                        BLog(L"%u allowlisted toast(s) while disconnected - left on the window path (unseen, retried)", (UINT)fresh.size());
                        // The banner is shown for each (window): a toast forwarded later, when the connection
                        // returns, may then reach dom0 a second time - the accepted price of never losing one.
                        for (auto const& e : fresh) HoldVerdict(e.id, TH_VERDICT_WINDOW, false);
                    }
                    // leave `fresh` UNSEEN so they forward once the connection returns
                }
                else if (fresh.size() > 3)
                {
                    // coalesce a burst into one dom0 notification (politeness rule). guestId 0 =>
                    // no dismiss-sync for coalesced items (documented A0 limit).
                    // A toast WITH actions cannot be coalesced (one dom0 notification cannot carry four toasts'
                    // buttons) and must not be forwarded half-way (rule 4): in a burst it takes the window path,
                    // where its buttons work - the politeness bound stays exactly what it was.
                    std::vector<NewToast> plain;
                    for (auto& e : fresh)
                    {
                        if (e.plan.ok && !e.plan.actions.empty())
                        {
                            seen.insert(e.id); fwdFails.erase(e.id); VerdictForget(e.id);
                            HoldVerdict(e.id, TH_VERDICT_WINDOW, false);
                            BLog(L"skip id=%u aumid=%s title='%s' (window path; a toast with actions inside a burst of %u is not coalesced)",
                                 e.id, e.aumid.c_str(), e.title.c_str(), (UINT)fresh.size());
                        }
                        else plain.push_back(std::move(e));
                    }
                    if (!plain.empty())
                    {
                        std::wstring lines;
                        for (auto const& e : plain) { if (!lines.empty()) lines += L"\n"; lines += e.title + L": " + e.body; }
                        wchar_t sum[256];
                        swprintf(sum, RTL_NUMBER_OF(sum), L"%u notifications (%s)", (UINT)plain.size(), plain[0].app.c_str());
                        bool ok = ForwardText(sum, lines, 0);
                        // Acknowledged by dom0: the record turns `forwarded` - the agent's suppression now stands even if
                        // this bridge dies (a `bridge` without the ack is reopened on bridge death: nobody knows whether
                        // dom0 has it). The classifier's verdict is forgotten only now that the toast is done.
                        if (ok) for (auto const& e : plain) { seen.insert(e.id); fwdFails.erase(e.id); VerdictForget(e.id); HoldVerdict(e.id, TH_VERDICT_FORWARDED, false); }
                        else { for (auto const& e : plain) capFailed(e.id); retryPending = true; }
                        BLog(L"SENT coalesced x%u: %s%s", (UINT)plain.size(), ok ? L"OK" : L"FAIL",
                             ok ? L"" : L" (unseen, retried)");
                    }
                }
                else for (auto const& e : fresh)
                {
                    // WITH ITS ACTIONS (ADR-toasts 11) when the plan carries any: dom0 renders them if its daemon does
                    // (the guest cannot know - Jev 0.76; the stock Linux client advertises them unconditionally too).
                    const bool withActions = e.plan.ok && !e.plan.actions.empty();
                    const std::vector<std::string> actions = withActions ? ToastActFlatten(e.plan) : std::vector<std::string>();
                    // The click comes back as ActionInvoked{proxy id, key}: the table entry is put BEFORE the send, keyed by
                    // our sequence, and the reader fills the proxy's id in from the Id reply - which it processes before any
                    // Dismissed/ActionInvoked for this notification can exist - so no click can find the table empty.
                    // Bounded (ToastActTable); evictions are anomalies, logged.
                    const uint64_t seqNext = g_seq + 1;   // ForwardText's sequence for this frame (sends are sequential, this thread)
                    if (withActions)
                    {
                        ToastActEntry te;
                        te.seq = seqNext; te.guestId = e.id; te.dom0Id = 0; te.aumid = e.aumid; te.app = e.app; te.title = e.title;
                        te.clsid = e.clsid; te.plan = e.plan;
                        size_t evicted;
                        { CsGuard g(&g_actLock); evicted = g_actTable.Put(std::move(te), GetTickCount64()); }
                        if (evicted) BLog(L"ACTION table: %u entr%s evicted to make room (TTL, dismissal grace, or the %u bound)",
                                          (UINT)evicted, evicted == 1 ? L"y" : L"ies", (UINT)ToastActTable::kMax);
                    }
                    uint64_t seq = 0;
                    bool ok = ForwardText(e.title, e.body.empty() ? e.app : e.body, e.id, NotifyKind::Info, actions, &seq);
                    uint32_t dom0Id = 0;
                    if (ok) { seen.insert(e.id); fwdFails.erase(e.id); VerdictForget(e.id); HoldVerdict(e.id, TH_VERDICT_FORWARDED, false); }
                    else { capFailed(e.id); retryPending = true; }
                    if (withActions)
                    {
                        if (!ok) { CsGuard g(&g_actLock); g_actTable.RemoveSeq(seqNext); }   // not acknowledged (or dom0 went away): nothing to click on
                        else
                        {
                            dom0Id = CorrDom0Id(seq);
                            if (seq != seqNext)   // cannot happen on this thread (sends are sequential): keyed wrong = unreachable, say so
                            {
                                CsGuard g(&g_actLock); g_actTable.RemoveSeq(seqNext);
                                BLog(L"ACTION id=%u: frame sequence %llu differs from the expected %llu (a bug of ours) - its actions are "
                                     L"unreachable (entry removed)", e.id, (ULONGLONG)seq, (ULONGLONG)seqNext);
                            }
                            else if (dom0Id == 0)
                                BLog(L"ACTION id=%u seq=%llu: no proxy id in the correlation table after the ack - its actions cannot be "
                                     L"matched when clicked (a dom0 click will log 'no forwarded toast')", e.id, (ULONGLONG)seq);
                        }
                    }
                    BLog(L"SENT id=%u app='%s' title='%s': %s%s actions=%s%s%s%s", e.id, e.app.c_str(), e.title.c_str(),
                         ok ? L"OK" : L"FAIL", ok ? L"" : L" (unseen, retried)",
                         withActions ? ToastActSlug(e.plan).c_str() : L"none",
                         (ok && withActions) ? L" dom0=" : L"", (ok && withActions) ? std::to_wstring(dom0Id).c_str() : L"",
                         e.allowlisted ? L" (allowlisted)" : L"");
                    // The assertion (guest finding 2026-10-07): a row-4 toast - real-choice buttons - must never go to dom0 as text.
                    if (ok && ToastActSentAnomaly(e.row, actions.size() / 2))
                        BLog(L"ANOMALY id=%u: a row-4 toast (real-choice buttons) was SENT with actions=none - a bug of ours (decision 4 "
                             L"forbids a half-way forward); its guest banner is held by the hold, so the choice is lost in dom0", e.id);
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
        BLog(L"LIST trig=%s n=%u new=%d ms=%llu", listTrig, listN, sawNew ? 1 : 0, GetTickCount64() - listT0);
        // A WAL-triggered listing that found nothing new may have run before its toast became listable: retry it, twice
        // at most, then rest (see walRetries).
        if (walTriggered)
        {
            if (sawNew || walRetries >= 2) { walRetries = 0; walRetryAt = 0; }
            else { walRetryAt = now + (walRetries ? 1000 : 250); walRetries++; }
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

        // dom0 clicks (ADR-toasts 11): the bound of those in flight, and the failures awaiting their outcome - the
        // agent's mark, or the error notice from here
        ULONGLONG actDue = 0;
        ActPump(GetTickCount64(), &actDue);

        // THE WAIT (rest-zero S4c): INFINITE unless something this loop armed is due - a toast left unseen for a
        // retry (2 s after its listing), the reconnect backoff while dom0 is unreachable with apps to forward (a
        // failure state's bounded timer), the listing floor (kFloorMs), and a failed click's show bound - and
        // woken by every event above.
        {
            DWORD timeout = INFINITE;
            const ULONGLONG t = GetTickCount64();
            auto dueAt = [&](ULONGLONG at) {
                const DWORD d = (at > t) ? (DWORD)((at - t) < 0x7FFFFFFFull ? (at - t) : 0x7FFFFFFFull) : 0;
                if (timeout == INFINITE || d < timeout) timeout = d;
            };
            if (g_connDead && !allow.empty()) dueAt(nextReconnect);
            if (retryPending) dueAt(lastListTick + 2000);
            if (!(pushArmed || g_etw.state == ETW_STATE_LIVE)) dueAt(nextFloorList);
            if (walRetryAt) dueAt(walRetryAt);
            if (actDue) dueAt(actDue);
            HANDLE hs[5 + kToastActInflightMax]; DWORD n = 0;
            const DWORD iToast = n; if (toastEvt) hs[n++] = toastEvt;
            const DWORD iWake = n;  if (g_mainWake) hs[n++] = g_mainWake;
            const DWORD iStop = n;  if (stopChg) hs[n++] = stopChg;
            const DWORD iCons = n;  if (consentEvt) hs[n++] = consentEvt;
            if (g_agentAlive) hs[n++] = g_agentAlive;   // abandoned = the agent died; checked at the loop top
            n += ActChildHandles(hs + n, kToastActInflightMax);   // a click's child exiting wakes the loop (ActPump reaps it)
            const DWORD w = n ? MsgWaitForMultipleObjects(n, hs, FALSE, timeout, QS_ALLINPUT)
                              : (Sleep(timeout == INFINITE ? 2000 : timeout), WAIT_TIMEOUT);
            const DWORD k = (w >= WAIT_ABANDONED_0 && w < WAIT_ABANDONED_0 + n) ? (w - WAIT_ABANDONED_0)
                          : (w >= WAIT_OBJECT_0 && w < WAIT_OBJECT_0 + n) ? (w - WAIT_OBJECT_0) : n;
            // A push, or queued work that asked for a listing (g_listWanted). The ETW thread's wake alone does not: the
            // queued ids decide at the top of the next pass.
            toastSignaled = (k == iToast && toastEvt) || (InterlockedExchange(&g_listWanted, 0) != 0);
            if (k == iStop && stopChg) FindNextChangeNotification(stopChg);           // the stop file is read at the top
            if (k == iCons && consentEvt) consentChanged = true;
            MSG msg;
            while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&msg); DispatchMessageW(&msg); }
        }
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
    if (msgWnd) { WTSUnRegisterSessionNotification(msgWnd); DestroyWindow(msgWnd); }
    for (HKEY k : consentKeys) if (k) RegCloseKey(k);
    if (consentEvt) CloseHandle(consentEvt);
    if (stopChg) FindCloseChangeNotification(stopChg);
    ShadowWorkerStop();   // bounded joins (worker + WAL watcher)
    EtwTierStop();        // bounded join of the IPC client; no kernel session to reap -
                          // the ETW session belongs to the SYSTEM agent (etwproxy.c) now

    HoldStop();   // records go dark; the agent fails every held banner open on our exit anyway (its wait array)
    // Markers: this version writes none (the agent's hold replaced ShowBanner, ADR-toasts 10); an older
    // version's leftovers are still undone on every exit path.
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
    NameThisThread(L"notifhost: relay-pump");
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

// --probe-push <seconds> [--sub] (rest-zero S4c diagnostic). Holds a UserNotificationListener for <seconds> - subscribed
// to NotificationChanged with --sub - and does NOTHING else, so a thread that wakes in this process is the listener's
// own. Measured 2026-10-01 on w11-ds: the resident bridge has a thread started in shcore.dll waking ~20.7 times a second
// at rest (66 ms after process start), while a PowerShell process holding the listener, its access and a listing has
// none; this separates the subscription from everything else the bridge runs.
static int ProbePushMain(int secs, bool sub)
{
    init_apartment(apartment_type::multi_threaded);
    try {
        auto listener = UserNotificationListener::Current();
        if (listener.RequestAccessAsync().get() != UserNotificationListenerAccessStatus::Allowed)
        { wprintf(L"PROBEPUSH access denied\n"); return 2; }
        HANDLE e = CreateEventW(nullptr, FALSE, FALSE, nullptr);
        if (!e) { wprintf(L"PROBEPUSH event failed\n"); return 4; }
        winrt::event_token tok{};
        if (sub) tok = listener.NotificationChanged([e](UserNotificationListener const&, auto const&) { SetEvent(e); });
        wprintf(L"PROBEPUSH armed sub=%d pid=%lu\n", sub ? 1 : 0, GetCurrentProcessId());
        fflush(stdout);
        const ULONGLONG end = GetTickCount64() + (ULONGLONG)secs * 1000;
        unsigned changes = 0;
        for (;;)
        {
            const ULONGLONG now = GetTickCount64();
            if (now >= end) break;
            if (WaitForSingleObject(e, (DWORD)(end - now)) == WAIT_OBJECT_0) changes++;
        }
        if (sub) listener.NotificationChanged(tok);
        wprintf(L"PROBEPUSH done sub=%d changes=%u\n", sub ? 1 : 0, changes);
        CloseHandle(e);
    } catch (...) { wprintf(L"PROBEPUSH listener error\n"); return 3; }
    return 0;
}

// ==========================================================================================

int wmain(int argc, wchar_t** argv)
{
    SetUnhandledExceptionFilter(BridgeCrashFilter);   // every mode: crash leaves a breadcrumb
    const wchar_t* relayPipe = nullptr;
    bool bridge = false, dump = false, stop = false, restore = false, dumpdb = false, dumpetw = false;
    bool etwproxy = false, probePush = false, probeSub = false;
    int dumpdbN = 20, dumpEtwSecs = 30, probeSecs = 30;
    std::wstring notifySummary, notifyBody;
    const wchar_t* notifyFile = nullptr;
    NotifyKind notifyKind = NotifyKind::Error;   // --severity: the one-shot notice's kind (absent = an error, as before)
    const wchar_t* aliveName = nullptr;   // remembered for a bare --hold (names derived from it)
    bool holdDerive = false;
    const wchar_t* actExecFile = nullptr;    // --act-exec <file>: one activation in a child process (the bridge's own click handler)
    const wchar_t* resolveAumid = nullptr;   // --resolve-activator <AUMID>
    const wchar_t* invokeAumid = nullptr;    // --invoke-activator <AUMID> [<arguments>]
    const wchar_t* invokeArgs = nullptr;
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
        else if (_wcsicmp(argv[i], L"--notify-file") == 0 && i + 1 < argc) notifyFile = argv[++i];
        else if (_wcsicmp(argv[i], L"--severity") == 0 && i + 1 < argc)
        {
            const wchar_t* sv = argv[++i];
            if (_wcsicmp(sv, L"warning") == 0) notifyKind = NotifyKind::Warning;
            else if (_wcsicmp(sv, L"info") == 0) notifyKind = NotifyKind::Info;
            else if (_wcsicmp(sv, L"error") == 0) notifyKind = NotifyKind::Error;
            else BLog(L"NOTIFY --severity %s is not error|warning|info - sent as an error (stays until dismissed)", sv);
        }
        else if (_wcsicmp(argv[i], L"--notify") == 0 && i + 1 < argc)
        {
            notifySummary = argv[++i];
            if (i + 1 < argc && argv[i + 1][0] != L'-') notifyBody = argv[++i];
        }
        else if (_wcsicmp(argv[i], L"--etw-proxy") == 0) etwproxy = true;
        else if (_wcsicmp(argv[i], L"--probe-push") == 0)
        {
            probePush = true;
            if (i + 1 < argc && argv[i + 1][0] >= L'0' && argv[i + 1][0] <= L'9')
                probeSecs = _wtoi(argv[++i]);
        }
        else if (_wcsicmp(argv[i], L"--sub") == 0) probeSub = true;
        else if (_wcsicmp(argv[i], L"--alive") == 0 && i + 1 < argc)
        {
            aliveName = argv[i + 1];
            g_agentAlive = OpenMutexW(SYNCHRONIZE, FALSE, argv[++i]);
        }
        else if (_wcsicmp(argv[i], L"--ready") == 0 && i + 1 < argc)
            g_readyEvt = OpenEventW(EVENT_MODIFY_STATE, FALSE, argv[++i]);
        // --hold <section> [--verdict <event>], or a BARE --hold: then both names are derived from the --alive name
        // (the agent names all four objects Global\\QubesToastBridge_<nonce>_{alive,ready,hold,verdict}). The bare form
        // exists because Task Scheduler refuses a /tr longer than 261 characters, and four nonce'd names do not fit
        // (measured 2026-10-06: the toast-hold build's bridge never started - "schtasks /create failed").
        else if (_wcsicmp(argv[i], L"--hold") == 0)
        {
            if (i + 1 < argc && wcsncmp(argv[i + 1], L"--", 2) != 0) HoldOpen(argv[++i]);
            else holdDerive = true;
        }
        else if (_wcsicmp(argv[i], L"--verdict") == 0 && i + 1 < argc)
            g_holdVerdictEvt = OpenEventW(EVENT_MODIFY_STATE, FALSE, argv[++i]);
        else if (_wcsicmp(argv[i], L"--notify-errors") == 0 && i + 1 < argc) g_notifyErrorsGate = (_wtoi(argv[++i]) != 0);
        else if (_wcsicmp(argv[i], L"--client-sid") == 0 && i + 1 < argc) i++;   // consumed by etwproxy.exe
        else if (_wcsicmp(argv[i], L"--act-exec") == 0 && i + 1 < argc) actExecFile = argv[++i];
        else if (_wcsicmp(argv[i], L"--resolve-activator") == 0 && i + 1 < argc) resolveAumid = argv[++i];
        else if (_wcsicmp(argv[i], L"--invoke-activator") == 0 && i + 1 < argc)
        {
            invokeAumid = argv[++i];
            if (i + 1 < argc && wcsncmp(argv[i + 1], L"--", 2) != 0) invokeArgs = argv[++i];
        }
    }
    if (actExecFile) return ActExecMain(actExecFile);
    if (resolveAumid) return ResolveActivatorMain(resolveAumid);
    if (invokeAumid) return InvokeActivatorMain(invokeAumid, invokeArgs);
    if (holdDerive)
    {
        const size_t suffix = wcslen(L"_alive");
        const size_t n = aliveName ? wcslen(aliveName) : 0;
        if (n > suffix && n < 200 && _wcsicmp(aliveName + n - suffix, L"_alive") == 0)
        {
            std::wstring prefix(aliveName, n - suffix);
            HoldOpen((prefix + L"_hold").c_str());
            g_holdVerdictEvt = OpenEventW(EVENT_MODIFY_STATE, FALSE, (prefix + L"_verdict").c_str());
            if (!g_holdVerdictEvt) BLog(L"HOLD verdict event %s_verdict not opened (%lu)", prefix.c_str(), GetLastError());
        }
        else
            BLog(L"HOLD a bare --hold needs an --alive name ending in _alive to derive the section and event from - no records published");
    }
    if (etwproxy)
    {
        // MOVED (2026-09-05 console split): the proxy lives in etwproxy.exe, which links no
        // user32/gdi32 and therefore cannot die 0xC0000142 under the winsta-less
        // qubes-etwproxy token. THIS binary imports both (WinRT --bridge), so running the
        // proxy here would re-create the exact failure the split removed. Refuse LOUDLY with
        // the proxy's hard-refuse exit class (9): an agent old enough to still launch
        // `notifhost --etw-proxy` parks its ETW tier for the boot on 9 (fail-open, one log
        // line) instead of treadmilling - never a silent no-op.
        printf("NOTIFHOST FAIL --etw-proxy has moved to etwproxy.exe (GUI-DLL-free console "
               "split); launch that binary instead - refusing\n");
        BLog(L"NOTIFHOST FAIL --etw-proxy invoked on the WinRT/user32 binary - moved to etwproxy.exe, refusing");
        return 9;
    }
    if (relayPipe) return RelayMain(relayPipe);
    if (notifyFile)
    {
        std::wstring fs, fb;
        if (!ReadNotifyFile(notifyFile, fs, fb))
        { BLog(L"NOTIFY one-shot: unreadable/empty %s", notifyFile); return 3; }
        return NotifyOnceMain(fs, fb, notifyKind);
    }
    if (!notifySummary.empty()) return NotifyOnceMain(notifySummary, notifyBody, notifyKind);
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
        // One-shot restorer of last resort: undo every ShowBanner suppression an OLDER version's
        // markers record for this user (this version writes none - docs/ADR-toasts.md 10) and exit.
        // Launched by the agent (in the user session - markers are
        // SID-scoped HKCU state) when the bridge gate is OFF and a crashed bridge may have
        // left markers behind: with the gate off no bridge will ever start to run its own
        // startup BannerRestoreAll, so without this pass those apps stay bannerless forever.
        // Registry/file work only - no COM, no listener consent needed.
        BLog(L"RESTORE one-shot (--restore-banners)");
        BannerRestoreAll();
        return 0;
    }
    if (dump) return DumpMain();
    if (probePush) return ProbePushMain(probeSecs, probeSub);
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
