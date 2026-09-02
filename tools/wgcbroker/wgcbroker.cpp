// wgcbroker - user-session WGC capture broker (SCAFFOLD).
//
// Runs in the interactive user session (spawned by the SYSTEM gui-agent via the
// SpawnHelperAsUser token-borrow pattern, main.c:1857), because WGC refuses to activate from
// the agent's SYSTEM context (IsSupported -> 0x80070424) but works from a user session
// (proven 2026-09-02, win11-p2/26100). It captures the "stranded" window classes the agent's
// PrintWindow engine cannot -- per-HWND for app/UWP/NRB/o-r-menu windows (CreateForWindow) and
// ONE monitor capture for shell CoreWindows / toasts (CreateForMonitor, sliced) -- and streams
// BGRA frames to the agent over cross-session shared memory. The agent copies those frames into
// the existing per-window granted buffers, replacing the DDA-slice source on Win11 24H2+.
//
// This is a SCAFFOLD: the real capture core (reuse tools/wgcprobe's proven CreateForWindow /
// CreateForMonitor / CreateFreeThreaded / staging-readback), the shared-memory IPC (control
// block + per-window slots + seqlock + heartbeat, SDDL for cross-session open), and the
// lifecycle (single-instance mutex, session-change exit, agent-heartbeat watchdog) land next,
// from DESIGN-wgc-broker.md. Kept minimal-but-compiling so the vcxproj + CI wiring are valid.
#define WIN32_LEAN_AND_MEAN
#define NOMINMAX
#include <windows.h>
#include <stdio.h>

int main(int, char**)
{
    setvbuf(stdout, nullptr, _IONBF, 0);
    printf("wgcbroker scaffold: not yet implemented (see DESIGN-wgc-broker.md)\n");
    return 0;
}
