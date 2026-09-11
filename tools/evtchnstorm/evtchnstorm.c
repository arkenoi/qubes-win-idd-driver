/*
 * evtchnstorm - open and close Xen event channels from several threads as fast as the
 * guest allows.
 *
 * WHY. The "guest never came back" stall (findings/issues.md) is a phantom writer bit on a
 * xenbus hash-table bucket lock, planted when two event-channel CLOSES (or a close and the
 * table's free-DPC) collide on two CPUs. Every qrexec connection costs the guest one
 * event-channel open and one close, so the field trigger is qrexec churn; this tool is the
 * same churn with the transport removed, so a stock guest should wedge in minutes and a
 * guest carrying the fixed xenbus should not. That is the defect-reintroduced proof.
 *
 * usage: evtchnstorm [threads] [seconds] [remote-domain]     (defaults 4 300 0)
 *
 * Output: one progress line every 5 s and a final `=== RESULT === {json}` line. Exit 0 when
 * the run completed, 2 when xencontrol.dll or the xeniface device could not be opened.
 * A guest that wedges never prints the RESULT line - that absence IS the measurement, and
 * the harness reads the vCPU burn from dom0, not this output.
 */
#include <windows.h>
#include <stdio.h>
#include <stdlib.h>

typedef struct _XENCONTROL_CONTEXT *PXENCONTROL_CONTEXT;
typedef DWORD (*XcOpen_t)(void *Logger, PXENCONTROL_CONTEXT *Xc);
typedef void  (*XcClose_t)(PXENCONTROL_CONTEXT Xc);
typedef DWORD (*XcEvtchnOpenUnbound_t)(PXENCONTROL_CONTEXT Xc, USHORT RemoteDomain, HANDLE Event, BOOL Mask, ULONG *LocalPort);
typedef DWORD (*XcEvtchnClose_t)(PXENCONTROL_CONTEXT Xc, ULONG LocalPort);

static XcOpen_t               pXcOpen;
static XcClose_t              pXcClose;
static XcEvtchnOpenUnbound_t  pXcEvtchnOpenUnbound;
static XcEvtchnClose_t        pXcEvtchnClose;

static volatile LONG   g_stop;
static volatile LONG64 g_opens, g_closes, g_errors;
static USHORT          g_domain;

static HMODULE load_xencontrol(void)
{
    static const char *candidates[] = {
        "xencontrol.dll",
        "C:\\Program Files\\Qubes Tools\\bin\\xencontrol.dll",
        "C:\\Program Files\\Xen PV Drivers\\bin\\xencontrol.dll",
        "C:\\Program Files\\Qubes Tools\\xencontrol.dll",
        NULL
    };
    for (int i = 0; candidates[i]; i++) {
        HMODULE h = LoadLibraryA(candidates[i]);
        if (h) { printf("xencontrol: %s\n", candidates[i]); return h; }
    }
    return NULL;
}

static DWORD WINAPI worker(LPVOID arg)
{
    PXENCONTROL_CONTEXT xc = NULL;
    HANDLE ev;
    DWORD rc;
    (void)arg;

    rc = pXcOpen(NULL, &xc);
    if (rc != 0) { printf("XcOpen failed: %lu\n", rc); InterlockedIncrement64(&g_errors); return 2; }
    ev = CreateEventW(NULL, FALSE, FALSE, NULL);

    while (!g_stop) {
        ULONG port = 0;
        rc = pXcEvtchnOpenUnbound(xc, g_domain, ev, TRUE, &port);
        if (rc != 0) { InterlockedIncrement64(&g_errors); Sleep(1); continue; }
        InterlockedIncrement64(&g_opens);
        rc = pXcEvtchnClose(xc, port);
        if (rc != 0) InterlockedIncrement64(&g_errors);
        else InterlockedIncrement64(&g_closes);
    }
    CloseHandle(ev);
    pXcClose(xc);
    return 0;
}

int main(int argc, char **argv)
{
    int threads = argc > 1 ? atoi(argv[1]) : 4;
    int seconds = argc > 2 ? atoi(argv[2]) : 300;
    g_domain    = (USHORT)(argc > 3 ? atoi(argv[3]) : 0);
    if (threads < 1 || threads > 64 || seconds < 1) { fprintf(stderr, "usage: evtchnstorm [threads 1..64] [seconds] [remote-domain]\n"); return 1; }

    HMODULE h = load_xencontrol();
    if (!h) { printf("=== RESULT === {\"ok\":false,\"error\":\"xencontrol.dll not found\"}\n"); return 2; }
    pXcOpen = (XcOpen_t)GetProcAddress(h, "XcOpen");
    pXcClose = (XcClose_t)GetProcAddress(h, "XcClose");
    pXcEvtchnOpenUnbound = (XcEvtchnOpenUnbound_t)GetProcAddress(h, "XcEvtchnOpenUnbound");
    pXcEvtchnClose = (XcEvtchnClose_t)GetProcAddress(h, "XcEvtchnClose");
    if (!pXcOpen || !pXcClose || !pXcEvtchnOpenUnbound || !pXcEvtchnClose) {
        printf("=== RESULT === {\"ok\":false,\"error\":\"xencontrol exports missing\"}\n"); return 2;
    }

    /* Prove the device opens once before spawning the storm: an unopenable xeniface would
     * otherwise read as "no wedge" for the whole duration. */
    {
        PXENCONTROL_CONTEXT xc = NULL; ULONG port = 0; HANDLE ev = CreateEventW(NULL, FALSE, FALSE, NULL);
        DWORD rc = pXcOpen(NULL, &xc);
        if (rc != 0) { printf("=== RESULT === {\"ok\":false,\"error\":\"XcOpen %lu\"}\n", rc); return 2; }
        rc = pXcEvtchnOpenUnbound(xc, g_domain, ev, TRUE, &port);
        if (rc != 0) { printf("=== RESULT === {\"ok\":false,\"error\":\"XcEvtchnOpenUnbound %lu\"}\n", rc); return 2; }
        pXcEvtchnClose(xc, port); pXcClose(xc); CloseHandle(ev);
        printf("probe: open/close of one channel to domain %u ok (port %lu)\n", g_domain, port);
    }

    HANDLE *th = (HANDLE *)calloc((size_t)threads, sizeof(HANDLE));
    for (int i = 0; i < threads; i++) th[i] = CreateThread(NULL, 0, worker, NULL, 0, NULL);

    ULONGLONG t0 = GetTickCount64(); LONG64 last = 0;
    while ((GetTickCount64() - t0) < (ULONGLONG)seconds * 1000ULL) {
        Sleep(5000);
        LONG64 c = g_closes;
        printf("t=%4llus opens=%lld closes=%lld errors=%lld rate=%lld/s\n",
               (GetTickCount64() - t0) / 1000ULL, (long long)g_opens, (long long)c, (long long)g_errors, (long long)((c - last) / 5));
        fflush(stdout);
        last = c;
    }
    InterlockedExchange(&g_stop, 1);
    WaitForMultipleObjects((DWORD)threads, th, TRUE, 30000);
    printf("=== RESULT === {\"ok\":true,\"threads\":%d,\"seconds\":%d,\"domain\":%u,\"opens\":%lld,\"closes\":%lld,\"errors\":%lld}\n",
           threads, seconds, g_domain, (long long)g_opens, (long long)g_closes, (long long)g_errors);
    return 0;
}
