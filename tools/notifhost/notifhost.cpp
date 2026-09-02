// notifhost.exe - user-session toast interceptor for QWT.
//
// Windows toasts are NRB/DirectComposition shell CoreWindows that the gui-agent cannot capture
// per-HWND (WGC CreateForWindow -> E_INVALIDARG) and can only SLICE from the composited desktop.
// To retire the slicer, toasts must instead arrive as ORDINARY windows. This helper - the
// in-guest analogue of the Linux notification daemon - subscribes to UserNotificationListener
// (access proven Allowed on the guest) and renders each incoming toast as a NORMAL bordered GDI
// window (redirected, PrintWindow-capturable), which the agent maps and dom0 borders like any
// guest window. NOT dom0-forwarding (that is the future "notification bridge"); this is pure
// in-guest rendering, so dom0 draws its own trust border around guest-supplied content.
//
// It needs NO IPC with the agent - the windows it creates ARE the output. Spawned by the SYSTEM
// agent into the user session (SpawnHelperAsUser), it exits when the agent dies or the session
// changes. Build mirrors tools/wgcbroker (v143, /MT, C++/WinRT from the SDK, no WDK/nuget).
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.UI.Notifications.h>
#include <winrt/Windows.UI.Notifications.Management.h>
#include <string>
#include <unordered_set>
#include <vector>
#include <deque>

#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
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
    // WS_OVERLAPPED|WS_CAPTION => a NORMAL, redirected, PrintWindow-capturable window that dom0
    // borders; NOT topmost/NRB/o-r, so it is NOT slice-fed and needs no broker.
    HWND h = CreateWindowExW(WS_EX_APPWINDOW, cls, L"Notification",
        WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_VISIBLE,
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

int wmain(int argc, wchar_t** argv)
{
    // single instance per session
    HANDLE mtx = CreateMutexW(nullptr, FALSE, L"Local\\QubesNotifHostSingleton");
    if (mtx) { DWORD w = WaitForSingleObject(mtx, 0); if (w != WAIT_OBJECT_0 && w != WAIT_ABANDONED) return 0; }
    ProcessIdToSessionId(GetCurrentProcessId(), &g_mySession);
    for (int i = 1; i + 1 < argc; i++)
        if (_wcsicmp(argv[i], L"--agent-pid") == 0) {
            DWORD pid = (DWORD)_wtoi64(argv[i + 1]);
            if (pid) g_agent = OpenProcess(SYNCHRONIZE, FALSE, pid);
        }

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
