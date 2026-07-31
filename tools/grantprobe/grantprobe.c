/*
 * grantprobe - guest-side probe for the grant budget / re-grant cost question
 * (SESSION-PLAN-per-window-capture.md Step 4 / DESIGN-QUESTIONS Q2).
 *
 * Measures, from inside the Windows guest, what XcGnttabPermitForeignAccess2 can
 * sustain when granting per-window-sized buffers:
 *
 *   grantprobe ceiling <domid> [maxwins]
 *       Allocate page-aligned buffers of representative window sizes, cycling
 *       {1280x720, 1920x1080, 3840x2160} at 4 bytes/px, and grant each read-only
 *       to <domid>, stepping until a grant fails or maxwins (default 64) are up.
 *       Prints per-grant latency (QueryPerformanceCounter, microseconds), the
 *       running page total, and on failure the failing Windows status + the
 *       ceiling reached. Then revokes everything, timing the revokes too.
 *
 *   grantprobe regrant <domid> <iters>
 *       Grant + revoke a single 1920x1080 buffer <iters> times; report p50/p95
 *       (and min/max/mean) for grant and revoke separately. This prices the
 *       window-resize path (revoke old size, grant new size).
 *
 * <domid> is the grant target domain. The gui-agent reads it from qubesdb
 * ("/qubes-gui-domain-xid", agent/gui-agent/main.c:2815 GetGuiDomainId) at
 * startup; this probe deliberately does NOT link qubesdb-client and takes the
 * id as an argument instead. The harness passes 0 (dom0, the GUI domain in the
 * default Qubes setup and on win-idd-test).
 *
 * The grant call matches agent/gui-agent/capture.c:528 exactly: same XcOpen
 * handle pattern (logger callback registered at open, capture.c:357), same
 * in-place grant of an existing VA, notifyOffset=0 / notifyPort=0 (ignored:
 * no XENIFACE_GNTTAB_USE_NOTIFY_* flag is set), flags=XENIFACE_GNTTAB_READONLY,
 * revoke via XcGnttabRevokeForeignAccess(xc, sharedAddress) (capture.c:246,419).
 *
 * HONEST LIMITATION: no dom0-side consumer ever maps these grants. The numbers
 * are the guest-side ceiling and guest-side grant/revoke latency only; the
 * dom0 mapping cost is a separate open item for the design writeup.
 *
 * SAFETY: this runs on a live guest that must stay healthy. Every exit path
 * revokes every grant it made: normal return, error paths, atexit, and a
 * console ctrl handler. Grants are NOT auto-revoked when the xeniface handle
 * closes (see the comment at agent/gui-agent/capture.c:417), so leaking one
 * means leaked locked pages until reboot.
 *
 * Output: human-readable lines, then "=== GRANTPROBE JSON ===" followed by
 * exactly one single-line JSON object (same convention as tools/ddaprobe).
 * Exit codes: 0 = probe completed (a discovered ceiling is a *successful*
 * measurement), 1 = probe could not run (XcOpen/alloc failure; JSON emitted
 * if the failure happened after argument parsing), 2 = bad arguments.
 *
 * Build: MSVC v143, /MT, plain C. Needs xencontrol.h + xeniface_ioctls.h and
 * the synthesized xencontrol.lib -- see grantprobe.vcxproj and README.md.
 * STATUS: UNCOMPILED on the dev qube (no MSVC on Linux).
 */

#define WIN32_LEAN_AND_MEAN
#include <windows.h>

#include <xencontrol.h>

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define PAGE_SIZE 0x1000 /* agent/include/common.h:24 */
#define ALIGN(x, a) (((x) + (a) - 1) & ~((a) - 1))
/* agent/gui-agent/capture.h:34 */
#define FRAMEBUFFER_PAGE_COUNT(width, height) \
    (ALIGN(((width) * (height) * 4), PAGE_SIZE) / PAGE_SIZE)

