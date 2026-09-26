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

// --hold <secs> [--pump]: DOES A RELAY KEEP DELIVERING? The four-state and sweep modes captured each
// destination ONCE, after a fixed settle, and reported frames=1 or 2. That established that a
// thumbnail destination is CAPTURABLE. It said nothing about whether arrivals CONTINUE as the source
// changes - and the broker can only use an ongoing feed. Measured on the rig afterwards: five relay
// slots opened (relayOk=1) and were demoted to polled PrintWindow because no arrival landed within
// the 2 s quiet window. Jev rated my "all four classes relay" claim overstated at 0.93 and put this
// measurement at 0.93 as the cheapest way to find out why.
//
// --pump runs a message loop on the thread that owns the destination. A window belongs to its
// creating thread, and the broker's main thread never pumps; if arrivals depend on that pump, this
// A/B says so in one run and the fix is structural rather than guessed.
// --broker-dest replicates the BROKER's destination EXACTLY - same extended styles (adding
// WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT) and the same position (0,0) instead of
// this probe's own (40,40) with WS_EX_LAYERED alone. WHY: measured 2026-09-26, a relay slot in the
// broker received ZERO arrivals across a source repaint while a direct-WGC control on the same window
// class received several, and the destination window itself was verified alive, visible, uncloaked,
// on-screen and at alpha 0. This probe's destination, with the same alpha 0, receives CONTINUOUS
// arrivals from a changing source. So the difference is in the destination's styles or position, and
// this flag turns that into a one-run A/B instead of a guess.
static bool g_noClose = false;   // see --no-close in HoldAndCount's handler
static bool g_pwSource = false;  // see --pw-source below

