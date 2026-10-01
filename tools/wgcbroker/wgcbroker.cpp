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
#include <dwmapi.h>
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

// ABI 12 frame signature - defined further down (it needs g_slots), used by the WGC publish path
// above that definition. Declared here so the call site compiles.
static void PublishSignature(int i, const BYTE* buf, int w, int h);
#include <intrin.h>
#include <vector>

#pragma comment(lib, "d3d11.lib")
#pragma comment(lib, "dxgi.lib")
#pragma comment(lib, "dwmapi.lib")
#pragma comment(lib, "wtsapi32.lib")
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
#ifndef WGCBRK_FAULT_INJECTION
#define WGCBRK_FAULT_INJECTION 0
#endif
#if WGCBRK_FAULT_INJECTION
// TEST BUILDS ONLY (qwt-full fault_injection=true; a release broker has none of this). rest-zero M7's deaf-session test:
// every WGC arrival of the window whose HWND (hex) is written in C:\Users\Public\qwt-fi-deaf-hwnd.txt is dropped before
// the broker counts it as delivered - so its quiet test sees a session that stopped delivering, recreates it, sees the
// fresh one deliver nothing, and declares DEAF (QGAWGCRECREATE, then QGAWGCDEAF in the agent's log). Re-read at most twice
// a second, and only when an arrival asks (no timer). Arrivals of different slots run on different WGC threadpool threads
// under different locks: one caller wins the refresh, the others return the last value it published.
static HWND FiDeafHwnd() {
    static volatile LONG64 at = 0; static HWND volatile h = nullptr;
    const LONG64 now = (LONG64)GetTickCount64(), last = at;
    if (now - last >= 500 && _InterlockedCompareExchange64(&at, now, last) == last) {
        HWND v = nullptr;
        if (FILE* f = _wfopen(L"C:\\Users\\Public\\qwt-fi-deaf-hwnd.txt", L"r")) {
            unsigned long long x = 0;
            if (fscanf_s(f, "%llx", &x) == 1) v = (HWND)(ULONG_PTR)x;
            fclose(f);
        }
        h = v;
    }
    return h;
}
#endif
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
    // Last PrintWindow render: the poke coalescing interval runs from here (a deadline, never a tick).
    ULONGLONG pwLastTick = 0;
    // REST-ZERO S3: a PrintWindow slot renders on open and on its own pokes ONLY - the staleness backstop, its adaptive
    // backoff and the futile-poke stretch are gone with the timer they tuned. What stays bounded is the FIRST frame: a
    // popup rendered before it painted comes back black (FAILED, 0x103) and its own paint may land inside the pass whose
    // damage the agent attributes to its appearance, so the open is retried on a short schedule (WGCBRK_PW_FIRST_MS)
    // until one render publishes - a request deadline (R2), armed by the open and ended by the frame or the schedule.
    int       pwTries = 0;
    // BEHAVIOURAL DETECTION. When this WGC channel opened, and when it last delivered a frame.
    // A visible window whose feed has been silent since it opened is one WGC is not serving.
    ULONGLONG openTick = 0;
    ULONGLONG lastArrivalTick = 0;
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
    // When the broker first saw damage that no frame has answered yet (0 = none pending). The quiet test times the
    // silence from HERE, not from the last arrival - see the pending-damage tracker in Reconcile.
    ULONGLONG   pokePendingSince = 0;
    HWND        relayDest  = nullptr;   // the window we own that carries the thumbnail
    HTHUMBNAIL  relayThumb = nullptr;
    bool        relay      = false;     // this channel captures relayDest, not c.hwnd
    int         relayW = 0, relayH = 0; // relayDest's size = the thumbnail source size when it was opened
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
// These two MUST outlive a channel. CloseChannel does `c = Channel{}`, so anything kept in the
// Channel is erased by the very close that precedes a re-open - measured 2026-09-25: forcePw was
// set, then wiped by CloseChannel, so the re-route reopened on WGC and did nothing, the probe
// never ran (probeBounces stayed 0) and the hysteresis never applied, leaving an idle window's
// channel closed and reopened every quiet period for ever - 38 times on a window whose feed was
// perfectly healthy. Per-slot, not per-channel.
static bool      g_forcePw[WGCBRK_MAX_SLOTS]      = {};
// A RELAY THAT WENT QUIET MUST BE ABLE TO REACH PRINTWINDOW. The quiet re-route sets g_forcePw and
// reopens, but g_forcePw only means "do not try WGC on the window itself" - the reopen then chose the
// RELAY again, so a relay delivering nothing looped back onto itself for ever and the polled fallback
// was unreachable. This veto is what lets the ladder finish: WGC -> relay -> PrintWindow.
// Set AFTER CloseChannel, never before: CloseChannel wipes the Channel, which is exactly how the
// earlier g_forcePw assignment got erased and cost 38 needless re-routes on a healthy window.
static bool      g_noRelay[WGCBRK_MAX_SLOTS] = {};
// A RELAY DESTINATION IS SIZED ONCE (2026-09-30). RelayOpenDest sizes it to the thumbnail source size at open, and
// DWM draws the source scaled into it. When the source window later changes size, the agent retargets the card (a
// new ControlSeq) but the destination never followed: a LARGER card can never be cut from it (PublishCard and the
// retained republish both refuse a card the capture does not cover, and a static window brings no arrival), and a
// smaller one would be cut from a scaled image. Measured on a German 25H2 cold boot: a relay window grew 346x233 ->
// 348x234 when its caption was restyled, the agent retargeted at once, and its frames were rejected for 16.4 s until
// the agent's stuck detector forced a full re-registration - whose re-open served the new size 3 ms later. So a relay
// whose thumbnail source size no longer equals its destination is re-opened through the ordinary Close/OpenChannel
// path. AT MOST ONCE PER (AGENT REQUEST, SOURCE SIZE): the ControlSeq and the live source size a size re-open was done
// for survive the close, so even if the open-time probe and the live thumbnail were ever to disagree about the size,
// this cannot re-open every pass - while a source that changes size AGAIN (with or without a new request) still is.
// SETTLED, NOT EVERY STEP: a drag-resize makes the agent retarget on every step, and re-opening per step would be the
// tear-down-and-rebuild-every-pass churn this file has paid for before. The new size must hold for
// RELAY_SIZE_SETTLE_MS (tracked below, across passes) before the re-open.
static LONG      g_relaySizeCtl[WGCBRK_MAX_SLOTS]      = {};
static bool      g_relaySizeCtlValid[WGCBRK_MAX_SLOTS] = {};
static LONG      g_relayReopenW[WGCBRK_MAX_SLOTS] = {}, g_relayReopenH[WGCBRK_MAX_SLOTS] = {};
static LONG      g_relaySeenW[WGCBRK_MAX_SLOTS] = {}, g_relaySeenH[WGCBRK_MAX_SLOTS] = {};
static ULONGLONG g_relaySeenTick[WGCBRK_MAX_SLOTS] = {};
#define RELAY_SIZE_SETTLE_MS 150
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
// The channel generation (WGCBRK_SLOT::ChanGen) whose capture item Windows CLOSED last, per slot; 0 = none. Written by the
// item.Closed handler (a WGC thread), read by Reconcile: a channel whose own item closed gets no trailing-poke absorption.
static volatile LONG g_closedGen[WGCBRK_MAX_SLOTS] = {};
// A CLOSED ITEM IS REPAIRED AT ONCE (2026-10-01): set when Reconcile reopened a channel because Windows closed its capture
// item; a reopened item that is closed again before it delivered anything goes DEAF instead (no loop). Cleared with the
// other per-registration flags.
static bool      g_closedReopened[WGCBRK_MAX_SLOTS] = {};

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

