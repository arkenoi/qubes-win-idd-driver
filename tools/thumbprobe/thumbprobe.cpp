// thumbprobe - does a DWM thumbnail give us a per-window pixel source for the ROGUE classes?
//
// WHY THIS EXISTS. The rogue classes - override-redirect popups, WS_EX_NOREDIRECTIONBITMAP (every
// UWP app and Windows Terminal), ULW/colourkey layered, and toasts (CoreWindow NRB) - have no
// per-window pixel source today. WGC's CreateForWindow was measured working for real app windows
// but FAILING for shell CoreWindows (DESIGN-pure-per-window.md P8, 2026-09-02); PrintWindow returns
// blank for o-r bubbles and premultiplied near-black for ULW; DwmGetDxSharedSurface is rejected
// three ways. So they are sliced out of the composited desktop, which is the one thing that renders
// them correctly - and that slice is why the in-guest desktop capture cannot be deleted.
//
// DwmRegisterThumbnail is the one candidate the design survey does NOT list as rejected. DWM draws a
// live copy of any window it composites - shell surfaces included - into a destination window the
// caller owns, ALREADY BLENDED. If that works, capturing our own destination gives the rogue
// window's pixels through a path measured to work, and it sidesteps the protocol's missing
// per-pixel alpha at the same time. Jev: worth probing 0.83.
//
// THE DECISIVE UNKNOWN, which is all this probe is for (Jev 0.87): a thumbnail is drawn when DWM
// composites the DESTINATION. If the destination is hidden or off-screen, DWM may not composite it
// and there may be no pixels AT ALL - in which case the whole idea dies here, cheaply. Note the
// distinction that cost a whole survey earlier: a thumbnail is a COMPOSITION effect and is NOT in
// the destination window's own redirection surface, so PrintWindow of the destination cannot see it.
// Only a composed-tree capture can. Hence WGC, hence the user session.
//
// Output: one RESULT= line per destination state, plus RESULT=SUMMARY. Never a verdict - it reports
// colours and frame counts and lets the caller judge.
#include <windows.h>
#include <dwmapi.h>
#include <d3d11.h>
#include <dxgi.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <stdio.h>
#include <set>
#include <vector>
#include <string>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "windowsapp.lib")

using namespace winrt;
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
using namespace winrt::Windows::Graphics::DirectX::Direct3D11;

static com_ptr<ID3D11Device>        g_dev;
static com_ptr<ID3D11DeviceContext> g_ctx;
static IDirect3DDevice              g_rtDev{ nullptr };

static bool InitD3D()
{
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr,
            D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
            g_dev.put(), nullptr, g_ctx.put())))
    {
        if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
                D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
                g_dev.put(), nullptr, g_ctx.put())))
            return false;
    }
    auto dxgi = g_dev.as<IDXGIDevice>();
    com_ptr<::IInspectable> insp;
    if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), insp.put()))) return false;
    g_rtDev = insp.as<IDirect3DDevice>();
    return true;
}

// Count distinct sampled colours and how many pixels are non-black. Same shape of measure the
// window-truth survey used, so the numbers are comparable with it.
struct Shot {
    int frames = 0; int colours = 0; int nonBlack = 0; int w = 0, h = 0; bool ok = false;
    // ALPHA, which the first version of this probe THREW AWAY by masking with 0x00FFFFFF while
    // counting colours - so every statement anyone could make about blending was unmeasured. The
    // relay's whole claim is that DWM hands us pre-blended pixels; whether the alpha channel is
    // uniformly opaque, meaningfully graded, or premultiplied garbage is the thing that decides how
    // wrong the blend is. Jev: measure-the-relay-alpha-first 0.93, alpha_is_blocking only 0.28 -
    // a fidelity question, and this is what quantifies it.
    int alphaDistinct = 0;      // how many distinct alpha values appear
    int alphaMin = 255, alphaMax = 0;
    int alphaPartial = 0;       // samples with 0 < a < 255: genuine translucency
    int alphaZero = 0;          // fully transparent samples
    int samples = 0;
};

