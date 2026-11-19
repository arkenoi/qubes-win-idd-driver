// wgcbroker.exe - user-session Windows.Graphics.Capture broker for QWT gui-agent.
// Runs as the interactive user (spawned by the SYSTEM agent via SpawnHelperAsUser). Captures
// exactly the HWNDs the SYSTEM agent lists in the shared control block; publishes each window's
// BGRA frame into the section's pixel arena via a per-slot seqlock. Exits when the agent dies,
// the section says Shutdown, the console session changes, or the launcher pid stops owning the
// section - each an event; at rest the main loop sleeps without a timeout (docs/DESIGN-rest-zero-capture.md
// S4). Build: mirror tools/wgcprobe (v143, /MT, stdcpp17,
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
#include <thread>
#include <memory>
#include <future>
#include <chrono>
#include <dxgi.h>
#include <wtsapi32.h>   // WTSRegisterSessionNotification (rest-zero S4: the console-session check is an event)
#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>   // Direct3D11CaptureFrame::DirtyRegions (rest-zero S1)
#include <winrt/Windows.Foundation.Metadata.h>      // ApiInformation: the dirty-region API, latched at start
#include <winrt/Windows.Graphics.Capture.h>
#include <winrt/Windows.Graphics.DirectX.h>
#include <winrt/Windows.Graphics.DirectX.Direct3D11.h>
#include <windows.graphics.capture.interop.h>
#include <windows.graphics.directx.direct3d11.interop.h>
#include <set>
#include <string>
#include "../../agent/gui-agent/wgcbroker_ipc.h"
#include "dirty_union.h"   // the union of two frames' dirty regions (S1); tested on Linux by tools/tests/dirty-union-test.cpp

// ABI 12 frame signature - defined further down (it needs g_slots), used by the WGC publish path
// above that definition. Declared here so the call site compiles.
static void PublishSignature(int i, const BYTE* buf, int w, int h);
#include <intrin.h>
#include <vector>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "wtsapi32.lib")
#pragma comment(lib, "user32.lib")
#pragma comment(lib, "gdi32.lib")
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
static HANDLE            g_hFrame = nullptr;   // agent wake: a frame was published (auto-reset)

// Tell the agent a frame is ready. Without this the agent only noticed a published frame on its
// next DESKTOP-capture pass, and a redundant desktop frame skipped that walk entirely - so a
// painted window could sit unnoticed on a static desktop. Signal AFTER the sequence bump so the
// agent that wakes always sees the finished frame.
// REST-ZERO (docs/DESIGN-rest-zero-capture.md C/D). The main loop waits INFINITE unless a request armed a deadline;
// g_hWake is how work armed OFF the main loop (a publish on a WGC thread) reaches it - set only on the transition that
// arms something, never per frame.
static HANDLE            g_hWake = nullptr;
// R5: a published frame must move the agent's AgentFrameWakes (bumped on every agent main-loop wake) within
// WGCBRK_AGENT_DEADLINE_MS. Armed by the first publish after the last check, from any thread; checked and disarmed by the
// main loop (CheckAgentDeadline).
static volatile LONGLONG g_r5Since = 0;
static volatile LONG     g_r5Base = 0;
static inline void SignalFramePublished() {
    // The base is read BEFORE the signal: the agent's answer to this very signal must move the counter past it (read
    // after, a fast agent's increment could already be in it and the deadline would expire on an agent that answered).
    const LONG base = g_hdr ? g_hdr->AgentFrameWakes : 0;
    if (g_hFrame) SetEvent(g_hFrame);
    if (g_hdr && g_r5Since == 0 &&
        InterlockedCompareExchange64(&g_r5Since, (LONGLONG)GetTickCount64(), 0) == 0) {
        g_r5Base = base;                     // after the CAS: a racing check can only see an OLDER base (a missed
        if (g_hWake) SetEvent(g_hWake);      // detection, never a false one) - see CheckAgentDeadline
    }
}
static HANDLE            g_agent= nullptr;
// REST-ZERO S1: GraphicsCaptureSession.DirtyRegionMode and Direct3D11CaptureFrame.DirtyRegions are present (24H2+),
// latched once at start like every capability (CLAUDE.md: decided at START). Absent, every arrival is read whole.
static bool              g_dirtyApi = false;
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
    // WGC pool size, tracked so FrameArrived can follow the window's CONTENT size instead of
    // the agent's requested (possibly CROPPED) size - see the FrameArrived comment.
    int     poolW = 0, poolH = 0;
    // When this channel last delivered a frame (0 = never): a reopened item that Windows closes again before it
    // delivered anything goes DEAF (see g_closedReopened).
    ULONGLONG lastArrivalTick = 0;
    // A frame FrameArrived dropped for size with nothing published since: when (0 = none owed) and its content size.
    // The recreated pool delivers the window at that size only when the window next changes; see SizeDropOwed.
    ULONGLONG sizeDropTick = 0;
    LONG      sizeDropW = 0, sizeDropH = 0;
    // ---- THE LAST FULL-WINDOW CAPTURE, KEPT FOR REPUBLISHING --------------------------------
    // WGC publishes only inside FrameArrived, and a static window sends no arrival.
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
    // REST-ZERO S1, DIRTY REGIONS (docs/DESIGN-rest-zero-capture.md A, Jev a2 0.84; forks 2026-10-01: a persistent copy +
    // the union of two frames' regions 0.95, the agent's row compare kept). A direct WGC session runs in DirtyRegionMode
    // ReportOnly: every surface is complete and WGC says which regions changed, and lastFull - now ONE persistent CPU
    // copy per channel - is kept current by reading only those. ReportOnly, not ReportAndRender (Jev's review: under
    // ReportAndRender an arrival dropped before its regions are read - the pool-recreate return - or a whole read of a
    // surface rendered only partly leaves the copy stale with no way back; complete surfaces make one whole read the
    // repair for any doubt, which needWhole requests). The ring stays whole by one invariant: the SPARE buffer differs from the ACTIVE
    // one only inside prevRegs (card-relative; everywhere while prevFull) - so writing prevRegs plus this frame's regions
    // from lastFull makes the spare current. Measured first (M9(b), wgcprobe dirty on w11-ds): typing into a 3804x998
    // Notepad, every arrival's regions were 2.1% of the frame and only a session's first frame was whole.
    bool              dirty    = false;   // this session reports dirty regions (ReportOnly set)
    bool              needWhole = false;  // an arrival was dropped or failed before its regions were read: read the next whole
    std::vector<RECT> prevRegs;           // the last publish's regions: the spare still has the frame before them
    bool              prevFull = true;    // the spare is not known to match the active buffer anywhere
    // The ControlSeq a republish from THIS lastFull already failed for (the card does not fit it, or the
    // copy failed): not retried until the agent asks again or a new arrival replaces lastFull, so a card
    // that cannot be cut costs one attempt, not an attempt per loop pass.
    LONG        triedCtlSeq = 0;
    bool        triedValid  = false;
};
static std::vector<Channel> g_ch(WGCBRK_MAX_SLOTS);
// How long a new content size must hold before the size reopen below (g_sizeReopenCtl): a drag-resize makes the agent
// retarget on every step, and it costs one reopen once the size settles, not one per step.
#define SIZE_SETTLE_MS 150
// The channel generation (WGCBRK_SLOT::ChanGen) whose capture item Windows CLOSED last, per slot; 0 = none. Written by the
// item.Closed handler (a WGC thread), read by Reconcile, which reopens a channel whose own item closed (g_closedReopened).
static volatile LONG g_closedGen[WGCBRK_MAX_SLOTS] = {};
// A CLOSED ITEM IS REPAIRED AT ONCE (2026-10-01): set when Reconcile reopened a channel because Windows closed its capture
// item; a reopened item that is closed again before it delivered anything goes DEAF instead (no loop). Cleared with the
// other per-registration flags.
static bool      g_closedReopened[WGCBRK_MAX_SLOTS] = {};
// A FRAME DROPPED FOR SIZE IS REPAIRED BY ONE REOPEN. FrameArrived recreates the pool at the window's new size and
// publishes nothing, and a recreated pool delivers again only when the window changes: a window resized after its
// session opened and then left alone - a dialog the agent's caption restyle grows right after registration - is never
// published at its new size, and one with nothing published at all stays withheld (SIZEDROPPEDFIRSTFRAMEWITHHOLDSWINDOW).
// A fresh session delivers the window's current content without a repaint. So a channel that dropped a frame for size
// and has published nothing for SIZE_SETTLE_MS is reopened through Close/OpenChannel, and an (agent request, dropped
// size) pair is reopened at most once - a window that drops again at that size stays on the recreated pool, which
// delivers on its next change. These survive the close; cleared with the other per-registration flags.
static LONG      g_sizeReopenCtl[WGCBRK_MAX_SLOTS] = {};
static bool      g_sizeReopenValid[WGCBRK_MAX_SLOTS] = {};
static LONG      g_sizeReopenW[WGCBRK_MAX_SLOTS] = {}, g_sizeReopenH[WGCBRK_MAX_SLOTS] = {};

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
// ABI 18: WHAT THE MAIN LOOP IS DOING NOW, for the agent's hang report (WGCBRK_STG_*). Scoped: the
// innermost active stage is published, and the enclosing one comes back when it ends. A hang leaves the agent's
// request unacknowledged (CtlAck) with this still naming the call it is blocked in.
// ABI 19: every stage entered and left also bumps BrokerProgress - the agent's hang deadline (R1) requires NO progress
// as well as no acknowledgement, so a broker that is busy (eight session opens in one pass) is not reaped as hung.
struct StageScope {
    LONG prev;
    StageScope(unsigned code, int slot) : prev(g_hdr ? g_hdr->BrokerStage : 0) {
        if (g_hdr) { g_hdr->BrokerStage = (LONG)((code << 8) | ((unsigned)slot & 0xFFu)); InterlockedIncrement(&g_hdr->BrokerProgress); }
    }
    ~StageScope() { if (g_hdr) { g_hdr->BrokerStage = prev; InterlockedIncrement(&g_hdr->BrokerProgress); } }
    StageScope(const StageScope&) = delete;
    StageScope& operator=(const StageScope&) = delete;
};

