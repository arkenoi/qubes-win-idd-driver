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
#include <sddl.h>   // ConvertSidToStringSidW
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

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "windowsapp.lib")

using namespace winrt;
using namespace winrt::Windows::UI::Notifications;
using namespace winrt::Windows::UI::Notifications::Management;

static HANDLE g_agent = nullptr;
static DWORD  g_mySession = 0;

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

static std::string Utf8(std::wstring const& w)
{
    if (w.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n > 0 ? n : 0, 0);
    if (n > 0) WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

static void BLog(const wchar_t* fmt, ...)
{
    static std::wstring path;
    if (path.empty()) path = StateDir() + L"\\bridge.log";
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

// --- config -------------------------------------------------------------------------------

// Allowlist of AUMIDs whose toasts are bridged: REG_MULTI_SZ "NotifyBridgeAllow" under the
// gui-agent's config key. Absent/empty list = the bridge idles (forwards nothing, suppresses
// nothing); unknown apps always stay on the window path - the classification IS the list.
static std::vector<std::wstring> ReadAllowlist()
{
    std::vector<std::wstring> out;
    HKEY k;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Invisible Things Lab\\Qubes Tools\\gui-agent",
                      0, KEY_READ | KEY_WOW64_64KEY, &k))
        return out;
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
    return out;
}

// Seed the per-user listener consent ONLY when it has never been set (same value the Settings
// toggle writes; proven sufficient for an unpackaged reader by guest/listener-probe.ps1). An
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

static void BannerRestoreAll()
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
            EnterCriticalSection(&g_corrLock);
            for (auto& e : g_corr) if (e.seq == seq) { e.dom0Id = id; break; }
            LeaveCriticalSection(&g_corrLock);
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
            EnterCriticalSection(&g_corrLock);
            for (size_t i = 0; i < g_corr.size(); i++)
                if (g_corr[i].dom0Id == id && id != 0)
                {
                    if (reason == 2 && g_corr[i].guestId)
                        g_pendingDismiss.push_back(g_corr[i].guestId);
                    g_corr.erase(g_corr.begin() + i);   // no further replies for this id either way
                    break;
                }
            LeaveCriticalSection(&g_corrLock);
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
    EnterCriticalSection(&g_corrLock);
    g_corr.clear();
    g_pendingDismiss.clear();
    LeaveCriticalSection(&g_corrLock);
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
static bool ForwardText(std::wstring const& title, std::wstring const& body, uint32_t guestId)
{
    if (g_connDead) return false;
    uint64_t seq = ++g_seq;
    EnterCriticalSection(&g_corrLock);
    g_corr.push_back({ seq, guestId, 0, GetTickCount64() });
    while (g_corr.size() > 256) g_corr.erase(g_corr.begin());
    LeaveCriticalSection(&g_corrLock);

    auto frame = EncodeNotifyFrame(seq, Utf8(title.empty() ? L"Notification" : title), Utf8(body));
    g_awaitSeq = seq; g_awaitOk = 0; ResetEvent(g_ackEvt);
    if (!PipeXfer(FALSE, frame.data(), (DWORD)frame.size(), 15000)) { MarkConnDead(); return false; }
    if (WaitForSingleObject(g_ackEvt, 15000) != WAIT_OBJECT_0)
    { BLog(L"send seq=%llu: ack timeout", (ULONGLONG)seq); MarkConnDead(); return false; }
    return g_awaitOk == 1;
}

// --- bridge main --------------------------------------------------------------------------