#define DEFAULT_MAXWINS 64
#define MAX_SLOTS 4096
#define MAX_ITERS 100000

typedef struct
{
    UINT width;
    UINT height;
} WINDOW_SIZE;

/* representative per-window buffer sizes, cycled in order */
static const WINDOW_SIZE g_sizes[] = {
    { 1280, 720 },
    { 1920, 1080 },
    { 3840, 2160 },
};
#define NUM_SIZES (sizeof(g_sizes) / sizeof(g_sizes[0]))

typedef struct
{
    PVOID buffer;        /* VirtualAlloc'd VA we asked to share */
    PVOID shared;        /* sharedAddress out-param; what revoke wants */
    ULONG pages;
    ULONG* refs;         /* grant references out array */
    BOOL granted;
    UINT size_index;     /* into g_sizes */
} GRANT_SLOT;

/* Global so the cleanup paths (atexit / ctrl handler) can reach everything. */
static PXENCONTROL_CONTEXT g_xc = NULL;
static GRANT_SLOT g_slots[MAX_SLOTS];
static size_t g_slot_count = 0;
static LONG g_cleaned = 0; /* interlocked once-guard */

static double g_qpc_to_us = 0.0;

static double Now(void)
{
    LARGE_INTEGER t;
    QueryPerformanceCounter(&t);
    return (double)t.QuadPart * g_qpc_to_us;
}

/* ---------------------------------------------------------------- logging */

/* Same shape as the agent's XcLogger (capture.c:337) minus the agent's log
 * framework: xencontrol.dll's own messages go to stderr so they never pollute
 * the parseable stdout stream. (No strsafe.h: _vsnwprintf_s truncation is fine
 * for diagnostics.) */
static void XcLogger(XENCONTROL_LOG_LEVEL logLevel, const char* function, const wchar_t* format, va_list args)
{
    wchar_t buf[1024];
    if (_vsnwprintf_s(buf, _countof(buf), _TRUNCATE, format, args) < 0)
        buf[_countof(buf) - 1] = L'\0'; /* truncated: still print what fit */
    fwprintf(stderr, L"[xc:%d] %hs: %s\n", (int)logLevel, function, buf);
}

/* ---------------------------------------------------------------- cleanup */

/* Revoke everything still granted. Returns number revoked; fills optional
 * latency array (element per revoke, us). MUST stay safe to call twice and
 * from the ctrl-handler thread (interlocked guard in CleanupAll). */
static size_t RevokeAll(double* lat_us, size_t lat_cap)
{
    size_t revoked = 0;

    if (!g_xc)
        return 0;

    for (size_t i = g_slot_count; i-- > 0; )
    {
        GRANT_SLOT* s = &g_slots[i];
        if (!s->granted)
            continue;

        double t0 = Now();
        DWORD status = XcGnttabRevokeForeignAccess(g_xc, s->shared);
        double dt = Now() - t0;

        if (status != ERROR_SUCCESS)
        {
            /* Report loudly; nothing more we can do for this one. */
            fprintf(stderr, "XcGnttabRevokeForeignAccess(slot %zu) failed: %lu (0x%lx)\n",
                    i, status, status);
        }

        s->granted = FALSE;
        if (lat_us && revoked < lat_cap)
            lat_us[revoked] = dt;
        revoked++;
    }
    return revoked;
}

static void CleanupAll(void)
{
    if (InterlockedExchange(&g_cleaned, 1))
        return; /* already done */

    size_t leaked = RevokeAll(NULL, 0);
    if (leaked)
        fprintf(stderr, "cleanup: revoked %zu leftover grant(s)\n", leaked);

    if (g_xc)
    {
        XcClose(g_xc);
        g_xc = NULL;
    }
    /* VirtualAlloc'd buffers are reclaimed by process exit. */
}