static void WaitSameWindowTeardown(int i, HWND hwnd);   // defined with CloseChannel; used by OpenChannel
static void CloseChannel(int i);                        // used by OpenChannel when an open fails late

// REST-ZERO (docs/DESIGN-rest-zero-capture.md C/D): the earliest deadline any pending request armed this pass; the main
// loop waits until then, or INFINITE when nothing is pending. Recomputed from state on every pass, so a deadline whose
// request was answered simply is not armed again - nothing to disarm, nothing that can leak into a rest wake.
static ULONGLONG g_nextDue = 0;
static inline void Due(ULONGLONG t) { if (t && (!g_nextDue || t < g_nextDue)) g_nextDue = t; }
// A FAILED SLOT IS HELD (rest-zero E, ADR-capture 36). A slot whose capture cannot be opened, or whose reopened capture
// item Windows closed again before it delivered anything (DEAF), goes FAILED with the code that says why and is held - not
// reopened - until the agent asks again (its ControlSeq moves). Reopening on the broker's own initiative would be a retry
// in hope, and between two attempts the agent could read the slot as pending and never report it.
static bool g_failHold[WGCBRK_MAX_SLOTS] = {};
static LONG g_failHoldCtl[WGCBRK_MAX_SLOTS] = {};
static void HoldFailed(int i, LONG hr) {
    WGCBRK_SLOT* s = &g_slots[i];
    s->FailHr = hr;
    MemoryBarrier();                         // FailHr first: an agent that reads FAILED reads why
    s->AckState = WGCBRK_FAILED;
    g_failHold[i] = true;
    g_failHoldCtl[i] = s->ControlSeq;
    SignalFramePublished();                  // wake the agent (a deaf hold is reported on that wake, QGAWGCDEAF)
}
static void DeclareDeaf(int i) {
    InterlockedIncrement(&g_slots[i].DeafHolds);
    HoldFailed(i, WGCBRK_E_DEAF);
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

// THE SECURITY GATE, MEASURED NOW, AND PUBLISHED AS MEASURED (rest-zero S4). Producing used to be sampled by the main
// loop on its 250 ms tick and AND-ed with a live check at every publish. With no tick, a sampled value could stay 0
// after the secure desktop is left - and the agent rejects every frame while it reads 0 (BrokerFreshFrame) - so the
// live result is the value published: every publish that asks writes what it just measured, and the desktop-switch
// hook installed in wmain refreshes it between publishes. Only ever true when the input desktop is Default right now.
static bool LiveProducing() {
    const bool live = InputDesktopIsDefault();
    g_hdr->Producing = live ? 1 : 0;
    return live;
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
    // LIVE check, never a cached flag: FrameArrived is asynchronous, so a frame that arrives after
    // the input desktop has left Default (UAC consent, the lock screen, the secure desktop) must be
    // judged at the moment of publishing. The whole point of the gate is that secure-desktop pixels
    // never leave the guest, so it is evaluated NOW (LiveProducing, which also publishes the result).
    return LiveProducing();
}

// Crop the agent's CURRENT card out of a CPU-readable full-window copy and publish it into slot i.
// Caller holds g_pubCs[i] and has passed PublishAllowed. Returns true if a frame was published.
// regs (rest-zero S1): this arrival's dirty regions in texture coordinates - only those (and the previous publish's,
// which the spare buffer lacks) are written; nullptr = the whole card.
static bool PublishCard(int i, ID3D11Texture2D* full, int texW, int texH, const std::vector<RECT>* regs = nullptr) {
    WGCBRK_SLOT* s = &g_slots[i];
    Channel& ch = g_ch[i];
    // ControlSeq is read BEFORE the geometry. The agent writes the geometry and buffers, fences, then
    // bumps ControlSeq, so what is read below is at least as new as `ctl`; a registration landing
    // mid-copy is caught by the re-check after the copy.
    const LONG ctl = s->ControlSeq;
    MemoryBarrier();
    // The slot must still be THIS channel's window: a registration for another window re-points
    // BufOffset before Reconcile has closed this channel, and those are that window's buffers.
    if ((HWND)(ULONG_PTR)s->Hwnd != g_ch[i].hwnd) return false;
    // Publish the agent's REQUESTED (card) rect, lifted from the full-window capture at the
    // agent's crop offset. Before this the WGC path
    // published the whole texture and FrameArrived dropped every frame whose ContentSize did
    // not equal ReqWidth/ReqHeight, so a WGC-capturable window with a nonzero crop (a shell
    // toast/menu whose shadow margin the agent trims) could NEVER publish: pool recreate,
    // drop, repeat. That was survivable only because the agent silently sliced the
    // whole-desktop composite instead; with the composite fallback removed on eligible
    // guests (owner 2026-09-06, "no fallback ... fail hard") it would freeze the window for
    // ever, so the crop is implemented here rather than worked around there.
    const int w = s->ReqWidth, h = s->ReqHeight;
    // THE CROP FROM LIVE GEOMETRY WHEN THE AGENT SUPPLIES THE CARD'S SCREEN POSITION (ABI 25).
    //
    // ReqCropX/Y are an offset INSIDE the window, measured by the agent's card walk at one moment
    // and applied here to whatever the window is NOW. For a shell surface those disagree: the walk
    // reported "toast card in 666x750 window, insets l=12 t=12" while the same handle measured
    // 5120x1392 seconds later - the shell's CoreWindow is full-screen while it composes and
    // card-sized once the menu is placed. Cropping at (12,12) in the full-screen state lifts the
    // empty top-left corner of the screen, which is the QGASLICEBLACK nonblack=0/7371 that has made
    // the Start menu unpaintable. A crop whose frame of reference depends on WHEN it was measured
    // is a race, and the owner's standing rule is that races are not tolerated.
    //
    // So when ReqCardX/Y are supplied (>= 0), the offset is derived here, against the window's rect
    // at capture time. -1 means not supplied and nothing changes - which is every non-shell window.
    int cropX = s->ReqCropX, cropY = s->ReqCropY;
    // THE WINDOW ORIGIN IS PUBLISHED WHENEVER THERE IS ONE, not only when a card position was
    // supplied. CropWinX/Y used to be written only inside the derivation below, so a slot whose
    // derivation never ran left them at their zero-initialised value - and a reader cannot tell
    // "the window really is at 0,0" from "nobody wrote this". The agent's QGACROPFALLBACK compares
    // CropUsed against ReqCard - CropWin, so an unwritten origin made a perfectly healthy window
    // look mis-cropped: measured 2026-10-18, the Start card painted at 100% non-black and the agent
    // still warned "card outside the capture - cropped 0,0 not 2239,654", because its source was
    // the card-sized window (origin 2239,654) and CropWin read 0. A warning on a healthy window is
    // the boot noise the owner refuses, so the origin is published unconditionally and the compare
    // becomes exact in both directions.
    // AND IT IS A FLAG, NOT AN UNCONDITIONAL WRITE (ABI 28). The paragraph above says the origin is
    // "published unconditionally" - it is not: it is conditional on haveRect, and when
    // GetWindowRect FAILS these fields keep what they held, which on a fresh slot is zero. The
    // reader cannot tell that from a window really at 0,0, which is the exact ambiguity the
    // paragraph set out to remove. MEASURED on acceptance run 40037710497: for a toast whose
    // GetWindowRect was refusing (the agent logged `no usable GetWindowRect - rejecting` three
    // times for that handle) the agent warned `card outside the capture - cropped 0,0 not
    // 4740,1251` on a window whose card really was at 4740,1251 - the only breach in each of three
    // win11 cells. So the validity is published beside the value, the way ReqCardValid is for the
    // card, and the agent's compare requires it.
    RECT wr{};
    const bool haveRect = ch.hwnd && IsWindow(ch.hwnd) && GetWindowRect(ch.hwnd, &wr);
    if (haveRect) { s->CropWinX = wr.left; s->CropWinY = wr.top; }
    s->CropWinValid = haveRect ? 1 : 0;
    if (s->ReqCardValid && haveRect) {
        const int lx = s->ReqCardX - wr.left, ly = s->ReqCardY - wr.top;
        if (lx >= 0 && ly >= 0 && lx + w <= texW && ly + h <= texH) {
            cropX = lx; cropY = ly;
        }
        // Out of the texture: keep the agent's inset rather than publish a wrong rectangle.
        // The card is genuinely outside what this capture covers (the 1392-vs-1440 case), and
        // a clamped crop would be pixels from the wrong place, which is worse than none.
    }
    if (w <= 0 || h <= 0 || cropX < 0 || cropY < 0) return false;
    // SAY WHAT WAS USED (ABI 26). This broker has no log, so a black cropped copy could not be
    // told apart from a wrong crop. Published before the bounds test so even a refused publish
    // leaves its reasoning visible.
    s->CropUsedX = cropX; s->CropUsedY = cropY;
    if (cropX + w > texW || cropY + h > texH) return false;   // capture does not cover the card yet
    if ((LONGLONG)w * h * 4 > s->BufBytes) return false;      // agent sized for ReqW*ReqH*4; skip oversize

    // WHOLE CARD unless this is a steady-state arrival with regions: a registration to answer (the card or the buffers
    // may be new), a spare not known to match the active buffer, or a geometry the active frame does not have.
    const bool regAnswer = (ch.pubCtlSeq != ctl);
    // deltaKnown: the active buffer is a complete frame of THIS card geometry and this arrival's regions say exactly
    // where the window changed since it - the condition for writing regions, and for knowing afterwards what the spare
    // (that frame) lacks against the new one. Every published buffer is complete, so after a publish with a known delta
    // the spare lacks exactly this arrival's regions, whatever was written this time.
    const bool deltaKnown = regs && !regAnswer && s->AckState == WGCBRK_ACTIVE &&
                            s->FrameWidth == w && s->FrameHeight == h &&
                            s->ActiveBuffer >= 0 && s->ActiveBuffer < WGCBRK_RING;
    const bool whole = !deltaKnown || ch.prevFull;
    std::vector<RECT> cur;                      // this arrival's regions, card-relative
    if (regs) {
        const RECT card = { 0, 0, w, h };
        for (const RECT& r : *regs) {
            const RECT q = { r.left - cropX, r.top - cropY, r.right - cropX, r.bottom - cropY };
            RECT k;
            if (IntersectRect(&k, &q, &card)) cur.push_back(k);
        }
        // Everything this arrival changed lies outside the card (the cropped shadow margin): nothing to publish, and the
        // spare is no more stale than it was.
        if (cur.empty() && !whole) { InterlockedIncrement(&s->SameFrames); return false; }
    }
    D3D11_MAPPED_SUBRESOURCE map;
    if (FAILED(g_ctx->Map(full, 0, D3D11_MAP_READ, 0, &map))) return false;
    int wbuf = 1 - s->ActiveBuffer;             // spare (RING==2)
    if (wbuf < 0 || wbuf >= WGCBRK_RING) wbuf = 0;
    BYTE* dst = WGCBRK_ARENA(g_base, s->BufOffset[wbuf]);
    const BYTE* src = (const BYTE*)map.pData + (size_t)cropY * map.RowPitch + (size_t)cropX * 4;
    LONGLONG bytes = 0;
    ch.prevFull = true;                         // the spare is being written: unknown until this publish settles
    if (whole) {
        for (int y = 0; y < h; y++)
            memcpy(dst + (size_t)y * w * 4, src + (size_t)y * map.RowPitch, (size_t)w * 4);
        bytes = (LONGLONG)w * h * 4;
    } else {
        // THE UNION of the previous arrival's regions (the spare holds the frame before the active one) and this arrival's - every
        // pixel once (dirty_union.h). Writing the two lists one after the other copied each overlap twice: measured 2026-10-03 (M9(b),
        // rz36) a blinking caret's same 3x20 rect at ~500 bytes per publish instead of 240, a marquee bar at ~2x its rect.
        ForEachUnionRun(ch.prevRegs, cur, [&](long y0, long y1, long l, long r) {
            const size_t rb = (size_t)(r - l) * 4;
            for (long y = y0; y < y1; y++)
                memcpy(dst + (size_t)y * w * 4 + (size_t)l * 4, src + (size_t)y * map.RowPitch + (size_t)l * 4, rb);
            bytes += (LONGLONG)rb * (y1 - y0);
        });
    }
    // THE OPAQUE BOUNDING BOX. The agent tightens its crop to it "instead of UIA's +/-1-2px estimate";
    // without it a WGC-captured popup fell back to that estimate and kept a rim of its transparent shadow
    // margin - which a premultiplied capture delivers as OPAQUE BLACK. Photographed 2026-10-17 on
    // a Notepad teaching tip (Microsoft.UI.Content.PopupWindowSiteBridge): scanning in from the
    // announced edge gave 2 px of dom0's label border, then 3 px (left) and 6 px (top) of
    // (0,0,0), then the popup's own (249,249,249). The owner, looking at the same window: "the o-r
    // pop up could be either properly synthesized or properly cut, and it is neither."
    //
    // Measured on a WHOLE publish only - a registration answer, a resize, or a first frame - so a
    // static popup pays for it once rather than on every arrival. Non-black is any channel > 16.
    if (whole) {
        int minx = texW, miny = texH, maxx = -1, maxy = -1;
        for (int y = 0; y < texH; y++) {
            const BYTE* rr = (const BYTE*)map.pData + (size_t)y * map.RowPitch;
            for (int x = 0; x < texW; x++) {
                const BYTE* q = rr + (size_t)x * 4;
                if (q[0] > 16 || q[1] > 16 || q[2] > 16) {
                    if (x < minx) minx = x; if (x > maxx) maxx = x;
                    if (y < miny) miny = y; if (y > maxy) maxy = y;
                }
            }
        }
        if (maxx >= minx && maxy >= miny) {
            s->OpaqueL = minx; s->OpaqueT = miny;
            s->OpaqueR = texW - 1 - maxx; s->OpaqueB = texH - 1 - maxy;
        }
    }
    g_ctx->Unmap(full, 0);
    MemoryBarrier();
    InterlockedExchangeAdd64(&s->DirtyBytes, bytes);
    // A registration during the copy may have moved the card or the buffers: this frame answers a
    // request that no longer exists. Drop it UNPUBLISHED (Seq untouched, so the agent never sees
    // it); ControlSeq now differs from pubCtlSeq, so the main loop serves the new one next pass.
    if (s->ControlSeq != ctl) return false;     // prevFull stays set: the spare is half-written
    // THE SAME PIXELS ARE NOT A CHANGE (owner, 2026-09-30: "if you repaint the same pixels it is not a change"). A window
    // that presents again without changing - at rest on w11-ds an Explorer window published ~15 frames a minute - still
    // costs a WGC arrival here, but its card is not republished and the agent is not woken to compare it again.
    // Steady state only: an arrival that answers a registration (ControlSeq moved since this channel last published) is
    // published whatever it holds - that is the frame the agent waits for. The quiet/deaf test keys on arrivals
    // (lastArrivalTick), not on publishes, so a window that keeps repainting the same pixels is not judged deaf.
    if (!regAnswer && s->AckState == WGCBRK_ACTIVE && s->FrameWidth == w && s->FrameHeight == h &&
        s->ActiveBuffer >= 0 && s->ActiveBuffer < WGCBRK_RING && s->ActiveBuffer != wbuf) {
        const BYTE* act = WGCBRK_ARENA(g_base, s->BufOffset[s->ActiveBuffer]);
        bool same = true;
        if (whole)
            same = (memcmp(act, dst, (size_t)w * h * 4) == 0);
        else
            for (size_t n = 0; same && n < cur.size(); n++)
                for (int y = cur[n].top; same && y < cur[n].bottom; y++)
                    same = (memcmp(act + (size_t)y * w * 4 + (size_t)cur[n].left * 4,
                                   dst + (size_t)y * w * 4 + (size_t)cur[n].left * 4,
                                   (size_t)(cur[n].right - cur[n].left) * 4) == 0);
        if (same) {
            // The spare now equals the active buffer everywhere: it lacked only prevRegs (rewritten just now with pixels
            // equal to the active frame's) and this arrival changed nothing (or the whole card was just compared equal).
            ch.prevRegs.clear(); ch.prevFull = false;
            InterlockedIncrement(&s->SameFrames);
            return false;
        }
    }
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
    // The buffer that just became the spare holds the frame before this one: it differs from the new active buffer
    // only inside this arrival's regions - or, after a whole write, anywhere.
    if (deltaKnown) { ch.prevRegs.swap(cur); ch.prevFull = false; }
    else { ch.prevRegs.clear(); ch.prevFull = true; }
    if (!whole) InterlockedIncrement(&s->DirtyPublishes);
    return true;
}

static void PublishFrame(int i, Direct3D11CaptureFrame const& frame) {
    PubLock pubLock(i);   // RAII: a throw inside must not strand the section (see PubLock)
    do {
        WGCBRK_SLOT* s = &g_slots[i];
        Channel& c = g_ch[i];

        auto surf = frame.Surface();
        auto access = surf.as<Windows::Graphics::DirectX::Direct3D11::IDirect3DDxgiInterfaceAccess>();
        com_ptr<ID3D11Texture2D> tex;
        if (FAILED(access->GetInterface(guid_of<ID3D11Texture2D>(), tex.put_void()))) { c.needWhole = true; break; }
        D3D11_TEXTURE2D_DESC td; tex->GetDesc(&td);
        const int texW = (int)td.Width, texH = (int)td.Height;
        if (texW <= 0 || texH <= 0) { c.needWhole = true; break; }

        // KEEP THE WINDOW'S PIXELS CURRENT, whether or not this arrival is published (the secure-desktop gate below): it
        // is the window's content until the next arrival, and the only source a static window's re-registered card can be
        // served from (RepublishRetained). ONE persistent copy per channel (it was a new texture per arrival); with dirty
        // regions only the changed rectangles are read. A whole read when the copy is new, the size changed, or an earlier
        // arrival never reached it (needWhole) - the surface is always complete (ReportOnly).
        bool wholeRead = !c.dirty || c.needWhole || !c.lastFull || c.lastFullW != texW || c.lastFullH != texH;
        std::vector<RECT> regs;
        if (!wholeRead) {
            try {
                auto dr = frame.DirtyRegions();
                const RECT texR = { 0, 0, texW, texH };
                for (uint32_t k = 0; k < dr.Size(); k++) {
                    auto r = dr.GetAt(k);
                    const RECT q = { r.X, r.Y, r.X + r.Width, r.Y + r.Height };
                    RECT x;
                    if (IntersectRect(&x, &q, &texR)) regs.push_back(x);
                }
            } catch (...) { wholeRead = true; }
            // An arrival that reports NO region: nothing is known about what changed (none were seen in M9(b)'s 51 typing
            // arrivals, but a skipped change would stay stale) - read it whole; the identical-frame check keeps an
            // unchanged one from being published.
            if (!wholeRead && regs.empty()) wholeRead = true;
            if (!wholeRead && regs.size() > 64) {    // many small rects: one bounding box, a superset
                RECT b = regs[0];
                for (const RECT& r : regs) UnionRect(&b, &b, &r);
                regs.assign(1, b);
            }
        }
        if (wholeRead) {
            if (!c.lastFull || c.lastFullW != texW || c.lastFullH != texH) {
                td.Usage = D3D11_USAGE_STAGING; td.BindFlags = 0;
                td.CPUAccessFlags = D3D11_CPU_ACCESS_READ; td.MiscFlags = 0;
                com_ptr<ID3D11Texture2D> stg;
                if (FAILED(g_d3d->CreateTexture2D(&td, nullptr, stg.put()))) { c.lastFull = nullptr; c.needWhole = true; break; }
                c.lastFull = stg; c.lastFullW = texW; c.lastFullH = texH;
            }
            g_ctx->CopyResource(c.lastFull.get(), tex.get());
            c.needWhole = false;
            InterlockedIncrement(&s->DirtyFullCopies);
        } else {
            for (const RECT& r : regs) {
                const D3D11_BOX b = { (UINT)r.left, (UINT)r.top, 0, (UINT)r.right, (UINT)r.bottom, 1 };
                g_ctx->CopySubresourceRegion(c.lastFull.get(), 0, (UINT)r.left, (UINT)r.top, 0, tex.get(), 0, &b);
            }
        }
        c.triedValid = false;                   // a new capture may cover a card the old one could not
        if (!PublishAllowed(s)) break;
        PublishCard(i, c.lastFull.get(), texW, texH, wholeRead ? nullptr : &regs);
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
        if (!g_ch[i].hwnd) continue;                         // hwnd is written on this thread only
        PubLock lk(i);                                       // lastFull is written by FrameArrived
        Channel& c = g_ch[i];
        WGCBRK_SLOT* s = &g_slots[i];
        if (!c.hwnd || !c.lastFull) continue;
        const LONG ctl = s->ControlSeq;
        if (ctl == c.pubCtlSeq) continue;                    // nothing asked that was not served
        if (c.triedValid && ctl == c.triedCtlSeq) continue;  // already failed for this request and capture
        if (s->ReqState != WGCBRK_REQUESTED) continue;       // freed: never write to its buffers
        if (!PublishAllowed(s)) continue;                    // secure desktop: NOT marked tried - retry later
        StageScope st(WGCBRK_STG_REPUBLISH, i);
        if (PublishCard(i, c.lastFull.get(), c.lastFullW, c.lastFullH))
            InterlockedIncrement(&s->Republished);
        else { c.triedCtlSeq = ctl; c.triedValid = true; }
    }
}

// TEST SWITCHES for the typing-latency regression (2026-10-01: key -> damage p90 ~190-200 ms from the build that brought
// DirtyRegionMode, against ~20 ms before it; bisected to that range). Read ONCE at start, never again:
//   QubesWgcDirtyMode = 0     direct sessions are NOT put in DirtyRegionMode (whole frames, as before S1b)
//   QubesWgcMinUpdateMs = N   GraphicsCaptureSession.MinUpdateInterval = N ms on every direct session (absent: left alone)
// Not product settings; absent = the shipped behaviour.
static bool g_dirtyModeOn = true;
static LONG g_minUpdateMs = -1;
static bool g_minUpdateApi = false;

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
    if (!postGap && g_pubSigTick[i] && (now - g_pubSigTick[i]) < 1000) {
        // The tail signer runs on the main loop, which now sleeps until something is due: wake it once, when this
        // slot's signature first goes pending - not per frame of the burst.
        if (!g_pubSigPending[i]) { g_pubSigPending[i] = true; if (g_hWake) SetEvent(g_hWake); }
        return;
    }
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
        // The burst may still be running: come back when it has been quiet for 500 ms (a deadline armed by the burst,
        // so it ends with it - at rest nothing is pending and nothing is armed).
        if (now - g_pubSigLast[i] <= 500) { Due(g_pubSigLast[i] + 501); continue; }
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
        { StageScope st(WGCBRK_STG_SIGN, i); SignFrame(i, WGCBRK_ARENA(g_base, s->BufOffset[b]), w, h); }
        MemoryBarrier();
        if (s->ControlSeq != ctl) continue;                 // re-registered mid-read: stays pending
        g_pubSigTick[i] = now;
        g_pubSigPending[i] = false;
    }
}