static int BridgeMain()
{
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
    BannerRestoreAll();               // crash leftovers from a previous instance: clean slate

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

    // baseline: everything already in the center predates us - never forwarded. If the FIRST read
    // throws we must NOT proceed with an empty set (that would forward the whole backlog to dom0);
    // `primed` gates forwarding until a poll has successfully seeded `seen`.
    std::unordered_set<uint32_t> seen;
    bool primed = false;
    try {
        for (auto const& un : listener.GetNotificationsAsync(NotificationKinds::Toast).get()) seen.insert(un.Id());
        primed = true;
    } catch (...) { BLog(L"baseline read failed - will prime on the first good poll, forwarding nothing until then"); }

    bool connected = false;                        // a connection is up (banners may be suppressed)
    std::unordered_set<std::wstring> suppressed;   // AUMIDs whose banner is currently ShowBanner=0
    int failStreak = 0, backoff = 0;
    ULONGLONG nextReconnect = 0, nextConsent = 0;
    int rc = 0;

    for (;;)
    {
        ULONGLONG now = GetTickCount64();
        if (g_agent && WaitForSingleObject(g_agent, 0) == WAIT_OBJECT_0) { BLog(L"agent gone"); break; }
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
                if (ConnUp()) { backoff = 0; connected = true; }
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

        // poll for new toasts
        try
        {
            auto list = listener.GetNotificationsAsync(NotificationKinds::Toast).get();
            failStreak = 0;
            // First good poll after a failed baseline: seed `seen` with the whole current center
            // and forward NOTHING this pass (the backlog predates us). This is the legacy `primed`
            // guard, mirrored, so a failed baseline can never replay the backlog to dom0.
            if (!primed)
            {
                for (auto const& un : list) seen.insert(un.Id());
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
                    bool listed = false;
                    for (auto const& a : allow) if (_wcsicmp(a.c_str(), aumid.c_str()) == 0) { listed = true; break; }
                    if (!listed) { seen.insert(id); BLog(L"skip id=%u aumid=%s (window path)", id, aumid.c_str()); continue; }
                    // allowlisted: DEFER marking seen until a forward succeeds, so a failed/absent
                    // forward is retried and never silently drops a toast (P.2 fail-open invariant).
                    auto tb = FirstTexts(un);
                    size_t sep = tb.find(L'\x1f');
                    fresh.push_back({ id, aumid, app, tb.substr(0, sep),
                                      sep == std::wstring::npos ? L"" : tb.substr(sep + 1) });
                }
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
                    if (ok) for (auto const& e : fresh) { seen.insert(e.id); suppressNow(e.aumid); }
                    BLog(L"SENT coalesced x%u: %s%s", (UINT)fresh.size(), ok ? L"OK" : L"FAIL",
                         ok ? L"" : L" (unseen, retried)");
                }
                else for (auto const& e : fresh)
                {
                    bool ok = ForwardText(e.title, e.body.empty() ? e.app : e.body, e.id);
                    if (ok) { seen.insert(e.id); suppressNow(e.aumid); }
                    BLog(L"SENT id=%u app='%s' title='%s': %s%s", e.id, e.app.c_str(), e.title.c_str(),
                         ok ? L"OK" : L"FAIL", ok ? L"" : L" (unseen, retried)");
                }
            }
            // bound the seen-set (rebuild from what is still in the center)
            if (seen.size() > 500)
            {
                std::unordered_set<uint32_t> keep;
                for (auto const& un : list) keep.insert(un.Id());
                seen.swap(keep);
            }
        }
        catch (...)
        {
            failStreak++;
            BLog(L"poll error (%d)", failStreak);
            if (failStreak >= 30) { BLog(L"FATAL 30 consecutive poll errors"); rc = 3; break; }
        }

        // dom0 dismissals queued by the reader: keep the guest Notification Center in sync
        {
            std::vector<uint32_t> dis;
            EnterCriticalSection(&g_corrLock);
            dis.swap(g_pendingDismiss);
            LeaveCriticalSection(&g_corrLock);
            for (uint32_t id : dis)
            {
                try { listener.RemoveNotification(id); BLog(L"dom0 dismissed -> RemoveNotification(%u)", id); }
                catch (...) { BLog(L"RemoveNotification(%u) failed", id); }
            }
        }

        Sleep(2000);
    }

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
    const wchar_t* relayPipe = nullptr;
    bool bridge = false, dump = false, stop = false;
    for (int i = 1; i < argc; i++)
    {
        if (_wcsicmp(argv[i], L"--agent-pid") == 0 && i + 1 < argc)
        {
            DWORD pid = (DWORD)_wtoi64(argv[++i]);
            if (pid) g_agent = OpenProcess(SYNCHRONIZE, FALSE, pid);
        }
        else if (_wcsicmp(argv[i], L"--relay") == 0 && i + 1 < argc) relayPipe = argv[++i];
        else if (_wcsicmp(argv[i], L"--bridge") == 0) bridge = true;
        else if (_wcsicmp(argv[i], L"--bridge-stop") == 0) stop = true;
        else if (_wcsicmp(argv[i], L"--dump-aumids") == 0) dump = true;
    }
    if (relayPipe) return RelayMain(relayPipe);
    if (stop)
    {
        std::wstring f = StateDir() + L"\\stop";
        HANDLE h = CreateFileW(f.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                               FILE_ATTRIBUTE_NORMAL, nullptr);
        if (h != INVALID_HANDLE_VALUE) { DWORD wr; WriteFile(h, "stop", 4, &wr, nullptr); CloseHandle(h); }
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
        if (g_agent && WaitForSingleObject(g_agent, 0) == WAIT_OBJECT_0) break;
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
