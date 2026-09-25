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
struct Shot { int frames = 0; int colours = 0; int nonBlack = 0; int w = 0, h = 0; bool ok = false; };

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
                        for (UINT y = 0; y < d.Height; y += 9)
                        {
                            auto row = (const uint32_t*)((const BYTE*)m.pData + (size_t)y * m.RowPitch);
                            for (UINT x = 0; x < d.Width; x += 9)
                            {
                                uint32_t p = row[x] & 0x00FFFFFF;
                                cols.insert(p);
                                if (p) s.nonBlack++;
                            }
                        }
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

int wmain(int argc, wchar_t** argv)
{
    // The source window: by class name, or the foreground window. A rogue-class source is the point,
    // but the mechanism must first be shown to work at all on an ordinary one.
    HWND src = nullptr;
    std::wstring want = (argc > 1) ? argv[1] : L"";
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
               "frames=%d colours=%d nonBlack=%d size=%dx%d\n",
               c.name, (unsigned long)hu, ss.cx, ss.cy, s.ok ? "ok" : "none",
               s.frames, s.colours, s.nonBlack, s.w, s.h);
        // "Usable" = the capture of OUR destination carries content. One colour means the thumbnail
        // did not reach the composed tree; that is the death condition for this state.
        if (s.ok && s.colours > 2) usable++;
        DwmUnregisterThumbnail(th);
        DestroyWindow(dest);
    }
    printf("RESULT=SUMMARY usableStates=%d of 4\n", usable);
    return 0;
}