static void OpenChannel(int i) {
    StageScope stage(WGCBRK_STG_OPEN, i);
    WaitSameWindowTeardown(i, (HWND)(ULONG_PTR)g_slots[i].Hwnd);
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
    // A window that is gone is E_HANDLE - the agent does not report it as refused (DirectSuppressFault).
    if (!monitor && (!hwnd || !IsWindow(hwnd))) { HoldFailed(i, E_HANDLE); return; }
    // A UWP-STYLE FRAME (ApplicationFrameWindow with its CoreWindow in another process) IS CAPTURED ON THE WINDOW ITSELF,
    // like any other window: measured 2026-09-30 on 26100.1742 with our agent and broker stopped, a direct session on the
    // Settings frame returns the full page and delivers a burst on each navigation.
    c.lastArrivalTick = 0;
    LONG hr = E_FAIL;
    try {
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
            check_hresult(interop->CreateForWindow(hwnd, guid_of<GraphicsCaptureItem>(),
                          reinterpret_cast<void**>(put_abi(item))));
        // This open has a real capture item: claim the tick block for it, in order.
        s->TickHwnd  = s->Hwnd;
        s->TickOpenOk = 0;
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
        // OWNED POPUPS COME WITH THE OWNER. A WinUI popup - a tooltip, a flyout, a teaching tip -
        // is its own TOP-LEVEL HWND, so by default an owner's capture excludes it and the agent
        // has to announce it to dom0 as a separate window. dom0 then marks it, like any window,
        // with the qube's 2 px label border: a coloured rectangle drawn INSIDE the parent, around
        // a popup that lies wholly within it. Photographed 2026-10-17 on a Notepad teaching tip.
        // Cropping cannot finish the job either - that popup has a callout BEAK, so the rows
        // beside the beak are transparent, transparency arrives as opaque black, and no rectangle
        // can exclude them.
        //
        // IncludeSecondaryWindows makes Windows composite owned windows into the OWNER's frames,
        // with their real transparency. MEASURED on 26200 before enabling it: same owner window,
        // same rectangle, two captures - with it off the rect held the parent's own text
        // (rectcolors ... 585858,474747,383838,767676), with it on that text was gone and the rect
        // was the popup's light panel. The property is present (secondaryWindowsApi=1) and applies
        // (set=1).
        //
        // It costs nothing: no extra capture, no extra copy, and the owner's feed changes when the
        // popup opens AND when it closes, so there is no stale region to repair afterwards. The
        // agent's side of this is to stop announcing a popup that lies wholly inside a tracked
        // owner; a popup that extends beyond its owner - most context menus - still needs its own
        // window and is unaffected, because it is still captured and announced as before.
        try { session.IncludeSecondaryWindows(true); } catch (...) {}
        
        // DIRTY REGIONS (rest-zero S1) on a window session only: the monitor keeps the whole-frame path. ReportOnly:
        // complete surfaces, regions reported; PublishFrame reads only the regions.
        if (g_dirtyApi && !monitor) {
            if (g_dirtyModeOn) { try { session.DirtyRegionMode(GraphicsCaptureDirtyRegionMode::ReportOnly); c.dirty = true; } catch (...) {} }
            if (g_minUpdateApi && g_minUpdateMs >= 0) {
                try { session.MinUpdateInterval(winrt::Windows::Foundation::TimeSpan{ std::chrono::milliseconds(g_minUpdateMs) }); } catch (...) {}
            }
        }
        c.hwnd = monitor ? (HWND)(ULONG_PTR)WGCBRK_MONITOR_HWND : hwnd;
        c.item = item; c.pool = pool; c.session = session; c.slot = i;
        // WGC can CLOSE a capture item, after which FrameArrived never fires again for that session. The handler records
        // it and wakes this loop, and Reconcile reopens the channel (g_closedReopened).
        // The generation this channel will have once the open completes (ChanGen is bumped at the end of this try, and
        // only on this main thread): the Closed handler records it, so a Closed that belongs to an EARLIER item - its
        // teardown runs on another thread and can end after this open - is never taken for this channel's.
        const LONG closeGen = g_slots[i].ChanGen + 1;
        c.closedRev = item.Closed(auto_revoke, [i, closeGen](auto const&, auto const&) {
            InterlockedIncrement(&g_slots[i].ItemClosed);
            g_slots[i].ItemClosedTick = (LONGLONG)GetTickCount64();
            InterlockedExchange(&g_closedGen[i], closeGen);
            if (g_hWake) SetEvent(g_hWake);   // Reconcile reopens it (see g_closedReopened)
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
                ch.lastArrivalTick = GetTickCount64();   // this channel has delivered (see g_closedReopened)
                g_slots[i].LastContentW = cs.Width; g_slots[i].LastContentH = cs.Height;
                g_slots[i].PoolW = ch.poolW;        g_slots[i].PoolH = ch.poolH;
                // A frame rendered before a Recreate keeps that pool's surface size (the surface is always the pool's
                // size; larger content is clipped to it), so its ContentSize can match the recreated pool while its
                // surface cannot cover the card. It is a size drop too, not a publish: PublishCard would refuse it, and
                // clearing sizeDropTick for it would leave a static window with no reopen. The pool is already the right
                // size, so nothing is recreated: FramesDropSize above RecreateOk + RecreateFail counts these frames.
                const auto sd = f.Surface().Description();
                const bool poolMismatch = cs.Width != ch.poolW || cs.Height != ch.poolH;
                if (poolMismatch || sd.Width < cs.Width || sd.Height < cs.Height) {
                    g_slots[i].FramesDropSize++;
                    ch.needWhole = true;                 // this arrival's regions never reach lastFull (rest-zero S1)
                    if (poolMismatch) {
                        bool ok = false;
                        try {
                            ch.pool.Recreate(g_rtDev,
                                DirectXPixelFormat::B8G8R8A8UIntNormalized, 2, cs);
                            ch.poolW = cs.Width; ch.poolH = cs.Height;
                            ok = true;
                        } catch (...) {}
                        if (ok) g_slots[i].RecreateOk++; else g_slots[i].RecreateFail++;
                    }
                    // Nothing reaches the agent at the new size until the window changes again, so this frame is
                    // owed: Reconcile reopens a plain-WGC channel once the size has settled (g_sizeReopenCtl). That
                    // reopen also repairs a swallowed Recreate failure, whose stale poolW/poolH drop every later frame.
                    ch.sizeDropTick = GetTickCount64(); ch.sizeDropW = cs.Width; ch.sizeDropH = cs.Height;
                    if (g_hWake) SetEvent(g_hWake);
                    return;
                }
                ch.sizeDropTick = 0;   // a frame at the pool's size, on a surface that covers it, reaches PublishFrame
                g_slots[i].FramesPublished++;
                PublishFrame(i, f);
            });
        // FI ONE-SHOT, NEVER MERGED (ADR-capture 36 evidence): a Notepad open fails late, with the pool and session stored.
        if (!monitor) {
            WCHAR fiCls[32] = {};
            GetClassNameW(hwnd, fiCls, 32);
            if (lstrcmpW(fiCls, L"Notepad") == 0) throw_hresult(hresult(static_cast<int32_t>(0x80FE0036u)));
        }
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
        s->AckState = WGCBRK_ACTIVE; s->FailHr = 0;
        return;
    } catch (hresult_error const& e) {
        hr = e.code();
    } catch (...) {
        hr = E_FAIL;
    }
    // THE CAPTURE COULD NOT BE OPENED, AND NOTHING ELSE CAPTURES THE WINDOW (ADR-capture 36): the slot is held FAILED with
    // the code that refused it, and the agent reports it (DirectSuppressFault). A window that closed while it was being
    // opened is E_HANDLE, so it is not reported as refused. A throw after the pool and session were stored left them on
    // the channel: they are closed first, because CloseChannel frees the slot and the hold must come after it.
    if (!monitor && !IsWindow(hwnd)) hr = E_HANDLE;
    if (c.hwnd) CloseChannel(i);
    HoldFailed(i, hr);
}