static BOOL WINAPI CtrlHandler(DWORD type)
{
    (void)type;
    fprintf(stderr, "interrupted, revoking all grants\n");
    CleanupAll();
    ExitProcess(3);
    /* not reached; ExitProcess is not annotated noreturn in all SDKs */
    return TRUE;
}

/* ------------------------------------------------------------- grant/revoke */

/* Grant one buffer to domid exactly like capture.c:528 does for the
 * framebuffer. Returns ERROR_SUCCESS and marks the slot granted, or the
 * failing status (slot left ungranted, buffer freed by caller/exit). */
static DWORD GrantSlot(USHORT domid, GRANT_SLOT* s, double* grant_us)
{
    PVOID shared = NULL;
    double t0 = Now();

    DWORD status = XcGnttabPermitForeignAccess2(g_xc,
        domid,
        s->buffer,
        s->pages,
        0,                          /* notifyOffset: unused, no notify flag */
        0,                          /* notifyPort:   unused, no notify flag */
        XENIFACE_GNTTAB_READONLY,
        &shared,
        s->refs);

    *grant_us = Now() - t0;

    if (status != ERROR_SUCCESS)
        return status;

    /* The agent asserts sharedAddress == input VA (capture.c:544). */
    if (shared != s->buffer)
        fprintf(stderr, "note: sharedAddress %p != buffer %p (agent asserts equality)\n",
                shared, s->buffer);

    s->shared = shared;
    s->granted = TRUE;
    return ERROR_SUCCESS;
}

static GRANT_SLOT* AllocSlot(UINT size_index)
{
    if (g_slot_count >= MAX_SLOTS)
        return NULL;

    GRANT_SLOT* s = &g_slots[g_slot_count];
    const WINDOW_SIZE* ws = &g_sizes[size_index];
    size_t pages = FRAMEBUFFER_PAGE_COUNT(ws->width, ws->height);
    size_t bytes = pages * PAGE_SIZE;

    s->size_index = size_index;
    s->pages = (ULONG)pages;
    s->refs = (ULONG*)malloc(pages * sizeof(ULONG));
    /* VirtualAlloc: page-aligned by construction, like a mapped surface VA */
    s->buffer = VirtualAlloc(NULL, bytes, MEM_COMMIT | MEM_RESERVE, PAGE_READWRITE);
    s->shared = NULL;
    s->granted = FALSE;

    if (!s->refs || !s->buffer)
    {
        free(s->refs);
        if (s->buffer)
            VirtualFree(s->buffer, 0, MEM_RELEASE);
        return NULL;
    }

    /* Touch every page so grant time never includes demand-zero faults and the
     * buffer is representative of a real, populated window backing store. */
    memset(s->buffer, 0x5A, bytes);

    g_slot_count++;
    return s;
}

/* ---------------------------------------------------------------- stats */

typedef struct
{
    double min, max, mean, p50, p95, total;
    size_t n;
} STATS;

static int CmpDouble(const void* a, const void* b)
{
    double x = *(const double*)a, y = *(const double*)b;
    return (x > y) - (x < y);
}

static STATS Summarize(double* v, size_t n)
{
    STATS st;
    memset(&st, 0, sizeof(st));
    st.n = n;
    if (!n)
        return st;

    qsort(v, n, sizeof(double), CmpDouble);
    for (size_t i = 0; i < n; i++)
        st.total += v[i];
    st.min = v[0];
    st.max = v[n - 1];
    st.mean = st.total / (double)n;
    /* nearest-rank percentiles */
    st.p50 = v[(n * 50 + 99) / 100 - 1];
    st.p95 = v[(n * 95 + 99) / 100 - 1];
    return st;
}

static void PrintStats(const char* label, const STATS* st)
{
    printf("  %-10s n=%zu min=%.1f p50=%.1f p95=%.1f max=%.1f mean=%.1f total=%.1f (us)\n",
           label, st->n, st->min, st->p50, st->p95, st->max, st->mean, st->total);
}