// Render a window exactly as the broker's DEMOTION PROBE does. The broker decides whether to demote a
// quiet relay by PrintWindow(PW_RENDERFULLCONTENT)-ing the relay's SOURCE and hashing it. An A/B on one
// guest showed the relay delivers a driven change when that rule is DISABLED (delivered moved 20.6,
// matched the new source 1.4) and delivers NOTHING when it is enabled (0.0 while the source moved 21.8)
// - Jev rated the rule responsible at 0.91, with the mechanism itself only 0.53, so this reproduces the
// suspected mechanism here, with no broker involved: if PrintWindowing a thumbnail's SOURCE suppresses
// DWM's recomposition of that thumbnail, this probe's own arrivals will stop when --pw-source is on.
static void PwRenderSource(HWND src)
{
    RECT r{};
    if (!GetWindowRect(src, &r)) return;
    int w = r.right - r.left, h = r.bottom - r.top;
    if (w <= 0 || h <= 0 || w > 4096 || h > 4096) return;
    HDC screen = GetDC(nullptr);
    HDC mem = CreateCompatibleDC(screen);
    BITMAPINFO bi{};
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = w; bi.bmiHeader.biHeight = -h;
    bi.bmiHeader.biPlanes = 1; bi.bmiHeader.biBitCount = 32; bi.bmiHeader.biCompression = BI_RGB;
    void* bits = nullptr;
    HBITMAP bmp = CreateDIBSection(mem, &bi, DIB_RGB_COLORS, &bits, nullptr, 0);
    if (bmp && bits) { SelectObject(mem, bmp); PrintWindow(src, mem, PW_RENDERFULLCONTENT); }
    if (bmp) DeleteObject(bmp);
    DeleteDC(mem);
    ReleaseDC(nullptr, screen);
}
static int HoldAndCount(HWND src, int secs, bool pump, bool brokerDest)
{
    HTHUMBNAIL th = nullptr; int w = 0, h = 0;
    RECT sr{}; GetWindowRect(src, &sr);
    w = sr.right - sr.left; h = sr.bottom - sr.top;
    const DWORD destEx = brokerDest
        ? (WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT)
        : WS_EX_LAYERED;
    const int destX = brokerDest ? 0 : 40, destY = brokerDest ? 0 : 40;
    printf("RESULT=HOLDDEST brokerDest=%d ex=0x%08lx pos=%d,%d noClose=%d pwSource=%d\n",
           brokerDest ? 1 : 0, (unsigned long)destEx, destX, destY, g_noClose ? 1 : 0,
           g_pwSource ? 1 : 0);
    HWND dest = MakeDest(w, h, destX, destY, destEx);
    if (!dest) { printf("RESULT=HOLD dest=FAIL\n"); return 2; }
    SetLayeredWindowAttributes(dest, 0, 0, LWA_ALPHA);
    ShowWindow(dest, SW_SHOWNA);
    if (FAILED(DwmRegisterThumbnail(dest, src, &th)) || !th) {
        printf("RESULT=HOLD register=FAIL\n"); DestroyWindow(dest); return 2; }
    SIZE ss{}; DwmQueryThumbnailSourceSize(th, &ss);
    DWM_THUMBNAIL_PROPERTIES p{};
    p.dwFlags = DWM_TNP_RECTDESTINATION | DWM_TNP_VISIBLE | DWM_TNP_OPACITY;
    p.rcDestination = RECT{ 0, 0, ss.cx ? ss.cx : w, ss.cy ? ss.cy : h };
    p.fVisible = TRUE; p.opacity = 255;
    DwmUpdateThumbnailProperties(th, &p);

    // A REAL FrameArrived handler, not TryGetNextFrame polling: the broker is event-driven and the
    // question is whether the event fires at all.
    // STATIC, not a stack local. The handler is invoked on a threadpool thread and can run during
    // teardown; capturing a stack variable by reference is what made the probe exit 0xc0000409
    // (stack buffer overrun) AFTER printing correct results. The numbers were right, the exit was not.
    static volatile LONG arrivals;
    arrivals = 0;
    try {
        auto interop = get_activation_factory<GraphicsCaptureItem, ::IGraphicsCaptureItemInterop>();
        GraphicsCaptureItem item{ nullptr };
        if (FAILED(interop->CreateForWindow(dest, guid_of<GraphicsCaptureItem>(),
                                            reinterpret_cast<void**>(put_abi(item)))) || !item) {
            printf("RESULT=HOLD createForWindow=FAIL\n");
            DwmUnregisterThumbnail(th); DestroyWindow(dest); return 2;
        }
        auto size = item.Size();
        auto pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
            g_rtDev, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
        auto session = pool.CreateCaptureSession(item);
        try { session.IsBorderRequired(false); } catch (...) {}
        // --no-close DELIBERATELY OMITS f.Close(), which is the ONE difference left between this probe
        // and the broker's arrival handler. The broker never closes its frame; it relies on the local
        // being destroyed at handler exit. Its relay slots freeze after a handful of frames - one
        // stopped at exactly 2, which is the pool's buffer count - while this probe, which DOES close,
        // delivered 437 arrivals over 240 s against the same kind of destination. If Direct3D11Capture-
        // Frame only returns its buffer on Close() rather than on release of the last reference, a
        // handler that never closes exhausts a 2-buffer pool and stops receiving events. This flag
        // settles that in the instrument I control instead of guessing about the product.
        const bool noClose = g_noClose;
        auto rev = pool.FrameArrived(auto_revoke, [noClose](auto const& sender, auto const&) {
            if (auto f = sender.TryGetNextFrame()) {
                InterlockedIncrement(&arrivals);
                if (!noClose) f.Close();
            }
        });
        session.StartCapture();
        printf("RESULT=HOLD start src=0x%llx dest=0x%llx %dx%d pump=%d secs=%d\n",
               (unsigned long long)(ULONG_PTR)src, (unsigned long long)(ULONG_PTR)dest,
               (int)size.Width, (int)size.Height, pump ? 1 : 0, secs);
        fflush(stdout);
        // Report per second, so "a burst then silence" is visibly different from "steady".
        for (int t = 0; t < secs; t++) {
            LONG before = arrivals;
            // --pw-source: render the SOURCE the way the broker's demotion probe does, twice a second,
            // which is that probe's most aggressive cadence (it resets to 500 ms whenever it sees a
            // change, so a changing window gets it hardest - matching the observed inversion).
            if (g_pwSource) PwRenderSource(src);
            ULONGLONG until = GetTickCount64() + 1000;
            while (GetTickCount64() < until) {
                if (pump) {
                    MSG m;
                    while (PeekMessageW(&m, nullptr, 0, 0, PM_REMOVE)) { TranslateMessage(&m); DispatchMessageW(&m); }
                }
                Sleep(10);
            }
            if (g_pwSource) PwRenderSource(src);
            printf("RESULT=HOLDSEC t=%d arrivals=%ld delta=%ld\n", t + 1, (long)arrivals, (long)(arrivals - before));
            fflush(stdout);
        }
        session.Close(); pool.Close();
    } catch (...) { printf("RESULT=HOLD threw=1\n"); }
    printf("RESULT=HOLDDONE arrivals=%ld pump=%d\n", (long)arrivals, pump ? 1 : 0);
    DwmUnregisterThumbnail(th); DestroyWindow(dest);
    return 0;
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
    // --hold2 <secs> <stacked|apart> [class]: TWO relays alive at once. The broker had five
    // destinations stacked at (0,0) and every relay went quiet; the probe had exactly one, at 40,40,
    // and sustained ~2 arrivals/s. This isolates the count-and-position variable without touching the
    // broker. Jev ranked it the cheapest discriminator at 0.61 against a longer single hold at 0.39,
    // and rated my own overlapping-destinations theory only 0.07 - so this is as much a test of that
    // theory as of the broker.
    if (want == L"--hold2")
    {
        if (!InitD3D()) { printf("RESULT=FAIL reason=d3d-init\n"); return 2; }
        int secs = (argc > 2) ? _wtoi(argv[2]) : 12;
        bool stacked = (argc > 3) && !wcscmp(argv[3], L"stacked");
        std::wstring srcCls = (argc > 4) ? argv[4] : L"";
        HWND src = srcCls.empty() ? nullptr : FindWindowW(srcCls.c_str(), nullptr);
        if (!src) src = GetForegroundWindow();
        if (!src) { printf("RESULT=FAIL reason=no-source\n"); return 2; }
        RECT sr{}; GetWindowRect(src, &sr);
        int w = sr.right - sr.left, h = sr.bottom - sr.top;
        printf("RESULT=HOLD2 mode=%ls src=0x%llx %dx%d secs=%d\n",
               stacked ? L"stacked" : L"apart", (unsigned long long)(ULONG_PTR)src, w, h, secs);
        fflush(stdout);
        struct Two { HWND dest; HTHUMBNAIL th; Direct3D11CaptureFramePool pool{ nullptr };
                     GraphicsCaptureSession sess{ nullptr };
                     Direct3D11CaptureFramePool::FrameArrived_revoker rev; };
        static volatile LONG cnt[2]; cnt[0] = cnt[1] = 0;
        Two two[2]{};
        for (int k = 0; k < 2; k++) {
            int x = stacked ? 0 : (k * (w + 80));
            int y = stacked ? 0 : 0;
            two[k].dest = MakeDest(w, h, x, y, WS_EX_LAYERED);
            if (!two[k].dest) { printf("RESULT=HOLD2 k=%d dest=FAIL\n", k); continue; }
            SetLayeredWindowAttributes(two[k].dest, 0, 0, LWA_ALPHA);
            ShowWindow(two[k].dest, SW_SHOWNA);
            if (FAILED(DwmRegisterThumbnail(two[k].dest, src, &two[k].th)) || !two[k].th) {
                printf("RESULT=HOLD2 k=%d register=FAIL\n", k); continue; }
            SIZE ss{}; DwmQueryThumbnailSourceSize(two[k].th, &ss);
            DWM_THUMBNAIL_PROPERTIES p{};
            p.dwFlags = DWM_TNP_RECTDESTINATION | DWM_TNP_VISIBLE | DWM_TNP_OPACITY;
            p.rcDestination = RECT{ 0, 0, ss.cx ? ss.cx : w, ss.cy ? ss.cy : h };
            p.fVisible = TRUE; p.opacity = 255;
            DwmUpdateThumbnailProperties(two[k].th, &p);
            try {
                auto interop = get_activation_factory<GraphicsCaptureItem, ::IGraphicsCaptureItemInterop>();
                GraphicsCaptureItem item{ nullptr };
                if (FAILED(interop->CreateForWindow(two[k].dest, guid_of<GraphicsCaptureItem>(),
                                                    reinterpret_cast<void**>(put_abi(item)))) || !item) {
                    printf("RESULT=HOLD2 k=%d createForWindow=FAIL\n", k); continue; }
                auto size = item.Size();
                two[k].pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
                    g_rtDev, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
                two[k].sess = two[k].pool.CreateCaptureSession(item);
                try { two[k].sess.IsBorderRequired(false); } catch (...) {}
                int idx = k;
                two[k].rev = two[k].pool.FrameArrived(auto_revoke,
                    [idx](auto const& sender, auto const&) {
                        if (auto f = sender.TryGetNextFrame()) { InterlockedIncrement(&cnt[idx]); f.Close(); }
                    });
                two[k].sess.StartCapture();
            } catch (...) { printf("RESULT=HOLD2 k=%d threw=1\n", k); }
        }
        for (int t = 0; t < secs; t++) {
            LONG b0 = cnt[0], b1 = cnt[1];
            Sleep(1000);
            printf("RESULT=HOLD2SEC t=%d a0=%ld d0=%ld a1=%ld d1=%ld\n",
                   t + 1, (long)cnt[0], (long)(cnt[0] - b0), (long)cnt[1], (long)(cnt[1] - b1));
            fflush(stdout);
        }
        printf("RESULT=HOLD2DONE mode=%ls a0=%ld a1=%ld\n",
               stacked ? L"stacked" : L"apart", (long)cnt[0], (long)cnt[1]);
        for (int k = 0; k < 2; k++) {
            if (two[k].sess) { try { two[k].sess.Close(); } catch (...) {} }
            if (two[k].pool) { try { two[k].pool.Close(); } catch (...) {} }
            if (two[k].th)   DwmUnregisterThumbnail(two[k].th);
            if (two[k].dest) DestroyWindow(two[k].dest);
        }
        return 0;
    }
    // --holdn <count> <secs> [apart] : hold COUNT relays of one source at once, STACKED at (0,0) by
    // default, exactly as the broker does - it creates one destination per relay slot, all at (0,0),
    // all sized to their source, so they overlap almost completely. Destinations are created STAGGERED
    // (one every 3 s) and each relay's per-second delta is printed, so an earlier relay going quiet the
    // moment a new destination appears over it is visible directly rather than inferred.
    //
    // WHY: the broker's relay slots freeze after a VARYING handful of frames (2, 3, 12, 25, 89) while
    // direct-WGC slots in the same process keep delivering and a SINGLE-relay probe delivers
    // indefinitely (437 arrivals over 240 s). After eliminating the destination's styles and position,
    // settling, per-pixel-alpha specificity, cloaking, stale counters, a closed channel, a required
    // message pump and a required f.Close(), the remaining structural difference is that the broker
    // holds MANY overlapping destinations. Jev: many-overlapping-destinations 0.91,
    // probe-holds-many-stacked 0.84. `apart` is the control.
    // --holdmulti <secs> <class1> <class2> ... : hold ONE relay per NAMED SOURCE CLASS, all at once,
    // and print each source's per-second delta. This exists to explain a measured INVERSION that no
    // mechanism guess has accounted for: in the broker, relay slots for two windows ADVANCED while
    // three did not, at the same moment in the same process - and the frozen ones were the windows
    // whose content had definitely just changed (a terminal being typed into, a per-pixel-alpha window
    // whose content was advanced on purpose), while the advancing ones were static by construction.
    //
    // If this probe reproduces the same split across the same five sources, the behaviour belongs to
    // the SOURCE WINDOWS and not to the broker. If all five advance here, it is broker-specific. Either
    // answer is decisive, which is more than any of the four refuted mechanisms offered.
    if (want == L"--holdmulti")
    {
        if (!InitD3D()) { printf("RESULT=FAIL reason=d3d-init\n"); return 2; }
        int secs = (argc > 2) ? _wtoi(argv[2]) : 30;
        const int MAXS = 8;
        std::wstring cls[MAXS];
        int n = 0;
        for (int a = 3; a < argc && n < MAXS; a++) cls[n++] = argv[a];
        if (!n) { printf("RESULT=FAIL reason=no-classes\n"); return 2; }
        struct One { HWND src; HWND dest; HTHUMBNAIL th; Direct3D11CaptureFramePool pool{ nullptr };
                     GraphicsCaptureSession sess{ nullptr };
                     Direct3D11CaptureFramePool::FrameArrived_revoker rev; };
        static volatile LONG mcnt[MAXS];
        for (int k = 0; k < MAXS; k++) mcnt[k] = 0;
        static One ms[MAXS]{};
        for (int k = 0; k < n; k++) {
            ms[k].src = FindWindowW(cls[k].c_str(), nullptr);
            if (!ms[k].src) { printf("RESULT=HOLDMULTI k=%d class=%ls src=NOTFOUND\n", k, cls[k].c_str()); continue; }
            RECT sr{}; GetWindowRect(ms[k].src, &sr);
            int w = sr.right - sr.left, h = sr.bottom - sr.top;
            // The broker's destination exactly: same extended styles, same (0,0), alpha 0.
            ms[k].dest = MakeDest(w, h, 0, 0,
                WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT);
            if (!ms[k].dest) { printf("RESULT=HOLDMULTI k=%d dest=FAIL\n", k); continue; }
            SetLayeredWindowAttributes(ms[k].dest, 0, 0, LWA_ALPHA);
            ShowWindow(ms[k].dest, SW_SHOWNA);
            if (FAILED(DwmRegisterThumbnail(ms[k].dest, ms[k].src, &ms[k].th)) || !ms[k].th) {
                printf("RESULT=HOLDMULTI k=%d register=FAIL\n", k); continue; }
            SIZE ss{}; DwmQueryThumbnailSourceSize(ms[k].th, &ss);
            printf("RESULT=HOLDMULTI k=%d class=%ls src=0x%llx srcSize=%dx%d thumbSize=%dx%d\n",
                   k, cls[k].c_str(), (unsigned long long)(ULONG_PTR)ms[k].src, w, h,
                   (int)ss.cx, (int)ss.cy);
            DWM_THUMBNAIL_PROPERTIES p{};
            p.dwFlags = DWM_TNP_RECTDESTINATION | DWM_TNP_VISIBLE | DWM_TNP_OPACITY;
            p.rcDestination = RECT{ 0, 0, ss.cx ? ss.cx : w, ss.cy ? ss.cy : h };
            p.fVisible = TRUE; p.opacity = 255;
            DwmUpdateThumbnailProperties(ms[k].th, &p);
            try {
                auto interop = get_activation_factory<GraphicsCaptureItem, ::IGraphicsCaptureItemInterop>();
                GraphicsCaptureItem item{ nullptr };
                if (FAILED(interop->CreateForWindow(ms[k].dest, guid_of<GraphicsCaptureItem>(),
                              reinterpret_cast<void**>(put_abi(item)))) || !item) {
                    printf("RESULT=HOLDMULTI k=%d createForWindow=FAIL\n", k); continue; }
                auto size = item.Size();
                ms[k].pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
                    g_rtDev, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
                ms[k].sess = ms[k].pool.CreateCaptureSession(item);
                try { ms[k].sess.IsBorderRequired(false); } catch (...) {}
                int idx = k;
                ms[k].rev = ms[k].pool.FrameArrived(auto_revoke,
                    [idx](auto const& sender, auto const&) {
                        if (auto f = sender.TryGetNextFrame()) { InterlockedIncrement(&mcnt[idx]); f.Close(); }
                    });
                ms[k].sess.StartCapture();
            } catch (...) { printf("RESULT=HOLDMULTI k=%d threw=1\n", k); }
        }
        fflush(stdout);
        for (int t = 0; t < secs; t++) {
            LONG before[MAXS];
            for (int k = 0; k < n; k++) before[k] = mcnt[k];
            Sleep(1000);
            printf("RESULT=HOLDMULTISEC t=%d", t + 1);
            for (int k = 0; k < n; k++)
                printf(" a%d=%ld d%d=%ld", k, (long)mcnt[k], k, (long)(mcnt[k] - before[k]));
            printf("\n"); fflush(stdout);
        }
        printf("RESULT=HOLDMULTIDONE");
        for (int k = 0; k < n; k++) printf(" %ls=%ld", cls[k].c_str(), (long)mcnt[k]);
        printf("\n");
        for (int k = 0; k < n; k++) {
            if (ms[k].sess) { try { ms[k].sess.Close(); } catch (...) {} }
            if (ms[k].pool) { try { ms[k].pool.Close(); } catch (...) {} }
            if (ms[k].th)   DwmUnregisterThumbnail(ms[k].th);
            if (ms[k].dest) DestroyWindow(ms[k].dest);
        }
        return 0;
    }
    if (want == L"--holdn")
    {
        if (!InitD3D()) { printf("RESULT=FAIL reason=d3d-init\n"); return 2; }
        int count = (argc > 2) ? _wtoi(argv[2]) : 4;
        int secs  = (argc > 3) ? _wtoi(argv[3]) : 40;
        bool apart = false;
        std::wstring srcCls;
        for (int a = 4; a < argc; a++) {
            if (!wcscmp(argv[a], L"apart")) apart = true; else srcCls = argv[a];
        }
        if (count < 1) count = 1;
        const int MAXN = 12;
        if (count > MAXN) count = MAXN;
        HWND src = srcCls.empty() ? nullptr : FindWindowW(srcCls.c_str(), nullptr);
        if (!src) src = GetForegroundWindow();
        if (!src) { printf("RESULT=FAIL reason=no-source\n"); return 2; }
        RECT sr{}; GetWindowRect(src, &sr);
        int w = sr.right - sr.left, h = sr.bottom - sr.top;
        printf("RESULT=HOLDN mode=%ls count=%d src=0x%llx %dx%d secs=%d\n",
               apart ? L"apart" : L"stacked", count,
               (unsigned long long)(ULONG_PTR)src, w, h, secs);
        fflush(stdout);
        struct One { HWND dest; HTHUMBNAIL th; Direct3D11CaptureFramePool pool{ nullptr };
                     GraphicsCaptureSession sess{ nullptr };
                     Direct3D11CaptureFramePool::FrameArrived_revoker rev; };
        static volatile LONG ncnt[MAXN];
        for (int k = 0; k < MAXN; k++) ncnt[k] = 0;
        static One ones[MAXN]{};
        int made = 0;
        for (int t = 0; t < secs; t++) {
            // Stagger: bring one more relay up every 3 s until `count` are running.
            if (made < count && (t % 3) == 0) {
                int k = made;
                int x = apart ? (k * 40) : 0, y = apart ? (k * 40) : 0;
                ones[k].dest = MakeDest(w, h, x, y,
                    WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT);
                if (ones[k].dest) {
                    SetLayeredWindowAttributes(ones[k].dest, 0, 0, LWA_ALPHA);
                    ShowWindow(ones[k].dest, SW_SHOWNA);
                    if (SUCCEEDED(DwmRegisterThumbnail(ones[k].dest, src, &ones[k].th)) && ones[k].th) {
                        SIZE ss{}; DwmQueryThumbnailSourceSize(ones[k].th, &ss);
                        DWM_THUMBNAIL_PROPERTIES p{};
                        p.dwFlags = DWM_TNP_RECTDESTINATION | DWM_TNP_VISIBLE | DWM_TNP_OPACITY;
                        p.rcDestination = RECT{ 0, 0, ss.cx ? ss.cx : w, ss.cy ? ss.cy : h };
                        p.fVisible = TRUE; p.opacity = 255;
                        DwmUpdateThumbnailProperties(ones[k].th, &p);
                        try {
                            auto interop = get_activation_factory<GraphicsCaptureItem, ::IGraphicsCaptureItemInterop>();
                            GraphicsCaptureItem item{ nullptr };
                            if (SUCCEEDED(interop->CreateForWindow(ones[k].dest, guid_of<GraphicsCaptureItem>(),
                                          reinterpret_cast<void**>(put_abi(item)))) && item) {
                                auto size = item.Size();
                                ones[k].pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
                                    g_rtDev, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
                                ones[k].sess = ones[k].pool.CreateCaptureSession(item);
                                try { ones[k].sess.IsBorderRequired(false); } catch (...) {}
                                int idx = k;
                                ones[k].rev = ones[k].pool.FrameArrived(auto_revoke,
                                    [idx](auto const& sender, auto const&) {
                                        if (auto f = sender.TryGetNextFrame()) {
                                            InterlockedIncrement(&ncnt[idx]); f.Close(); }
                                    });
                                ones[k].sess.StartCapture();
                                printf("RESULT=HOLDN up k=%d dest=0x%llx t=%d\n",
                                       k, (unsigned long long)(ULONG_PTR)ones[k].dest, t);
                                fflush(stdout);
                            } else printf("RESULT=HOLDN k=%d createForWindow=FAIL\n", k);
                        } catch (...) { printf("RESULT=HOLDN k=%d threw=1\n", k); }
                    } else printf("RESULT=HOLDN k=%d register=FAIL\n", k);
                } else printf("RESULT=HOLDN k=%d dest=FAIL\n", k);
                made++;
            }
            LONG before[MAXN];
            for (int k = 0; k < count; k++) before[k] = ncnt[k];
            Sleep(1000);
            printf("RESULT=HOLDNSEC t=%d", t + 1);
            for (int k = 0; k < count; k++)
                printf(" a%d=%ld d%d=%ld", k, (long)ncnt[k], k, (long)(ncnt[k] - before[k]));
            printf("\n"); fflush(stdout);
        }
        printf("RESULT=HOLDNDONE mode=%ls", apart ? L"apart" : L"stacked");
        for (int k = 0; k < count; k++) printf(" a%d=%ld", k, (long)ncnt[k]);
        printf("\n");
        for (int k = 0; k < count; k++) {
            if (ones[k].sess) { try { ones[k].sess.Close(); } catch (...) {} }
            if (ones[k].pool) { try { ones[k].pool.Close(); } catch (...) {} }
            if (ones[k].th)   DwmUnregisterThumbnail(ones[k].th);
            if (ones[k].dest) DestroyWindow(ones[k].dest);
        }
        return 0;
    }
    if (want == L"--hold")
    {
        if (!InitD3D()) { printf("RESULT=FAIL reason=d3d-init\n"); return 2; }
        int secs = (argc > 2) ? _wtoi(argv[2]) : 15;
        bool pump = false;
        std::wstring srcCls;
        bool brokerDest = false;
        for (int a = 3; a < argc; a++) {
            if (!wcscmp(argv[a], L"--pump")) pump = true;
            else if (!wcscmp(argv[a], L"--broker-dest")) brokerDest = true;
            else if (!wcscmp(argv[a], L"--no-close")) g_noClose = true;
            else if (!wcscmp(argv[a], L"--pw-source")) g_pwSource = true;
            else srcCls = argv[a];
        }
        HWND src = srcCls.empty() ? nullptr : FindWindowW(srcCls.c_str(), nullptr);
        if (!src) src = GetForegroundWindow();
        if (!src) { printf("RESULT=FAIL reason=no-source\n"); return 2; }
        WCHAR cls[128] = {}; GetClassNameW(src, cls, 128);
        printf("RESULT=SOURCE hwnd=0x%llx class=%ls\n", (unsigned long long)(ULONG_PTR)src, cls);
        return HoldAndCount(src, secs, pump, brokerDest);
    }
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
