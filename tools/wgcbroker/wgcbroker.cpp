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
#include <d3d11_4.h>   // ID3D11Multithread (see InitD3D)
#include <dxgi.h>
#include <dwmapi.h>
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <set>
#include "../../agent/gui-agent/wgcbroker_ipc.h"

// ABI 12 frame signature - defined further down (it needs g_slots), used by the WGC publish path
// above that definition. Declared here so the call site compiles.
static void PublishSignature(int i, const BYTE* buf, int w, int h);
#include <intrin.h>
#include <vector>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "kernel32.lib")
#pragma comment(lib, "windowsapp.lib")

#ifndef PW_RENDERFULLCONTENT
#define PW_RENDERFULLCONTENT 0x00000002
#endif

using namespace winrt;
using namespace winrt::Windows::Graphics::Capture;
using namespace winrt::Windows::Graphics::DirectX;
using namespace winrt::Windows::Graphics::DirectX::Direct3D11;

static BYTE*             g_base = nullptr;
static WGCBRK_HEADER*    g_hdr  = nullptr;
static WGCBRK_SLOT*      g_slots= nullptr;
static HANDLE            g_hCtl = nullptr;
static HANDLE            g_hFrame = nullptr;   // agent wake: a frame was published (auto-reset)

// Tell the agent a frame is ready. Without this the agent only noticed a published frame on its
// next DESKTOP-capture pass, and a redundant desktop frame skipped that walk entirely - so a
// painted window could sit unnoticed on a static desktop. Signal AFTER the sequence bump so the
// agent that wakes always sees the finished frame.
static inline void SignalFramePublished() { if (g_hFrame) SetEvent(g_hFrame); }
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
    GraphicsCaptureItem::Closed_revoker closedRev;   // ABI 16: see ItemClosed in wgcbroker_ipc.h
    int slot = -1;
    // PrintWindow fallback: WGC CreateForWindow rejects override-redirect menus/popups
    // (itemCreated fails), but PrintWindow(PW_RENDERFULLCONTENT) captures them from THIS user
    // session (proven). When WGC fails, the channel switches to a polled PrintWindow into a
    // top-down 32bpp DIB, published through the same seqlock. True-black results (CoreWindows,
    // NRB/ULW) fail the non-black check and fall back to the agent's slice.
    bool    pw     = false;   // this channel is PrintWindow-polled, not WGC
    HDC     pwDC   = nullptr;  // memory DC holding pwBmp
    HBITMAP pwBmp  = nullptr;  // top-down 32bpp DIB section (BGRX)
    void*   pwBits = nullptr;  // pixels of pwBmp
    int     pwW = 0, pwH = 0;  // current DIB dimensions
    // WGC pool size, tracked so FrameArrived can follow the window's CONTENT size instead of
    // the agent's requested (possibly CROPPED) size - see the FrameArrived comment.
    int     poolW = 0, poolH = 0;
    // Last PrintWindow render, for the staleness bound on the damage-driven path.
    ULONGLONG pwLastTick = 0;
    // Last time this WGC channel was re-checked for a cross-process content child.
    ULONGLONG xprocTick = 0;
    // Current adaptive interval between PrintWindow renders, grown while renders change nothing.
    ULONGLONG pwBackoffMs = 0;
    // BEHAVIOURAL DETECTION. When this WGC channel opened, and when it last delivered a frame.
    // A visible window whose feed has been silent since it opened is one WGC is not serving.
    ULONGLONG openTick = 0;
    ULONGLONG lastArrivalTick = 0;
    bool      probing = false;   // this PrintWindow channel is a TEST, not yet a commitment
    // ABI 10: the source-change test used before demoting a RELAY. A hash of the SOURCE window's
    // own pixels at the moment of the last demotion question, plus when it was taken, so the test
    // is throttled rather than run on every loop tick.
    unsigned long long srcHash     = 0;
    ULONGLONG          srcHashTick = 0;
    bool               srcHashSeen = false;
    // ADAPTIVE INTERVAL between source-change tests, same philosophy as the PrintWindow backoff
    // below and for the same reason. The demotion question is asked on EVERY loop tick once a
    // channel is quiet, so a fixed short throttle would run PrintWindow several times a second per
    // static window - at a measured p50 of 31-49 ms on the target's own UI thread that is worse
    // than the polled fallback this work exists to remove. Unchanged doubles it to the ceiling;
    // a change resets it, so detection stays prompt exactly when something is happening.
    ULONG              srcHashMs   = 500;
    // CONSECUTIVE measured source changes with no frame in between. A SINGLE change must not demote:
    // measured 2026-09-26 on win11de-led4, the one class that still fell back did so on
    // srcChanged=1 pwFail=0 - one differing render, permanently onto the polled path, while the
    // control (demotion disabled) held every class on an arrival-driven route. The founding symptom
    // this detector exists for was FramesArrived frozen at 3 while a control ran 637->678 over 23 s,
    // i.e. damage repeatedly with NO frames at all - not one sample. Jev:
    // require-repeated-changes-with-no-frames 0.93. Reset by any arriving frame and by any measured
    // SAME, so the streak only ever counts an unbroken run of "the source moved and nothing came".
    int                srcChangeStreak = 0;
    // ---- THE DWM-THUMBNAIL RELAY (ABI 8) ----------------------------------------------------
    // A window whose own surface is empty has nothing for WGC to capture, and PrintWindow is a PULL
    // api, so a slot that falls back to it has no arrival event and must be driven by an invented
    // clock. DWM will draw a live copy of ANY window it composites into a destination window we
    // own; capturing THAT destination is arrival-driven again. Measured with tools/thumbprobe on
    // win11de-led (German 25H2), 11/11 rogue windows at oneToOne=1, including the toast
    // (Windows.UI.Core.CoreWindow) that CreateForWindow refuses outright.
    //
    // The destination is WS_EX_LAYERED at alpha 0, NOT off-screen: both composite, but off-screen
    // returned alphaZero=511/2640 where alpha-0 and on-screen both returned a uniform 255.
    // PokeSeq as it stood when this channel last delivered a frame. The difference against the live
    // PokeSeq is "damage the agent saw since our last frame" - the only thing that separates an IDLE
    // arrival-driven channel from a BROKEN one. Without it the quiet detector demoted channels that
    // had delivered thousands of frames and simply gone quiet (measured: 2934 on one slot), and
    // demoting idle to polled is backwards on cost (Jev 0.84).
    LONG        pokeAtLastArrival = 0;
    HWND        relayDest  = nullptr;   // the window we own that carries the thumbnail
    HTHUMBNAIL  relayThumb = nullptr;
    bool        relay      = false;     // this channel captures relayDest, not c.hwnd
    // ---- THE LAST FULL-WINDOW CAPTURE, KEPT FOR REPUBLISHING --------------------------------
    // WGC and the relay publish only inside FrameArrived, and a static window sends no arrival.
    // Every agent (re-)registration or retarget writes a new card geometry, fresh buffers and a
    // reset Seq/Ack, and bumps ControlSeq - so a static window whose card moved was never served
    // again. Measured 2026-09-27 on win11de-v5, three cold boots: the toast host re-registered at
    // 364x157 crop 16,199 after a second toast grew it, and the slot sat at ack=0 seq=0 with the
    // old 364x326 frame for the rest of the census while the agent rejected every frame (Jev:
    // product defect 0.99, mechanism 0.91, this fix over a session re-open 1.00 - a fresh session
    // is exactly what goes deaf after a cold boot). lastFull is the CPU copy PublishFrame already
    // makes of each arrival; pubCtlSeq is the slot's ControlSeq when a frame was last published
    // from it. Both are touched only under g_pubCs[i], which CloseChannel holds across the wipe.
    com_ptr<ID3D11Texture2D> lastFull;
    int         lastFullW = 0, lastFullH = 0;
    LONG        pubCtlSeq = 0;
    // The ControlSeq a republish from THIS lastFull already failed for (the card does not fit it, or the
    // copy failed): not retried until the agent asks again or a new arrival replaces lastFull, so a card
    // that cannot be cut costs one attempt, not an attempt per loop pass.
    LONG        triedCtlSeq = 0;
    bool        triedValid  = false;
};
static std::vector<Channel> g_ch(WGCBRK_MAX_SLOTS);
// These two MUST outlive a channel. CloseChannel does `c = Channel{}`, so anything kept in the
// Channel is erased by the very close that precedes a re-open - measured 2026-09-25: forcePw was
// set, then wiped by CloseChannel, so the re-route reopened on WGC and did nothing, the probe
// never ran (probeBounces stayed 0) and the hysteresis never applied, leaving an idle window's
// channel closed and reopened every quiet period for ever - 38 times on a window whose feed was
// perfectly healthy. Per-slot, not per-channel.
static bool      g_forcePw[WGCBRK_MAX_SLOTS]      = {};
static ULONGLONG g_noProbeUntil[WGCBRK_MAX_SLOTS] = {};
// A RELAY THAT WENT QUIET MUST BE ABLE TO REACH PRINTWINDOW. The quiet re-route sets g_forcePw and
// reopens, but g_forcePw only means "do not try WGC on the window itself" - the reopen then chose the
// RELAY again, so a relay delivering nothing looped back onto itself for ever and the polled fallback
// was unreachable. This veto is what lets the ladder finish: WGC -> relay -> PrintWindow.
// Set AFTER CloseChannel, never before: CloseChannel wipes the Channel, which is exactly how the
// earlier g_forcePw assignment got erased and cost 38 needless re-routes on a healthy window.
static bool      g_noRelay[WGCBRK_MAX_SLOTS] = {};
// ONE FRESH SESSION BEFORE THE LADDER DROPS A RELAY (2026-09-27). After a cold boot, with the full
// window set and an all-window PrintWindow sweep, a relay's OWN capture session stops delivering while
// DWM keeps compositing its destination - measured: a fresh session on that destination captures the
// source every second, restarting the broker cures it, and the capture item is never Closed. Demoting
// such a relay to PrintWindow (the old and only answer) fails the arrival-driven acceptance bar, so the
// first "source changed, no frame" on a relay RE-OPENS it as a relay instead - new destination,
// thumbnail, pool and session through the ordinary Close/OpenChannel path. Once per window: set here,
// cleared when the slot is given a different window; after it, the 3-change demotion applies as before.
static bool      g_relayReopened[WGCBRK_MAX_SLOTS] = {};
// THE SAME, ONE RUNG HIGHER (2026-09-27). A cold boot makes the broker's FIRST sessions deaf, plain-WGC
// ones included, and the ladder then moved a quiet plain-WGC window down to the relay for good. For a
// shell toast that is the wrong rung: warm, the toast is served on plain WGC and matches (MAD 2.2); on
// every cold boot it ended on the relay, whose thumbnail renders it with 15 colours against the guest's
// 28 (MAD 17.7), every time. So a quiet plain-WGC channel gets ONE fresh plain-WGC session before it is
// re-routed; windows plain WGC never serves (the rogue classes) lose one quiet period on the way to the
// relay. Jev: relay-renders-the-toast-unfaithfully 0.83, this fix 0.85, low risk 0.71.
static bool      g_wgcReopened[WGCBRK_MAX_SLOTS] = {};

