/*
 * svc-exitcode-test.c - offline suite for patches/windows-utils-service-exit-code.patch: windows-utils'
 * SvcMainLoop must END THE SERVICE WITH THE WORKER'S ERROR, so that the SCM logs event 7023 and runs the
 * recovery actions the installer arms (docs/ADR-supervision.md 2; the standing finding of health-check.ps1
 * section 2b: QdbDaemon and QrexecAgent exited 0 when their worker failed, so their recovery was inert).
 *
 * gcc on the dev qube, no Windows: this file #includes the PATCHED copy of src/service.c that
 * tools/tests/svc-exitcode-selftest.sh prepares, and stubs the SCM. The dispatcher calls ServiceMain
 * synchronously; CreateThread runs the worker synchronously and keeps its return value for
 * GetExitCodeThread; SetServiceStatus records every status the service reports. So the checks are what
 * the SCM would be told, for the real control flow of service.c - not a re-implementation of it.
 * The selftest also builds this against the UNPATCHED service.c (the defect present) and requires it to
 * FAIL. Prints "ok <case>" / "FAIL <case>" lines; exit 0 iff no FAIL.
 */
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <wchar.h>

#include "service.c"   /* the copy the selftest put next to this file: patched, or the original under the defect knob */

/* --- the stubbed SCM and runtime ----------------------------------------------------------- */
#define MAX_STATUS 16
static SERVICE_STATUS g_reported[MAX_STATUS];
static int g_reportedCount;
static DWORD g_workerReturns;          /* what the worker thread returns */
static int g_createThreadFails;        /* CreateThread returns NULL, GetLastError = 8 */
static int g_exitCodeThreadFails;      /* GetExitCodeThread returns FALSE, GetLastError = 6 */
static DWORD g_lastError;
static DWORD g_threadResult;
static int g_workerRan;
static HANDLE g_fakeThread = (HANDLE)0x7117;
static int g_perrorCalls;
static int g_logErrorCalls;
static int g_logWarningCalls;
static int g_workerAsksStop;      /* the SCM asks for the stop while the worker runs (the real order) */

void _LogFormat(IN int level, IN BOOL raw, IN const char *fn, IN const WCHAR *fmt, ...)
{
    (void)raw; (void)fn; (void)fmt;
    if (level == LOG_LEVEL_ERROR) g_logErrorCalls++;
    if (level == LOG_LEVEL_WARNING) g_logWarningCalls++;
}
DWORD _win_perror(IN const char *fn, IN const WCHAR *prefix) { (void)fn; (void)prefix; g_perrorCalls++; return g_lastError; }
DWORD _win_perror2(IN const char *fn, IN DWORD error, IN const WCHAR *prefix) { (void)fn; (void)prefix; g_perrorCalls++; return error; }
DWORD GetLastError(void) { return g_lastError; }
/* The interlocked intrinsics the wrapper uses for its stop latch; this harness is single-threaded (CreateThread
   above runs the worker synchronously), so a plain read/write models them exactly. */
LONG InterlockedExchange(volatile LONG *t, LONG v) { LONG old = *t; *t = v; return old; }
LONG InterlockedCompareExchange(volatile LONG *t, LONG v, LONG cmp) { LONG old = *t; if (old == cmp) *t = v; return old; }