static void JsonStats(char* out, size_t cap, const STATS* st)
{
    _snprintf_s(out, cap, _TRUNCATE,
        "{\"n\":%zu,\"min_us\":%.1f,\"p50_us\":%.1f,\"p95_us\":%.1f,"
        "\"max_us\":%.1f,\"mean_us\":%.1f,\"total_us\":%.1f}",
        st->n, st->min, st->p50, st->p95, st->max, st->mean, st->total);
}

/* ---------------------------------------------------------------- modes */

static int ModeCeiling(USHORT domid, ULONG maxwins)
{
    double* grant_lat = (double*)calloc(maxwins, sizeof(double));
    double* revoke_lat = (double*)calloc(maxwins, sizeof(double));
    /* per-size grant latencies for the by-size breakdown */
    double* by_size[NUM_SIZES];
    size_t by_size_n[NUM_SIZES] = { 0 };
    BOOL alloc_ok = (grant_lat && revoke_lat);
    for (size_t i = 0; i < NUM_SIZES; i++)
    {
        by_size[i] = (double*)calloc(maxwins, sizeof(double));
        if (!by_size[i])
            alloc_ok = FALSE;
    }
    if (!alloc_ok)
        return 1;

    ULONGLONG total_pages = 0;
    ULONG granted = 0;
    DWORD fail_status = ERROR_SUCCESS;
    int fail_size_index = -1;
    BOOL failed = FALSE;

    printf("=== CEILING: stepping grants to domid %u, max %lu windows ===\n", domid, maxwins);
    printf("%-4s %-10s %-7s %-12s %-12s\n", "#", "size", "pages", "grant_us", "total_pages");

    for (ULONG i = 0; i < maxwins; i++)
    {
        UINT si = i % NUM_SIZES;
        GRANT_SLOT* s = AllocSlot(si);
        if (!s)
        {
            fprintf(stderr, "buffer allocation failed at window %lu (not a grant limit)\n", i);
            failed = TRUE;
            fail_status = ERROR_OUTOFMEMORY;
            fail_size_index = (int)si;
            break;
        }

        double dt = 0.0;
        DWORD status = GrantSlot(domid, s, &dt);
        if (status != ERROR_SUCCESS)
        {
            failed = TRUE;
            fail_status = status;
            fail_size_index = (int)si;
            printf("%-4lu %ux%-5u GRANT FAILED: status %lu (0x%lx)\n",
                   i, g_sizes[si].width, g_sizes[si].height, status, status);
            break;
        }

        grant_lat[granted] = dt;
        by_size[si][by_size_n[si]++] = dt;
        granted++;
        total_pages += s->pages;

        printf("%-4lu %ux%-5u %-7lu %-12.1f %-12llu\n",
               i, g_sizes[si].width, g_sizes[si].height, s->pages, dt, total_pages);
    }

    printf("\n=== ceiling result: %lu window(s) granted, %llu pages total%s ===\n",
           granted, total_pages, failed ? "" : " (maxwins reached, no ceiling hit)");
    if (failed)
        printf("  failing status: %lu (0x%lx) at size %ux%u\n",
               fail_status, fail_status,
               g_sizes[fail_size_index].width, g_sizes[fail_size_index].height);

    /* release everything, timed */
    size_t revoked = RevokeAll(revoke_lat, maxwins);

    STATS gs = Summarize(grant_lat, granted);
    STATS rs = Summarize(revoke_lat, revoked);
    STATS bys[NUM_SIZES];
    for (size_t i = 0; i < NUM_SIZES; i++)
        bys[i] = Summarize(by_size[i], by_size_n[i]);

    printf("\n=== LATENCY ===\n");
    PrintStats("grant", &gs);
    for (size_t i = 0; i < NUM_SIZES; i++)
    {
        char lbl[32];
        _snprintf_s(lbl, sizeof(lbl), _TRUNCATE, "g %ux%u", g_sizes[i].width, g_sizes[i].height);
        PrintStats(lbl, &bys[i]);
    }
    PrintStats("revoke", &rs);
    printf("  revoked %zu/%lu grant(s)\n", revoked, granted);

    /* JSON */
    char jg[256], jr[256], jbys[NUM_SIZES][256];
    JsonStats(jg, sizeof(jg), &gs);
    JsonStats(jr, sizeof(jr), &rs);
    for (size_t i = 0; i < NUM_SIZES; i++)
        JsonStats(jbys[i], sizeof(jbys[i]), &bys[i]);

    printf("=== GRANTPROBE JSON ===\n");
    printf("{\"tool\":\"grantprobe\",\"mode\":\"ceiling\",\"domid\":%u,\"maxwins\":%lu,"
           "\"granted_windows\":%lu,\"granted_pages\":%llu,\"revoked\":%zu,"
           "\"hit_ceiling\":%s,\"fail_status\":%lu,\"fail_status_hex\":\"0x%lx\",\"fail_size\":\"%s\","
           "\"grant_us\":%s,"
           "\"grant_us_by_size\":{\"1280x720\":%s,\"1920x1080\":%s,\"3840x2160\":%s},"
           "\"revoke_us\":%s}\n",
           domid, maxwins, granted, total_pages, revoked,
           failed ? "true" : "false", fail_status, fail_status,
           failed ? (fail_size_index == 0 ? "1280x720" :
                     fail_size_index == 1 ? "1920x1080" : "3840x2160") : "",
           jg, jbys[0], jbys[1], jbys[2], jr);
    fflush(stdout);
    return 0;
}