// RAII for g_pubCs. Both long regions below call C++/WinRT methods that THROW - frame.Surface() on a
// closed frame is the obvious one - while sitting between a bare Enter and a bare Leave. A throw
// there leaves the section owned by a WGC threadpool thread for ever, and the main loop blocks on it
// at the next Reconcile: a hang, not a crash, with no log line. The review flagged it as collateral
// on the teardown race it was verifying rather than as its own finding, which is exactly the kind of
// thing that never gets its own commit.
struct PubLock {
    int i;
    explicit PubLock(int idx) : i(idx) { EnterCriticalSection(&g_pubCs[i]); }
    ~PubLock() { LeaveCriticalSection(&g_pubCs[i]); }
    PubLock(const PubLock&) = delete;
    PubLock& operator=(const PubLock&) = delete;
};
static bool g_anyPw = false;   // any PrintWindow channel active -> poll the loop faster
// LATCHED AT STARTUP, never re-read. Capabilities are decided at START here: a runtime re-read that
// failed transiently would silently downgrade an eligible guest, which is the forbidden silent
// fallback arriving by the back door.
static bool g_RelayOn = false;
static DWORD g_RelayBuild = 0;   // the build the decision was made from, published for the record

// ---- THE RELAY ------------------------------------------------------------------------------
// Give a window whose own surface WGC cannot capture a per-window source anyway: let DWM draw a live
// copy of it into a destination window we own, and capture THAT. Returns the destination, or null.
//
// Destination properties are not arbitrary - each was measured with tools/thumbprobe:
//   * WS_EX_LAYERED at alpha 0. It must be a real top-level window DWM composites; SW_HIDE yields
//     nothing at all. Off-screen also works but returned alphaZero=511/2640 where alpha-0 returned a
//     uniform 255, so alpha-0 is the one that hands the agent fully blended pixels.
//   * sized to DwmQueryThumbnailSourceSize, not to the source's window rect. Sizing it to the window
//     rect made the content land 1:1 inside a larger surface and misreported as scaled.
//   * WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE so it never takes focus or appears in the taskbar, and
//     WS_EX_TRANSPARENT so it cannot swallow a click meant for what is underneath.
// The agent refuses to MAP any window owned by this process (ShouldAcceptWindow, keyed on the
// validated broker pid), which is what keeps these destinations out of dom0.
static HWND RelayOpenDest(HWND src, HTHUMBNAIL* outThumb, int* outW, int* outH)
{
    static bool reg = false;
    if (!reg) {
        WNDCLASSEXW wc{}; wc.cbSize = sizeof(wc); wc.lpfnWndProc = DefWindowProcW;
        wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = L"QubesWgcRelayDest";
        wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
        RegisterClassExW(&wc); reg = true;
    }
    if (!src || !IsWindow(src)) return nullptr;
    // The source size is only knowable from a registration, so a scratch destination is registered
    // purely to ask, then thrown away. Cheap, and it removes the sizing guess.
    RECT sr{}; if (!GetWindowRect(src, &sr)) return nullptr;
    int w = sr.right - sr.left, h = sr.bottom - sr.top;
    if (w < 8 || h < 8) return nullptr;
    HWND probe = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE,
                                 L"QubesWgcRelayDest", L"", WS_POPUP, 0, 0, 16, 16,
                                 nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (probe) {
        HTHUMBNAIL t0 = nullptr;
        if (SUCCEEDED(DwmRegisterThumbnail(probe, src, &t0)) && t0) {
            SIZE q{};
            if (SUCCEEDED(DwmQueryThumbnailSourceSize(t0, &q)) && q.cx > 0 && q.cy > 0) { w = q.cx; h = q.cy; }
            DwmUnregisterThumbnail(t0);
        }
        DestroyWindow(probe);
    }
    HWND dest = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT,
                                L"QubesWgcRelayDest", L"", WS_POPUP, 0, 0, w, h,
                                nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!dest) return nullptr;
    SetLayeredWindowAttributes(dest, 0, 0, LWA_ALPHA);   // invisible to a human, still composited
    ShowWindow(dest, SW_SHOWNA);
    HTHUMBNAIL th = nullptr;
    if (FAILED(DwmRegisterThumbnail(dest, src, &th)) || !th) { DestroyWindow(dest); return nullptr; }
    DWM_THUMBNAIL_PROPERTIES p{};
    p.dwFlags = DWM_TNP_RECTDESTINATION | DWM_TNP_VISIBLE | DWM_TNP_OPACITY;
    p.rcDestination = RECT{ 0, 0, w, h };
    p.fVisible = TRUE; p.opacity = 255;
    if (FAILED(DwmUpdateThumbnailProperties(th, &p))) {
        DwmUnregisterThumbnail(th); DestroyWindow(dest); return nullptr;
    }
    *outThumb = th; *outW = w; *outH = h;
    return dest;
}

static void RelayCloseDest(Channel& c)
{
    if (c.relayThumb) { DwmUnregisterThumbnail(c.relayThumb); c.relayThumb = nullptr; }
    if (c.relayDest)  { DestroyWindow(c.relayDest);           c.relayDest  = nullptr; }
    c.relay = false;
}