BOOL StartServiceCtrlDispatcher(const SERVICE_TABLE_ENTRY *table)
{
    table[0].lpServiceProc(0, NULL);
    return TRUE;
}
SERVICE_STATUS_HANDLE RegisterServiceCtrlHandlerEx(LPCWSTR name, LPHANDLER_FUNCTION_EX fn, void *ctx)
{
    (void)name; (void)fn; (void)ctx;
    return (SERVICE_STATUS_HANDLE)0x5C;
}
BOOL SetServiceStatus(SERVICE_STATUS_HANDLE h, SERVICE_STATUS *st)
{
    (void)h;
    if (g_reportedCount < MAX_STATUS) g_reported[g_reportedCount++] = *st;
    return TRUE;
}
HANDLE CreateEvent(void *sa, BOOL manual, BOOL initial, LPCWSTR name) { (void)sa; (void)manual; (void)initial; (void)name; return (HANDLE)0xE7; }
BOOL SetEvent(HANDLE h) { (void)h; return TRUE; }
BOOL CloseHandle(HANDLE h) { (void)h; return TRUE; }
HANDLE CreateThread(void *sa, size_t stack, LPTHREAD_START_ROUTINE fn, void *param, DWORD flags, DWORD *id)
{
    (void)sa; (void)stack; (void)flags; (void)id;
    if (g_createThreadFails) { g_lastError = 8; return NULL; }   /* ERROR_NOT_ENOUGH_MEMORY */
    g_workerRan = 1;
    g_threadResult = fn(param);                                  /* synchronous: the "thread" has finished */
    return g_fakeThread;
}
DWORD WaitForSingleObject(HANDLE h, DWORD ms) { (void)h; (void)ms; return WAIT_OBJECT_0; }
BOOL GetExitCodeThread(HANDLE h, DWORD *code)
{
    if (h != g_fakeThread) return FALSE;
    if (g_exitCodeThreadFails) { g_lastError = 6; return FALSE; }  /* ERROR_INVALID_HANDLE */
    *code = g_threadResult;
    return TRUE;
}
wchar_t *_wcsdup(const wchar_t *s) { size_t n = wcslen(s) + 1; wchar_t *d = malloc(n * sizeof(wchar_t)); if (d) wmemcpy(d, s, n); return d; }
/* SvcCreate/SvcDelete are compiled but never called here */
SC_HANDLE OpenSCManager(LPCWSTR a, LPCWSTR b, DWORD c) { (void)a; (void)b; (void)c; return NULL; }
SC_HANDLE CreateService(SC_HANDLE a, LPCWSTR b, LPCWSTR c, DWORD d, DWORD e, DWORD f, DWORD g, LPCWSTR h, LPCWSTR i, LPDWORD j, LPCWSTR k, LPCWSTR l, LPCWSTR m)
{ (void)a; (void)b; (void)c; (void)d; (void)e; (void)f; (void)g; (void)h; (void)i; (void)j; (void)k; (void)l; (void)m; return NULL; }
SC_HANDLE OpenService(SC_HANDLE a, LPCWSTR b, DWORD c) { (void)a; (void)b; (void)c; return NULL; }
BOOL DeleteService(SC_HANDLE a) { (void)a; return FALSE; }
BOOL CloseServiceHandle(SC_HANDLE a) { (void)a; return TRUE; }

/* --- the worker under test: returns whatever the case says ------------------------------- */
static DWORD WINAPI Worker(void *param)
{
    PSERVICE_WORKER_CONTEXT ctx = param;
    (void)ctx;
    /* A REQUESTED STOP, in the real order: the SCM calls the control handler while the worker is still
       running, and the worker then finishes - here with whatever error the case gives it. */
    if (g_workerAsksStop)
        SvcCtrlHandlerEx(SERVICE_CONTROL_STOP, 0, NULL, NULL);
    return g_workerReturns;
}

/* --- harness ------------------------------------------------------------------------------- */
static int g_run, g_fail;
static void check(const char *name, int ok)
{
    g_run++;
    if (!ok) g_fail++;
    printf("%s %s\n", ok ? "ok  " : "FAIL", name);
}
static void reset(void)
{
    memset(g_reported, 0, sizeof(g_reported));
    g_reportedCount = 0; g_workerReturns = 0; g_createThreadFails = 0; g_exitCodeThreadFails = 0;
    g_lastError = 0; g_threadResult = 0; g_workerRan = 0; g_perrorCalls = 0; g_logErrorCalls = 0;
    g_logWarningCalls = 0; g_workerAsksStop = 0;
}
static const SERVICE_STATUS *last(void) { return g_reportedCount ? &g_reported[g_reportedCount - 1] : NULL; }
static const SERVICE_STATUS *nth(DWORD state)
{
    int i;
    for (i = 0; i < g_reportedCount; i++) if (g_reported[i].dwCurrentState == state) return &g_reported[i];
    return NULL;
}
static DWORD run(DWORD workerReturns)
{
    reset();
    g_workerReturns = workerReturns;
    return SvcMainLoop(L"QrexecAgent", 0, Worker, NULL, NULL, NULL);
}