// EVERYTHING A CLOSED WGC CHANNEL STILL OWNS, torn down OFF THE MAIN LOOP. Measured 2026-09-27 (build
// 3be5415, win11de-v7): two broker deaths were both named by BrokerStage as close-channel, one on a slot
// whose window was hung - and moving revoke/Close out of the slot lock had not helped, so the teardown call
// itself blocks (Jev: WGC teardown 0.62). Each teardown gets its own detached thread: one that never
// returns (a window that never answers) pins only itself, not the loop and not the next close.
struct DoomedCapture {
    Direct3D11CaptureFramePool::FrameArrived_revoker rev;
    GraphicsCaptureItem::Closed_revoker closedRev;
    GraphicsCaptureSession session{ nullptr };
    Direct3D11CaptureFramePool pool{ nullptr };
    GraphicsCaptureItem item{ nullptr };
    com_ptr<ID3D11Texture2D> lastFull;
};
// The last teardown handed off per slot, and which window it was for. A quiet re-open of the SAME window
// waits (bounded) for it: before the teardown thread the old session was always closed before the new one
// opened, and the re-open exists precisely because a first session can go deaf - an old session still
// closing beside the new one is a state this code has never run in. 250 ms covers a healthy teardown; a
// hung one costs the loop at most that, then the new session opens anyway.
static std::shared_future<void> g_teardownDone[WGCBRK_MAX_SLOTS];
static HWND                     g_teardownHwnd[WGCBRK_MAX_SLOTS] = {};
static void WaitSameWindowTeardown(int i, HWND hwnd) {
    if (!g_teardownDone[i].valid()) return;
    if (g_teardownHwnd[i] == hwnd) {
        StageScope st(WGCBRK_STG_CLOSE_REAP, i);
        (void)g_teardownDone[i].wait_for(std::chrono::milliseconds(250));
    }
    g_teardownDone[i] = std::shared_future<void>();
    g_teardownHwnd[i] = nullptr;
}

