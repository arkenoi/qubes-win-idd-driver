// wgcprobe - per-window-capture feasibility probes (SESSION-PLAN steps 2 and 3).
//
// Q4: is Windows.Graphics.Capture usable on this guest, does it deliver CORRECT content
//     for an occluded window, and what does it cost to get a frame into CPU-mappable
//     memory (staging copy + Map)? WGC surfaces are GPU-side; the copy is the honest
//     price of feeding the existing grant-based transport from WGC.
// Q3: does N-window capture cost scale with window count or with damaged area?
//
// Modes:
//   wgcprobe check
//       - IsSupported + presence probes (DirtyRegions, IsBorderRequired,
//         IsCursorCaptureEnabled)
//       - spawns pattern window A (static) + cover B, captures A via WGC, byte-compares
//         against the exact pattern  -> occluded-correctness verdict
//   wgcprobe bench <K> <frames_per_window> [w h]
//       - spawns K animated pattern windows (16 ms invalidate timer), captures all K
//         concurrently, per-frame acquire->mapped latency stats + achieved fps + process
//         CPU time. Run with K = 1,4,10,30 against a ddaprobe DDA control (same scene).
//   wgcprobe benchstatic <K> <seconds> [w h]
//       - same scene but windows NOT animated: measures what capture costs when nothing
//         changes (scales-with-damage vs scales-with-count).
//
// Output: human-readable report, then "=== WGCPROBE JSON ===" + one single-line JSON.
// Build: MSVC v143, /std:c++17, /MT, Windows SDK 10 (C++/WinRT headers in the SDK).

#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dxgi1_2.h>
#include <inspectable.h>

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Metadata.h>
#include <winrt/Windows.Graphics.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>

#include <stdio.h>
#include <vector>
#include <string>
#include <algorithm>
#include <atomic>
#include <thread>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "windowsapp.lib")

using namespace winrt;
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
using namespace winrt::Windows::Graphics::DirectX::Direct3D11;
namespace meta = winrt::Windows::Foundation::Metadata;

// ------------------------------------------------------------------ pattern windows

static const int DEF_W = 800, DEF_H = 600;
static std::atomic<int> g_phase{0};   // bumped per animation tick; painted into pattern

static DWORD PatternPixel(int x, int y, int phase)
{
    BYTE r = (BYTE)((x + phase) & 0xFF), g = (BYTE)((y + phase) & 0xFF),
         b = (BYTE)((x ^ y) & 0xFF);
    return ((DWORD)r << 16) | ((DWORD)g << 8) | b; // BGRX DWORD == masked BGRA DWORD
}

struct PatWin {
    HWND hwnd = nullptr;
    int w = DEF_W, h = DEF_H;
    bool animate = false;
    int tile = 0;   // 0 = invalidate whole window per tick; else a tile x tile region
};

static LRESULT CALLBACK PatProc(HWND h, UINT m, WPARAM w, LPARAM l)
{
    PatWin *pw = (PatWin *)GetWindowLongPtrW(h, GWLP_USERDATA);
    switch (m) {
    case WM_TIMER: {
        int ph = g_phase.fetch_add(1);
        if (pw && pw->tile > 0) {
            // bounded damage: walk a tile across the window so per-tick damage is
            // constant regardless of window size (Q3: count vs damaged area)
            int tx = (ph * pw->tile) % (pw->w > pw->tile ? pw->w - pw->tile : 1);
            int ty = (ph * 37) % (pw->h > pw->tile ? pw->h - pw->tile : 1);
            RECT r{ tx, ty, tx + pw->tile, ty + pw->tile };
            InvalidateRect(h, &r, FALSE);
        } else {
            InvalidateRect(h, nullptr, FALSE);
        }
        return 0;
    }
    case WM_PAINT: {
        PAINTSTRUCT ps;
        HDC dc = BeginPaint(h, &ps);
        if (pw) {
            // paint ONLY the invalid rect: scene cost tracks damage, not window size
            int x0 = ps.rcPaint.left, y0 = ps.rcPaint.top;
            int pw_ = ps.rcPaint.right - x0, ph_ = ps.rcPaint.bottom - y0;
            if (pw_ > 0 && ph_ > 0) {
                static thread_local std::vector<DWORD> buf;
                buf.resize((size_t)pw_ * ph_);
                int phase = pw->animate ? g_phase.load() : 0;
                for (int y = 0; y < ph_; y++)
                    for (int x = 0; x < pw_; x++)
                        buf[(size_t)y * pw_ + x] =
                            PatternPixel(x0 + x, y0 + y, phase);
                BITMAPINFO bi{};
                bi.bmiHeader.biSize = sizeof(bi.bmiHeader);
                bi.bmiHeader.biWidth = pw_;
                bi.bmiHeader.biHeight = -ph_;
                bi.bmiHeader.biPlanes = 1;
                bi.bmiHeader.biBitCount = 32;
                bi.bmiHeader.biCompression = BI_RGB;
                SetDIBitsToDevice(dc, x0, y0, pw_, ph_, 0, 0, 0, ph_,
                                  buf.data(), &bi, DIB_RGB_COLORS);
            }
        }
        EndPaint(h, &ps);
        return 0;
    }
    }
    return DefWindowProcW(h, m, w, l);
}