static int ModeRegrant(USHORT domid, ULONG iters)
{
    double* grant_lat = (double*)calloc(iters, sizeof(double));
    double* revoke_lat = (double*)calloc(iters, sizeof(double));
    if (!grant_lat || !revoke_lat)
        return 1;

    GRANT_SLOT* s = AllocSlot(1); /* 1920x1080 */
    if (!s)
    {
        fprintf(stderr, "buffer allocation failed\n");
        return 1;
    }

    printf("=== REGRANT: %lu x grant+revoke of one 1920x1080 buffer (%lu pages) to domid %u ===\n",
           iters, s->pages, domid);

    ULONG done = 0;
    DWORD fail_status = ERROR_SUCCESS;

    for (ULONG i = 0; i < iters; i++)
    {
        double dt = 0.0;
        DWORD status = GrantSlot(domid, s, &dt);
        if (status != ERROR_SUCCESS)
        {
            fail_status = status;
            fprintf(stderr, "grant failed at iter %lu: %lu (0x%lx)\n", i, status, status);
            break;
        }
        grant_lat[done] = dt;

        double t0 = Now();
        status = XcGnttabRevokeForeignAccess(g_xc, s->shared);
        revoke_lat[done] = Now() - t0;
        s->granted = FALSE;
        if (status != ERROR_SUCCESS)
        {
            fail_status = status;
            fprintf(stderr, "revoke failed at iter %lu: %lu (0x%lx)\n", i, status, status);
            s->granted = TRUE; /* let cleanup retry it */
            break;
        }
        done++;
    }

    STATS gs = Summarize(grant_lat, done);
    STATS rs = Summarize(revoke_lat, done);

    printf("completed %lu/%lu iterations\n", done, iters);
    printf("=== LATENCY (resize-path price: one revoke + one grant per resize) ===\n");
    PrintStats("grant", &gs);
    PrintStats("revoke", &rs);

    char jg[256], jr[256];
    JsonStats(jg, sizeof(jg), &gs);
    JsonStats(jr, sizeof(jr), &rs);

    printf("=== GRANTPROBE JSON ===\n");
    printf("{\"tool\":\"grantprobe\",\"mode\":\"regrant\",\"domid\":%u,\"iters\":%lu,"
           "\"completed\":%lu,\"pages\":%lu,"
           "\"failed\":%s,\"fail_status\":%lu,\"fail_status_hex\":\"0x%lx\","
           "\"grant_us\":%s,\"revoke_us\":%s}\n",
           domid, iters, done, s->pages,
           (done == iters) ? "false" : "true", fail_status, fail_status,
           jg, jr);
    fflush(stdout);
    return 0;
}