static void TearDown(std::unique_ptr<DoomedCapture> d) {
    if (!d) return;
    d->rev.revoke();
    if (d->session) { try { d->session.Close(); } catch (...) {} }
    if (d->pool)    { try { d->pool.Close();    } catch (...) {} }
    d.reset();                                   // Closed revoker, item, lastFull released here
}

static void CloseChannel(int i) {
    StageScope stage(WGCBRK_STG_CLOSE, i);      // declared first: restores the caller's stage at the end
    // WGC TEARDOWN HAPPENS OUTSIDE THE LOCK. This used to revoke FrameArrived and Close the session
    // and pool while holding g_pubCs[i] - the very lock an in-flight FrameArrived takes first thing.
    // If the teardown waits for that callback, neither can proceed: the main loop stops, the heartbeat
    // stops, and the agent reaps the broker as dead (QGABROKERDIED). Measured 2026-09-27 on
    // win11de-v6: the heartbeat stopped within 0.1 s of the agent unmapping a window (this close), and
    // the older build died the same way 45 s after a census, when the census closes its windows (Jev:
    // this deadlock 1.00). So under the lock only DETACH: move the WinRT objects out and wipe the
    // channel - an in-flight handler then sees `g_ch[i].pool != sender` and returns - and only then,
    // with the lock released, revoke and Close, which may wait for that handler as long as they like.
    auto d = std::make_unique<DoomedCapture>();
    HWND closedHwnd = nullptr;
    {
    // The lock wait is its own stage: a FrameArrived handler holding this slot's lock and stuck would
    // stop the loop HERE, which the teardown thread below cannot help with - so it must be told apart.
    if (g_hdr) g_hdr->BrokerStage = (LONG)((WGCBRK_STG_CLOSE_LOCK << 8) | ((unsigned)i & 0xFFu));
    PubLock closeLock(i);                       // serialize with any in-flight PublishFrame
    if (g_hdr) g_hdr->BrokerStage = (LONG)((WGCBRK_STG_CLOSE << 8) | ((unsigned)i & 0xFFu));
    Channel& c = g_ch[i];
    closedHwnd = c.hwnd;
    d->rev = std::move(c.rev);
    d->closedRev = std::move(c.closedRev);
    d->session = c.session; c.session = nullptr;
    d->pool = c.pool;       c.pool = nullptr;
    d->item = c.item;       c.item = nullptr;
    d->lastFull = std::move(c.lastFull);
    g_pubSigPending[i] = false;                 // nothing of this channel is left to sign
    c = Channel{};
    g_slots[i].AckState = WGCBRK_FREE;
    // ABI 14: the session is gone. The FRAME counters are deliberately left alone - their history is
    // useful - but without this flag a slot showing FramesArrived=53 and no movement was
    // indistinguishable from a slot whose session had been closed and never reopened. Jev rated that
    // confusion plausible at 0.81 and a DIFFERENT defect at 0.83.
    InterlockedIncrement(&g_slots[i].ChanCloses);
    g_slots[i].SessionLive = 0;
    }   // PubLock released: an in-flight FrameArrived can now take it, see the wiped pool and return
    if (!d->session && !d->pool && !d->item && !d->lastFull) return;   // nothing to reap
    StageScope reap(WGCBRK_STG_CLOSE_REAP, i);
    std::promise<void> done;
    g_teardownDone[i] = done.get_future().share();
    g_teardownHwnd[i] = closedHwnd;
    try {
        std::thread([](std::unique_ptr<DoomedCapture> dd, std::promise<void> fin) {
            // NOTHING MAY ESCAPE THIS THREAD: an exception here is std::terminate - the broker dies,
            // which is the very outcome this thread exists to prevent.
            bool com = false;
            try { init_apartment(apartment_type::multi_threaded); com = true; } catch (...) {}
            try { TearDown(std::move(dd)); } catch (...) {}
            if (com) { try { uninit_apartment(); } catch (...) {} }
            try { fin.set_value(); } catch (...) {}
        }, std::move(d), std::move(done)).detach();
    } catch (...) {
        TearDown(std::move(d));                  // no thread (exceptional): the old in-line teardown
        g_teardownDone[i] = std::shared_future<void>();
        g_teardownHwnd[i] = nullptr;
    }
}