static HWND MakePatWin(PatWin *pw, int x, int y, const wchar_t *title)
{
    static bool reg = false;
    if (!reg) {
        WNDCLASSW wc{};
        wc.lpfnWndProc = PatProc;
        wc.hInstance = GetModuleHandleW(nullptr);
        wc.lpszClassName = L"wgcprobePat";
        wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
        RegisterClassW(&wc);
        reg = true;
    }
    HWND h = CreateWindowExW(0, L"wgcprobePat", title, WS_POPUP | WS_VISIBLE,
                             x, y, pw->w, pw->h, nullptr, nullptr,
                             GetModuleHandleW(nullptr), nullptr);
    SetWindowLongPtrW(h, GWLP_USERDATA, (LONG_PTR)pw);
    if (pw->animate)
        SetTimer(h, 1, 16, nullptr);
    UpdateWindow(h);
    pw->hwnd = h;
    return h;
}

// Scene thread: creates the K windows on its OWN thread and pumps them there, so
// scene generation cannot starve the capture-polling loop (review blocker fix).
struct SceneThread {
    std::vector<PatWin> *wins;
    HANDLE ready = nullptr;
    HANDLE thread = nullptr;
    std::atomic<bool> quit{false};
};

static DWORD WINAPI ScenePump(LPVOID p)
{
    SceneThread *st = (SceneThread *)p;
    int i = 0;
    for (auto &pw : *st->wins) {
        MakePatWin(&pw, 40 + (i % 8) * 90, 40 + (i / 8) * 90, L"wgcprobe-bench");
        i++;
    }
    SetEvent(st->ready);
    MSG msg;
    while (!st->quit.load()) {
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        MsgWaitForMultipleObjects(0, nullptr, FALSE, 5, QS_ALLINPUT);
    }
    for (auto &pw : *st->wins)
        if (pw.hwnd) DestroyWindow(pw.hwnd);
    return 0;
}

static void PumpFor(DWORD ms)
{
    DWORD end = GetTickCount() + ms;
    MSG msg;
    for (;;) {
        while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
            TranslateMessage(&msg);
            DispatchMessageW(&msg);
        }
        if ((LONG)(GetTickCount() - end) >= 0)
            break;
        MsgWaitForMultipleObjects(0, nullptr, FALSE, 10, QS_ALLINPUT);
    }
}

// ------------------------------------------------------------------ D3D/WGC plumbing

struct D3D {
    com_ptr<ID3D11Device> dev;
    com_ptr<ID3D11DeviceContext> ctx;
    IDirect3DDevice rtdev{nullptr};
};

static bool MakeD3D(D3D &d)
{
    UINT flags = D3D11_CREATE_DEVICE_BGRA_SUPPORT;
    if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_HARDWARE, nullptr, flags,
                                 nullptr, 0, D3D11_SDK_VERSION, d.dev.put(), nullptr,
                                 d.ctx.put())))
        if (FAILED(D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr, flags,
                                     nullptr, 0, D3D11_SDK_VERSION, d.dev.put(),
                                     nullptr, d.ctx.put())))
            return false;
    com_ptr<IDXGIDevice> dxgi = d.dev.as<IDXGIDevice>();
    com_ptr<::IInspectable> insp;
    if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), insp.put())))
        return false;
    d.rtdev = insp.as<IDirect3DDevice>();
    return true;
}

