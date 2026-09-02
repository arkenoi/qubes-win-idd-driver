// wgcbroker.exe - user-session Windows.Graphics.Capture broker for QWT gui-agent.
// Runs as the interactive user (spawned by the SYSTEM agent via SpawnHelperAsUser). Captures
// exactly the HWNDs the SYSTEM agent lists in the shared control block; publishes each window's
// BGRA frame into the section's pixel arena via a per-slot seqlock. Exits when the agent dies,
// the section says Shutdown, the console session changes, the launcher pid stops owning the
// section, or the agent heartbeat stalls. Build: mirror tools/wgcprobe (v143, /MT, stdcpp17,
// windowsapp.lib, no WDK/nuget).
//
// SCOPE (adversary): the broker exists for OCCLUDED app/NRB windows where the composited slice
// bleeds the occluder. Topmost surfaces (toasts, o-r menus) stay on the slice - the agent does
// not register them. The broker just captures whatever HWNDs the agent asks for.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <d3d11.h>
#include <dxgi.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include "../../agent/gui-agent/wgcbroker_ipc.h"
#include <intrin.h>
#include <vector>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "kernel32.lib")
#pragma comment(lib, "windowsapp.lib")

using namespace winrt;
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
using namespace winrt::Windows::Graphics::DirectX::Direct3D11;

static BYTE*             g_base = nullptr;
static WGCBRK_HEADER*    g_hdr  = nullptr;
static WGCBRK_SLOT*      g_slots= nullptr;
static HANDLE            g_hCtl = nullptr;
static HANDLE            g_agent= nullptr;
static DWORD             g_mySession = 0;
static DWORD             g_launcherPid = 0;
static com_ptr<ID3D11Device>        g_d3d;
static com_ptr<ID3D11DeviceContext> g_ctx;
static IDirect3DDevice              g_rtDev{ nullptr };
static CRITICAL_SECTION  g_pubCs[WGCBRK_MAX_SLOTS];   // adversary (a): serialize publish/teardown per slot

struct Channel {
    HWND                          hwnd = nullptr;
    GraphicsCaptureItem           item{ nullptr };
    Direct3D11CaptureFramePool    pool{ nullptr };
    GraphicsCaptureSession        session{ nullptr };
    Direct3D11CaptureFramePool::FrameArrived_revoker rev;
    int slot = -1;
};
static std::vector<Channel> g_ch(WGCBRK_MAX_SLOTS);

static bool InitD3D() {
    D3D_FEATURE_LEVEL fl;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
        g_d3d.put(), &fl, g_ctx.put());
    if (FAILED(hr)) return false;
    com_ptr<IDXGIDevice> dxgi = g_d3d.as<IDXGIDevice>();
    com_ptr<::IInspectable> insp;
    if (FAILED(CreateDirect3D11DeviceFromDXGIDevice(dxgi.get(), insp.put()))) return false;
    g_rtDev = insp.as<IDirect3DDevice>();
    return true;
}

static bool WgcSupported() {
    try { return GraphicsCaptureSession::IsSupported(); }
    catch (...) { return false; }   // 0x80070424 here == not a real user session
}

static bool InputDesktopIsDefault() {
    HDESK d = OpenInputDesktop(0, FALSE, DESKTOP_READOBJECTS);
    if (!d) return false;           // Winlogon owns input == secure desktop
    WCHAR name[64] = {0}; DWORD need = 0;
    BOOL ok = GetUserObjectInformationW(d, UOI_NAME, name, sizeof(name), &need);
    CloseDesktop(d);
    return ok && _wcsicmp(name, L"Default") == 0;
}