// True when the channel on slot i dropped a frame for size, has published nothing since, that size has held
// SIZE_SETTLE_MS, and the channel was not reopened yet for this agent request and size (see g_sizeReopenCtl); *w and
// *h get the size. A drop already answered for that request and size is cleared here, so it arms no deadline: the recreated
// pool delivers on the window's next change. Under the slot's PubLock, because FrameArrived writes these fields under it.
static bool SizeDropOwed(int i, const WGCBRK_SLOT* s, LONG* w, LONG* h) {
    PubLock lk(i);
    Channel& c = g_ch[i];
    if (!c.sizeDropTick || GetTickCount64() - c.sizeDropTick < SIZE_SETTLE_MS) return false;
    if (g_sizeReopenValid[i] && g_sizeReopenCtl[i] == s->ControlSeq &&
        c.sizeDropW == g_sizeReopenW[i] && c.sizeDropH == g_sizeReopenH[i]) { c.sizeDropTick = 0; return false; }
    *w = c.sizeDropW; *h = c.sizeDropH;
    return true;
}

// ONE SLOT'S CHANNEL OPEN MUST NOT MAKE ANOTHER SLOT'S REQUEST LOOK UNANSWERED (2026-10-07).
//
// Measured on 2026-10-01 (findings/issues.md P1; Jev: cause 0.92, this fix 0.97): an Explorer window registered on
// slot 3 while this loop was inside OpenChannel for slot 0. The loop acknowledges each slot at the END of that slot's
// own iteration, so slot 3's acknowledgement waited behind slot 0's open; the open took longer than the agent's
// WGCBRK_ACK_DEADLINE_MS, the agent read "unacknowledged and no progress" as a hang, and it TERMINATED a broker that
// was working. 1218 ms with every window withheld, and on an eligible guest there is no composite fallback.
//
// So a FIRST registration is acknowledged in this cheap pre-pass, before any per-slot work: it says "seen and
// accepted", which is all the agent's liveness deadline asks, and the outcome of the open is reported as it always
// was (ReqState / WGCBRK_E_DEAF, and the first frame the agent waits for anyway).
//
// WHY ONLY A SLOT WITH NO OPEN CHANNEL. The same acknowledgement doubles as "your buffers are mine no longer": the
// agent reuses an arena region once the slot's CtlAck has reached the request that released it (R4, main.c
// WgcArenaReapPending). Acknowledging a re-registration early would authorise that reuse while this process still
// holds the old channel's buffers. A slot whose channel is not open has none of the agent's buffers in flight, which
// is exactly the measured case - a brand-new window, CtlAck 0 wanted 1 - so that case is acknowledged early and
// every other request keeps its acknowledgement after the work, where it still means what the agent reads it to mean.
static void AckFirstRegistrations() {
    for (int i = 0; i < WGCBRK_MAX_SLOTS; i++) {
        WGCBRK_SLOT* s = &g_slots[i];
        const LONG ctl = s->ControlSeq;
        MemoryBarrier();
        if ((LONG)((ULONG)s->CtlAck - (ULONG)ctl) >= 0) continue;      // nothing outstanding on this slot
        if (s->ReqState != WGCBRK_REQUESTED) continue;                 // a release: its ack stays after CloseChannel
        if (g_ch[i].hwnd != nullptr) continue;                         // a re-registration: buffers may be in flight
        if (!(HWND)(ULONG_PTR)s->Hwnd) continue;                       // nothing to open
        s->CtlAck = ctl;
        InterlockedIncrement(&g_hdr->BrokerProgress);
    }
}