static GraphicsCaptureItem ItemForWindow(HWND hwnd)
{
    auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
    GraphicsCaptureItem item{nullptr};
    check_hresult(interop->CreateForWindow(hwnd, guid_of<GraphicsCaptureItem>(),
                                           put_abi(item)));
    return item;
}

static com_ptr<ID3D11Texture2D> TexFromSurface(IDirect3DSurface const &surf)
{
    auto access = surf.as<::Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
    com_ptr<ID3D11Texture2D> tex;
    check_hresult(access->GetInterface(guid_of<ID3D11Texture2D>(), tex.put_void()));
    return tex;
}

// one capture channel = one window being captured
struct Chan {
    HWND hwnd;
    Direct3D11CaptureFramePool pool{nullptr};
    GraphicsCaptureSession session{nullptr};
    com_ptr<ID3D11Texture2D> staging;
    int w, h;
    std::vector<double> mapUs;   // per-frame copy+map+readback cost
    std::vector<double> arriveMs; // inter-arrival times
    LARGE_INTEGER lastArrive{};
    std::vector<DWORD> scratch;  // bench-mode readback target
    int sizeMismatch = 0;        // frames whose ContentSize != pool size
};

static void OpenChan(D3D &d, Chan &c, HWND hwnd, int w, int h)
{
    c.hwnd = hwnd; c.w = w; c.h = h;
    auto item = ItemForWindow(hwnd);
    c.pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
        d.rtdev, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, { w, h });
    c.session = c.pool.CreateCaptureSession(item);
    try { c.session.IsCursorCaptureEnabled(false); } catch (...) {}
    try {
        if (meta::ApiInformation::IsPropertyPresent(
                L"Windows.Graphics.Capture.GraphicsCaptureSession", L"IsBorderRequired"))
            c.session.IsBorderRequired(false);
    } catch (...) {}
    D3D11_TEXTURE2D_DESC sd{};
    sd.Width = w; sd.Height = h; sd.MipLevels = 1; sd.ArraySize = 1;
    sd.Format = DXGI_FORMAT_B8G8R8A8_UNORM; sd.SampleDesc.Count = 1;
    sd.Usage = D3D11_USAGE_STAGING; sd.CPUAccessFlags = D3D11_CPU_ACCESS_READ;
    check_hresult(d.dev->CreateTexture2D(&sd, nullptr, c.staging.put()));
    c.session.StartCapture();
}

// poll one frame; returns true if got one. Measures the FULL per-frame CPU price:
// CopyResource + Map + full-frame readback into system memory — that readback is what
// feeding the grant-based transport actually costs, so it is never skipped (review fix).
static bool PollFrame(D3D &d, Chan &c, std::vector<DWORD> *pixelsOut)
{
    auto frame = c.pool.TryGetNextFrame();
    if (!frame)
        return false;
    LARGE_INTEGER f, t0, t1;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&t0);
    if (c.lastArrive.QuadPart)
        c.arriveMs.push_back(1000.0 * (t0.QuadPart - c.lastArrive.QuadPart) / f.QuadPart);
    c.lastArrive = t0;

    // ContentSize vs pool-buffer mismatch turns the byte-compare into garbage; count it
    // instead of silently mis-judging (review fix)
    auto cs = frame.ContentSize();
    if (cs.Width != c.w || cs.Height != c.h)
        c.sizeMismatch++;

    auto tex = TexFromSurface(frame.Surface());
    d.ctx->CopyResource(c.staging.get(), tex.get());
    D3D11_MAPPED_SUBRESOURCE map{};
    check_hresult(d.ctx->Map(c.staging.get(), 0, D3D11_MAP_READ, 0, &map));
    std::vector<DWORD> *dst = pixelsOut ? pixelsOut : &c.scratch;
    dst->resize((size_t)c.w * c.h);
    for (int y = 0; y < c.h; y++)
        memcpy(dst->data() + (size_t)y * c.w,
               (BYTE *)map.pData + (size_t)y * map.RowPitch,
               (size_t)c.w * 4);
    d.ctx->Unmap(c.staging.get(), 0);
    QueryPerformanceCounter(&t1);
    c.mapUs.push_back(1e6 * (t1.QuadPart - t0.QuadPart) / f.QuadPart);
    return true;
}

