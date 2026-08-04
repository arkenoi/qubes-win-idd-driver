/*
 * chromerepro - reproduce the post-2013 Office "compound window" layout WITHOUT Office.
 *
 * Qubes Windows display work, CLAUDE.md Phase 2A-chrome. See README.md for how to run it
 * and what to expect from `qtest shot` before and after the gui-agent fix.
 *
 * What it builds:
 *   1 normal main window (WS_OVERLAPPEDWINDOW, captioned) - a real window, must always be
 *     shown in dom0 with a normal qube border;
 *   4 "shadow strip" windows arranged around the main frame, each
 *     WS_POPUP + WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE and
 *     OWNED by the main window - the exact shape of what Office 2013+ puts around its frame,
 *     and what the agent used to map as four extra bordered windows;
 *   optionally a popup (--popup / F2), a fully transparent layered window (--ghost / F3) and
 *     a benign layered window that MUST keep being shown (--control).
 *
 * Deliberately a /SUBSYSTEM:WINDOWS app: a console subsystem build would open a console
 * window, which is one more bordered window in dom0 and would wreck the acceptance count.
 * The window inventory therefore goes to a text file (default %TEMP%\chromerepro.txt),
 * printed with `qtest run "type %TEMP%\chromerepro.txt"`.
 *
 * Pure Win32 C, no MFC/ATL, no CRT startup dependencies beyond the defaults.
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#include <stdarg.h>
#include <wchar.h>
#include <strsafe.h>

#define CLASS_MAIN    L"QubesChromeReproMain"
#define CLASS_SHADOW  L"QubesChromeReproShadow"
#define CLASS_POPUP   L"QubesChromeReproPopup"
#define CLASS_GHOST   L"QubesChromeReproGhost"
#define CLASS_CONTROL L"QubesChromeReproControl"

// --mso: the strips exactly as a real Microsoft 365 install creates them, measured with
// tools/dump-windows on win-idd-test around Word's "Normal template" NUIDialog:
//
//   0x10348 "MSO_BORDEREFFECT_WINDOW_CLASS" "" (391x8)  WS_POPUP WS_VISIBLE WS_CLIPSIBLINGS
//           WS_CLIPCHILDREN | WS_EX_LAYERED WS_EX_MAKEVISIBLEWHENUNGHOSTED WS_EX_TOOLWINDOW
//
// The reason to reproduce these rather than reuse CLASS_SHADOW: the real strips carry
// NEITHER WS_EX_TRANSPARENT NOR WS_EX_NOACTIVATE, so the style heuristic (rule 2) does not
// and cannot match them. Only the class rule can.
//
// THICKNESS - the subtle part, and the reason --mso-thin is not the default:
//   The real strips are 8 px, far under the SM_CXMIN x SM_CYMIN floor. They reach the class
//   rule at all only because a caption-less WS_POPUP is classified override-redirect, which
//   lowers the floor to 4 px - and that exemption is fork-local, added in agent d6ab61c
//   ("Accept small override-redirect popups: keytip badges died on the SM_CXMIN floor").
//   Stock QWT applies the full floor to every window and drops an 8 px strip on SIZE.
//   So against a stock control, 8 px strips are rejected by BOTH sides for different
//   reasons, the comparison is all zeros, and it proves nothing.
//   Strips therefore clear the floor by default, which the class rule does not care about
//   (it keys on class alone), so the control is able to fail and the rule is what is being
//   measured. --mso-thin reproduces the true 8 px geometry, which is only meaningful
//   against a FORK build that has d6ab61c.
#define CLASS_MSO_STRIP L"MSO_BORDEREFFECT_WINDOW_CLASS"
#define MSO_THIN_THICKNESS 8

// --orphan: the scene agent 66fc670 fixes - an owned popup whose GW_OWNER the agent does
// NOT track, sitting inside an unrelated same-process sibling.
//
// SynthQualifies() used to test `entry->Owner && FindWindowByHandle(entry->Owner) != NULL`
// in one condition, so an untracked owner fell through to the same-process fallback, which
// adopted the popup into whatever topmost sibling contained it. Office hit this with the
// shadow strips around its sign-in dialog: adopted by the maximized frame, patched in from
// the composited desktop, then masked out of the owner's own capture - a frozen L-shaped
// shadow ghost burned into the document that outlived the dialog.
//
// The repro needs three windows, and the owner must be genuinely untracked: it is created
// and never shown, so ShouldAcceptWindow() drops it on !IsVisible - on EVERY build, which
// keeps the scene identical either side of the fix.
#define CLASS_ORPHAN L"QubesChromeReproOrphan"

#define SHADOW_COUNT 4

#define ID_TOP    0
#define ID_BOTTOM 1
#define ID_LEFT   2
#define ID_RIGHT  3

static HINSTANCE g_Instance;
static HWND g_Main;
static HWND g_Shadow[SHADOW_COUNT];
static HWND g_Popup;
static HWND g_Ghost;
static HWND g_Control;
static HWND g_HiddenOwner;
static HWND g_Orphan;

// Thickness of the shadow strips, in pixels. NOT a realistic Office shadow (those are
// ~8 px): ShouldAcceptWindow() drops anything smaller than SM_CXMIN x SM_CYMIN (~136x39 on
// a 96 DPI Win10 guest) long before the chrome rules get a chance to look at it, so an
// 8 px strip would be filtered by the OLD code and prove nothing. Computed in wWinMain from
// the live metrics so the repro exercises the NEW predicate on every guest.
static int g_Thickness = 160;

static BOOL g_WantPopup;
static BOOL g_WantGhost;
static BOOL g_WantControl;
static BOOL g_WantMso;
static BOOL g_WantMsoThin;
static BOOL g_WantOrphan;

static WCHAR g_LogPath[MAX_PATH];

// ---------------------------------------------------------------- reporting

static void LogLine(const WCHAR* format, ...)
{
    WCHAR buffer[1024];
    va_list args;
    HANDLE file;
    char utf8[4096]; // worst case 3 UTF-8 bytes per WCHAR of `buffer`, plus the CRLF
    int bytes;
    DWORD written;

    va_start(args, format);
    StringCchVPrintfW(buffer, ARRAYSIZE(buffer), format, args);
    va_end(args);

    OutputDebugStringW(buffer);
    OutputDebugStringW(L"\r\n");

    file = CreateFileW(g_LogPath, FILE_APPEND_DATA, FILE_SHARE_READ, NULL,
        OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, NULL);
    if (file == INVALID_HANDLE_VALUE)
        return;

    StringCchCatW(buffer, ARRAYSIZE(buffer), L"\r\n");
    bytes = WideCharToMultiByte(CP_UTF8, 0, buffer, -1, utf8, sizeof(utf8), NULL, NULL);
    if (bytes > 1) // bytes includes the terminating NUL, which we don't want in the file
        WriteFile(file, utf8, (DWORD)(bytes - 1), &written, NULL);

    CloseHandle(file);
}

// Dump one window the way tools/winenum would, so the report can be diffed against what the
// agent logged for the same HWND.
static void ReportWindow(const WCHAR* role, HWND window, const WCHAR* expectation)
{
    RECT rect = { 0, 0, 0, 0 };
    COLORREF key = 0;
    BYTE alpha = 255;
    DWORD flags = 0;
    DWORD style, exStyle;
    WCHAR className[64] = L"";

    if (!window)
    {
        LogLine(L"%-8s (not created)", role);
        return;
    }

    GetWindowRect(window, &rect);
    style = (DWORD)GetWindowLongW(window, GWL_STYLE);
    exStyle = (DWORD)GetWindowLongW(window, GWL_EXSTYLE);
    GetClassNameW(window, className, ARRAYSIZE(className));

    if (!(exStyle & WS_EX_LAYERED) || !GetLayeredWindowAttributes(window, &key, &alpha, &flags))
    {
        alpha = 255;
        flags = 0;
    }
    else if (!(flags & LWA_ALPHA))
    {
        alpha = 255;
    }

    LogLine(L"%-8s hwnd=0x%08X class=%-24s style=0x%08X exstyle=0x%08X "
            L"owner=0x%08X rect=(%d,%d %dx%d) alpha=%u -> %s",
        role, (unsigned)(ULONG_PTR)window, className, style, exStyle,
        (unsigned)(ULONG_PTR)GetWindow(window, GW_OWNER),
        rect.left, rect.top, rect.right - rect.left, rect.bottom - rect.top,
        alpha, expectation);
}

static void ReportAll(void)
{
    LogLine(L"--- chromerepro inventory ---");
    LogLine(L"min window size filter: SM_CXMIN=%d SM_CYMIN=%d, strip thickness=%d",
        GetSystemMetrics(SM_CXMIN), GetSystemMetrics(SM_CYMIN), g_Thickness);
    ReportWindow(L"main", g_Main, L"ALWAYS shown in dom0 (normal border)");
    ReportWindow(L"shadow0", g_Shadow[ID_TOP], L"chrome: shown BEFORE fix, gone AFTER");
    ReportWindow(L"shadow1", g_Shadow[ID_BOTTOM], L"chrome: shown BEFORE fix, gone AFTER");
    ReportWindow(L"shadow2", g_Shadow[ID_LEFT], L"chrome: shown BEFORE fix, gone AFTER");
    ReportWindow(L"shadow3", g_Shadow[ID_RIGHT], L"chrome: shown BEFORE fix, gone AFTER");
    ReportWindow(L"popup", g_Popup, L"ALWAYS shown, override_redirect (1px border)");
    ReportWindow(L"ghost", g_Ghost, L"alpha 0: shown BEFORE fix, gone AFTER");
    ReportWindow(L"control", g_Control, L"layered but visible: ALWAYS shown (regression canary)");
    ReportWindow(L"hiddenowner", g_HiddenOwner, L"never shown: must never be tracked (owner of 'orphan')");
    ReportWindow(L"orphan", g_Orphan, L"owned by an UNTRACKED window: synthesized BEFORE 66fc670, refused AFTER");
    LogLine(L"--- end ---");
}

// ---------------------------------------------------------------- layout

static void LayoutShadows(void)
{
    RECT r;
    int t = g_Thickness;
    int w, h;

    if (!g_Main || !GetWindowRect(g_Main, &r))
        return;

    w = r.right - r.left;
    h = r.bottom - r.top;

    // Placed just below the main window in Z order (hWndInsertAfter = g_Main), like a real
    // drop shadow. SWP_NOACTIVATE keeps focus where it is.
    if (g_Shadow[ID_TOP])
        SetWindowPos(g_Shadow[ID_TOP], g_Main, r.left - t, r.top - t, w + 2 * t, t, SWP_NOACTIVATE);
    if (g_Shadow[ID_BOTTOM])
        SetWindowPos(g_Shadow[ID_BOTTOM], g_Main, r.left - t, r.bottom, w + 2 * t, t, SWP_NOACTIVATE);
    if (g_Shadow[ID_LEFT])
        SetWindowPos(g_Shadow[ID_LEFT], g_Main, r.left - t, r.top, t, h, SWP_NOACTIVATE);
    if (g_Shadow[ID_RIGHT])
        SetWindowPos(g_Shadow[ID_RIGHT], g_Main, r.right, r.top, t, h, SWP_NOACTIVATE);
}

// ---------------------------------------------------------------- window procs

static void PaintFilled(HWND window, COLORREF color, const WCHAR* text)
{
    PAINTSTRUCT ps;
    HDC dc = BeginPaint(window, &ps);
    RECT client;
    HBRUSH brush = CreateSolidBrush(color);

    GetClientRect(window, &client);
    FillRect(dc, &client, brush);
    DeleteObject(brush);

    if (text)
    {
        SetBkMode(dc, TRANSPARENT);
        SetTextColor(dc, RGB(20, 20, 20));
        DrawTextW(dc, text, -1, &client, DT_CENTER | DT_WORDBREAK | DT_NOPREFIX);
    }

    EndPaint(window, &ps);
}

static LRESULT CALLBACK MainProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam)
{
    switch (message)
    {
    case WM_PAINT:
        PaintFilled(window, RGB(245, 245, 250),
            L"\r\n\r\nchromerepro - Office compound-window repro\r\n\r\n"
            L"This is the ONE real window.\r\n"
            L"The 4 grey strips around it are layered/transparent/toolwindow\r\n"
            L"HWNDs owned by this window - unmappable chrome.\r\n\r\n"
            L"F2 toggle popup   F3 toggle alpha-0 ghost   F5 re-dump inventory   Esc quit");
        return 0;

    case WM_MOVE:
    case WM_SIZE:
        LayoutShadows();
        return 0;

    case WM_KEYDOWN:
        switch (wParam)
        {
        case VK_F2:
            if (g_Popup)
                ShowWindow(g_Popup, IsWindowVisible(g_Popup) ? SW_HIDE : SW_SHOWNA);
            return 0;
        case VK_F3:
            if (g_Ghost)
                ShowWindow(g_Ghost, IsWindowVisible(g_Ghost) ? SW_HIDE : SW_SHOWNA);
            return 0;
        case VK_F5:
            ReportAll();
            return 0;
        case VK_ESCAPE:
            DestroyWindow(window);
            return 0;
        }
        break;

    case WM_DESTROY:
        PostQuitMessage(0);
        return 0;
    }

    return DefWindowProcW(window, message, wParam, lParam);
}

static LRESULT CALLBACK ShadowProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam)
{
    if (message == WM_PAINT)
    {
        PaintFilled(window, RGB(96, 96, 104), NULL);
        return 0;
    }

    // WS_EX_TRANSPARENT already makes this click-through; answering HTTRANSPARENT as well
    // matches what the Office strips do and makes the "no user can ever click it" claim in
    // the agent's rule 2 explicit here too.
    if (message == WM_NCHITTEST)
        return HTTRANSPARENT;

    return DefWindowProcW(window, message, wParam, lParam);
}

static LRESULT CALLBACK PlainProc(HWND window, UINT message, WPARAM wParam, LPARAM lParam)
{
    if (message == WM_PAINT)
    {
        PaintFilled(window, RGB(255, 250, 205), L"\r\npopup / control window");
        return 0;
    }

    return DefWindowProcW(window, message, wParam, lParam);
}

// ---------------------------------------------------------------- setup

static BOOL RegisterClasses(void)
{
    WNDCLASSEXW wc;

    ZeroMemory(&wc, sizeof(wc));
    wc.cbSize = sizeof(wc);
    wc.hInstance = g_Instance;
    wc.hCursor = LoadCursorW(NULL, IDC_ARROW);
    wc.hbrBackground = NULL; // everything paints itself

    wc.lpfnWndProc = MainProc;
    wc.lpszClassName = CLASS_MAIN;
    if (!RegisterClassExW(&wc))
        return FALSE;

    wc.lpfnWndProc = ShadowProc;
    wc.lpszClassName = CLASS_SHADOW;
    if (!RegisterClassExW(&wc))
        return FALSE;

    wc.lpfnWndProc = PlainProc;
    wc.lpszClassName = CLASS_POPUP;
    if (!RegisterClassExW(&wc))
        return FALSE;

    wc.lpszClassName = CLASS_GHOST;
    if (!RegisterClassExW(&wc))
        return FALSE;

    wc.lpszClassName = CLASS_CONTROL;
    if (!RegisterClassExW(&wc))
        return FALSE;

    wc.lpfnWndProc = ShadowProc;
    wc.lpszClassName = CLASS_MSO_STRIP;
    if (!RegisterClassExW(&wc))
        return FALSE;

    wc.lpfnWndProc = PlainProc;
    wc.lpszClassName = CLASS_ORPHAN;
    if (!RegisterClassExW(&wc))
        return FALSE;

    return TRUE;
}

static HWND CreateShadow(void)
{
    HWND window = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TRANSPARENT | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
        CLASS_SHADOW, NULL,
        WS_POPUP,
        0, 0, 10, 10,
        g_Main,  // OWNER (not parent: WS_POPUP without WS_CHILD makes this an owned window)
        NULL, g_Instance, NULL);

    if (!window)
        return NULL;

    // Semi-transparent, so that BEFORE the fix the strips are plainly visible as four
    // separate bordered windows in the dom0 screenshot.
    SetLayeredWindowAttributes(window, 0, 160, LWA_ALPHA);
    ShowWindow(window, SW_SHOWNA);
    return window;
}

// An Office frame-shadow strip, reproduced attribute for attribute (see CLASS_MSO_STRIP).
// WS_EX_MAKEVISIBLEWHENUNGHOSTED, which the real ones also carry, is undocumented and set
// by the shell rather than by the app, so it is not requested here; nothing reads it.
static HWND CreateMsoStrip(void)
{
    HWND window = CreateWindowExW(
        WS_EX_LAYERED | WS_EX_TOOLWINDOW,   // NOT transparent, NOT noactivate - as measured
        CLASS_MSO_STRIP, NULL,
        WS_POPUP | WS_CLIPSIBLINGS | WS_CLIPCHILDREN,
        0, 0, 10, 10,
        g_Main,  // owned by the frame it decorates, like the real strips
        NULL, g_Instance, NULL);

    if (!window)
        return NULL;

    SetLayeredWindowAttributes(window, 0, 160, LWA_ALPHA);
    ShowWindow(window, SW_SHOWNA);
    return window;
}

int WINAPI wWinMain(HINSTANCE instance, HINSTANCE previous, PWSTR commandLine, int showCommand)
{
    MSG message;
    RECT work;
    const WCHAR* args = GetCommandLineW();
    int mainW, mainH, mainX, mainY;
    int minThickness;
    int i;

    UNREFERENCED_PARAMETER(previous);
    UNREFERENCED_PARAMETER(commandLine);

    g_Instance = instance;

    g_WantPopup = (wcsstr(args, L"--popup") != NULL);
    g_WantGhost = (wcsstr(args, L"--ghost") != NULL);
    g_WantControl = (wcsstr(args, L"--control") != NULL);
    g_WantMsoThin = (wcsstr(args, L"--mso-thin") != NULL);
    g_WantMso = g_WantMsoThin || (wcsstr(args, L"--mso") != NULL);
    g_WantOrphan = (wcsstr(args, L"--orphan") != NULL);

    if (!GetTempPathW(ARRAYSIZE(g_LogPath), g_LogPath))
        StringCchCopyW(g_LogPath, ARRAYSIZE(g_LogPath), L".\\");
    StringCchCatW(g_LogPath, ARRAYSIZE(g_LogPath), L"chromerepro.txt");
    DeleteFileW(g_LogPath); // one file per run

    if (!RegisterClasses())
    {
        MessageBoxW(NULL, L"RegisterClassEx failed", L"chromerepro", MB_ICONERROR);
        return 1;
    }

    // Strips must clear the agent's minimum-window-size filter in BOTH dimensions, or the
    // old code rejects them on size alone and the "before" case never reproduces.
    minThickness = GetSystemMetrics(SM_CXMIN);
    if (GetSystemMetrics(SM_CYMIN) > minThickness)
        minThickness = GetSystemMetrics(SM_CYMIN);
    g_Thickness = minThickness + 24;

    // --mso keeps the floor-clearing thickness so a stock control can still map the strips;
    // only --mso-thin drops to Office's true 8 px (see CLASS_MSO_STRIP).
    if (g_WantMsoThin)
        g_Thickness = MSO_THIN_THICKNESS;

    if (!SystemParametersInfoW(SPI_GETWORKAREA, 0, &work, 0))
    {
        work.left = 0;
        work.top = 0;
        work.right = GetSystemMetrics(SM_CXSCREEN);
        work.bottom = GetSystemMetrics(SM_CYSCREEN);
    }

    // Leave room for the strips on every side; shrink the frame rather than let them go
    // off-screen, where dom0 would clip them and the count would be wrong.
    mainW = 640;
    mainH = 460;
    if (mainW > (work.right - work.left) - 2 * g_Thickness - 16)
        mainW = (work.right - work.left) - 2 * g_Thickness - 16;
    if (mainH > (work.bottom - work.top) - 2 * g_Thickness - 16)
        mainH = (work.bottom - work.top) - 2 * g_Thickness - 16;
    if (mainW < 320)
        mainW = 320;
    if (mainH < 240)
        mainH = 240;
    mainX = work.left + ((work.right - work.left) - mainW) / 2;
    mainY = work.top + ((work.bottom - work.top) - mainH) / 2;

    g_Main = CreateWindowExW(0, CLASS_MAIN, L"chromerepro - main window",
        WS_OVERLAPPEDWINDOW, mainX, mainY, mainW, mainH,
        NULL, NULL, g_Instance, NULL);
    if (!g_Main)
    {
        MessageBoxW(NULL, L"CreateWindowEx(main) failed", L"chromerepro", MB_ICONERROR);
        return 1;
    }

    for (i = 0; i < SHADOW_COUNT; i++)
        g_Shadow[i] = g_WantMso ? CreateMsoStrip() : CreateShadow();

    // Popup: no caption, so the agent's IsPopup() classifies it as override_redirect and
    // the daemon gives it a 1 px border instead of a full frame - the same treatment the
    // Linux agent gives menus. Owned but NOT layered, so the chrome rules must not touch it.
    g_Popup = CreateWindowExW(0, CLASS_POPUP, NULL,
        WS_POPUP | WS_BORDER,
        mainX + 60, mainY + 90, 340, 220,
        g_Main, NULL, g_Instance, NULL);

    // Regression canary: layered (alpha 200) AND owned AND undecorated, but NOT
    // hit-test transparent - a perfectly ordinary translucent tool window. If the chrome
    // rules ever get loosened to drop this, the fix has gone too far.
    if (g_WantControl)
    {
        // NOTE: plain WS_POPUP, deliberately NO WS_BORDER. The chrome rule tests
        // !(Style & WS_CAPTION), and WS_CAPTION == WS_BORDER|WS_DLGFRAME, so a bordered
        // window is spared by the caption clause before the WS_EX_TRANSPARENT clause is
        // ever reached. With WS_BORDER this canary would pass for the wrong reason and
        // would not actually test that non-click-through windows survive.
        g_Control = CreateWindowExW(WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE, CLASS_CONTROL, NULL,
            WS_POPUP,
            work.left + 40, work.top + 40, 360, 260,
            g_Main, NULL, g_Instance, NULL);
        if (g_Control)
        {
            SetWindowLongW(g_Control, GWL_EXSTYLE,
                GetWindowLongW(g_Control, GWL_EXSTYLE) | WS_EX_LAYERED);
            SetLayeredWindowAttributes(g_Control, 0, 200, LWA_ALPHA);
            ShowWindow(g_Control, SW_SHOWNA);
        }
    }

    // Fully transparent layered window: a normal captioned frame that happens to draw
    // nothing. Exercises rule 1 on its own (unowned, not click-through), so a failure here
    // cannot be confused with the shadow-strip rule.
    if (g_WantGhost)
    {
        g_Ghost = CreateWindowExW(WS_EX_LAYERED, CLASS_GHOST, L"chromerepro - ghost (alpha 0)",
            WS_OVERLAPPEDWINDOW,
            work.right - 480, work.top + 40, 400, 300,
            NULL, NULL, g_Instance, NULL);
        if (g_Ghost)
        {
            SetLayeredWindowAttributes(g_Ghost, 0, 0, LWA_ALPHA);
            ShowWindow(g_Ghost, SW_SHOWNA);
        }
    }

    ShowWindow(g_Main, showCommand == SW_SHOWDEFAULT ? SW_SHOWNORMAL : showCommand);
    UpdateWindow(g_Main);
    LayoutShadows();

    // Orphan-owned popup: see CLASS_ORPHAN. Created LAST, and only after the agent has had
    // time to see the main frame. Ordering is the whole experiment: synthesis adopts a
    // popup into a TRACKED same-process non-override-redirect sibling, and the agent only
    // tracks the frame once it is visible. Created before ShowWindow(g_Main) - as this
    // originally was - the popup arrives while no sibling is tracked, SynthQualifies()
    // fails for want of a candidate, and BOTH builds simply announce it: a control that
    // cannot exhibit the defect. Measured that way round first; the agent attached the
    // frame 125 ms after the popup, so the 3 s below is ample.
    if (g_WantOrphan)
    {
        DWORD until = GetTickCount() + 3000;
        MSG pump;
        while ((int)(GetTickCount() - until) < 0)
        {
            while (PeekMessageW(&pump, NULL, 0, 0, PM_REMOVE))
            {
                TranslateMessage(&pump);
                DispatchMessageW(&pump);
            }
            Sleep(50);
        }

        // never shown, so every build drops it on !IsVisible and never tracks it
        g_HiddenOwner = CreateWindowExW(0, CLASS_ORPHAN, NULL,
            WS_POPUP,
            work.left, work.top, 200, 200,
            NULL, NULL, g_Instance, NULL);

        g_Orphan = CreateWindowExW(0, CLASS_ORPHAN, NULL,
            WS_POPUP | WS_BORDER,
            mainX + 60, mainY + 90, 340, 220,
            g_HiddenOwner, NULL, g_Instance, NULL);
        if (g_Orphan)
            ShowWindow(g_Orphan, SW_SHOWNA);
    }

    if (g_Popup && g_WantPopup)
        ShowWindow(g_Popup, SW_SHOWNA);

    // Everything is placed and shown by now, so the rects in the report are the real ones.
    ReportAll();

    while (GetMessageW(&message, NULL, 0, 0) > 0)
    {
        TranslateMessage(&message);
        DispatchMessageW(&message);
    }

    return 0;
}