// publish one WGC frame into slot i (per-slot CS + seqlock + double buffer)
static void PublishFrame(int i, Direct3D11CaptureFrame const& frame) {
    EnterCriticalSection(&g_pubCs[i]);
    do {
        WGCBRK_SLOT* s = &g_slots[i];
        if (s->ReqState != WGCBRK_REQUESTED && s->AckState != WGCBRK_ACTIVE) break;
        if (!g_hdr->Producing) break;   // secure desktop: frame arrives, do not publish

        auto surf = frame.Surface();
        auto access = surf.as<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
        com_ptr<ID3D11Texture2D> tex;
        if (FAILED(access->GetInterface(guid_of<ID3D11Texture2D>(), tex.put_void()))) break;
        D3D11_TEXTURE2D_DESC td; tex->GetDesc(&td);
        int w = (int)td.Width, h = (int)td.Height;
        if (w <= 0 || h <= 0) break;
        if ((LONGLONG)w * h * 4 > s->BufBytes) break;   // agent sized for ReqW*ReqH*4; skip oversize

        td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0;
        td.CPUAccessFlags = D3D11_CPU_ACCESS_READ; td.MiscFlags = 0;
        com_ptr<ID3D11Texture2D> stg;
        if (FAILED(g_d3d->CreateTexture2D(&td, nullptr, stg.put()))) break;
        g_ctx->CopyResource(stg.get(), tex.get());
        D3D11_MAPPED_SUBRESOURCE map;
        if (FAILED(g_ctx->Map(stg.get(), 0, D3D11_MAP_READ, 0, &map))) break;

        int wbuf = 1 - s->ActiveBuffer;             // spare (RING==2)
        if (wbuf < 0 || wbuf >= WGCBRK_RING) wbuf = 0;
        BYTE* dst = WGCBRK_ARENA(g_base, s->BufOffset[wbuf]);
        const BYTE* src = (const BYTE*)map.pData;
        for (int y = 0; y < h; y++)
            memcpy(dst + (size_t)y * w * 4, src + (size_t)y * map.RowPitch, (size_t)w * 4);
        g_ctx->Unmap(stg.get(), 0);

        s->FrameWidth = w; s->FrameHeight = h; s->Stride = w * 4;
        LONG q = s->Seq;                            // even
        _InterlockedExchange(&s->Seq, q | 1);       // -> ODD: write in progress
        MemoryBarrier();
        s->ActiveBuffer = wbuf;
        s->FrameId++;
        s->CaptureTick = (LONGLONG)GetTickCount64();
        MemoryBarrier();
        _InterlockedExchange(&s->Seq, (q | 1) + 1); // -> next EVEN: complete
        s->AckState = WGCBRK_ACTIVE;
    } while (0);
    LeaveCriticalSection(&g_pubCs[i]);
}

static void OpenChannel(int i) {
    WGCBRK_SLOT* s = &g_slots[i];
    Channel& c = g_ch[i];
    HWND hwnd = (HWND)(ULONG_PTR)s->Hwnd;
    if (!hwnd || !IsWindow(hwnd)) { s->AckState = WGCBRK_FAILED; s->FailHr = E_HANDLE; return; }
    try {
        auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
        GraphicsCaptureItem item{ nullptr };
        check_hresult(interop->CreateForWindow(hwnd, guid_of<GraphicsCaptureItem>(),
                      reinterpret_cast<void**>(put_abi(item))));
        auto size = item.Size();
        auto pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
            g_rtDev, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
        auto session = pool.CreateCaptureSession(item);
        try { session.IsCursorCaptureEnabled(false); } catch (...) {}
        try { session.IsBorderRequired(false); } catch (...) {}   // borderDisableOk proven on 26100
        c.hwnd = hwnd; c.item = item; c.pool = pool; c.session = session; c.slot = i;
        c.rev = pool.FrameArrived(auto_revoke,
            [i](Direct3D11CaptureFramePool const& sender, auto const&) {
                auto f = sender.TryGetNextFrame();
                if (!f) return;
                auto cs = f.ContentSize();
                WGCBRK_SLOT* sl = &g_slots[i];
                if (cs.Width != sl->ReqWidth || cs.Height != sl->ReqHeight) {
                    try { g_ch[i].pool.Recreate(g_rtDev,
                            DirectXPixelFormat::B8G8R8A8UIntNormalized, 2,
                            { sl->ReqWidth, sl->ReqHeight }); } catch (...) {}
                    return;
                }
                PublishFrame(i, f);
            });
        session.StartCapture();
        s->AckState = WGCBRK_ACTIVE; s->FailHr = 0;
    } catch (hresult_error const& e) {
        s->AckState = WGCBRK_FAILED; s->FailHr = e.code();
    } catch (...) {
        s->AckState = WGCBRK_FAILED; s->FailHr = E_FAIL;
    }
}

static void CloseChannel(int i) {
    EnterCriticalSection(&g_pubCs[i]);          // serialize with any in-flight PublishFrame
    Channel& c = g_ch[i];
    c.rev.revoke();
    if (c.session) { try { c.session.Close(); } catch (...) {} }
    if (c.pool)    { try { c.pool.Close();    } catch (...) {} }
    c = Channel{};
    g_slots[i].AckState = WGCBRK_FREE;
    LeaveCriticalSection(&g_pubCs[i]);
}

static void Reconcile() {
    for (int i = 0; i < WGCBRK_MAX_SLOTS; i++) {
        WGCBRK_SLOT* s = &g_slots[i];
        HWND want = (HWND)(ULONG_PTR)s->Hwnd;
        bool wantOpen = (s->ReqState == WGCBRK_REQUESTED) && want;
        Channel& c = g_ch[i];
        if (wantOpen && c.hwnd != want) { if (c.hwnd) CloseChannel(i); OpenChannel(i); }
        else if (!wantOpen && c.hwnd)   { CloseChannel(i); }
    }
}