static double Pct(std::vector<double> v, double p)
{
    if (v.empty()) return -1;
    std::sort(v.begin(), v.end());
    size_t i = (size_t)(p / 100.0 * (v.size() - 1) + 0.5);
    return v[i];
}

static double CpuSeconds()
{
    FILETIME c2, e, k, u;
    GetProcessTimes(GetCurrentProcess(), &c2, &e, &k, &u);
    auto f = [](FILETIME t) {
        return ((((ULONGLONG)t.dwHighDateTime) << 32) | t.dwLowDateTime) / 1e7;
    };
    return f(k) + f(u);
}

// ------------------------------------------------------------------ modes

static int ModeCheck()
{
    bool supported = GraphicsCaptureSession::IsSupported();
    bool dirtyApi = false, borderApi = false, cursorApi = false;
    try {
        dirtyApi = meta::ApiInformation::IsPropertyPresent(
            L"Windows.Graphics.Capture.Direct3D11CaptureFrame", L"DirtyRegions");
        borderApi = meta::ApiInformation::IsPropertyPresent(
            L"Windows.Graphics.Capture.GraphicsCaptureSession", L"IsBorderRequired");
        cursorApi = meta::ApiInformation::IsPropertyPresent(
            L"Windows.Graphics.Capture.GraphicsCaptureSession", L"IsCursorCaptureEnabled");
    } catch (...) {}
    printf("wgc-supported=%d dirty-regions-api=%d border-api=%d cursor-api=%d\n",
           supported, dirtyApi, borderApi, cursorApi);
    if (!supported) {
        printf("=== WGCPROBE JSON ===\n{\"supported\":false}\n");
        return 1;
    }

    // occluded-correctness: static pattern window A + cover B, capture A
    PatWin A; A.animate = false;
    MakePatWin(&A, 200, 200, L"wgcprobe-A");
    PumpFor(800);
    PatWin B; B.w = A.w + 120; B.h = A.h + 120; B.animate = false;
    // B paints the pattern too but phase-shifted content differences don't matter;
    // make it visually distinct by animating one phase bump
    MakePatWin(&B, 140, 140, L"wgcprobe-B");
    SetWindowPos(B.hwnd, HWND_TOP, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE);
    PumpFor(800);
    POINT ctr{ 200 + A.w / 2, 200 + A.h / 2 };
    bool occluded = GetAncestor(WindowFromPoint(ctr), GA_ROOT) == B.hwnd;

    D3D d;
    if (!MakeD3D(d)) {
        printf("d3d11-device=FAIL\n=== WGCPROBE JSON ===\n{\"supported\":true,\"d3d\":false}\n");
        return 1;
    }
    Chan c;
    OpenChan(d, c, A.hwnd, A.w, A.h);
    std::vector<DWORD> px;
    bool got = false;
    for (int i = 0; i < 300 && !got; i++) { // ~3 s budget for first frame
        got = PollFrame(d, c, &px);
        PumpFor(10);
    }
    double pct = -1;
    if (got) {
        size_t match = 0, total = (size_t)A.w * A.h;
        for (int y = 0; y < A.h; y++)
            for (int x = 0; x < A.w; x++)
                if ((px[(size_t)y * A.w + x] & 0xFFFFFF) == (PatternPixel(x, y, 0) & 0xFFFFFF))
                    match++;
        pct = 100.0 * match / total;
    }
    printf("occluded=%s first-frame=%d content-pct=%.1f size-mismatch=%d\n",
           occluded ? "YES" : "NO", got, pct, c.sizeMismatch);
    if (c.sizeMismatch)
        printf("WARNING: ContentSize != pool size on %d frame(s) — a MISMATCH verdict "
               "below is diagnostic of geometry, not of wrong pixels\n", c.sizeMismatch);
    const char *verdict = (got && pct >= 99.0) ? "MATCH" : "MISMATCH";
    printf("WGCPROBE-CHECK: occluded-content=%s\n", verdict);
    printf("=== WGCPROBE JSON ===\n");
    printf("{\"supported\":true,\"dirtyRegionsApi\":%s,\"borderApi\":%s,\"cursorApi\":%s,"
           "\"occluded\":%s,\"firstFrame\":%s,\"contentPct\":%.1f,\"verdict\":\"%s\"}\n",
           dirtyApi ? "true" : "false", borderApi ? "true" : "false",
           cursorApi ? "true" : "false", occluded ? "true" : "false",
           got ? "true" : "false", pct, verdict);
    DestroyWindow(B.hwnd);
    DestroyWindow(A.hwnd);
    return (got && occluded) ? 0 : 1;
}