/* ---------------------------------------------------------------- main */

static void Usage(void)
{
    fprintf(stderr,
        "grantprobe - guest-side grant ceiling / latency probe (per-window-capture Q2)\n"
        "usage:\n"
        "  grantprobe ceiling <domid> [maxwins]   step grants until failure or maxwins (default %u)\n"
        "  grantprobe regrant <domid> <iters>     grant+revoke one 1920x1080 buffer <iters> times\n"
        "<domid>: grant target; the agent reads it from qubesdb /qubes-gui-domain-xid,\n"
        "         the harness passes 0 (dom0 = GUI domain on win-idd-test).\n"
        "exit: 0 probe completed (a discovered ceiling IS a result), 1 could not run, 2 bad args\n",
        DEFAULT_MAXWINS);
}

int main(int argc, char** argv)
{
    LARGE_INTEGER freq;
    QueryPerformanceFrequency(&freq);
    g_qpc_to_us = 1e6 / (double)freq.QuadPart;

    if (argc < 3)
    {
        Usage();
        return 2;
    }

    char* end = NULL;
    long domid_l = strtol(argv[2], &end, 10);
    if (!end || *end || domid_l < 0 || domid_l > 65535)
    {
        fprintf(stderr, "bad domid '%s'\n", argv[2]);
        Usage();
        return 2;
    }
    USHORT domid = (USHORT)domid_l;

    BOOL is_ceiling = (strcmp(argv[1], "ceiling") == 0);
    BOOL is_regrant = (strcmp(argv[1], "regrant") == 0);
    ULONG count = 0;

    if (is_ceiling)
    {
        count = DEFAULT_MAXWINS;
        if (argc >= 4)
            count = (ULONG)strtoul(argv[3], NULL, 10);
        if (count < 1 || count > MAX_SLOTS)
        {
            fprintf(stderr, "maxwins out of range (1..%u)\n", MAX_SLOTS);
            return 2;
        }
    }
    else if (is_regrant)
    {
        if (argc < 4)
        {
            Usage();
            return 2;
        }
        count = (ULONG)strtoul(argv[3], NULL, 10);
        if (count < 1 || count > MAX_ITERS)
        {
            fprintf(stderr, "iters out of range (1..%u)\n", MAX_ITERS);
            return 2;
        }
    }
    else
    {
        Usage();
        return 2;
    }

    /* Cleanup must be armed before the first grant can possibly happen. */
    atexit(CleanupAll);
    SetConsoleCtrlHandler(CtrlHandler, TRUE);

    /* Same open pattern as the agent (capture.c:357): logger passed to XcOpen. */
    DWORD status = XcOpen(XcLogger, &g_xc);
    if (status != ERROR_SUCCESS || !g_xc)
    {
        fprintf(stderr, "XcOpen failed: %lu (0x%lx) - is xeniface/xencontrol.dll present?\n",
                status, status);
        printf("=== GRANTPROBE JSON ===\n");
        printf("{\"tool\":\"grantprobe\",\"mode\":\"%s\",\"error\":\"XcOpen\","
               "\"fail_status\":%lu,\"fail_status_hex\":\"0x%lx\"}\n",
               argv[1], status, status);
        return 1;
    }
    XcSetLogLevel(g_xc, XLL_INFO); /* agent syncs levels the same way, capture.c:366 */

    int rc = is_ceiling ? ModeCeiling(domid, count) : ModeRegrant(domid, count);

    CleanupAll(); /* explicit; atexit guard makes the second call a no-op */
    return rc;
}