static Shot CaptureWindow(HWND hwnd, int settleMs)
{
    Shot s;
    try {
        auto interop = get_activation_factory<GraphicsCaptureItem, ::IGraphicsCaptureItemInterop>();
        GraphicsCaptureItem item{ nullptr };
        if (FAILED(interop->CreateForWindow(hwnd, guid_of<GraphicsCaptureItem>(),
                                            reinterpret_cast<void**>(put_abi(item)))) || !item)
            return s;
        auto size = item.Size();
        s.w = size.Width; s.h = size.Height;
        auto pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
            g_rtDev, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
        auto session = pool.CreateCaptureSession(item);
        try { session.IsBorderRequired(false); } catch (...) {}
        session.StartCapture();
        Sleep(settleMs);
        // Drain whatever arrived; the LAST frame is what we measure.
        Direct3D11CaptureFrame frame{ nullptr }, last{ nullptr };
        while ((frame = pool.TryGetNextFrame())) { s.frames++; last = frame; }
        if (last)
        {
            auto tex = last.Surface().as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
            com_ptr<ID3D11Texture2D> src;
            if (SUCCEEDED(tex->GetInterface(guid_of<ID3D11Texture2D>(), src.put_void())) && src)
            {
                D3D11_TEXTURE2D_DESC d{}; src->GetDesc(&d);
                d.Usage = D3D11_USAGE_STAGING; d.BindFlags = 0;
                d.CPUAccessFlags = D3D11_CPU_ACCESS_READ; d.MiscFlags = 0;
                com_ptr<ID3D11Texture2D> stg;
                if (SUCCEEDED(g_dev->CreateTexture2D(&d, nullptr, stg.put())))
                {
                    g_ctx->CopyResource(stg.get(), src.get());
                    D3D11_MAPPED_SUBRESOURCE m{};
                    if (SUCCEEDED(g_ctx->Map(stg.get(), 0, D3D11_MAP_READ, 0, &m)))
                    {
                        std::set<uint32_t> cols;
                        std::set<int> alphas;
                        for (UINT y = 0; y < d.Height; y += 9)
                        {
                            auto row = (const uint32_t*)((const BYTE*)m.pData + (size_t)y * m.RowPitch);
                            for (UINT x = 0; x < d.Width; x += 9)
                            {
                                uint32_t raw = row[x];
                                uint32_t p = raw & 0x00FFFFFF;
                                int a = (int)((raw >> 24) & 0xFF);
                                cols.insert(p);
                                if (p) s.nonBlack++;
                                alphas.insert(a);
                                if (a < s.alphaMin) s.alphaMin = a;
                                if (a > s.alphaMax) s.alphaMax = a;
                                if (a == 0) s.alphaZero++;
                                else if (a < 255) s.alphaPartial++;
                                s.samples++;
                            }
                        }
                        s.alphaDistinct = (int)alphas.size();
                        s.colours = (int)cols.size();
                        s.ok = true;
                        g_ctx->Unmap(stg.get(), 0);
                    }
                }
            }
        }
        session.Close(); pool.Close();
    } catch (...) { }
    return s;
}