static void Reconcile() {
    StageScope stage(WGCBRK_STG_RECONCILE, 0);
    AckFirstRegistrations();   // before any open, so no slot's work delays another slot's ack
    for (int i = 0; i < WGCBRK_MAX_SLOTS; i++) {
        WGCBRK_SLOT* s = &g_slots[i];
        // R1/R4 (rest-zero D): the request this pass answers, acknowledged in CtlAck once the slot has been handled below.
        InterlockedIncrement(&g_hdr->BrokerProgress);
        const LONG ctl0 = s->ControlSeq;
        MemoryBarrier();
        HWND want = (HWND)(ULONG_PTR)s->Hwnd;
        if (g_failHold[i] && ctl0 != g_failHoldCtl[i]) g_failHold[i] = false;   // the agent asked again: one more open
        bool wantOpen = (s->ReqState == WGCBRK_REQUESTED) && want && !g_failHold[i];
        Channel& c = g_ch[i];
        if (wantOpen && c.hwnd != want) { if (c.hwnd) CloseChannel(i); g_closedReopened[i] = false; g_sizeReopenValid[i] = false; OpenChannel(i); }
        else if (!wantOpen && c.hwnd)   { CloseChannel(i); g_closedReopened[i] = false; g_sizeReopenValid[i] = false; }
        // WINDOWS CLOSED THIS SESSION'S CAPTURE ITEM: reopen at once. Observed first (2026-09-30, Jev 0.96 observe-first) and
        // now measured: on 26100.1742 a UWP app's first item is closed as it launches - Settings (2026-09-30) and Calculator
        // (rz8, 2026-10-01: 3 frames, the splash, then ITEM closed=1) - and a closed item delivers nothing more, so the window
        // stayed on its splash in dom0 until something poked it (the owner watched Calculator do it for a minute, and found its
        // first menu render slow). The Closed handler wakes this loop; the reopen costs one session. A reopened item closed
        // again before it delivered anything is not reopened again: DEAF, loud (Jev: repair now 0.99, loop risk bounded 0.30).
        else if (wantOpen && c.hwnd == want && g_closedGen[i] == g_slots[i].ChanGen &&
                 IsWindow(want) && IsWindowVisible(want) && !IsIconic(want)) {
            const bool delivered = (c.lastArrivalTick != 0);
            g_slots[i].Reroutes++;
            CloseChannel(i);          // wipes the Channel - survivors are set after it
            if (g_closedReopened[i] && !delivered)
                DeclareDeaf(i);
            else { g_closedReopened[i] = true; OpenChannel(i); }
        }
        // A FRAME DROPPED FOR SIZE, NOTHING PUBLISHED SINCE: one fresh session serves the window at its new size (see
        // g_sizeReopenCtl).
        else if (LONG dw = 0, dh = 0; wantOpen && c.hwnd == want &&
                 IsWindow(want) && IsWindowVisible(want) && !IsIconic(want) && SizeDropOwed(i, s, &dw, &dh)) {
            g_slots[i].Reroutes++;                          // visible in the peek, next to dropsize
            const LONG ctl = s->ControlSeq;
            CloseChannel(i);                                // wipes the Channel - survivors are set after it
            g_sizeReopenCtl[i] = ctl; g_sizeReopenW[i] = dw; g_sizeReopenH[i] = dh; g_sizeReopenValid[i] = true;
            OpenChannel(i);
        }
        // THE NEXT MOMENT THIS SLOT'S ANSWER CAN CHANGE WITHOUT A NEW REQUEST (rest-zero D) - armed only while a frame
        // dropped for size is settling. At rest nothing is owed, so nothing is armed and the loop sleeps until an event.
        {
            const Channel& n = g_ch[i];
            if (wantOpen && n.hwnd == want && n.sizeDropTick &&
                IsWindow(want) && IsWindowVisible(want) && !IsIconic(want))
                Due(n.sizeDropTick + SIZE_SETTLE_MS);                                                   // size drop
        }
        s->CtlAck = ctl0;   // after any open/close above: for an unregister, the slot's buffers are no longer ours
    }
}

// R5 (rest-zero D): a frame this broker published has not woken the agent within WGCBRK_AGENT_DEADLINE_MS. Counted and
// stamped in the header (AgentStalls/AgentStallTick): a medium-IL broker cannot reap a SYSTEM agent, and the watchdog
// owns that remedy. Disarmed when AgentFrameWakes moves; re-armed by the next publish (SignalFramePublished).
static void CheckAgentDeadline() {
    const LONGLONG since = g_r5Since;
    if (!since) return;
    if (g_hdr->AgentFrameWakes != g_r5Base) { InterlockedExchange64(&g_r5Since, 0); return; }   // answered
    const ULONGLONG now = GetTickCount64();
    if (now - (ULONGLONG)since >= WGCBRK_AGENT_DEADLINE_MS) {
        InterlockedIncrement(&g_hdr->AgentStalls);
        g_hdr->AgentStallTick = (LONGLONG)now;
        InterlockedExchange64(&g_r5Since, 0);
        return;
    }
    Due((ULONGLONG)since + WGCBRK_AGENT_DEADLINE_MS);
}

static const wchar_t* ArgVal(int argc, wchar_t** argv, const wchar_t* key) {
    for (int i = 1; i + 1 < argc; i++) if (_wcsicmp(argv[i], key) == 0) return argv[i + 1];
    return nullptr;
}