// system-wide busy seconds (captures work done in dwm.exe etc., which
// GetProcessTimes on this process never sees — review fix; probe-only CPU is
// still reported separately so both are visible)
static double SysBusySeconds()
{
    FILETIME idle, kern, user;
    if (!GetSystemTimes(&idle, &kern, &user))
        return -1;
    auto f = [](FILETIME t) {
        return ((((ULONGLONG)t.dwHighDateTime) << 32) | t.dwLowDateTime) / 1e7;
    };
    // kernel time includes idle; busy = kernel - idle + user
    return f(kern) - f(idle) + f(user);
}

// bench: durationSec is ALWAYS a duration; animate only controls the scene.
// (review fix: previously <seconds> doubled as a per-window frame cap)
static int ModeBench(int K, int durationSec, int w, int h, bool animate, int tile)
{
    D3D d;
    if (!MakeD3D(d)) { printf("d3d11-device=FAIL\n"); return 1; }
    std::vector<PatWin> wins(K);
    for (int i = 0; i < K; i++) {
        wins[i].w = w; wins[i].h = h; wins[i].animate = animate;
        wins[i].tile = tile;
    }
    SceneThread st;
    st.wins = &wins;
    st.ready = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    st.thread = CreateThread(nullptr, 0, ScenePump, &st, 0, nullptr);
    WaitForSingleObject(st.ready, 10000);
    Sleep(1000); // let DWM compose the scene before measuring

    // Open as many capture channels as the system allows; a per-window failure is a
    // RESULT (the practical WGC session ceiling), not a crash. Failed channels are
    // reported and excluded.
    std::vector<Chan> chans(K);
    int opened = 0;
    HRESULT firstFail = S_OK;
    for (int i = 0; i < K; i++) {
        try {
            OpenChan(d, chans[i], wins[i].hwnd, w, h);
            opened++;
        } catch (hresult_error const &e) {
            if (firstFail == S_OK) firstFail = e.code();
            fprintf(stderr, "OpenChan[%d] failed: 0x%08X %ls\n", i,
                    (unsigned)e.code().value, e.message().c_str());
            chans.resize(i); // stop at first failure: ceiling reached
            break;
        }
    }
    if (opened == 0) {
        printf("no capture channel could be opened (first failure 0x%08X)\n",
               (unsigned)firstFail);
        printf("=== WGCPROBE JSON ===\n{\"mode\":\"bench\",\"k\":%d,\"opened\":0,"
               "\"firstFailHr\":\"0x%08X\"}\n", K, (unsigned)firstFail);
        st.quit.store(true);
        WaitForSingleObject(st.thread, 5000);
        return 1;
    }
    const int KEff = opened;

    double cpu0 = CpuSeconds(), sys0 = SysBusySeconds();
    LARGE_INTEGER f, t0, t1;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&t0);
    DWORD deadline = GetTickCount() + (DWORD)durationSec * 1000;
    for (;;) {
        bool any = false;
        for (int i = 0; i < KEff; i++)
            any = PollFrame(d, chans[i], nullptr) || any;
        if (!any)
            Sleep(1); // no frame pending anywhere; don't burn the core
        if ((LONG)(GetTickCount() - deadline) >= 0)
            break;
    }
    QueryPerformanceCounter(&t1);
    double wall = (double)(t1.QuadPart - t0.QuadPart) / f.QuadPart;
    double cpu = CpuSeconds() - cpu0;
    double sys = (sys0 >= 0) ? SysBusySeconds() - sys0 : -1;

    std::vector<double> allMap;
    size_t totFrames = 0;
    int mism = 0;
    double fpsMin = 1e9, fpsMax = 0;
    for (auto &c : chans) {
        totFrames += c.mapUs.size();
        mism += c.sizeMismatch;
        double fps = c.mapUs.size() / wall;
        fpsMin = std::min(fpsMin, fps);
        fpsMax = std::max(fpsMax, fps);
        allMap.insert(allMap.end(), c.mapUs.begin(), c.mapUs.end());
    }
    printf("K=%d opened=%d size=%dx%d animate=%d tile=%d frames=%zu wall=%.2fs "
           "procCpu=%.2fs sysBusy=%.2fs fps-agg=%.1f fps-min=%.1f fps-max=%.1f "
           "map-p50=%.0fus map-p95=%.0fus size-mismatch=%d\n",
           K, KEff, w, h, animate, tile, totFrames, wall, cpu, sys, totFrames / wall,
           fpsMin, fpsMax, Pct(allMap, 50), Pct(allMap, 95), mism);
    printf("=== WGCPROBE JSON ===\n");
    printf("{\"mode\":\"%s\",\"k\":%d,\"opened\":%d,\"w\":%d,\"h\":%d,\"tile\":%d,"
           "\"frames\":%zu,"
           "\"wallSec\":%.3f,\"procCpuSec\":%.3f,\"sysBusySec\":%.3f,\"fpsAgg\":%.1f,"
           "\"fpsMin\":%.1f,\"fpsMax\":%.1f,\"mapP50us\":%.0f,\"mapP95us\":%.0f,"
           "\"sizeMismatch\":%d}\n",
           animate ? "bench" : "benchstatic", K, KEff, w, h, tile, totFrames, wall,
           cpu, sys, totFrames / wall, fpsMin, fpsMax, Pct(allMap, 50),
           Pct(allMap, 95), mism);
    for (auto &c : chans) { c.session.Close(); c.pool.Close(); }
    st.quit.store(true);
    WaitForSingleObject(st.thread, 5000);
    CloseHandle(st.thread);
    CloseHandle(st.ready);
    return 0;
}