static HWND MakeDest(int w, int h, int x, int y, DWORD exStyle)
{
    static bool reg = false;
    if (!reg) {
        WNDCLASSEXW wc{}; wc.cbSize = sizeof(wc); wc.lpfnWndProc = DefWindowProcW;
        wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = L"QubesThumbProbeDest";
        wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
        RegisterClassExW(&wc); reg = true;
    }
    return CreateWindowExW(exStyle, L"QubesThumbProbeDest", L"thumbprobe destination",
                           WS_POPUP, x, y, w, h, nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
}

// --sweep: try the relay on EVERY rogue-class window currently up, and report per class. The single
// -class form proved the mechanism on one NRB window; the classes that actually justify the relay are
// the shell CoreWindow toast (must-keep by project rule) and the override-redirect popup, and those
// cannot be named in advance - they appear and vanish. So enumerate and report what was found, which
// also makes "this class was not present" distinguishable from "the relay failed for it".
struct Found { HWND h; std::wstring cls; DWORD ex; const char* why; };
static std::vector<Found>* g_found;

static BOOL CALLBACK SweepProc(HWND h, LPARAM)
{
    if (!IsWindowVisible(h)) return TRUE;
    RECT r{}; if (!GetWindowRect(h, &r)) return TRUE;
    if ((r.right - r.left) < 32 || (r.bottom - r.top) < 24) return TRUE;
    DWORD ex = (DWORD)GetWindowLongPtrW(h, GWL_EXSTYLE);
    WCHAR cls[160] = {}; GetClassNameW(h, cls, 160);
    const char* why = nullptr;
    // The agent's own ineligibility reasons, as closely as an out-of-process probe can see them.
    DWORD st = (DWORD)GetWindowLongPtrW(h, GWL_STYLE);
    // OVERRIDE-REDIRECT, by the AGENT'S OWN test (IsPopup, main.c:1518): visible and NOT
    // (WS_CAPTION, or WS_SYSMENU+WS_EX_APPWINDOW, or WS_EX_APPWINDOW alone) - a caption-less window
    // that does not ask for the taskbar. The first sweep checked only NRB / CoreWindow / layered and
    // so could not see this class AT ALL, which is why a sweep that found three windows found no
    // popup: a gap in the probe, not an absence in the guest.
    const bool orLike = !((st & WS_CAPTION) || (ex & WS_EX_APPWINDOW));
    if (ex & 0x00200000L /* WS_EX_NOREDIRECTIONBITMAP */)          why = "NRB";
    else if (orLike)                                              why = "OR";
    else if (wcsstr(cls, L"Windows.UI.Core.CoreWindow"))           why = "CoreWindow";
    else if (ex & WS_EX_LAYERED) {
        COLORREF k; BYTE a; DWORD f;
        if (!GetLayeredWindowAttributes(h, &k, &a, &f))            why = "ULW";
        else if (f & LWA_COLORKEY)                                 why = "COLORKEY";
    }
    if (!why) return TRUE;
    g_found->push_back(Found{ h, cls, ex, why });
    return TRUE;
}

// One relay attempt against one source, destination OFF-SCREEN (the state the probe proved usable
// and the only one that is invisible to dom0 without being hidden).
static void RelayOnce(const Found& f)
{
    // A window can vanish between enumeration and relay - chromerepro's fixtures and any menu do
    // exactly that. Without this the whole sweep dies and, because stdout was buffered, prints
    // NOTHING: the first run with the class fixtures up returned exit 1 with an empty output and no
    // indication of how far it got.
    if (!IsWindow(f.h)) { printf("RESULT=SWEEP class=%ls why=%s gone=1\n", f.cls.c_str(), f.why);
                          fflush(stdout); return; }
    RECT sr{}; GetWindowRect(f.h, &sr);
    int w = (int)(sr.right - sr.left), h = (int)(sr.bottom - sr.top);
    // The destination must be the THUMBNAIL'S source size, not the window rect: the first sweep
    // created it at window size (1129x635) while the thumbnail source was the client area
    // (1115x628), so the content was 1:1 inside a larger surface and oneToOne read 0 for a reason
    // that had nothing to do with DWM. Registering on a scratch destination first is the only way
    // to learn that size, so the real destination is created after the query.
    HWND probe0 = MakeDest(16, 16, -9200, -9200, 0);
    SIZE q{ w, h };
    if (probe0) {
        HTHUMBNAIL t0 = nullptr;
        if (SUCCEEDED(DwmRegisterThumbnail(probe0, f.h, &t0)) && t0) {
            SIZE qq{}; if (SUCCEEDED(DwmQueryThumbnailSourceSize(t0, &qq)) && qq.cx && qq.cy) q = qq;
            DwmUnregisterThumbnail(t0);
        }
        DestroyWindow(probe0);
    }
    HWND dest = MakeDest(q.cx, q.cy, -9000, -9000, 0);
    if (!dest) { printf("RESULT=SWEEP class=%ls why=%s dest=FAIL\n", f.cls.c_str(), f.why); return; }
    ShowWindow(dest, SW_SHOWNA);
    HTHUMBNAIL th = nullptr;
    HRESULT hr = DwmRegisterThumbnail(dest, f.h, &th);
    if (FAILED(hr) || !th) {
        printf("RESULT=SWEEP class=%ls why=%s register=FAIL hr=0x%08lx\n", f.cls.c_str(), f.why,
               (unsigned long)hr); fflush(stdout);
        DestroyWindow(dest); return;
    }
    SIZE ss{}; DwmQueryThumbnailSourceSize(th, &ss);
    // 1:1 THIS TIME: size the destination rect to the thumbnail's own source size, not to the
    // window rect. The first run scaled 1115x628 into 1129x635 and so could say nothing about
    // pixel exactness.
    DWM_THUMBNAIL_PROPERTIES p{};
    p.dwFlags = DWM_TNP_RECTDESTINATION | DWM_TNP_VISIBLE | DWM_TNP_OPACITY;
    p.rcDestination = RECT{ 0, 0, ss.cx ? ss.cx : q.cx, ss.cy ? ss.cy : q.cy };
    p.fVisible = TRUE; p.opacity = 255;
    HRESULT hu = DwmUpdateThumbnailProperties(th, &p);
    Shot s = CaptureWindow(dest, 900);
    printf("RESULT=SWEEP class=%ls why=%s ex=0x%08lx src=%dx%d srcsize=%ldx%ld update=0x%08lx "
           "capture=%s frames=%d colours=%d nonBlack=%d cap=%dx%d oneToOne=%d "
           "alphaDistinct=%d alphaMin=%d alphaMax=%d alphaPartial=%d alphaZero=%d samples=%d\n",
           f.cls.c_str(), f.why, (unsigned long)f.ex, w, h, ss.cx, ss.cy, (unsigned long)hu,
           s.ok ? "ok" : "none", s.frames, s.colours, s.nonBlack, s.w, s.h,
           (ss.cx == s.w && ss.cy == s.h) ? 1 : 0,
           s.alphaDistinct, s.alphaMin, s.alphaMax, s.alphaPartial, s.alphaZero, s.samples);
    fflush(stdout);
    DwmUnregisterThumbnail(th);
    DestroyWindow(dest);
}

int wmain(int argc, wchar_t** argv)
{
    // The source window: by class name, or the foreground window. A rogue-class source is the point,
    // but the mechanism must first be shown to work at all on an ordinary one.
    HWND src = nullptr;
    std::wstring want = (argc > 1) ? argv[1] : L"";
    // --watch <seconds>: the toast race, removed. A guest toast under the generic PowerShell AUMID
    // lives about five seconds; every one-shot sweep enumerated either before its window existed or
    // after it had gone, and I twice read that as "no toast window exists" when the owner could see
    // the notification. This baselines the rogue set, then polls for NEW rogue windows and relays
    // each the instant it appears - so a transient window is caught rather than missed.
    if (want == L"--watch")
    {
        int secs = (argc > 2) ? _wtoi(argv[2]) : 30;
        if (!InitD3D()) { printf("RESULT=FAIL reason=d3d-init\n"); return 2; }
        std::vector<Found> base; g_found = &base;
        EnumWindows(SweepProc, 0);
        std::set<HWND> seen;
        for (auto& f : base) seen.insert(f.h);
        printf("RESULT=WATCHBASE count=%d secs=%d\n", (int)base.size(), secs);
        fflush(stdout);
        ULONGLONG until = GetTickCount64() + (ULONGLONG)secs * 1000;
        int caught = 0;
        while (GetTickCount64() < until)
        {
            std::vector<Found> now; g_found = &now;
            EnumWindows(SweepProc, 0);
            for (auto& f : now)
            {
                if (seen.count(f.h)) continue;
                seen.insert(f.h);
                caught++;
                printf("RESULT=WATCHNEW class=%ls why=%s\n", f.cls.c_str(), f.why); fflush(stdout);
                RelayOnce(f);   // relay it NOW, while it is still up
                fflush(stdout);
            }
            Sleep(120);
        }
        printf("RESULT=WATCHDONE caught=%d\n", caught);
        return 0;
    }
    if (want == L"--sweep")
    {
        if (!InitD3D()) { printf("RESULT=FAIL reason=d3d-init\n"); return 2; }
        std::vector<Found> found; g_found = &found;
        EnumWindows(SweepProc, 0);
        printf("RESULT=SWEEPFOUND count=%d\n", (int)found.size()); fflush(stdout);
        for (auto& f : found) {
            // One bad window must not take the sweep with it: the point of a sweep is the set.
            try { RelayOnce(f); }
            catch (...) { printf("RESULT=SWEEP class=%ls why=%s threw=1\n", f.cls.c_str(), f.why); }
            fflush(stdout);
        }
        int ok = 0; for (auto& f : found) { (void)f; }
        printf("RESULT=SWEEPDONE count=%d\n", (int)found.size());
        return 0;
    }
    if (!want.empty()) src = FindWindowW(want.c_str(), nullptr);
    if (!src) src = GetForegroundWindow();
    if (!src) { printf("RESULT=FAIL reason=no-source-window\n"); return 2; }

    WCHAR cls[128] = {}; GetClassNameW(src, cls, 128);
    RECT sr{}; GetWindowRect(src, &sr);
    printf("RESULT=SOURCE hwnd=0x%llx class=%ls %ldx%ld\n",
           (unsigned long long)(ULONG_PTR)src, cls, sr.right - sr.left, sr.bottom - sr.top);

    if (!InitD3D()) { printf("RESULT=FAIL reason=d3d-init\n"); return 2; }

    struct Case { const char* name; int x, y; DWORD ex; int show; };
    // THE FOUR DESTINATION STATES THAT DECIDE IT. If only 'onscreen' yields pixels, the relay can
    // only work with a real on-screen window, which on a seamless guest means dom0 would see it -
    // unusable. The other three are what would make it usable.
    Case cases[] = {
        { "onscreen",        40,   40, 0,                 SW_SHOWNA },
        { "offscreen",    -9000, -9000, 0,                SW_SHOWNA },
        { "layered-alpha0",  40,   40, WS_EX_LAYERED,     SW_SHOWNA },
        { "hidden",          40,   40, 0,                 SW_HIDE   },
    };
    int usable = 0;
    for (auto& c : cases)
    {
        int w = (int)(sr.right - sr.left), h = (int)(sr.bottom - sr.top);
        if (w < 16 || h < 16) { w = 400; h = 300; }
        HWND dest = MakeDest(w, h, c.x, c.y, c.ex);
        if (!dest) { printf("RESULT=%s state=no-dest\n", c.name); continue; }
        if (c.ex & WS_EX_LAYERED) SetLayeredWindowAttributes(dest, 0, 0, LWA_ALPHA);
        ShowWindow(dest, c.show);

        HTHUMBNAIL th = nullptr;
        HRESULT hr = DwmRegisterThumbnail(dest, src, &th);
        if (FAILED(hr) || !th) {
            printf("RESULT=%s register=FAIL hr=0x%08lx\n", c.name, (unsigned long)hr);
            DestroyWindow(dest); continue;
        }
        SIZE ss{}; DwmQueryThumbnailSourceSize(th, &ss);
        DWM_THUMBNAIL_PROPERTIES p{};
        p.dwFlags = DWM_TNP_RECTDESTINATION | DWM_TNP_VISIBLE | DWM_TNP_OPACITY |
                    DWM_TNP_SOURCECLIENTAREAONLY;
        p.rcDestination = RECT{ 0, 0, w, h };
        p.fVisible = TRUE; p.opacity = 255; p.fSourceClientAreaOnly = FALSE;
        HRESULT hu = DwmUpdateThumbnailProperties(th, &p);

        Shot s = CaptureWindow(dest, 900);
        printf("RESULT=%s register=ok update=0x%08lx srcsize=%ldx%ld capture=%s "
               "frames=%d colours=%d nonBlack=%d size=%dx%d "
               "alphaDistinct=%d alphaMin=%d alphaMax=%d alphaPartial=%d alphaZero=%d samples=%d\n",
               c.name, (unsigned long)hu, ss.cx, ss.cy, s.ok ? "ok" : "none",
               s.frames, s.colours, s.nonBlack, s.w, s.h,
               s.alphaDistinct, s.alphaMin, s.alphaMax, s.alphaPartial, s.alphaZero, s.samples);
        // "Usable" = the capture of OUR destination carries content. One colour means the thumbnail
        // did not reach the composed tree; that is the death condition for this state.
        if (s.ok && s.colours > 2) usable++;
        DwmUnregisterThumbnail(th);
        DestroyWindow(dest);
    }
    printf("RESULT=SUMMARY usableStates=%d of 4\n", usable);
    return 0;
}