static bool InitD3D() {
    D3D_FEATURE_LEVEL fl;
    HRESULT hr = D3D11CreateDevice(nullptr, D3D_DRIVER_TYPE_WARP, nullptr,
        D3D11_CREATE_DEVICE_BGRA_SUPPORT, nullptr, 0, D3D11_SDK_VERSION,
        g_d3d.put(), &fl, g_ctx.put());
    if (FAILED(hr)) return false;
    // ONE immediate context, several threads. PublishFrame runs on WGC threadpool threads - one
    // FrameArrived per slot, and free-threaded pools deliver different slots concurrently - under a
    // PER-SLOT lock, so two slots could already run CopyResource/Map on g_ctx at once; and
    // RepublishRetained now maps from the main loop too. ID3D11DeviceContext is not thread-safe by
    // itself; this serialises every call on it inside the runtime.
    if (auto mt = g_ctx.try_as<ID3D11Multithread>()) mt->SetMultithreadProtected(TRUE);
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
// First-frame stage ticks are QPC (ABI 5): the components they separate are 16-31 ms and
// GetTickCount64's step is ~15.6 ms, so on that clock the split was quantisation noise. Only the
// six stage ticks move; heartbeats and CaptureTick stay on GetTickCount64, which they are
// compared against elsewhere.
static inline LONGLONG QpcNow() {
    LARGE_INTEGER q; QueryPerformanceCounter(&q); return q.QuadPart;
}

// The gate every arrival-driven publish passes, the retained-capture republish included.
static bool PublishAllowed(WGCBRK_SLOT* s) {
    if (s->ReqState != WGCBRK_REQUESTED && s->AckState != WGCBRK_ACTIVE) return false;
    // LIVE check, not the cached flag. g_hdr->Producing is sampled once per main-loop
    // iteration, and that loop waits up to 250 ms - but FrameArrived is asynchronous, so a
    // frame that arrives after the input desktop has left Default (UAC consent, the lock
    // screen, the secure desktop) would still be published against a flag that is up to a
    // quarter second stale. The whole point of the gate is that secure-desktop pixels never
    // leave the guest, so it must be evaluated NOW, at the moment of publishing.
    return g_hdr->Producing && InputDesktopIsDefault();
}

// Crop the agent's CURRENT card out of a CPU-readable full-window copy and publish it into slot i.
// Caller holds g_pubCs[i] and has passed PublishAllowed. Returns true if a frame was published.
static bool PublishCard(int i, ID3D11Texture2D* full, int texW, int texH) {
    WGCBRK_SLOT* s = &g_slots[i];
    // ControlSeq is read BEFORE the geometry. The agent writes the geometry and buffers, fences, then
    // bumps ControlSeq, so what is read below is at least as new as `ctl`; a registration landing
    // mid-copy is caught by the re-check after the copy.
    const LONG ctl = s->ControlSeq;
    MemoryBarrier();
    // The slot must still be THIS channel's window: a registration for another window re-points
    // BufOffset before Reconcile has closed this channel, and those are that window's buffers.
    if ((HWND)(ULONG_PTR)s->Hwnd != g_ch[i].hwnd) return false;
    // Publish the agent's REQUESTED (card) rect, lifted from the full-window capture at the
    // agent's crop offset - exactly what the PrintWindow path does. Before this the WGC path
    // published the whole texture and FrameArrived dropped every frame whose ContentSize did
    // not equal ReqWidth/ReqHeight, so a WGC-capturable window with a nonzero crop (a shell
    // toast/menu whose shadow margin the agent trims) could NEVER publish: pool recreate,
    // drop, repeat. That was survivable only because the agent silently sliced the
    // whole-desktop composite instead; with the composite fallback removed on eligible
    // guests (owner 2026-09-06, "no fallback ... fail hard") it would freeze the window for
    // ever, so the crop is implemented here rather than worked around there.
    const int w = s->ReqWidth, h = s->ReqHeight;
    const int cropX = s->ReqCropX, cropY = s->ReqCropY;
    if (w <= 0 || h <= 0 || cropX < 0 || cropY < 0) return false;
    if (cropX + w > texW || cropY + h > texH) return false;   // capture does not cover the card yet
    if ((LONGLONG)w * h * 4 > s->BufBytes) return false;      // agent sized for ReqW*ReqH*4; skip oversize

    D3D11_MAPPED_SUBRESOURCE map;
    if (FAILED(g_ctx->Map(full, 0, D3D11_MAP_READ, 0, &map))) return false;
    int wbuf = 1 - s->ActiveBuffer;             // spare (RING==2)
    if (wbuf < 0 || wbuf >= WGCBRK_RING) wbuf = 0;
    BYTE* dst = WGCBRK_ARENA(g_base, s->BufOffset[wbuf]);
    const BYTE* src = (const BYTE*)map.pData + (size_t)cropY * map.RowPitch + (size_t)cropX * 4;
    for (int y = 0; y < h; y++)
        memcpy(dst + (size_t)y * w * 4, src + (size_t)y * map.RowPitch, (size_t)w * 4);
    g_ctx->Unmap(full, 0);
    MemoryBarrier();
    // A registration during the copy may have moved the card or the buffers: this frame answers a
    // request that no longer exists. Drop it UNPUBLISHED (Seq untouched, so the agent never sees
    // it); ControlSeq now differs from pubCtlSeq, so the main loop serves the new one next pass.
    if (s->ControlSeq != ctl) return false;
    PublishSignature(i, dst, w, h);

    // THE SEQLOCK, COMPARE-AND-SWAPPED. An agent registration resets Seq to 0 with plain stores; the
    // blind exchanges this used to do overwrote such a reset and advertised a frame in buffers this
    // copy never wrote. With CAS, a reset that lands anywhere in here makes the matching CAS fail and
    // the frame is simply not published (the main loop serves the new registration next pass).
    // FrameWidth/Height/Stride are written INSIDE the odd window: they used to be written before it,
    // where a reader could pair the new size with the previous buffer.
    const LONG q = s->Seq;                      // even: one writer per slot, under g_pubCs[i]
    if ((q & 1) || _InterlockedCompareExchange(&s->Seq, q | 1, q) != q) return false;   // -> ODD
    MemoryBarrier();
    s->FrameWidth = w; s->FrameHeight = h; s->Stride = w * 4;
    s->ActiveBuffer = wbuf;
    s->FrameId++;
    s->CaptureTick = (LONGLONG)GetTickCount64();
    MemoryBarrier();
    if (_InterlockedCompareExchange(&s->Seq, (q | 1) + 1, q | 1) != (q | 1)) return false;  // -> EVEN
    if (!s->FirstPublishTick) s->FirstPublishTick = QpcNow();
    SignalFramePublished();                     // after the seq bump: a woken agent sees it whole
    s->AckState = WGCBRK_ACTIVE;
    g_ch[i].pubCtlSeq = ctl;
    return true;
}

static void PublishFrame(int i, Direct3D11CaptureFrame const& frame) {
    PubLock pubLock(i);   // RAII: a throw inside must not strand the section (see PubLock)
    do {
        WGCBRK_SLOT* s = &g_slots[i];
        if (!PublishAllowed(s)) break;

        auto surf = frame.Surface();
        auto access = surf.as<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
        com_ptr<ID3D11Texture2D> tex;
        if (FAILED(access->GetInterface(guid_of<ID3D11Texture2D>(), tex.put_void()))) break;
        D3D11_TEXTURE2D_DESC td; tex->GetDesc(&td);
        const int texW = (int)td.Width, texH = (int)td.Height;
        if (texW <= 0 || texH <= 0) break;

        td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0;
        td.CPUAccessFlags = D3D11_CPU_ACCESS_READ; td.MiscFlags = 0;
        com_ptr<ID3D11Texture2D> stg;
        if (FAILED(g_d3d->CreateTexture2D(&td, nullptr, stg.put()))) break;
        g_ctx->CopyResource(stg.get(), tex.get());
        // KEEP THIS CAPTURE, whether or not the current card can be cut from it: it is the window's
        // content until the next arrival, and the only source a static window's re-registered card
        // can be served from (see Channel::lastFull and RepublishRetained).
        g_ch[i].lastFull = stg; g_ch[i].lastFullW = texW; g_ch[i].lastFullH = texH;
        g_ch[i].triedValid = false;             // a new capture may cover a card the old one could not
        PublishCard(i, stg.get(), texW, texH);
    } while (0);
}

// SERVE A REGISTRATION NO ARRIVAL WILL ANSWER. For every arrival-driven channel whose slot's
// ControlSeq moved since the broker last published into it (an agent register, re-register or
// retarget), cut the new card from the retained full-window capture now. A window that is still
// changing is served by its next arrival anyway; this is for the one that is not - the toast
// host after a second toast grew it (measured 2026-09-27, win11de-v5: ack=0 seq=0 for the whole
// census, the agent rejecting every frame). No new capture session is opened: a fresh session is
// what goes deaf after a cold boot. Runs on the main loop after Reconcile, so a slot whose window
// changed has already had its channel (and its retained capture) closed.
static void RepublishRetained() {
    for (int i = 0; i < WGCBRK_MAX_SLOTS; i++) {
        if (!g_ch[i].hwnd || g_ch[i].pw) continue;          // hwnd/pw are written on this thread only
        PubLock lk(i);                                       // lastFull is written by FrameArrived
        Channel& c = g_ch[i];
        WGCBRK_SLOT* s = &g_slots[i];
        if (!c.hwnd || c.pw || !c.lastFull) continue;
        const LONG ctl = s->ControlSeq;
        if (ctl == c.pubCtlSeq) continue;                    // nothing asked that was not served
        if (c.triedValid && ctl == c.triedCtlSeq) continue;  // already failed for this request and capture
        if (s->ReqState != WGCBRK_REQUESTED) continue;       // freed: never write to its buffers
        if (!PublishAllowed(s)) continue;                    // secure desktop: NOT marked tried - retry later
        if (PublishCard(i, c.lastFull.get(), c.lastFullW, c.lastFullH))
            InterlockedIncrement(&s->Republished);
        else { c.triedCtlSeq = ctl; c.triedValid = true; }
    }
}

// (re)create the channel's top-down 32bpp DIB section to match w x h.
static bool EnsurePwDib(Channel& c, int w, int h) {
    if (c.pwDC && c.pwW == w && c.pwH == h) return true;
    if (c.pwBmp) { DeleteObject(c.pwBmp); c.pwBmp = nullptr; c.pwBits = nullptr; }
    if (!c.pwDC) { HDC scr = GetDC(nullptr); c.pwDC = CreateCompatibleDC(scr); ReleaseDC(nullptr, scr); }
    if (!c.pwDC) return false;
    BITMAPINFO bi = {};
    bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
    bi.bmiHeader.biWidth = w;
    bi.bmiHeader.biHeight = -h;          // top-down, so rows match the agent's expected layout
    bi.bmiHeader.biPlanes = 1;
    bi.bmiHeader.biBitCount = 32;
    bi.bmiHeader.biCompression = BI_RGB; // BGRX, same channel order as B8G8R8A8
    c.pwBmp = CreateDIBSection(c.pwDC, &bi, DIB_RGB_COLORS, &c.pwBits, nullptr, 0);
    if (!c.pwBmp || !c.pwBits) return false;
    SelectObject(c.pwDC, c.pwBmp);
    c.pwW = w; c.pwH = h;
    return true;
}

// Poll one PrintWindow-mode channel: render the window into its DIB and publish if the pixels
// changed. Non-black check filters the classes PrintWindow cannot capture (they slice instead).
// Returns true if this render produced a CHANGED card (i.e. it was worth doing). The adaptive
// backoff in the main loop keys on that: a window whose renders keep coming back identical is a
// window nobody is looking at changing, and rendering it is pure waste - measured 2026-09-25 at
// 30 renders per 30 s producing ZERO published frames on an idle window, about 3.2% of a core
// spent inside the captured application for nothing.
// CONTROL KNOB. `QubesWgcRelayNoDemote=1` (same registry key as the other broker switches) stops a
// relay channel being demoted at all. It exists because Jev required a CONTROL before the demotion
// rule was changed (needs_a_control 0.74): with it set, a relay that would have been demoted keeps
// running, which is what shows the relay WOULD have kept delivering these classes. It is not a
// product setting and defaults OFF.
static bool g_relayNoDemote = false;

// DID THE SOURCE ACTUALLY CHANGE? A poke only says something repainted inside this window's screen
// rectangle; it does not say this window's own content moved. Before demoting a relay we render the
// SOURCE once and compare a hash of its pixels with the last one we took. Unchanged => the relay is
// correctly delivering nothing and must be left alone; changed => damage really did occur with no
// frame behind it, which is the founding symptom the detector exists for.
//
// Cost is one PrintWindow per decision, not per frame, and it is throttled: the demotion question
// is only asked after WGCBRK_WGC_QUIET_MS of silence anyway. On the FIRST call for a channel there
// is no previous hash, so it records one and reports NO change - a relay is never demoted on the
// strength of a measurement that has no baseline.
// Returns SRC_CHANGED / SRC_SAME / SRC_UNMEASURED. The three are NOT interchangeable: SRC_SAME is
// a measurement that says the window is static, while SRC_UNMEASURED means the test was throttled
// or could not run. Collapsing them was a defect in the first cut of this function - the throttled
// case returned "no change", so RelayStaticHolds counted a hold on every loop tick and the counter
// that is supposed to be the EVIDENCE for this rule would have been inflated by orders of
// magnitude. A counter that cannot be read is not instrumentation.
enum { SRC_CHANGED = 1, SRC_SAME = 0, SRC_UNMEASURED = 2 };
static int RelaySourceChanged(int i) {
    Channel& c = g_ch[i];
    HWND hwnd = c.hwnd;
    if (!hwnd || !IsWindow(hwnd)) return SRC_CHANGED;   // gone: let the normal paths deal with it
    const ULONGLONG now = GetTickCount64();
    if (c.srcHashSeen && (now - c.srcHashTick) < c.srcHashMs) return SRC_UNMEASURED;  // too soon
    RECT r{};
    if (!GetWindowRect(hwnd, &r)) return SRC_CHANGED;
    int w = r.right - r.left, h = r.bottom - r.top;
    if (w <= 0 || h <= 0) return SRC_CHANGED;
    if (w > 4096) w = 4096;
    if (h > 4096) h = 4096;
    if (!EnsurePwDib(c, w, h)) return SRC_CHANGED;      // cannot measure => do not suppress a demotion
    if (!PrintWindow(hwnd, c.pwDC, PW_RENDERFULLCONTENT)) {
        // ABI 11: counted separately. "The test could not render the source" and "the source
        // changed" are different facts that this function used to collapse into one return value.
        InterlockedIncrement(&g_slots[i].RelayPwFail);
        return SRC_CHANGED;
    }
    const unsigned char* p = (const unsigned char*)c.pwBits;
    if (!p) return SRC_CHANGED;
    // FNV-1a over a strided sample: every 64th pixel is ample to notice a window repainting, and
    // hashing 2.6 Mpx in full on every decision would cost more than the demotion it is guarding.
    unsigned long long hsh = 1469598103934665603ull;
    const size_t stride = 64 * 4, bytes = (size_t)w * (size_t)h * 4;
    for (size_t off = 0; off + 4 <= bytes; off += stride) {
        for (int b = 0; b < 4; ++b) { hsh ^= p[off + b]; hsh *= 1099511628211ull; }
    }
    const bool first = !c.srcHashSeen;
    const bool changed = !first && hsh != c.srcHash;
    c.srcHash = hsh; c.srcHashTick = now; c.srcHashSeen = true;
    if (changed) c.srcHashMs = 500;
    else if (c.srcHashMs < 8000) { c.srcHashMs *= 2; if (c.srcHashMs > 8000) c.srcHashMs = 8000; }
    return changed ? SRC_CHANGED : SRC_SAME;
}

// Should a RELAY that has delivered be demoted now? Only on a MEASURED change of the source: damage
// was signalled and no frame followed, which is the founding symptom. A measured SAME is a static
// window and is counted, so the rule's effect is visible. UNMEASURED (throttled) neither demotes
// nor counts - it simply waits for the next test.
// How many CONSECUTIVE measured source changes, with no frame arriving in between, before a relay
// is demoted. One is far too few (see Channel::srcChangeStreak); demotion is one-way, so a single
// spurious difference costs the relay for the rest of that window's life.
#define WGCBRK_RELAY_CHANGE_STREAK 3

static bool RelaySrcDecides(int i) {
    Channel& c = g_ch[i];
    const int r = RelaySourceChanged(i);
    if (r == SRC_SAME)       { c.srcChangeStreak = 0;
                               InterlockedIncrement(&g_slots[i].RelayStaticHolds);    return false; }
    if (r == SRC_UNMEASURED) { InterlockedIncrement(&g_slots[i].RelaySrcUnmeasured);  return false; }
    InterlockedIncrement(&g_slots[i].RelaySrcChanged);
    // Measured change with no frame behind it. Before an unbroken run of these is allowed to demote,
    // try REPAIRING the channel once: a thumbnail registered while DWM was still coming up is accepted
    // but never recomposed, which is exactly this symptom on a cold-booted guest.
    // NO REPAIR HERE. A thumbnail re-registration was built on this line and is REVERTED unrun: the
    // measurement that followed showed the DWM thumbnail and the destination window are both fine - a
    // fresh WGC session on that same destination delivers the source's content every second - and that
    // the broker's OWN capture session is the dead part, which re-registering a thumbnail cannot touch.
    // Jev: brokers-own-capture-session-died 0.82, re-registration as the right repair 0.32, and
    // "recreate the session now" 0.00 against "subscribe to item.Closed and OBSERVE" 0.96. The
    // observation lands first (see ItemClosed in wgcbroker_ipc.h); the repair waits for it to speak.
    // A relay not yet re-opened needs ONE measured change: what follows is a re-open, which is cheap
    // and reversible. Demotion is one-way, so it keeps the full streak (see g_relayReopened).
    return (++c.srcChangeStreak) >= (g_relayReopened[i] ? WGCBRK_RELAY_CHANGE_STREAK : 1);
}

// ABI 12: a signature of the frame we just published, sampled EXACTLY as the guest samples its own
// render (guest/window-truth-survey.ps1 walks y += 9 { x += 9 } and counts distinct colours). Same
// sampling means the two numbers are directly comparable, per slot, with the slot's Hwnd giving an
// exact mapping - which dom0's per-window capture cannot provide for override-redirect windows
// because they are absent from _NET_CLIENT_LIST. Jev preferred this (0.63) to photographing the
// whole desktop (0.22).
//
// Throttled to once per second per slot: this walks 1/81 of the frame, which is cheap per call but
// pointless per frame on an arrival-driven feed, and the number it produces is a property of the
// content, not of any individual frame.
static ULONGLONG g_pubSigTick[WGCBRK_MAX_SLOTS] = {};   // when the signature was last COMPUTED
static ULONGLONG g_pubSigLast[WGCBRK_MAX_SLOTS] = {};   // when a frame last ARRIVED, to spot a post-gap one
// A publish whose signature the throttle SKIPPED and no later one has replaced. The throttle keeps a
// post-gap frame but still drops the LAST frame of a burst, and a static window publishes nothing after
// it - so the published signature stayed on the frame BEFORE, for ever. A republish lands exactly there
// (<=250 ms after the arrival burst): measured 2026-09-27, win11de-v6 run 2, the toast was served its
// correct card (req=frame 364x157, republished=1) while its signature still read the previous two-card
// frame (26 colours, MAD 20.6). FlushPendingSignatures signs the active buffer once the burst is over.
static bool      g_pubSigPending[WGCBRK_MAX_SLOTS] = {};
static void SignFrame(int i, const BYTE* buf, int w, int h);
static void PublishSignature(int i, const BYTE* buf, int w, int h) {
    if (!buf || w <= 0 || h <= 0) return;
    // THE THROTTLE MUST NEVER SKIP A POST-GAP FRAME, AND THIS ONE DID. A plain once-per-second rule
    // manufactured the very failure it was used to report: an arrival-driven feed on a STATIC window
    // delivers exactly ONE frame per discrete source change, and if that frame landed within a second
    // of the previous hash it was skipped - then no further frame arrived, so the published fingerprint
    // never reflected the change AT ALL, for ever. That is precisely the "delivered-vs-before 0.0 /
    // delivered-vs-source 21.8" staleness failure, which was recorded as a product P1 and has since
    // been withdrawn (Jev: p1_withdrawn 0.90, fix-the-throttle-and-rerun 1.00, and
    // throttle_is_the_defect_class 0.86 - a check whose own design can produce the fault it reports).
    //
    // So: a frame that ENDS A QUIET PERIOD is ALWAYS hashed, because it is the only frame that will
    // ever carry that change. Only a continuous stream is thinned, and there the next frame is along
    // in milliseconds anyway.
    const ULONGLONG now = GetTickCount64();
    const bool postGap = (g_pubSigLast[i] == 0) || ((now - g_pubSigLast[i]) > 500);
    g_pubSigLast[i] = now;
    if (!postGap && g_pubSigTick[i] && (now - g_pubSigTick[i]) < 1000) { g_pubSigPending[i] = true; return; }
    g_pubSigTick[i] = now;
    g_pubSigPending[i] = false;
    SignFrame(i, buf, w, h);
}

// The signature itself (distinct colours + the tile grid), unthrottled. Callers hold g_pubCs[i].
static void SignFrame(int i, const BYTE* buf, int w, int h) {
    std::set<unsigned int> seen;
    for (int y = 0; y < h; y += 9) {
        const BYTE* row = buf + (size_t)y * (size_t)w * 4;
        for (int x = 0; x < w; x += 9) {
            const BYTE* p = row + (size_t)x * 4;      // BGRA
            seen.insert(((unsigned int)p[2] << 16) | ((unsigned int)p[1] << 8) | (unsigned int)p[0]);
            if (seen.size() > 100000u) { y = h; break; }   // pathological guard
        }
    }
    g_slots[i].PubColours = (LONG)seen.size();

    // ABI 13: the same frame reduced to a fixed WGCBRK_TILES x WGCBRK_TILES grid of per-tile MEAN
    // RGB. Alpha is deliberately not touched (the two sides need not agree on it, and the protocol
    // carries none). Each tile averages a SUBSAMPLE of its own pixels - every other row and column -
    // because the mean of a subsample is what is being compared on both sides, not a checksum, and
    // this keeps the pass linear and cheap enough for the publish path.
    for (int ty = 0; ty < WGCBRK_TILES; ++ty) {
        const int y0 = (int)((LONGLONG)ty * h / WGCBRK_TILES);
        int y1 = (int)((LONGLONG)(ty + 1) * h / WGCBRK_TILES);
        if (y1 <= y0) y1 = y0 + 1;
        if (y1 > h) y1 = h;
        for (int tx = 0; tx < WGCBRK_TILES; ++tx) {
            const int x0 = (int)((LONGLONG)tx * w / WGCBRK_TILES);
            int x1 = (int)((LONGLONG)(tx + 1) * w / WGCBRK_TILES);
            if (x1 <= x0) x1 = x0 + 1;
            if (x1 > w) x1 = w;
            unsigned long long sr = 0, sg = 0, sb = 0, n = 0;
            for (int y = y0; y < y1; y += 2) {
                const BYTE* row = buf + (size_t)y * (size_t)w * 4;
                for (int x = x0; x < x1; x += 2) {
                    const BYTE* p = row + (size_t)x * 4;   // BGRA
                    sb += p[0]; sg += p[1]; sr += p[2]; ++n;
                }
            }
            BYTE* out = (BYTE*)&g_slots[i].PubTiles[((size_t)ty * WGCBRK_TILES + tx) * 3];
            if (n) { out[0] = (BYTE)(sr / n); out[1] = (BYTE)(sg / n); out[2] = (BYTE)(sb / n); }
            else   { out[0] = out[1] = out[2] = 0; }
        }
    }
}

// SIGN THE LAST FRAME OF A BURST. For every slot whose most recent publish was throttled, once no publish
// has followed for 500 ms, sign the frame the agent actually holds (the ACTIVE buffer) - under the slot's
// lock, so no publish can swap it mid-read. Only a frame published into the CURRENT registration is
// signed (FrameId > 0: the agent zeroes it on every registration), and a registration landing during
// the read discards the result rather than sign one window's pixels with another's geometry.
static void FlushPendingSignatures() {
    const ULONGLONG now = GetTickCount64();
    for (int i = 0; i < WGCBRK_MAX_SLOTS; i++) {
        if (!g_pubSigPending[i]) continue;                  // set/cleared under the lock; re-checked below
        if (now - g_pubSigLast[i] <= 500) continue;         // the burst may still be running
        PubLock lk(i);
        if (!g_pubSigPending[i]) continue;
        WGCBRK_SLOT* s = &g_slots[i];
        if (s->ReqState != WGCBRK_REQUESTED) { g_pubSigPending[i] = false; continue; }
        const LONG ctl = s->ControlSeq;
        MemoryBarrier();
        const LONG q = s->Seq;
        const int b = s->ActiveBuffer, w = s->FrameWidth, h = s->FrameHeight;
        if ((q & 1) || q == 0 || s->FrameId == 0) continue;
        if (b < 0 || b >= WGCBRK_RING || w <= 0 || h <= 0 || (LONGLONG)w * h * 4 > s->BufBytes) continue;
        SignFrame(i, WGCBRK_ARENA(g_base, s->BufOffset[b]), w, h);
        MemoryBarrier();
        if (s->ControlSeq != ctl) continue;                 // re-registered mid-read: stays pending
        g_pubSigTick[i] = now;
        g_pubSigPending[i] = false;
    }
}

static bool PublishPrintWindow(int i) {
    bool changed = false;
    PubLock pubLock(i);   // RAII, same reason
    do {
        WGCBRK_SLOT* s = &g_slots[i];
        Channel& c = g_ch[i];
        if (!c.pw) break;
        if (s->ReqState != WGCBRK_REQUESTED && s->AckState != WGCBRK_ACTIVE) break;
        if (!g_hdr->Producing || !InputDesktopIsDefault()) break;   // secure desktop: live check, see PublishFrame
        HWND hwnd = c.hwnd;
        if (!hwnd || !IsWindow(hwnd)) break;
        int w = s->ReqWidth, h = s->ReqHeight;               // published (card) size, agent-sized buffer
        int cropX = s->ReqCropX, cropY = s->ReqCropY;        // agent's current crop offset
        if (w <= 0 || h <= 0 || cropX < 0 || cropY < 0) break;
        if ((LONGLONG)w * h * 4 > s->BufBytes) break;         // agent sized for ReqW*ReqH*4
        // Render the FULL window: PrintWindow draws it at the DC origin and CLIPS to the DIB, so we
        // need a DIB spanning the whole window to (a) lift the card sub-rect at (cropX,cropY) and
        // (b) measure the menu's true OPAQUE bounds - the transparent shadow margin comes out black,
        // so the opaque bounding box is the menu's exterior edge, which we report so the agent can
        // crop pixel-exact instead of trusting UIA's +/-1-2px estimate.
        RECT wr;
        if (!GetWindowRect(hwnd, &wr)) break;
        int fullW = wr.right - wr.left, fullH = wr.bottom - wr.top;
        if (fullW < cropX + w) fullW = cropX + w;             // safety: must at least cover the card
        if (fullH < cropY + h) fullH = cropY + h;
        if (fullW <= 0 || fullH <= 0) break;
        if (!EnsurePwDib(c, fullW, fullH)) break;
        // Stage ticks (ABI 4), diagnostic only - the broker never decides on them. StartTick is the
        // first poll ENTERED (so OpenTick->StartTick is the wait before this window is first looked
        // at), FirstArrivedTick is the first PrintWindow RETURN (so the gap is the synchronous call
        // on the menu's own UI thread), and PollCount says how many polls it took to get a frame
        // worth publishing - which is how "the app had not painted yet" shows up.
        const bool ticksMine = (s->TickPw && s->TickHwnd == (UINT64)(ULONG_PTR)hwnd);
        if (ticksMine) {
            if (!s->StartTick) s->StartTick = QpcNow();
            if (s->PollCount < 0x7FFFFFFF) s->PollCount++;
        }
        if (!PrintWindow(hwnd, c.pwDC, PW_RENDERFULLCONTENT)) break;
        if (ticksMine && !s->FirstArrivedTick) s->FirstArrivedTick = QpcNow();
        const BYTE* rend = (const BYTE*)c.pwBits;
        const int fstride = fullW * 4;
        const BYTE* card = rend + (size_t)cropY * fstride + (size_t)cropX * 4; // card top-left (agent crop)
        // Non-black check (sampled) over the extracted card: a black/near-black capture is the
        // "PrintWindow cannot do this class" signal (CoreWindow/NRB/ULW) - mark FAILED so the
        // agent slices it instead.
        size_t total = 0, nonblack = 0;
        for (int y = 0; y < h; y += 8)
            for (int x = 0; x < w; x += 8) {
                const BYTE* p = card + (size_t)y * fstride + (size_t)x * 4;
                total++;
                if (p[0] > 16 || p[1] > 16 || p[2] > 16) nonblack++;
            }
        if (total == 0 || (nonblack * 100 / total) < 2) { s->AckState = WGCBRK_FAILED; s->FailHr = (LONG)0x00000103; break; }

        int wbuf = 1 - s->ActiveBuffer;
        if (wbuf < 0 || wbuf >= WGCBRK_RING) wbuf = 0;
        BYTE* dst = WGCBRK_ARENA(g_base, s->BufOffset[wbuf]);
        // Copy the card sub-rect (source stride fstride) into the contiguous w*h arena buffer.
        for (int y = 0; y < h; y++)
            memcpy(dst + (size_t)y * w * 4, card + (size_t)y * fstride, (size_t)w * 4);
        PublishSignature(i, dst, w, h);

        // Skip republish if the card is unchanged vs the active buffer (menus are static once open;
        // republishing would flood dom0 with damage). The sub-rect copy has strides, so compare the
        // just-written contiguous dst against the active buffer and, if identical, don't flip.
        if (s->AckState == WGCBRK_ACTIVE && s->ActiveBuffer >= 0 && s->ActiveBuffer < WGCBRK_RING &&
            s->FrameWidth == w && s->FrameHeight == h) {
            const BYTE* cur = WGCBRK_ARENA(g_base, s->BufOffset[s->ActiveBuffer]);
            if (memcmp(cur, dst, (size_t)w * h * 4) == 0) break;   // changed stays false
        }

        // Changed frame: measure the OPAQUE bounding box across the full render (one pass, non-black
        // = any channel > 16) and report it as insets from the window rect. The agent tightens its
        // crop to these - they only ever remove transparent margin, never opaque content. Done here,
        // after the unchanged-skip, so a static menu pays for it once, not every poll.
        {
            int minx = fullW, miny = fullH, maxx = -1, maxy = -1;
            for (int y = 0; y < fullH; y++) {
                const BYTE* rr = rend + (size_t)y * fstride;
                for (int x = 0; x < fullW; x++) {
                    const BYTE* p = rr + (size_t)x * 4;
                    if (p[0] > 16 || p[1] > 16 || p[2] > 16) {
                        if (x < minx) minx = x; if (x > maxx) maxx = x;
                        if (y < miny) miny = y; if (y > maxy) maxy = y;
                    }
                }
            }
            if (maxx >= minx && maxy >= miny) {
                s->OpaqueL = minx; s->OpaqueT = miny;
                s->OpaqueR = fullW - 1 - maxx; s->OpaqueB = fullH - 1 - maxy;
            }
        }

        changed = true;
        s->FrameWidth = w; s->FrameHeight = h; s->Stride = w * 4;
        LONG q = s->Seq;
        _InterlockedExchange(&s->Seq, q | 1);
        MemoryBarrier();
        s->ActiveBuffer = wbuf;
        s->FrameId++;
        s->CaptureTick = (LONGLONG)GetTickCount64();
        MemoryBarrier();
        _InterlockedExchange(&s->Seq, (q | 1) + 1);
        s->AckState = WGCBRK_ACTIVE;
        if (ticksMine && !s->FirstPublishTick) s->FirstPublishTick = QpcNow();
        SignalFramePublished();                     // PrintWindow path: wake the agent too
    } while (0);
    return changed;
}
// Does this window's visible content come from a child window owned by ANOTHER PROCESS that
// covers its client area? That is the shape whose own surface stays empty, so WGC captures
// nothing from it. Measured on a UWP host: the frame is owned by ApplicationFrameHost while a
// Windows.UI.Core.CoreWindow child in the app's process covers the client area.
//
// Walks DESCENDANTS, not immediate children: an earlier attempt used FindWindowEx on the frame
// and missed the CoreWindow entirely on one guest while EnumChildWindows found it, so a fix keyed
// on the immediate-child test would have been flaky.
struct XProcScan { DWORD ownPid; RECT client; bool found; };

static BOOL CALLBACK XProcChildProc(HWND child, LPARAM lp) {
    XProcScan* sc = (XProcScan*)lp;
    if (!IsWindowVisible(child)) return TRUE;
    DWORD pid = 0;
    GetWindowThreadProcessId(child, &pid);
    if (pid == 0 || pid == sc->ownPid) return TRUE;   // same process: an ordinary child control
    RECT r;
    if (!GetWindowRect(child, &r)) return TRUE;
    // "Covers the client area" is deliberately generous: the child need only span most of it,
    // because a frame host keeps a caption strip of its own outside the child.
    const LONG cw = sc->client.right - sc->client.left, chh = sc->client.bottom - sc->client.top;
    const LONG w = r.right - r.left, h = r.bottom - r.top;
    if (cw <= 0 || chh <= 0) return TRUE;
    if (w * 100 >= cw * 80 && h * 100 >= chh * 80) { sc->found = true; return FALSE; }
    return TRUE;
}


// Defined below, next to CloseChannel: does this window's content come from a child owned by
// another process? Declared here because OpenChannel routes on it.
static bool HasCrossProcessContentChild(HWND window);

static void OpenChannel(int i) {
    WGCBRK_SLOT* s = &g_slots[i];
    Channel& c = g_ch[i];
    // First-frame attribution. The tick block is NOT touched yet: a slot is recycled, and this
    // open may fail below on a window that has already been destroyed (menus are short-lived).
    // Overwriting the block first is what made this probe destroy the record of the SUCCESSFUL
    // open that was still serving frames - it reported last-open-failed-early while a frame from
    // the earlier open was being consumed. So the block is claimed only once this open has a real
    // capture item, and a failed open now leaves the working one's record intact.
    const LONGLONG openT = QpcNow();
    bool monitor = (s->Hwnd == WGCBRK_MONITOR_HWND);
    HWND hwnd = monitor ? nullptr : (HWND)(ULONG_PTR)s->Hwnd;
    if (!monitor && (!hwnd || !IsWindow(hwnd))) { s->AckState = WGCBRK_FAILED; s->FailHr = E_HANDLE; return; }
    // A window whose visible content is rendered by a child in ANOTHER PROCESS has an empty
    // surface of its own, so a WGC session on it delivers a couple of frames and then nothing at
    // all - it is capturing a surface that never changes again. Measured 2026-09-25 on Settings:
    // PrintWindow(flags=0), which excludes child composition, returned ONE distinct colour over
    // 1216x941 while PW_RENDERFULLCONTENT returned 191 and the complete page; the slot's arrivals
    // froze at 3 while a control slot ran 637 -> 678 over 23 s.
    //
    // Detect the SHAPE, not the class name: ApplicationFrameWindow is only today's example, and
    // Jev put the right detector at cross-process-child-covering-the-client-area 0.91 against the
    // class name at 0.01. Retargeting the capture at that child does not work either - WGC throws
    // for it (measured: the retarget build came up pw=1, which is only reachable from the catch
    // below) - so these windows go to the PrintWindow path deliberately and up front, rather than
    // arriving there via an exception after a session that was never going to produce anything.
    c.openTick = GetTickCount64();
    c.lastArrivalTick = 0;
    // The STRUCTURAL test is kept only as a fast path: it spares a known-bad window the quiet
    // period below. It is NOT the detector any more - it was rated reliable at 0.12, its 80%
    // threshold is a guess from one sample, and its worst failure is routing a WGC-capable
    // window to PrintWindow for nothing (0.73). The behavioural test in the main loop is what
    // decides, because it keys on the symptom rather than on a proxy for it.
    const bool xprocContent = g_forcePw[i] ||
                              (!monitor && hwnd && HasCrossProcessContentChild(hwnd));
    g_forcePw[i] = false;
    // THE RELAY IS TRIED WHERE THE PRINTWINDOW FALLBACK WOULD BE USED, and nowhere else. This slot's
    // window has no capturable surface of its own, so instead of dropping to a polled pull API we
    // give DWM a destination we own and capture that - arrival-driven, like any other WGC channel.
    // Routing is otherwise UNCHANGED: a window WGC can capture directly still is. Jev put this as
    // the first step at 0.98 precisely because it replaces a path rather than displacing one.
    HWND target = hwnd;
    const bool relayVetoed = g_noRelay[i];
    g_noRelay[i] = false;            // one-shot, same discipline as g_forcePw
    if (xprocContent && g_RelayOn && !relayVetoed && !monitor && hwnd) {
        int rw = 0, rh = 0; HTHUMBNAIL th = nullptr;
        HWND dest = RelayOpenDest(hwnd, &th, &rw, &rh);
        if (dest) {
            c.relayDest = dest; c.relayThumb = th; c.relay = true;
            target = dest;
            s->RelayOk++; s->RelayDest = (UINT64)(ULONG_PTR)dest;
        } else {
            s->RelayFail++;
        }
    }
    if (!xprocContent || c.relay) try {
        auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
        GraphicsCaptureItem item{ nullptr };
        if (monitor)
        {
            // EXACTLY wgcprobe's proven call: CreateForMonitor takes only the HMONITOR, so the
            // handle is the sole variable, and MonitorFromPoint({0,0}, DEFAULTTOPRIMARY) is what
            // captured the monitor successfully from a Task-Scheduler /it launch. (MonitorFromWindow
            // (GetDesktopWindow()) was an earlier wrong theory - the real fix was the launch path.)
            HMONITOR hmon = MonitorFromPoint(POINT{0,0}, MONITOR_DEFAULTTOPRIMARY);
            check_hresult(interop->CreateForMonitor(hmon,
                          guid_of<GraphicsCaptureItem>(), reinterpret_cast<void**>(put_abi(item))));
        }
        else
            check_hresult(interop->CreateForWindow(target, guid_of<GraphicsCaptureItem>(),
                          reinterpret_cast<void**>(put_abi(item))));
        // This open has a real capture item: claim the tick block for it, in order.
        s->TickHwnd  = s->Hwnd;
        s->TickOpenOk = 0;
        s->TickPw = 0;                   // this record describes the WGC path
        s->PollCount = 0;
        s->OpenTick  = openT;
        s->PoolTick = s->StartTick = 0;
        s->FirstArrivedTick = s->FirstPublishTick = 0;
        s->ItemTick = QpcNow();
        MemoryBarrier();
        s->TickOpenOk = 1;               // published last: a reader sees a complete record
        auto size = item.Size();
        auto pool = Direct3D11CaptureFramePool::CreateFreeThreaded(
            g_rtDev, DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, size);
        auto session = pool.CreateCaptureSession(item);
        s->PoolTick = QpcNow();
        try { session.IsCursorCaptureEnabled(false); } catch (...) {}
        try { session.IsBorderRequired(false); } catch (...) {}   // borderDisableOk proven on 26100
        c.hwnd = monitor ? (HWND)(ULONG_PTR)WGCBRK_MONITOR_HWND : hwnd;
        c.item = item; c.pool = pool; c.session = session; c.slot = i;
        // OBSERVATION ONLY. WGC can CLOSE a capture item, after which FrameArrived never fires again for
        // that session - and until now nothing here subscribed, so that state looked exactly like a
        // window whose content had stopped changing. Measured 2026-09-27: a deaf relay channel whose
        // destination a FRESH session (another process) captured fine, every second, with the source's
        // own content. This records whether Closed is what happened, and changes nothing: Jev put
        // observe-first at 0.96 and any repair in the same build at 0.00.
        c.closedRev = item.Closed(auto_revoke, [i](auto const&, auto const&) {
            InterlockedIncrement(&g_slots[i].ItemClosed);
            g_slots[i].ItemClosedTick = (LONGLONG)GetTickCount64();
        });
        c.poolW = size.Width; c.poolH = size.Height;   // FrameArrived tracks content-size changes
        c.rev = pool.FrameArrived(auto_revoke,
            [i](Direct3D11CaptureFramePool const& sender, auto const&) {
                // SERIALIZE AGAINST TEARDOWN, FIRST THING. This runs on a WGC threadpool thread
                // while CloseChannel can be executing `c = Channel{}` on the main thread. After that
                // wipe poolW and poolH are 0, so the size comparison below ALWAYS takes the Recreate
                // branch - the dangerous path becomes the only reachable one - and Recreate on a
                // wiped (null) C++/WinRT handle dereferences null for its vtable. That is an access
                // violation, and the catch(...) around it CANNOT catch it: this project builds with
                // /EHsc, which does not map SEH into C++ exceptions, and the file installs no
                // vectored or unhandled-exception filter. The broker dies, and on an eligible guest
                // that is not cosmetic - the agent withholds toasts, menus and WinUI surfaces rather
                // than falling back to the composite (QGABROKERDIED), for about 8 s until relaunch.
                //
                // The race is PRE-EXISTING - the handler is byte-identical in 5cb2dd9^ - but the
                // relay is what put an HWND and a DWM thumbnail handle inside the struct being
                // wiped, so it is no longer only pixels at stake. Jev: is_real 0.85,
                // crashes-or-hangs 0.96.
                //
                // g_pubCs[i] is the lock CloseChannel already holds across the wipe, and a Windows
                // CRITICAL_SECTION is recursive, so PublishFrame taking it again below is safe.
                // COUNT THE RAW INVOCATION FIRST, before any guard and before the lock. If the
                // event stops firing this stays flat; if the guard throws arrivals away this keeps
                // climbing while FramesArrived does not. Those two were indistinguishable and cost a
                // whole diagnosis round.
                _InterlockedIncrement(&g_slots[i].ArrivalRaw);
                PubLock arrivalLock(i);   // recursive: PublishFrame below takes it again, safely
                // Re-validate under the lock: a wiped or recycled channel has no pool, or has been
                // rebuilt around a different sender. Either way this arrival belongs to a session
                // that is gone, and publishing it would publish another window's pixels.
                if (!g_ch[i].pool || g_ch[i].pool != sender) {
                    _InterlockedIncrement(&g_slots[i].ArrivalRejected);
                    return;
                }
                if (!g_slots[i].FirstArrivedTick)
                    g_slots[i].FirstArrivedTick = QpcNow();
                g_ch[i].pokeAtLastArrival = g_slots[i].PokeSeq;   // damage seen as of this frame
                auto f = sender.TryGetNextFrame();
                if (!f) return;
                auto cs = f.ContentSize();
                // Follow the window's CONTENT size, not the agent's request. ContentSize is the
                // window's own size; the agent's ReqWidth/ReqHeight is the CARD (post-crop) rect
                // it wants published, and those are equal only for an uncropped window. Comparing
                // against the request therefore recreated the pool and dropped the frame on every
                // arrival for any cropped window - a permanent feed loss that only looked benign
                // while the agent could silently slice the desktop composite instead. The crop
                // itself now happens in PublishFrame, from a full-size capture.
                Channel& ch = g_ch[i];
                // ABI 6 accounting: record what every arrival did, so a slot that stops
                // publishing can be told apart from a slot that never receives anything.
                g_slots[i].FramesArrived++;
                InterlockedIncrement(&g_slots[i].GenFrames);   // ABI 15: attributable to THIS session
                ch.lastArrivalTick = GetTickCount64();   // behavioural detector: the feed is alive
                ch.srcChangeStreak = 0;                  // a frame arrived: the run of "no frames" is broken
                g_slots[i].LastContentW = cs.Width; g_slots[i].LastContentH = cs.Height;
                g_slots[i].PoolW = ch.poolW;        g_slots[i].PoolH = ch.poolH;
                if (cs.Width != ch.poolW || cs.Height != ch.poolH) {
                    g_slots[i].FramesDropSize++;
                    bool ok = false;
                    try {
                        ch.pool.Recreate(g_rtDev,
                            DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, cs);
                        ch.poolW = cs.Width; ch.poolH = cs.Height;
                        ok = true;
                    } catch (...) {}
                    if (ok) g_slots[i].RecreateOk++; else g_slots[i].RecreateFail++;
                    // BEHAVIOUR DELIBERATELY UNCHANGED HERE. A swallowed Recreate failure leaves
                    // poolW/poolH stale, so every later frame mismatches and is dropped - a
                    // permanent feed loss wearing an ACTIVE slot, and a real defect. It is NOT
                    // fixed in this commit: this build exists to MEASURE which mechanism stops
                    // the Settings feed, and a fix on the same path could alter or mask the very
                    // state being measured (Jev, asked directly: should-have-been-separate 0.98,
                    // against my own argument that they were separable). The counters above
                    // record what happened; the fix lands once they have spoken.
                    return;
                }
                g_slots[i].FramesPublished++;
                PublishFrame(i, f);
            });
        session.StartCapture();
        s->StartTick = QpcNow();
        // ABI 14: a session is now live on this slot, and this is which one. ChanGen lets a reader
        // tell whether the frame counters it is looking at belong to the CURRENT session or to a
        // previous one on the same slot - the ambiguity that made a closed-and-never-reopened channel
        // indistinguishable from a channel that stopped delivering.
        InterlockedIncrement(&s->ChanOpens);
        InterlockedIncrement(&s->ChanGen);
        s->SessionLive = 1;
        s->GenFrames = 0;   // ABI 15: this session's own frame count starts here
        // WHICH WRITER IS FEEDING THIS SLOT (ABI 8). Both of these are arrival-driven; only
        // WGCBRK_ROUTE_PW below is polled. "How many slots are still on PW" is the number that says
        // whether the fallback is going away, and it cannot be read if the two are collapsed.
        s->Route = c.relay ? WGCBRK_ROUTE_RELAY : WGCBRK_ROUTE_WGC;
        s->AckState = WGCBRK_ACTIVE; s->FailHr = 0;
        return;
    } catch (hresult_error const& e) {
        s->FailHr = e.code();
    } catch (...) {
        s->FailHr = E_FAIL;
    }
    // WGC could not capture this window (o-r menu / CoreWindow / popup). For a real window, fall
    // back to polled PrintWindow instead of giving up - redirected & modern XAML menus render that
    // way, so they leave the slice. The monitor slot never falls back here. Non-black check in
    // PublishPrintWindow marks FAILED (agent slices) for the classes PrintWindow also cannot do.
    // A relay that opened but whose capture failed leaks its destination and thumbnail unless it is
    // closed here: the PrintWindow fallback below never touches them, and CloseChannel is not
    // reached on this path. One leaked top-level window per failed open, for the broker's lifetime.
    if (c.relay) { RelayCloseDest(c); s->RelayFail++; }
    if (!monitor && hwnd && IsWindow(hwnd)) {
        c.hwnd = hwnd; c.slot = i; c.pw = true; s->FailHr = 0;
        // Claim the tick block for the PrintWindow path (ABI 4). Until this existed, a menu - which
        // ALWAYS lands here, because WGC rejects override-redirect popups - left the block holding
        // the last WGC window's ticks, and the agent reported a false "slot reopened" for it.
        s->TickHwnd  = s->Hwnd;
        s->TickOpenOk = 0;
        s->TickPw = 1;
        s->Route = WGCBRK_ROUTE_PW;   // the polled fallback - the thing the relay exists to retire
        s->PollCount = 0;
        s->OpenTick = openT;
        // ItemTick on this path = the moment the WGC attempt was abandoned and we fell back. The
        // gap OpenTick->ItemTick is therefore what a menu PAYS for a CreateForWindow that cannot
        // succeed: WGC rejects override-redirect popups by rule, so this cost is spent on every
        // single menu to learn something already known. Measured as part of a 31-78 ms
        // "first poll" that the loop structure says contains no waiting at all.
        s->ItemTick = QpcNow();
        s->PoolTick = s->StartTick = 0;
        s->FirstArrivedTick = s->FirstPublishTick = 0;
        MemoryBarrier();
        s->TickOpenOk = 1;                // published last
        s->AckState = WGCBRK_REQUESTED;   // pending until the first PrintWindow poll publishes
    } else {
        s->AckState = WGCBRK_FAILED;
    }
}

static bool HasCrossProcessContentChild(HWND window) {
    XProcScan sc{};
    GetWindowThreadProcessId(window, &sc.ownPid);
    if (!GetWindowRect(window, &sc.client)) return false;
    EnumChildWindows(window, XProcChildProc, (LPARAM)&sc);
    return sc.found;
}

static void CloseChannel(int i) {
    // WGC TEARDOWN HAPPENS OUTSIDE THE LOCK. This used to revoke FrameArrived and Close the session
    // and pool while holding g_pubCs[i] - the very lock an in-flight FrameArrived takes first thing.
    // If the teardown waits for that callback, neither can proceed: the main loop stops, the heartbeat
    // stops, and the agent reaps the broker as dead (QGABROKERDIED). Measured 2026-09-27 on
    // win11de-v6: the heartbeat stopped within 0.1 s of the agent unmapping a window (this close), and
    // the older build died the same way 45 s after a census, when the census closes its windows (Jev:
    // this deadlock 1.00). So under the lock only DETACH: move the WinRT objects out and wipe the
    // channel - an in-flight handler then sees `g_ch[i].pool != sender` and returns - and only then,
    // with the lock released, revoke and Close, which may wait for that handler as long as they like.
    Direct3D11CaptureFramePool::FrameArrived_revoker rev;
    GraphicsCaptureItem::Closed_revoker closedRev;
    GraphicsCaptureSession session{ nullptr };
    Direct3D11CaptureFramePool pool{ nullptr };
    GraphicsCaptureItem item{ nullptr };
    com_ptr<ID3D11Texture2D> lastFull;
    {
    PubLock closeLock(i);                       // serialize with any in-flight PublishFrame
    Channel& c = g_ch[i];
    rev = std::move(c.rev);
    closedRev = std::move(c.closedRev);
    session = c.session; c.session = nullptr;
    pool = c.pool;       c.pool = nullptr;
    item = c.item;       c.item = nullptr;
    lastFull = std::move(c.lastFull);
    g_pubSigPending[i] = false;                 // nothing of this channel is left to sign
    if (c.pwBmp)   { DeleteObject(c.pwBmp); }
    if (c.pwDC)    { DeleteDC(c.pwDC); }
    // The relay's destination is a real top-level window and its thumbnail is a DWM handle; `c =
    // Channel{}` below would forget both and leak them for the broker's lifetime. Released BEFORE
    // the struct is wiped, for the same reason g_forcePw had to be set after it (that assignment
    // erased state the re-route depended on and cost 38 needless re-routes on a healthy window).
    RelayCloseDest(c);
    c = Channel{};
    g_slots[i].AckState = WGCBRK_FREE;
    g_slots[i].Route = WGCBRK_ROUTE_WGC;   // a free slot claims no writer
    g_slots[i].RelayDest = 0;
    // ABI 14: the session is gone. The FRAME counters are deliberately left alone - their history is
    // useful - but without this flag a slot showing FramesArrived=53 and no movement was
    // indistinguishable from a slot whose session had been closed and never reopened. Jev rated that
    // confusion plausible at 0.81 and a DIFFERENT defect at 0.83.
    InterlockedIncrement(&g_slots[i].ChanCloses);
    g_slots[i].SessionLive = 0;
    }   // PubLock released: an in-flight FrameArrived can now take it, see the wiped pool and return
    rev.revoke();
    if (session) { try { session.Close(); } catch (...) {} }
    if (pool)    { try { pool.Close();    } catch (...) {} }
    // item, closedRev, lastFull and the moved-out objects are released here, outside the lock too.
}

static void Reconcile() {
    for (int i = 0; i < WGCBRK_MAX_SLOTS; i++) {
        WGCBRK_SLOT* s = &g_slots[i];
        HWND want = (HWND)(ULONG_PTR)s->Hwnd;
        bool wantOpen = (s->ReqState == WGCBRK_REQUESTED) && want;
        Channel& c = g_ch[i];
        if (wantOpen && c.hwnd != want) { if (c.hwnd) CloseChannel(i); g_relayReopened[i] = false; g_wgcReopened[i] = false; OpenChannel(i); }
        else if (!wantOpen && c.hwnd)   { CloseChannel(i); g_relayReopened[i] = false; g_wgcReopened[i] = false; }
        else if (wantOpen && c.hwnd == want && !c.pw &&
                 IsWindow(want) && IsWindowVisible(want) && !IsIconic(want) &&
                 GetTickCount64() >= g_noProbeUntil[i] &&
                 (GetTickCount64() - (c.lastArrivalTick ? c.lastArrivalTick : c.openTick))
                     >= WGCBRK_WGC_QUIET_MS &&
                 // SILENCE IS NOT ENOUGH. An arrival-driven feed produces nothing when its source is
                 // not changing, and that is CORRECT. Re-route only when the agent has seen damage
                 // for this window since our last frame - damage happened, no frame followed - or
                 // when we have never delivered at all, which is the case this detector was built
                 // for (its founding measurement had FramesArrived frozen at 3 while a control ran
                 // 637 -> 678). Measured 2026-09-26: without this, a relay that delivered 2934
                 // frames and went idle was demoted to POLLING, which costs a render per backoff
                 // interval for a window nobody is touching - the exact idle cost this work removes.
                 // Jev: silent-while-the-window-is-changing 0.63, demotion-of-idle-is-backwards 0.84,
                 // and "has never delivered" alone only 0.25 because it never fires for the founding
                 // case.
                 // ABI 10: a poke is NOT evidence the source changed - see wgcbroker_ipc.h. For a
                 // RELAY that has already delivered, confirm the SOURCE actually moved before
                 // demoting it; otherwise a healthy relay on a static window is demoted for ever.
                 // Jev: quiet-rule-demotes-healthy-static-relays 1.00, require-evidence-the-source-
                 // changed 0.76. g_relayNoDemote is the control, not a product setting.
                 !(c.relay && g_relayNoDemote) &&
                 (g_slots[i].FramesArrived == 0 ||
                  (g_slots[i].PokeSeq != c.pokeAtLastArrival &&
                   (!c.relay || RelaySrcDecides(i))))) {
            // BEHAVIOURAL DETECTION - this, not the structural test, is what decides.
            //
            // A visible, unminimised window whose WGC feed has said NOTHING since it opened is a
            // window WGC is not serving. That is the SYMPTOM, measured directly, rather than a
            // guess about why: FramesArrived frozen at 3 while a control slot ran 637 -> 678 in
            // the same 23 s. Keying on it cannot misclassify a window WGC is in fact serving,
            // needs no threshold, and catches causes nobody has seen yet. Jev rated it 0.94
            // against the structural test at 0.00, and rated the structural test's reliability
            // 0.12 - it holds on the one instance measured and its 80% coverage threshold is a
            // guess from a single sample.
            //
            // It can afford to be liberal because a WRONG re-route is now cheap: the adaptive
            // backoff renders such a window once and then decays to the 8 s ceiling. A genuinely
            // static window costs one render to misjudge. That trade only became available once
            // the backoff existed.
            // The re-route is a TEST, not a commitment. A window that is merely STATIC produces
            // no WGC arrivals either - there is nothing to send - so keying on silence alone would
            // re-route every quiet window on the desktop and leave each costing a render per 8 s
            // once the backoff decayed. Ten such windows would be about 4% of a core, the same
            // order as the single-window cost already called unacceptable. Jev rated that
            // blocking at 0.87 and this refinement at 0.96.
            g_slots[i].Reroutes++;
            g_slots[i].QuietReroutes++;
            const bool wasRelay = c.relay;   // read BEFORE CloseChannel wipes it
            const bool wasPlainWgc = !c.relay && !c.pw;
            CloseChannel(i);          // wipes the Channel - so set the survivors AFTER it
            // A quiet plain-WGC channel first gets one fresh plain-WGC session (g_wgcReopened); only a
            // second quiet period sends it down the ladder.
            if (wasPlainWgc && !g_wgcReopened[i]) { g_wgcReopened[i] = true; g_forcePw[i] = false; }
            else                                  { g_forcePw[i] = true; }
            // A quiet WGC channel becomes a relay; a quiet RELAY first gets ONE fresh re-open (its own
            // capture session is what dies after a cold boot - see g_relayReopened), and only a relay
            // that goes quiet again goes to PrintWindow, or the ladder has no last rung.
            if (wasRelay) {
                if (!g_relayReopened[i]) g_relayReopened[i] = true;   // re-open as a relay, once
                else                     g_noRelay[i] = true;         // it went deaf again: demote
            }
            OpenChannel(i);
            g_ch[i].probing = true;   // OpenChannel re-made the Channel; mark the new one
        }
        else if (wantOpen && c.hwnd == want && !c.pw && !c.relay) {
            // `&& !c.relay` IS LOAD-BEARING, and its absence was a regression I introduced with the
            // relay. This re-check exists for a channel that WGC opened on the window itself and
            // that should move to the fallback once the cross-process child appears. A RELAYED
            // channel has already made that move - it IS the fallback, just an arrival-driven one -
            // and it keeps c.pw false, so without this guard the branch stayed armed for ever:
            //   * HasCrossProcessContentChild(want) still tests the SOURCE, and the relay's
            //     destination is a separate top-level window that EnumChildWindows(source) cannot
            //     see, so the predicate remains true;
            //   * the 500 ms throttle could not bound it either, because c.xprocTick is erased by
            //     `c = Channel{}` inside CloseChannel, so the next pass always reads 0;
            //   * before the relay the re-open fell through to c.pw = true, which disarmed this
            //     branch after one pass. The relay removed that disarm without replacing it.
            // Result: two CreateWindowExW plus two DwmRegisterThumbnail plus a fresh frame pool,
            // session and StartCapture, torn down and rebuilt EVERY main-loop pass - 250 ms idle,
            // 33 ms with any PrintWindow channel active. Jev: is_real 0.90, wrong-pixels 0.70.
            // The same churn shape as the 38 needless re-routes this file was bitten by before.
            // RE-CHECK THE ROUTING. A UWP-style frame exists BEFORE the app creates the
            // cross-process child that carries its content, so the routing decision taken in
            // OpenChannel is usually taken too early and says "WGC". Without this the window
            // stays on a session that will never deliver another frame - which is precisely how
            // the previous attempt at this fix failed, silently, and why Jev rated that risk
            // blocking at 0.85 before this was written.
            const ULONGLONG nowX = GetTickCount64();
            if (nowX - c.xprocTick >= 500) {      // bounded: EnumChildWindows is not free
                c.xprocTick = nowX;
                if (HasCrossProcessContentChild(want)) {
                    g_slots[i].Reroutes++;
                    CloseChannel(i);
                    OpenChannel(i);               // now takes the PrintWindow path
                }
            }
        }
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
    const wchar_t* frmName = ArgVal(argc, argv, L"--frame");
    const wchar_t* pidStr  = ArgVal(argc, argv, L"--agent-pid");
    if (!shmName || !ctlName || !pidStr) return 1;
    g_launcherPid = (DWORD)_wtoi64(pidStr);
    g_agent = g_launcherPid ? OpenProcess(SYNCHRONIZE, FALSE, g_launcherPid) : nullptr;

    init_apartment(apartment_type::multi_threaded);
    if (!WgcSupported()) return 2;
    if (!InitD3D())      return 3;

    // THE RELAY CAPABILITY, LATCHED HERE AND NEVER RE-READ. Decided once, at start, from the build
    // and an explicit opt-out - the project's rule, because a runtime re-read that failed
    // transiently would silently downgrade an eligible guest, and a silent downgrade is exactly the
    // fallback this work exists to remove. Default ON where it is known to work: the relay was
    // measured on 26200 and every WGC prerequisite it leans on (border removal, DirtyRegions) needs
    // 24H2+ anyway. Never on Win10, where WGC cannot serve a per-window path at all.
    {
        // RtlGetVersion, NOT VerifyVersionInfo/GetVersionEx. Those are subject to the compatibility
        // manifest shim and report an older build unless the binary declares supportedOS - the agent
        // documents exactly this at main.c:11652 and uses RtlGetVersion for the same gate. The first
        // R1 build used VerifyVersionInfo and the relay NEVER ENGAGED on a 26200.8037 guest: two
        // slots sat on the polled fallback with relayOk=0 AND relayFail=0, i.e. not even attempted,
        // and nothing said why. A capability that fails to latch has to be visible.
        DWORD build = 0;
        if (HMODULE nt = GetModuleHandleW(L"ntdll.dll")) {
            typedef LONG (WINAPI *PFN_RTLGETVERSION)(OSVERSIONINFOW*);
            auto pRtlGetVersion = (PFN_RTLGETVERSION)GetProcAddress(nt, "RtlGetVersion");
            OSVERSIONINFOW ovi{}; ovi.dwOSVersionInfoSize = sizeof(ovi);
            if (pRtlGetVersion && pRtlGetVersion(&ovi) == 0) build = ovi.dwBuildNumber;
        }
        g_RelayOn = (build >= 26100);
        // Explicit opt-out, read ONCE: HKLM\SOFTWARE\Qubes\GuiAgent : QubesWgcRelay = 0.
        HKEY k = nullptr;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Qubes\\GuiAgent", 0, KEY_READ, &k) == ERROR_SUCCESS) {
            DWORD v = 1, cb = sizeof(v), ty = 0;
            if (RegQueryValueExW(k, L"QubesWgcRelay", nullptr, &ty, (BYTE*)&v, &cb) == ERROR_SUCCESS
                && ty == REG_DWORD && v == 0)
                g_RelayOn = false;
            // THE CONTROL, read the same way and latched the same way: QubesWgcRelayNoDemote = 1
            // stops a relay channel being demoted at all. Jev required a control run before the
            // demotion rule was changed (needs_a_control 0.74) - with this set, a relay that the old
            // rule would have demoted keeps running, which is what shows it WOULD have kept
            // delivering. Not a product setting; defaults off; never read again after start.
            DWORD nd = 0; DWORD cbnd = sizeof(nd); DWORD tynd = 0;
            if (RegQueryValueExW(k, L"QubesWgcRelayNoDemote", nullptr, &tynd, (BYTE*)&nd, &cbnd) == ERROR_SUCCESS
                && tynd == REG_DWORD && nd == 1)
                g_relayNoDemote = true;
            RegCloseKey(k);
        }
        g_RelayBuild = build;   // published below, once the section is mapped
    }

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
    // PUBLISH THE LATCHED CAPABILITY AND THE BUILD IT WAS DECIDED FROM. Without this the first R1
    // build's silent off was indistinguishable from "no rogue window appeared": every slot read
    // relayOk=0 relayFail=0 and nothing said whether the relay was disabled or simply unused. Now
    // guest/wgcbroker-peek.ps1 prints it, so "did the capability even latch" is answered before any
    // route is interpreted.
    g_hdr->RelayCapable = g_RelayOn ? 1 : 0;
    g_hdr->RelayOsBuild = (LONG)g_RelayBuild;
    g_hCtl = OpenEventW(EVENT_MODIFY_STATE | SYNCHRONIZE, FALSE, ctlName);
    // FAIL LOUD. This handle is how the agent WAKES us the instant it registers a window; without
    // it the wait below falls back to its 250 ms timeout and every window - every menu, every
    // toast - silently waits up to a quarter second before it is even looked at. A degradation
    // that is invisible and only shows up as "rendering feels slow" is exactly the kind this
    // project has resolved to report rather than absorb, so refuse to run half-deaf.
    if (!g_hCtl) return 8;
    // Optional by design: an older agent does not pass --frame, and the broker must still serve
    // it (the agent then falls back to noticing frames on its capture pass, as it always did).
    if (frmName) g_hFrame = OpenEventW(EVENT_MODIFY_STATE | SYNCHRONIZE, FALSE, frmName);

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

        // PrintWindow channels are polled (no FrameArrived), so tighten the wait while any is
        // active so menus refresh at ~30 Hz; otherwise stay lazy (WGC is event-driven).
        DWORD timeout = g_anyPw ? 33 : 250;
        DWORD n = 0; HANDLE compact[2];
        if (g_hCtl) compact[n++] = g_hCtl;
        if (g_agent) compact[n++] = g_agent;
        if (n == 0) { Sleep(timeout); }
        else {
            DWORD wr = WaitForMultipleObjects(n, compact, FALSE, timeout);
            if (g_agent && wr == WAIT_OBJECT_0 + (g_hCtl ? 1 : 0)) break; // agent exited
        }
        Reconcile();
        RepublishRetained();   // after Reconcile: a slot whose window changed is closed by now
        FlushPendingSignatures();   // sign a burst's last frame once the burst is over
        // Service PrintWindow-mode channels, DAMAGE-DRIVEN (ABI 7).
        //
        // PrintWindow is not cheap and it is not ours to pay: it renders the full window
        // SYNCHRONOUSLY ON THE CAPTURED APPLICATION'S UI THREAD. Measured 2026-09-25 on the
        // Settings window, p50 31.7 ms (p90 38.9, max 53.3, n=40), against this loop's old fixed
        // 33 ms tick - about 43% of one core, for one window, whether or not anything changed.
        // Jev on those numbers: unacceptable-as-is 1.00, damage-driven-polling 0.87.
        //
        // The agent already computes per-window damage by intersecting the desktop's dirty rects
        // with each window rect, so it bumps PokeSeq when this window's pixels actually changed
        // and signals the control event. Render only for a window that says it changed.
        //
        // SafetyPolls is a BOUND on staleness, not a fallback: if the poke path is broken this
        // still repaints once a second, and the counter says it happened. A SafetyPolls that
        // climbs in normal use means the damage signal is wrong and must be diagnosed - it is not
        // something to leave running quietly.
        const ULONGLONG nowTick = GetTickCount64();
        bool anyPw = false;
        for (int i = 0; i < WGCBRK_MAX_SLOTS; i++) {
            if (!g_ch[i].pw || !g_ch[i].hwnd) continue;
            anyPw = true;
            WGCBRK_SLOT* ps = &g_slots[i];
            // VISIBILITY GATE. A window dom0 is not showing - minimised, or gone - is not worth
            // rendering at all. Cheap, and it composes with the backoff below rather than
            // replacing it (Jev: combine 0.73).
            if (!IsWindow(g_ch[i].hwnd) || !IsWindowVisible(g_ch[i].hwnd) || IsIconic(g_ch[i].hwnd)) {
                ps->PollsSkipped++;
                continue;
            }
            const LONG poke = ps->PokeSeq;
            const bool changed = (poke != ps->PokeAck);
            // ADAPTIVE BACKOFF. The backstop exists so a window that changes WITHOUT dom0 input
            // does not freeze. But measured idle, it rendered 30 times in 30 s and published
            // NOTHING - about 3.2% of a core spent inside the captured application to discover
            // that nothing had changed, per window, for as long as it stays open.
            //
            // So let the render result drive the interval, which the broker already computes in
            // order to skip republishing an identical card: a render that changes nothing doubles
            // the interval, a render that changes something (or any poke) snaps it back to the
            // floor. A static window decays to almost no polling; a window that genuinely updates
            // on its own keeps its rate automatically, because its renders keep coming back
            // changed - which is why Jev rated the "this re-freezes self-updating windows" risk
            // at only 0.20 and this gate at 1.00.
            if (g_ch[i].pwBackoffMs < WGCBRK_POKE_SAFETY_MS) g_ch[i].pwBackoffMs = WGCBRK_POKE_SAFETY_MS;
            const bool stale = (nowTick - g_ch[i].pwLastTick) >= g_ch[i].pwBackoffMs;
            // Coalesce: however many pokes arrived, render at most every
            // WGCBRK_POKE_MIN_INTERVAL_MS. Input pokes arrive at input rate, and this render is
            // not cheap and not ours to spend - it runs on the captured application's UI thread.
            // The poke is NOT acknowledged here, so the render still happens at the next tick.
            if (changed && (nowTick - g_ch[i].pwLastTick) < WGCBRK_POKE_MIN_INTERVAL_MS && !stale) {
                ps->PollsSkipped++; continue;
            }
            if (!changed && !stale) { ps->PollsSkipped++; continue; }
            if (!changed && stale) ps->SafetyPolls++;
            ps->PokeAck = poke;              // before rendering: damage during the render re-pokes
            g_ch[i].pwLastTick = nowTick;
            ps->PollsServiced++;
            const bool produced = PublishPrintWindow(i);
            if (g_ch[i].probing) {
                // THE TEST'S ANSWER. PublishPrintWindow returns false when the card it rendered is
                // identical to the frame already published - which, on the first render after a
                // quiet re-route, is the last frame WGC delivered. Identical therefore means WGC
                // was serving this window correctly and it is simply static: give it back to WGC,
                // which costs nothing while nothing changes. Different means WGC was NOT serving
                // it and the re-route was right.
                //
                // The hysteresis matters as much as the test: without it a static window would be
                // re-tested every WGCBRK_WGC_QUIET_MS for ever, which is a churn loop costing a
                // render every couple of seconds - worse than what it replaces. Jev flagged that
                // hazard at 0.71 as needing handling rather than noting.
                g_ch[i].probing = false;
                if (!produced) {
                    g_slots[i].ProbeBounces++;
                    g_noProbeUntil[i] = nowTick + WGCBRK_WGC_PROBE_BACKOFF_MS;
                    CloseChannel(i);
                    g_forcePw[i] = false;
                    OpenChannel(i);      // back to WGC, which was right all along
                    continue;
                }
            }
            if (produced || changed) {
                g_ch[i].pwBackoffMs = WGCBRK_POKE_SAFETY_MS;   // something happened: stay attentive
            } else if (ps->PokeSeq == 0) {
                // NEVER BACK OFF A SLOT THAT HAS NO DAMAGE SIGNAL. Backoff assumes the safety poll
                // is a backstop and that pokes carry interactive updates. When PokeSeq has never
                // advanced there are no pokes, so this poll is the slot's ONLY render driver AND
                // the only source of the behavioural no-frames signal that decides routing at all.
                // Doubling it to the 8 s ceiling then makes the window unusable and blinds the
                // detector at the same time.
                //
                // Measured 2026-09-25 on win11de-ctl: slot0, an ApplicationFrameWindow, sat at
                // backoffMs=8000 with seq=0, serviced==safety==polls (every render from the
                // backstop, none from damage) and polls advancing by 1 per 6 s - a window
                // repainting once every 6-8 seconds, which is what the owner saw and reported.
                // Jev: backing off a slot's only render driver is unsafe (0.15), the defect is
                // real independent of which window it is (0.75), and the behavioural detector
                // must back the structural one and must not be throttled (1.00).
                //
                // Slots that DO get pokes are unaffected, so the idle-cost win this backoff was
                // added for - a 1 Hz safety poll costing 3.2% of a core - is kept for exactly the
                // case it was meant for.
                g_ch[i].pwBackoffMs = WGCBRK_POKE_SAFETY_MS;
            } else {
                g_ch[i].pwBackoffMs *= 2;                      // nothing to show: ask less often
                if (g_ch[i].pwBackoffMs > WGCBRK_POKE_BACKOFF_MAX_MS)
                    g_ch[i].pwBackoffMs = WGCBRK_POKE_BACKOFF_MAX_MS;
            }
            ps->BackoffMs = (LONG)g_ch[i].pwBackoffMs;
        }
        g_anyPw = anyPw;
    }
    for (int i = 0; i < WGCBRK_MAX_SLOTS; i++) if (g_ch[i].hwnd) CloseChannel(i);
    return 0;
}