// A HUNG TARGET BLOCKS PrintWindow WITH NO TIMEOUT, and both PrintWindow calls run on this main loop - so
// one hung window stopped the heartbeat and the agent reaped the whole broker (QGABROKERDIED). Measured
// 2026-09-27: every death began within seconds of a window disappearing, DWM "Ghost" stand-ins for hung
// windows were in the same censuses, and moving the WGC teardown out of the slot lock changed nothing (Jev:
// PrintWindow into a hung window 0.98). IsHungAppWindow catches a window hung for >= 5 s; the WM_NULL probe
// one that is not answering right now, bounded to 100 ms. Unresponsive = skip this pass, counted in
// HungSkips: a window that stays hung costs one bounded probe per pass, never the loop.
static void WaitSameWindowTeardown(int i, HWND hwnd);   // defined with CloseChannel; used by OpenChannel

static bool WindowResponsive(int i, HWND hwnd) {
    StageScope st(WGCBRK_STG_PROBE, i);
    DWORD_PTR res = 0;
    if (!IsHungAppWindow(hwnd) &&
        SendMessageTimeoutW(hwnd, WM_NULL, 0, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK, 100, &res)) return true;
    InterlockedIncrement(&g_slots[i].HungSkips);
    return false;
}
// REST-ZERO (docs/DESIGN-rest-zero-capture.md C/D): the earliest deadline any pending request armed this pass; the main
// loop waits until then, or INFINITE when nothing is pending. Recomputed from state on every pass, so a deadline whose
// request was answered simply is not armed again - nothing to disarm, nothing that can leak into a rest wake.
static ULONGLONG g_nextDue = 0;
static inline void Due(ULONGLONG t) { if (t && (!g_nextDue || t < g_nextDue)) g_nextDue = t; }
// The first-frame retry schedule of a PrintWindow slot (ms after its open). Bounded: past the last try the slot waits
// for its own poke like any other.
static const ULONGLONG WGCBRK_PW_FIRST_MS[] = { 0, 50, 100, 200, 400 };
// DEAFNESS HOLD (rest-zero E). A slot whose WGC session stayed quiet, was recreated once and stayed quiet again goes
// FAILED with WGCBRK_E_DEAF and is held - not reopened - until the agent asks again (its ControlSeq moves). Reopening on
// the broker's own initiative would be a timed retry loop on a window nothing is changing.
static bool g_deafHold[WGCBRK_MAX_SLOTS] = {};
static LONG g_deafCtl[WGCBRK_MAX_SLOTS]  = {};
static void DeclareDeaf(int i) {
    WGCBRK_SLOT* s = &g_slots[i];
    s->FailHr = WGCBRK_E_DEAF;
    MemoryBarrier();                         // FailHr first: an agent that reads FAILED reads why
    s->AckState = WGCBRK_FAILED;
    InterlockedIncrement(&s->DeafHolds);
    g_deafHold[i] = true;
    g_deafCtl[i] = s->ControlSeq;
    SignalFramePublished();                  // wake the agent: it reports the hold (QGAWGCDEAF) on that wake
}
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