static int Dispatch(int argc, char **argv);

int main(int argc, char **argv)
{
    // stdout is a fully-buffered pipe under qrexec; a crash loses EVERYTHING buffered.
    // Unbuffer so partial output + the banner always reach the harness.
    setvbuf(stdout, nullptr, _IONBF, 0);
    try {
        return Dispatch(argc, argv);
    } catch (hresult_error const &e) {
        printf("FATAL hresult 0x%08X: %ls\n=== WGCPROBE JSON ===\n"
               "{\"fatalHr\":\"0x%08X\"}\n",
               (unsigned)e.code().value, e.message().c_str(),
               (unsigned)e.code().value);
        return 3;
    } catch (std::exception const &e) {
        printf("FATAL: %s\n=== WGCPROBE JSON ===\n{\"fatal\":true}\n", e.what());
        return 3;
    }
}

static int Dispatch(int argc, char **argv)
{
    SetProcessDPIAware();
    init_apartment(apartment_type::multi_threaded);
    OSVERSIONINFOEXW ver{}; ver.dwOSVersionInfoSize = sizeof(ver);
    // GetVersionEx is shimmed; RtlGetVersion tells the truth
    typedef LONG(WINAPI *RtlGetVersion_t)(OSVERSIONINFOEXW *);
    if (auto p = (RtlGetVersion_t)GetProcAddress(GetModuleHandleW(L"ntdll"),
                                                 "RtlGetVersion"))
        p(&ver);
    printf("wgcprobe 1.0 os=%lu.%lu.%lu\n", ver.dwMajorVersion, ver.dwMinorVersion,
           ver.dwBuildNumber);

    if (argc >= 2 && strcmp(argv[1], "check") == 0)
        return ModeCheck();
    if (argc >= 4 && (strcmp(argv[1], "bench") == 0 ||
                      strcmp(argv[1], "benchstatic") == 0)) {
        int K = atoi(argv[2]), secs = atoi(argv[3]);
        int w = (argc >= 6) ? atoi(argv[4]) : DEF_W;
        int h = (argc >= 6) ? atoi(argv[5]) : DEF_H;
        int tile = (argc >= 7) ? atoi(argv[6]) : 128;
        if (K < 1 || K > 64 || secs < 1 || secs > 120) { printf("bad args\n"); return 2; }
        return ModeBench(K, secs, w, h, strcmp(argv[1], "bench") == 0, tile);
    }
    printf("usage: wgcprobe check | bench <K> <seconds> [w h [tile]] | "
           "benchstatic <K> <seconds> [w h [tile]]\n"
           "  tile: per-tick invalidation size, 0 = whole window (default 128)\n");
    return 2;
}