int wmain(int argc, wchar_t** argv) {
    // rest-zero M1 attribution: the main thread names itself (thread-who reads it); the WGC pool threads are the system's.
    {
        typedef HRESULT (WINAPI *PFN_STD)(HANDLE, PCWSTR);
        if (auto p = (PFN_STD)GetProcAddress(GetModuleHandleW(L"kernel32.dll"), "SetThreadDescription"))
            p(GetCurrentThread(), L"wgcbroker: main");
    }
    HANDLE mtx = CreateMutexW(nullptr, FALSE, WGCBRK_SINGLETON_NAME);   // first, and held for life: the agent reads it
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
    try {
        namespace meta = winrt::Windows::Foundation::Metadata;
        g_minUpdateApi = meta::ApiInformation::IsPropertyPresent(L"Windows.Graphics.Capture.GraphicsCaptureSession", L"MinUpdateInterval");
        g_dirtyApi = meta::ApiInformation::IsPropertyPresent(L"Windows.Graphics.Capture.GraphicsCaptureSession", L"DirtyRegionMode") &&
                     meta::ApiInformation::IsPropertyPresent(L"Windows.Graphics.Capture.Direct3D11CaptureFrame", L"DirtyRegions");
    } catch (...) { g_dirtyApi = false; }
    if (!InitD3D())      return 3;

    // THE TEST SWITCHES (g_dirtyModeOn, g_minUpdateMs), read ONCE at start from HKLM\SOFTWARE\Qubes\GuiAgent.
    {
        HKEY k = nullptr;
        if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE\\Qubes\\GuiAgent", 0, KEY_READ, &k) == ERROR_SUCCESS) {
            DWORD dm = 1, cbdm = sizeof(dm), tydm = 0;
            if (RegQueryValueExW(k, L"QubesWgcDirtyMode", nullptr, &tydm, (BYTE*)&dm, &cbdm) == ERROR_SUCCESS && tydm == REG_DWORD && dm == 0)
                g_dirtyModeOn = false;
            DWORD mu = 0, cbmu = sizeof(mu), tymu = 0;
            if (RegQueryValueExW(k, L"QubesWgcMinUpdateMs", nullptr, &tymu, (BYTE*)&mu, &cbmu) == ERROR_SUCCESS && tymu == REG_DWORD)
                g_minUpdateMs = (LONG)mu;
            RegCloseKey(k);
        }
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
    // TELL THE AGENT WE ARE UP. Everything it reads on this wake is already published above - the pid its adoption
    // path keys on and the two events it handed us - and the ctl open above has already
    // refused if we cannot serve, so this never announces a broker that will not run. Without it the agent learned
    // we were up on whichever main-loop pass next ran BrokerSupervise: over 229 launch->ready pairs that was a
    // median of 4.85 s but a 31.33 s maximum, against the agent's 30 s "broker not ready" warning to the user.
    // Best effort, like --frame above: an older agent never created this event, OpenEventW then fails, and the
    // agent falls back to noticing us on its next pass, as it always did. The event is the agent's and auto-reset;
    // we set it once and have no further use for the handle.
    {
        std::wstring rn(shmName);
        if (rn.size() > 4 && rn.compare(rn.size() - 4, 4, L"_shm") == 0) {
            rn.replace(rn.size() - 4, 4, L"_ready");
            HANDLE hRdy = OpenEventW(EVENT_MODIFY_STATE, FALSE, rn.c_str());
            if (hRdy) { SetEvent(hRdy); CloseHandle(hRdy); }
        }
    }

    // REST-ZERO S4 wake sources. Everything the old 250 ms tick re-read is now an event or a deadline:
    //   * agent exit: g_agent in the wait below (unchanged); agent shutdown: the agent sets Shutdown AND signals g_hCtl;
    //   * console session: WM_WTSSESSION_CHANGE on a message-only window (the check below re-runs on that wake);
    //   * secure desktop: EVENT_SYSTEM_DESKTOPSWITCH refreshes Producing (the gate itself is live at every publish);
    //   * work armed off this thread (a publish arming R5, a signature going pending): g_hWake;
    //   * everything else this loop does answers a request, and each pending one arms its own deadline (Due).
    // There is no heartbeat either way: a heartbeat is a timer on both sides and detects only a hung peer; hangs are
    // request deadlines now (CtlAck for the agent's requests, R5 for the agent's answer to ours).
    g_hWake = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    if (!g_hWake) return 9;                  // without it a deadline armed off this thread is never seen: refuse
    // THE AGENT'S DEATH (rest-zero S4c). This process cannot open the SYSTEM agent for SYNCHRONIZE (its limited token
    // is denied), so g_agent is normally NULL; it used to exit on the agent's heartbeat going 10 s stale. The agent's
    // main thread OWNS a mutex named after the section (..._shm -> ..._alive) for its whole life: when the agent dies
    // the mutex is ABANDONED and this wait returns at once. Refuse to run without it - a broker that cannot tell its
    // agent died would serve a dead section until the next agent's launch killed it.
    HANDLE agentAlive = nullptr;
    {
        std::wstring an(shmName);
        if (an.size() > 4 && an.compare(an.size() - 4, 4, L"_shm") == 0) {
            an.replace(an.size() - 4, 4, L"_alive");
            agentAlive = OpenMutexW(SYNCHRONIZE, FALSE, an.c_str());
        }
    }
    if (!agentAlive && !g_agent) return 11;
    HWND msgWnd = nullptr;
    {
        WNDCLASSEXW wc{}; wc.cbSize = sizeof(wc); wc.lpfnWndProc = DefWindowProcW;
        wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = L"QubesWgcBrokerMsg";
        RegisterClassExW(&wc);
        msgWnd = CreateWindowExW(0, L"QubesWgcBrokerMsg", L"", 0, 0, 0, 0, 0, HWND_MESSAGE, nullptr,
                                 GetModuleHandleW(nullptr), nullptr);
        // A session change must reach this loop as a message; without the registration the check below would only run
        // on an unrelated wake, so a broker serving a console that left could linger. Refuse to run half-deaf.
        if (!msgWnd || !WTSRegisterSessionNotification(msgWnd, NOTIFY_FOR_THIS_SESSION)) return 10;
    }
    HWINEVENTHOOK deskHook = SetWinEventHook(EVENT_SYSTEM_DESKTOPSWITCH, EVENT_SYSTEM_DESKTOPSWITCH, nullptr,
        [](HWINEVENTHOOK, DWORD, HWND, LONG, LONG, DWORD, DWORD) { (void)LiveProducing(); },
        0, 0, WINEVENT_OUTOFCONTEXT);
    (void)deskHook;                          // optional: the publish gate is live regardless (LiveProducing)
    (void)LiveProducing();
    // READY. The agent's supervisor runs on every wake and takes our pid from the header (validated); this is the wake.
    SignalFramePublished();

    for (;;) {
        if (g_hdr->Shutdown) break;
        if (g_hdr->AgentPid && (DWORD)g_hdr->AgentPid != g_launcherPid) break;
        if (g_agent && WaitForSingleObject(g_agent, 0) == WAIT_OBJECT_0) break;
        if (WTSGetActiveConsoleSessionId() != g_mySession) break;
        g_hdr->BrokerStage = (LONG)(WGCBRK_STG_LOOP << 8);

        // INFINITE unless a pending request armed a deadline on the previous pass (g_nextDue, see Due).
        DWORD timeout = INFINITE;
        if (g_nextDue) {
            const ULONGLONG now = GetTickCount64();
            timeout = (g_nextDue > now) ? (DWORD)((g_nextDue - now) < 0x7FFFFFFFull ? (g_nextDue - now) : 0x7FFFFFFFull) : 0;
        }
        DWORD n = 0; HANDLE compact[4];
        if (g_hCtl) compact[n++] = g_hCtl;
        compact[n++] = g_hWake;
        const DWORD agentIdx = n;
        if (g_agent) compact[n++] = g_agent;
        const DWORD aliveIdx = n;
        if (agentAlive) compact[n++] = agentAlive;
        // THIS THREAD OWNS A WINDOW, SO IT MUST PUMP: the session notifications arrive as messages to msgWnd and the
        // desktop-switch hook is delivered through this queue. The wait wakes for them, and the queue is drained every
        // pass.
        DWORD wr = MsgWaitForMultipleObjects(n, compact, FALSE, timeout, QS_ALLINPUT);
        if (g_agent && wr == WAIT_OBJECT_0 + agentIdx) break; // agent exited
        if (agentAlive && (wr == WAIT_ABANDONED_0 + aliveIdx || wr == WAIT_OBJECT_0 + aliveIdx)) break;   // agent died
        {
            MSG msg;
            while (PeekMessageW(&msg, nullptr, 0, 0, PM_REMOVE)) {
                TranslateMessage(&msg);
                DispatchMessageW(&msg);
            }
        }
        g_nextDue = 0;           // every pending request re-arms its own deadline below
        Reconcile();
        RepublishRetained();   // after Reconcile: a slot whose window changed is closed by now
        FlushPendingSignatures();   // sign a burst's last frame once the burst is over
        CheckAgentDeadline();
    }
    for (int i = 0; i < WGCBRK_MAX_SLOTS; i++) if (g_ch[i].hwnd) CloseChannel(i);
    return 0;
}