static const wchar_t* ArgVal(int argc, wchar_t** argv, const wchar_t* key) {
    for (int i = 1; i + 1 < argc; i++) if (_wcsicmp(argv[i], key) == 0) return argv[i + 1];
    return nullptr;
}

int wmain(int argc, wchar_t** argv) {
    HANDLE mtx = CreateMutexW(nullptr, FALSE, L"Global\\QubesWgcBrokerSingleton");
    if (mtx) { DWORD w = WaitForSingleObject(mtx, 0);
        if (w != WAIT_OBJECT_0 && w != WAIT_ABANDONED) return 0; }
    ProcessIdToSessionId(GetCurrentProcessId(), &g_mySession);
    for (int i = 0; i < WGCBRK_MAX_SLOTS; i++) InitializeCriticalSection(&g_pubCs[i]);

    const wchar_t* shmName = ArgVal(argc, argv, L"--shm");
    const wchar_t* ctlName = ArgVal(argc, argv, L"--ctl");
    const wchar_t* pidStr  = ArgVal(argc, argv, L"--agent-pid");
    if (!shmName || !ctlName || !pidStr) return 1;
    g_launcherPid = (DWORD)_wtoi64(pidStr);
    g_agent = g_launcherPid ? OpenProcess(SYNCHRONIZE, FALSE, g_launcherPid) : nullptr;

    init_apartment(apartment_type::multi_threaded);
    if (!WgcSupported()) return 2;
    if (!InitD3D())      return 3;

    HANDLE hMap = OpenFileMappingW(FILE_MAP_READ | FILE_MAP_WRITE, FALSE, shmName);
    if (!hMap) return 4;
    g_base = (BYTE*)MapViewOfFile(hMap, FILE_MAP_READ | FILE_MAP_WRITE, 0, 0, 0);
    if (!g_base) return 5;
    g_hdr = WGCBRK_HDR(g_base); g_slots = WGCBRK_SLOTS(g_base);
    for (int spin = 0; spin < 200; spin++) {
        if (g_hdr->Magic == (LONG)WGCBRK_MAGIC && g_hdr->AbiVersion == (LONG)WGCBRK_ABI_VERSION) break;
        Sleep(10);
    }
    if (g_hdr->Magic != (LONG)WGCBRK_MAGIC || g_hdr->AbiVersion != (LONG)WGCBRK_ABI_VERSION) return 6;
    // adversary (c): a stale broker must not serve a newer agent's section.
    if (g_hdr->AgentPid && (DWORD)g_hdr->AgentPid != g_launcherPid) return 7;
    g_hdr->BrokerPid = (LONG)GetCurrentProcessId();
    g_hCtl = OpenEventW(EVENT_MODIFY_STATE | SYNCHRONIZE, FALSE, ctlName);

    for (;;) {
        if (g_hdr->Shutdown) break;
        if (g_hdr->AgentPid && (DWORD)g_hdr->AgentPid != g_launcherPid) break;
        if (g_agent && WaitForSingleObject(g_agent, 0) == WAIT_OBJECT_0) break;
        if (WTSGetActiveConsoleSessionId() != g_mySession) break;
        // Agent-liveness: the process-death wait (g_agent) below is primary and instant; this
        // heartbeat is a generous backstop for a HUNG (not exited) agent. The agent bumps it
        // ~1/s (it caps its idle wait while the broker is active), so 10 s is safe headroom.
        if ((GetTickCount64() - (ULONGLONG)g_hdr->AgentHeartbeat) > 10000) break;

        g_hdr->Producing = InputDesktopIsDefault() ? 1 : 0;
        g_hdr->BrokerHeartbeat = (LONGLONG)GetTickCount64();

        HANDLE waits[2] = { g_hCtl, g_agent };
        DWORD n = 0; HANDLE compact[2];
        if (g_hCtl) compact[n++] = g_hCtl;
        if (g_agent) compact[n++] = g_agent;
        if (n == 0) { Sleep(250); }
        else {
            DWORD wr = WaitForMultipleObjects(n, compact, FALSE, 250);
            if (g_agent && wr == WAIT_OBJECT_0 + (g_hCtl ? 1 : 0)) break; // agent exited
        }
        Reconcile();
    }
    for (int i = 0; i < WGCBRK_MAX_SLOTS; i++) if (g_ch[i].hwnd) CloseChannel(i);
    return 0;
}