int main(void)
{
    DWORD rc;

    /* 1. the failure the finding is about: WaitForQdb timed out -> the service ends with that error */
    rc = run(ERROR_TIMEOUT);
    check("timeout: SvcMainLoop itself returns success (the dispatcher ran)", rc == ERROR_SUCCESS);
    check("timeout: the worker ran", g_workerRan == 1);
    check("timeout: the last status is STOPPED", last() && last()->dwCurrentState == SERVICE_STOPPED);
    check("timeout: STOPPED carries the worker's error 1460 as dwWin32ExitCode", last() && last()->dwWin32ExitCode == ERROR_TIMEOUT);
    check("timeout: dwServiceSpecificExitCode stays 0 (a Win32 code, not a service-specific one)", last() && last()->dwServiceSpecificExitCode == 0);
    check("timeout: the error is logged at ERROR", g_logErrorCalls >= 1);
    check("timeout: RUNNING was reported with exit code 0 first", nth(SERVICE_RUNNING) && nth(SERVICE_RUNNING)->dwWin32ExitCode == 0);
    check("timeout: START_PENDING -> RUNNING -> STOPPED, three reports", g_reportedCount == 3 &&
          g_reported[0].dwCurrentState == SERVICE_START_PENDING && g_reported[1].dwCurrentState == SERVICE_RUNNING);

    /* 2. a requested stop (the worker returns NO_ERROR) stays a clean stop */
    rc = run(NO_ERROR);
    check("clean stop: STOPPED with exit code 0", last() && last()->dwCurrentState == SERVICE_STOPPED && last()->dwWin32ExitCode == 0);
    check("clean stop: nothing logged at ERROR", g_logErrorCalls == 0);

    /* 3. the qubesdb daemon's code for a failed mainloop is forwarded too */
    rc = run(ERROR_UNIDENTIFIED_ERROR);
    check("qubesdb: STOPPED carries ERROR_UNIDENTIFIED_ERROR (1287)", last() && last()->dwWin32ExitCode == ERROR_UNIDENTIFIED_ERROR);

    /* 4. a worker that could not even be started is a visible start failure */
    reset(); g_createThreadFails = 1; g_workerReturns = 0;
    SvcMainLoop(L"QdbDaemon", 0, Worker, NULL, NULL, NULL);
    check("no thread: STOPPED with the CreateThread error (8), not 0", last() && last()->dwCurrentState == SERVICE_STOPPED && last()->dwWin32ExitCode == 8);
    check("no thread: the worker never ran", g_workerRan == 0);
    /* service.c returns from that path without freeing g_Service (a pre-existing leak of the wrapper, harmless in
       a process that exits right after); release it here or the next SvcMainLoop says ERROR_ALREADY_INITIALIZED */
    if (g_Service) { free(g_Service->Name); free(g_Service); g_Service = NULL; }

    /* 5. an outcome that cannot be read is never reported as success */
    reset(); g_exitCodeThreadFails = 1; g_workerReturns = NO_ERROR;
    SvcMainLoop(L"QrexecAgent", 0, Worker, NULL, NULL, NULL);
    check("unreadable outcome: STOPPED with a non-zero code", last() && last()->dwCurrentState == SERVICE_STOPPED && last()->dwWin32ExitCode != 0);
    check("unreadable outcome: one perror", g_perrorCalls >= 1);

    /* 6. the stop request path reports STOP_PENDING with exit code 0 */
    reset();
    g_Service = malloc(sizeof(*g_Service)); memset(g_Service, 0, sizeof(*g_Service));
    g_Service->StatusHandle = (SERVICE_STATUS_HANDLE)0x5C; g_Service->StopEvent = (HANDLE)0xE7;
    SvcCtrlHandlerEx(SERVICE_CONTROL_STOP, 0, NULL, NULL);
    check("stop request: STOP_PENDING reported with exit code 0", last() && last()->dwCurrentState == SERVICE_STOP_PENDING && last()->dwWin32ExitCode == 0);
    free(g_Service); g_Service = NULL;

    /* 7. A STOP THE SCM ASKED FOR IS NOT A FAILURE, whatever the worker returns (docs/ADR-supervision.md 5).
          Measured 2026-10-06: a requested stop of QdbDaemon whose worker returned an error ended the service with
          that error, so the SCM's armed recovery restarted it ~5 s later, behind an installer's device work. The
          worker's outcome is still logged - a stop path that returns an error is a defect of ours. */
    reset();
    g_workerAsksStop = 1;
    g_workerReturns = ERROR_TIMEOUT;
    SvcMainLoop(L"QdbDaemon", 0, Worker, NULL, NULL, NULL);
    check("requested stop: the last status is STOPPED", last() && last()->dwCurrentState == SERVICE_STOPPED);
    check("requested stop: STOPPED carries exit code 0 - the SCM runs NO recovery action", last() && last()->dwWin32ExitCode == 0);
    check("requested stop: the worker's error is still logged (at WARNING, not swallowed)", g_logWarningCalls >= 1);
    check("requested stop: it is NOT logged as an unasked failure (no ERROR)", g_logErrorCalls == 0);

    /* 8. the control case: the same worker error WITHOUT a stop request is still a failure the SCM must see */
    reset();
    g_workerAsksStop = 0;
    g_workerReturns = ERROR_TIMEOUT;
    SvcMainLoop(L"QdbDaemon", 0, Worker, NULL, NULL, NULL);
    check("unasked exit: STOPPED still carries the worker's error (the recovery actions must fire)", last() && last()->dwWin32ExitCode == ERROR_TIMEOUT);
    check("unasked exit: logged at ERROR", g_logErrorCalls >= 1);

    printf("%d checks, %d failed\n", g_run, g_fail);
    return g_fail ? 1 : 0;
}