// THE RELAY CAPABILITY IS MEASURED, NOT ASSUMED (rest-zero G, c6 0.81). Build >= 26100 is necessary but not sufficient:
// 26100.1742 refuses a WS_EX_TOOLWINDOW / WS_EX_NOACTIVATE destination at CreateForWindow (E_INVALIDARG), so on that
// build every ladder descent paid a relay open that could not succeed. One destination-shaped window, one
// CreateForWindow, ONCE; the RESULT is what is latched (RelayUsable) and published.
// MEASURED AT THE FIRST LADDER DESCENT, NOT AT PROCESS START (a deviation from G's "at broker start", for the reason G
// could not see): the agent tells a broker window from a user window only by the broker's VALIDATED pid, which it takes
// after this process has published it - and a destination-shaped window from an unvalidated broker is an ordinary
// window to it (measured 2026-09-26: a probe's destinations were accepted, given a slot and MAPPED to dom0). By the
// first descent the agent has registered windows with this broker, so it has validated it.
static int g_relayProbe = -1;   // -1 not measured yet, 0 refused, 1 capturable
static bool RelayDestCapturable();
static bool RelayUsable() {
    if (!g_RelayOn) return false;
    if (g_relayProbe < 0) {
        g_relayProbe = RelayDestCapturable() ? 1 : 0;
        if (!g_relayProbe) g_RelayOn = false;
        g_hdr->RelayCapable = g_relayProbe ? 1 : 2;   // 1 on, 0 off by build/opt-out, 2 eligible but the probe refused
    }
    return g_relayProbe == 1;
}
static bool RelayDestCapturable() {
    WNDCLASSEXW wc{}; wc.cbSize = sizeof(wc); wc.lpfnWndProc = DefWindowProcW;
    wc.hInstance = GetModuleHandleW(nullptr); wc.lpszClassName = L"QubesWgcRelayProbe";
    wc.hbrBackground = (HBRUSH)GetStockObject(BLACK_BRUSH);
    RegisterClassExW(&wc);
    HWND d = CreateWindowExW(WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_TRANSPARENT,
                             L"QubesWgcRelayProbe", L"", WS_POPUP, 0, 0, 64, 64,
                             nullptr, nullptr, GetModuleHandleW(nullptr), nullptr);
    if (!d) return false;
    SetLayeredWindowAttributes(d, 0, 0, LWA_ALPHA);   // exactly RelayOpenDest's destination
    ShowWindow(d, SW_SHOWNA);
    bool ok = false;
    try {
        auto interop = get_activation_factory<GraphicsCaptureItem, IGraphicsCaptureItemInterop>();
        GraphicsCaptureItem item{ nullptr };
        check_hresult(interop->CreateForWindow(d, guid_of<GraphicsCaptureItem>(),
                      reinterpret_cast<void**>(put_abi(item))));
        ok = (item != nullptr);
    } catch (...) { ok = false; }
    DestroyWindow(d);
    return ok;
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
        auto copyRect = [&](const RECT& k) {
            const size_t rb = (size_t)(k.right - k.left) * 4;
            for (int y = k.top; y < k.bottom; y++)
                memcpy(dst + (size_t)y * w * 4 + (size_t)k.left * 4, src + (size_t)y * map.RowPitch + (size_t)k.left * 4, rb);
            bytes += (LONGLONG)rb * (k.bottom - k.top);
        };
        for (const RECT& k : ch.prevRegs) copyRect(k);   // the spare holds the frame before the active one
        for (const RECT& k : cur) copyRect(k);
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
        StageScope st(WGCBRK_STG_REPUBLISH, i);
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
// TEST SWITCHES for the typing-latency regression (2026-10-01: key -> damage p90 ~190-200 ms from the build that brought
// DirtyRegionMode, against ~20 ms before it; bisected to that range). Read ONCE at start like QubesWgcRelay, never again:
//   QubesWgcDirtyMode = 0     direct sessions are NOT put in DirtyRegionMode (whole frames, as before S1b)
//   QubesWgcMinUpdateMs = N   GraphicsCaptureSession.MinUpdateInterval = N ms on every direct session (absent: left alone)
// Not product settings; absent = the shipped behaviour.
static bool g_dirtyModeOn = true;
static LONG g_minUpdateMs = -1;
static bool g_minUpdateApi = false;

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
    if (!WindowResponsive(i, hwnd)) return SRC_UNMEASURED;   // hung: PrintWindow would block this loop
    BOOL pwOk;
    { StageScope st(WGCBRK_STG_SRC_PW, i); pwOk = PrintWindow(hwnd, c.pwDC, PW_RENDERFULLCONTENT); }
    if (!pwOk) {
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
// How long after a frame arrived a poke still belongs to it (see the trailing-poke absorption in Reconcile): the agent
// pokes from its desktop-duplication pass, tens of milliseconds behind WGC; 500 ms is an order of magnitude of margin
// and still far inside WGCBRK_WGC_QUIET_MS, so a change that really went undelivered is caught one poke later.
#define WGCBRK_POKE_TRAIL_MS 500

static bool RelaySrcDecides(int i) {
    Channel& c = g_ch[i];
    const bool hadBaseline = c.srcHashSeen;   // the first test only records one and reports SAME
    const int r = RelaySourceChanged(i);
    if (r == SRC_SAME) {
        c.srcChangeStreak = 0;
        InterlockedIncrement(&g_slots[i].RelayStaticHolds);
        // A MEASURED SAME ANSWERS THE POKE (rest-zero S3). The damage that poked this relay was not its source's: left
        // pending, the quiet test asked again at every throttle interval - a PrintWindow of the source every 0.5-8 s for
        // as long as nothing changed, which is a timed render at rest. A baseline is not a measurement, so it answers
        // nothing: the test after it does. Under the lock FrameArrived writes these with.
        if (hadBaseline) {
            PubLock lk(i);
            c.pokeAtLastArrival = g_slots[i].PokeSeq;
            c.pokePendingSince = 0;
        }
        return false;
    }
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

static bool PublishPrintWindow(int i) {
    bool changed = false;
    PubLock pubLock(i);   // RAII, same reason
    do {
        WGCBRK_SLOT* s = &g_slots[i];
        Channel& c = g_ch[i];
        if (!c.pw) break;
        if (s->ReqState != WGCBRK_REQUESTED && s->AckState != WGCBRK_ACTIVE) break;
        if (!LiveProducing()) break;                         // secure desktop: live check, see PublishFrame
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
        if (!WindowResponsive(i, hwnd)) break;               // hung: no publish this pass (polled anyway)
        BOOL pwOk;
        { StageScope st(WGCBRK_STG_POLL_PW, i); pwOk = PrintWindow(hwnd, c.pwDC, PW_RENDERFULLCONTENT); }
        if (!pwOk) break;
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
    if (!monitor && (!hwnd || !IsWindow(hwnd))) { s->AckState = WGCBRK_FAILED; s->FailHr = E_HANDLE; return; }
    // A UWP-STYLE FRAME IS CAPTURED ON THE WINDOW ITSELF, like any other window (2026-09-30). Until now a window whose
    // content comes from a child in ANOTHER process (ApplicationFrameWindow + its CoreWindow) was routed up front to the
    // relay and, when that failed, to polled PrintWindow, on the 2026-09-25 reading that a WGC session on such a frame
    // "delivers a couple of frames and then nothing". That reading was taken on a Settings window nobody was changing.
    // Measured 2026-09-30 on w11-ds (26100.1742) with our agent and broker STOPPED, so no render of ours was involved: a
    // direct session on the Settings frame returns the full page (126-130 colours, 13933/13936 samples non-black),
    // delivers `1 0 0 0 0 0 0 0 0 0` frames/s left alone, and bursts of 17-22 right after each navigation when driven.
    // The frame is an ordinary WGC target, and the up-front re-route took its arrival-driven path away: on 26100.1742 the
    // relay cannot even open (that build refuses a WS_EX_TOOLWINDOW or WS_EX_NOACTIVATE destination), so Settings sat on
    // the polled route, re-rendered on its own UI thread up to ten times a second. A window WGC genuinely does not serve is
    // still caught - by the behavioural ladder in Reconcile (quiet while the agent says it changed: one fresh session,
    // then the relay, then PrintWindow), which keys on the symptom rather than on a shape.
    c.openTick = GetTickCount64();
    c.lastArrivalTick = 0;
    // Set only by that ladder: this window has already been found not to be served by a session on itself.
    const bool fallback = g_forcePw[i];
    g_forcePw[i] = false;
    // THE RELAY IS TRIED WHERE THE PRINTWINDOW FALLBACK WOULD BE USED, and nowhere else. The ladder has
    // found that a session on this slot's window does not serve it, so instead of dropping to a polled pull
    // API we give DWM a destination we own and capture that - arrival-driven, like any other WGC channel.
    // Routing is otherwise UNCHANGED: a window WGC can capture directly still is. Jev put this as
    // the first step at 0.98 precisely because it replaces a path rather than displacing one.
    HWND target = hwnd;
    const bool relayVetoed = g_noRelay[i];
    g_noRelay[i] = false;            // one-shot, same discipline as g_forcePw
    if (fallback && g_RelayOn && !relayVetoed && !monitor && hwnd) {
        int rw = 0, rh = 0; HTHUMBNAIL th = nullptr;
        HWND dest;
        { StageScope st(WGCBRK_STG_RELAY_DWM, i); dest = RelayOpenDest(hwnd, &th, &rw, &rh); }
        if (dest) {
            c.relayDest = dest; c.relayThumb = th; c.relay = true;
            c.relayW = rw; c.relayH = rh;
            target = dest;
            s->RelayOk++; s->RelayDest = (UINT64)(ULONG_PTR)dest;
        } else {
            s->RelayFail++;
        }
    }
    // NO PRINTWINDOW RUNG (rest-zero E/G, c2 0.05). Below a fresh WGC session the ladder's only rungs are the relay - where
    // the probe (RelayUsable) showed its destination can be captured - and the deaf hold. A ladder open whose relay did not
    // open is DEAF: FAILED + WGCBRK_E_DEAF, held until the agent asks again, never a polled PrintWindow.
    if (fallback && !c.relay) { DeclareDeaf(i); return; }
    if (!fallback || c.relay) try {
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
        // DIRTY REGIONS (rest-zero S1) on a direct window session only: the relay's destination and the monitor keep the
        // whole-frame path. ReportOnly: complete surfaces, regions reported; PublishFrame reads only the regions.
        if (g_dirtyApi && !monitor && !c.relay) {
            if (g_dirtyModeOn) { try { session.DirtyRegionMode(GraphicsCaptureDirtyRegionMode::ReportOnly); c.dirty = true; } catch (...) {} }
            if (g_minUpdateApi && g_minUpdateMs >= 0) {
                try { session.MinUpdateInterval(winrt::Windows::Foundation::TimeSpan{ std::chrono::milliseconds(g_minUpdateMs) }); } catch (...) {}
            }
        }
        c.hwnd = monitor ? (HWND)(ULONG_PTR)WGCBRK_MONITOR_HWND : hwnd;
        c.item = item; c.pool = pool; c.session = session; c.slot = i;
        // OBSERVATION ONLY. WGC can CLOSE a capture item, after which FrameArrived never fires again for
        // that session - and until now nothing here subscribed, so that state looked exactly like a
        // window whose content had stopped changing. Measured 2026-09-27: a deaf relay channel whose
        // destination a FRESH session (another process) captured fine, every second, with the source's
        // own content. This records whether Closed is what happened, and changes nothing: Jev put
        // observe-first at 0.96 and any repair in the same build at 0.00.
        // The generation this channel will have once the open completes (ChanGen is bumped at the end of this try, and
        // only on this main thread): the Closed handler records it, so a Closed that belongs to an EARLIER item - its
        // teardown runs on another thread and can end after this open - is never taken for this channel's.
        const LONG closeGen = g_slots[i].ChanGen + 1;
        c.closedRev = item.Closed(auto_revoke, [i, closeGen](auto const&, auto const&) {
            InterlockedIncrement(&g_slots[i].ItemClosed);
            g_slots[i].ItemClosedTick = (LONGLONG)GetTickCount64();
            InterlockedExchange(&g_closedGen[i], closeGen);
            if (g_hWake) SetEvent(g_hWake);   // the repair is Reconcile's, now - not at the next poke (see g_closedReopened)
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
#if WGCBRK_FAULT_INJECTION
                if (g_ch[i].hwnd && g_ch[i].hwnd == FiDeafHwnd()) {   // the injected deaf session (test builds only)
                    auto dropped = sender.TryGetNextFrame();          // released, so the pool keeps delivering
                    // In a test build ArrivalRejected also counts these drops; the deaf test reads QuietReroutes/DeafHolds
                    // and the agent's QGAWGCRECREATE/QGAWGCDEAF lines, timed against when the harness armed the knob.
                    _InterlockedIncrement(&g_slots[i].ArrivalRejected);
                    return;
                }
#endif
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
                    ch.needWhole = true;                 // this arrival's regions never reach lastFull (rest-zero S1)
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
    if (fallback) { DeclareDeaf(i); return; }   // a ladder open (the relay's capture failed): no PrintWindow rung, see above
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

// EVERYTHING A CLOSED WGC CHANNEL STILL OWNS, torn down OFF THE MAIN LOOP. Measured 2026-09-27 (build
// 3be5415, win11de-v7): with PrintWindow no longer able to hang the loop (the guard fired ~90 times in one
// census), the two remaining broker deaths were both named by BrokerStage as close-channel, one on a slot
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
    if (c.pwBmp)   { DeleteObject(c.pwBmp); }
    if (c.pwDC)    { DeleteDC(c.pwDC); }
    // The relay's destination is a real top-level window and its thumbnail is a DWM handle; `c =
    // Channel{}` below would forget both and leak them for the broker's lifetime. Released BEFORE
    // the struct is wiped, for the same reason g_forcePw had to be set after it (that assignment
    // erased state the re-route depended on and cost 38 needless re-routes on a healthy window).
    { StageScope st(WGCBRK_STG_RELAY_DWM, i); RelayCloseDest(c); }
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
    if (!d->session && !d->pool && !d->item && !d->lastFull) return;   // PrintWindow channel: nothing to reap
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

// True when the relay on slot i should be re-opened because its thumbnail source no longer has the destination's
// size (see g_relaySizeCtl). Main thread only: the thumbnail was registered here, in OpenChannel.
static bool RelayOutgrown(int i, const Channel& c, const WGCBRK_SLOT* s, SIZE* live) {
    SIZE q{};
    if (FAILED(DwmQueryThumbnailSourceSize(c.relayThumb, &q)) || q.cx <= 0 || q.cy <= 0) return false;
    if (q.cx == c.relayW && q.cy == c.relayH) { g_relaySeenTick[i] = 0; return false; }   // in step
    if (g_relaySizeCtlValid[i] && g_relaySizeCtl[i] == s->ControlSeq &&
        q.cx == g_relayReopenW[i] && q.cy == g_relayReopenH[i]) return false;              // done for this request+size
    *live = q;
    const ULONGLONG now = GetTickCount64();
    if (!g_relaySeenTick[i] || q.cx != g_relaySeenW[i] || q.cy != g_relaySeenH[i]) {    // a new size: start its clock
        g_relaySeenW[i] = q.cx; g_relaySeenH[i] = q.cy; g_relaySeenTick[i] = now;
        return false;
    }
    return now - g_relaySeenTick[i] >= RELAY_SIZE_SETTLE_MS;                             // settled: re-open
}

static void Reconcile() {
    StageScope stage(WGCBRK_STG_RECONCILE, 0);
    for (int i = 0; i < WGCBRK_MAX_SLOTS; i++) {
        WGCBRK_SLOT* s = &g_slots[i];
        // R1/R4 (rest-zero D): the request this pass answers, acknowledged in CtlAck once the slot has been handled below.
        InterlockedIncrement(&g_hdr->BrokerProgress);
        const LONG ctl0 = s->ControlSeq;
        MemoryBarrier();
        HWND want = (HWND)(ULONG_PTR)s->Hwnd;
        if (g_deafHold[i] && ctl0 != g_deafCtl[i]) g_deafHold[i] = false;   // the agent asked again: one more ladder
        bool wantOpen = (s->ReqState == WGCBRK_REQUESTED) && want && !g_deafHold[i];
        Channel& c = g_ch[i];
        // PENDING DAMAGE, TIMED FROM THE POKE (2026-09-30). The quiet test below demotes a channel when damage has gone
        // unanswered by a frame. It used to time that silence from the LAST ARRIVAL - so on a window that had been still
        // for 2 s the very first poke of its next change satisfied "damage, and 2 s without a frame" at once, before WGC
        // had had tens of milliseconds to deliver that change. Traced every 50 ms on w11-ds (26100.1742), Settings on
        // plain WGC: both re-routes of each round fired in the SAME sample as the first poke after >= 2.1 s of stillness,
        // on a session that went on to deliver 26 frames in between; that explains all 12 demotions of 12 driven runs.
        // So the broker notes when it first sees a poke no frame has answered (pokePendingSince), and the quiet test
        // times from there. Two refinements, both measured:
        //   * a poke first seen within WGCBRK_POKE_TRAIL_MS of an arrival is THAT arrival's - the agent pokes from its
        //     desktop-duplication pass, tens of milliseconds behind WGC, so a delivered change's poke can land after it;
        //   * except on a channel whose own capture item Windows CLOSED (the first item on a UWP frame closed as the app
        //     launched, `ITEM closed=1`): a closed item delivers nothing more, so its pokes are always pending.
        // A separate statement ahead of the chain - it changes no routing itself, only what the quiet test sees - and
        // under the slot's PubLock, because the FrameArrived handler writes pokeAtLastArrival/lastArrivalTick under it.
        if (wantOpen && c.hwnd == want && !c.pw) {
            PubLock pend(i);
            const LONG pk = g_slots[i].PokeSeq;
            const ULONGLONG nowP = GetTickCount64();
            if (pk == c.pokeAtLastArrival)
                c.pokePendingSince = 0;                               // every poke is answered by a frame
            else if (g_closedGen[i] != g_slots[i].ChanGen && c.lastArrivalTick &&
                     nowP - c.lastArrivalTick < WGCBRK_POKE_TRAIL_MS) {
                c.pokeAtLastArrival = pk;                             // it trails a frame: that frame's
                c.pokePendingSince = 0;
            }
            else if (!c.pokePendingSince)
                c.pokePendingSince = nowP;                            // the first unanswered poke
        }
        if (wantOpen && c.hwnd != want) { if (c.hwnd) CloseChannel(i); g_relayReopened[i] = false; g_wgcReopened[i] = false; g_closedReopened[i] = false; g_relaySizeCtlValid[i] = false; g_relaySeenTick[i] = 0; OpenChannel(i); }
        else if (!wantOpen && c.hwnd)   { CloseChannel(i); g_relayReopened[i] = false; g_wgcReopened[i] = false; g_closedReopened[i] = false; g_relaySizeCtlValid[i] = false; g_relaySeenTick[i] = 0; }
        // WINDOWS CLOSED THIS SESSION'S CAPTURE ITEM: reopen at once. Observed first (2026-09-30, Jev 0.96 observe-first) and
        // now measured: on 26100.1742 a UWP app's first item is closed as it launches - Settings (2026-09-30) and Calculator
        // (rz8, 2026-10-01: 3 frames, the splash, then ITEM closed=1) - and a closed item delivers nothing more, so the window
        // stayed on its splash in dom0 until something poked it (the owner watched Calculator do it for a minute, and found its
        // first menu render slow). The Closed handler wakes this loop; the reopen costs one session. A reopened item closed
        // again before it delivered anything is not reopened again: DEAF, loud (Jev: repair now 0.99, loop risk bounded 0.30).
        else if (wantOpen && c.hwnd == want && !c.pw && !c.relay && g_closedGen[i] == g_slots[i].ChanGen &&
                 IsWindow(want) && IsWindowVisible(want) && !IsIconic(want)) {
            const bool delivered = (c.lastArrivalTick != 0);
            g_slots[i].Reroutes++;
            CloseChannel(i);          // wipes the Channel - survivors are set after it
            if (g_closedReopened[i] && !delivered)
                DeclareDeaf(i);
            else { g_closedReopened[i] = true; g_forcePw[i] = false; OpenChannel(i); }
        }
        else if (SIZE live{}; wantOpen && c.hwnd == want && c.relay && c.relayThumb && RelayOutgrown(i, c, s, &live)) {
            g_slots[i].Reroutes++;                          // visible in the peek; RelayOk counts the re-open
            const LONG ctl = s->ControlSeq;
            CloseChannel(i);                                // wipes the Channel - survivors are set after it
            g_relaySizeCtl[i] = ctl; g_relaySizeCtlValid[i] = true; g_relaySeenTick[i] = 0;
            g_relayReopenW[i] = live.cx; g_relayReopenH[i] = live.cy;
            g_forcePw[i] = true;                            // OpenChannel tries the relay where PrintWindow would be
            OpenChannel(i);
        }
        else if (wantOpen && c.hwnd == want && !c.pw &&
                 IsWindow(want) && IsWindowVisible(want) && !IsIconic(want) &&
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
                 // R2: THIS session has delivered nothing (lastArrivalTick is per channel; FramesArrived is cumulative
                 // across every session the slot ever had, so a recreated session inherited the first one's frames).
                 (c.lastArrivalTick == 0 ||
                  (c.pokePendingSince && GetTickCount64() - c.pokePendingSince >= WGCBRK_WGC_QUIET_MS &&
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
            // A SESSION THAT DELIVERED IS NOT DEAF. This one produced at least its StartCapture frame, so WGC does serve
            // this window; an unanswered poke after that is either a false poke (DWM recomposed the window's area without
            // its content changing - DDA's dirty rects are coarser than a window's own change) or a session that stopped
            // delivering. Either way a fresh session costs one open and one current frame, and freezing the window would
            // cost its content for as long as it lives. So the deaf hold is reserved for a FRESH session that delivered
            // nothing at all; each recreate is counted (QuietReroutes) and reported by the agent (QGAWGCRECREATE).
            const bool delivered = (c.lastArrivalTick != 0);
            CloseChannel(i);          // wipes the Channel - so set the survivors AFTER it
            // THE LADDER ON 26100+ (rest-zero E, c2). A quiet plain-WGC channel gets ONE fresh plain-WGC session
            // (g_wgcReopened); then the relay, only where the probe showed its destination can be captured
            // (RelayUsable, G), with one re-open of its own (its session is what dies after a cold boot - see
            // g_relayReopened); past that the window is DEAF: FAILED + WGCBRK_E_DEAF, held until the agent asks again
            // (DeclareDeaf). The PrintWindow rung and its probe are gone - a polled render was the last rung, and on a
            // window that is merely static it rendered for ever (c2: 0.05).
            if (wasPlainWgc && (!g_wgcReopened[i] || delivered)) { g_wgcReopened[i] = true; g_forcePw[i] = false; OpenChannel(i); }
            else if (wasPlainWgc && RelayUsable())     { g_forcePw[i] = true; OpenChannel(i); }   // the relay, or deaf
            else if (wasRelay && (!g_relayReopened[i] || delivered)) { g_relayReopened[i] = true; g_forcePw[i] = true; OpenChannel(i); }
            else                                       DeclareDeaf(i);
        }
        // THE NEXT MOMENT THIS SLOT'S ANSWER CAN CHANGE WITHOUT A NEW REQUEST (rest-zero D) - armed only while something
        // is owed: a first frame (R2), an unanswered poke (R3), a throttled relay source test, a relay size settling. At
        // rest none of these hold, so nothing is armed and the loop sleeps until an event.
        {
            const Channel& n = g_ch[i];
            if (wantOpen && n.hwnd == want && !n.pw && !(n.relay && g_relayNoDemote) &&
                IsWindow(want) && IsWindowVisible(want) && !IsIconic(want)) {
                const ULONGLONG since = n.lastArrivalTick ? n.lastArrivalTick : n.openTick;
                if (!n.lastArrivalTick)
                    Due(since + WGCBRK_WGC_QUIET_MS);                                                     // R2
                else if (n.pokePendingSince) {
                    ULONGLONG due = (n.pokePendingSince > since ? n.pokePendingSince : since) + WGCBRK_WGC_QUIET_MS; // R3
                    // A relay's quiet test also needs its source test, which is throttled: the deadline is the LATER of
                    // the two - the earlier one would wake this loop to a test that cannot run yet, every pass, until the
                    // throttle ends (a spin).
                    if (n.relay && n.srcHashSeen && n.srcHashTick + n.srcHashMs > due) due = n.srcHashTick + n.srcHashMs;
                    Due(due);
                }
            }
            if (wantOpen && n.hwnd == want && n.relay && g_relaySeenTick[i])
                Due(g_relaySeenTick[i] + RELAY_SIZE_SETTLE_MS);
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
#if WGCBRK_FAULT_INJECTION
            p(GetCurrentThread(), L"wgcbroker: main [FAULT-INJECTION build]");   // a test binary says so where it runs
#else
            p(GetCurrentThread(), L"wgcbroker: main");
#endif
    }
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
    try {
        namespace meta = winrt::Windows::Foundation::Metadata;
        g_minUpdateApi = meta::ApiInformation::IsPropertyPresent(L"Windows.Graphics.Capture.GraphicsCaptureSession", L"MinUpdateInterval");
        g_dirtyApi = meta::ApiInformation::IsPropertyPresent(L"Windows.Graphics.Capture.GraphicsCaptureSession", L"DirtyRegionMode") &&
                     meta::ApiInformation::IsPropertyPresent(L"Windows.Graphics.Capture.Direct3D11CaptureFrame", L"DirtyRegions");
    } catch (...) { g_dirtyApi = false; }
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
            DWORD dm = 1, cbdm = sizeof(dm), tydm = 0;
            if (RegQueryValueExW(k, L"QubesWgcDirtyMode", nullptr, &tydm, (BYTE*)&dm, &cbdm) == ERROR_SUCCESS && tydm == REG_DWORD && dm == 0)
                g_dirtyModeOn = false;
            DWORD mu = 0, cbmu = sizeof(mu), tymu = 0;
            if (RegQueryValueExW(k, L"QubesWgcMinUpdateMs", nullptr, &tymu, (BYTE*)&mu, &cbmu) == ERROR_SUCCESS && tymu == REG_DWORD)
                g_minUpdateMs = (LONG)mu;
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
    g_hdr->RelayCapable = g_RelayOn ? 1 : 0;   // 2 once RelayUsable's probe has refused (rest-zero G)
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
        // THIS THREAD OWNS WINDOWS, SO IT MUST PUMP. The relay's destination windows are created here,
        // and a window-owning thread that retrieves no messages for 5 s is HUNG by Windows' definition
        // (IsHungAppWindow): Windows ghosted every relay destination - a "Ghost"-class twin of the exact
        // size of each relayed window, which the agent then mapped and the broker relayed in turn
        // (measured 2026-09-27, win11de-v7: five relayed windows, five Ghosts, same sizes; every census
        // today had them) - and the owner's drag of an override-redirect window raised Windows' own
        // not-responding warning for the broker (Jev: ghosts are ours 0.94, the warning 0.88). The wait
        // also wakes for input (and now for the session and desktop-switch notifications), and the queue
        // is drained every pass.
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
        // Service PrintWindow-mode channels: ON OPEN AND ON THEIR OWN POKES, NOTHING ELSE (rest-zero S3).
        //
        // PrintWindow is not cheap and it is not ours to pay: it renders the full window
        // SYNCHRONOUSLY ON THE CAPTURED APPLICATION'S UI THREAD. Measured 2026-09-25 on the
        // Settings window, p50 31.7 ms (p90 38.9, max 53.3, n=40), against this loop's old fixed
        // 33 ms tick - about 43% of one core, for one window, whether or not anything changed.
        // Jev on those numbers: unacceptable-as-is 1.00, damage-driven-polling 0.87.
        //
        // The agent bumps PokeSeq when this window's own pixels changed and signals the control event.
        // The 1 s staleness backstop that used to render anyway (SafetyPolls), its adaptive backoff and the
        // futile-poke stretch are REMOVED: on a static desktop they were the broker's own timed renders, and a
        // Windows 11 window asked to render repaints - which is the next change (ADR-capture section 8, 14).
        // SafetyPolls stays as a counter and must read 0. Only o-r popups (menus) reach this route on 26100+:
        // WGC refuses them by rule, and the ladder no longer descends here.
        const ULONGLONG nowTick = GetTickCount64();
        for (int i = 0; i < WGCBRK_MAX_SLOTS; i++) {
            if (!g_ch[i].pw || !g_ch[i].hwnd) continue;
            WGCBRK_SLOT* ps = &g_slots[i];
            const LONG poke = ps->PokeSeq;
            const bool changed = (poke != ps->PokeAck);
            // THE FIRST FRAME IS OWED (R2): rendered at open, then on WGCBRK_PW_FIRST_MS until one render publishes.
            const bool owed = (ps->AckState != WGCBRK_ACTIVE) &&
                              g_ch[i].pwTries < (int)(sizeof(WGCBRK_PW_FIRST_MS) / sizeof(WGCBRK_PW_FIRST_MS[0]));
            if (!changed && !owed) continue;                  // REST: nothing asked, nothing rendered
            // VISIBILITY GATE. A window dom0 is not showing - minimised, or gone - is not worth
            // rendering at all; its own change (a restore paints it) pokes it again.
            if (!IsWindow(g_ch[i].hwnd) || !IsWindowVisible(g_ch[i].hwnd) || IsIconic(g_ch[i].hwnd)) {
                ps->PollsSkipped++;
                continue;
            }
            ULONGLONG notBefore = 0;
            if (owed && !changed)
                notBefore = g_ch[i].openTick + WGCBRK_PW_FIRST_MS[g_ch[i].pwTries];
            else if (g_ch[i].pwLastTick)
                // Coalesce: however many pokes arrived, render at most every WGCBRK_POKE_MIN_INTERVAL_MS -
                // a deadline for the rest of the interval, not a tick. The poke is not acknowledged meanwhile.
                notBefore = g_ch[i].pwLastTick + WGCBRK_POKE_MIN_INTERVAL_MS;
            if (nowTick < notBefore) { Due(notBefore); ps->PollsSkipped++; continue; }
            ps->PokeAck = poke;              // before rendering: damage during the render re-pokes
            g_ch[i].pwLastTick = nowTick;
            if (owed) g_ch[i].pwTries++;
            ps->PollsServiced++;
            (void)PublishPrintWindow(i);
            // Still owed after this try: the schedule's next step is a deadline.
            if (ps->AckState != WGCBRK_ACTIVE &&
                g_ch[i].pwTries < (int)(sizeof(WGCBRK_PW_FIRST_MS) / sizeof(WGCBRK_PW_FIRST_MS[0])))
                Due(g_ch[i].openTick + WGCBRK_PW_FIRST_MS[g_ch[i].pwTries]);
        }
        CheckAgentDeadline();
    }
    for (int i = 0; i < WGCBRK_MAX_SLOTS; i++) if (g_ch[i].hwnd) CloseChannel(i);
    return 0;
}
