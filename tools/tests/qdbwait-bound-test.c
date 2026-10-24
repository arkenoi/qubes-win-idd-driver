/* qdbwait-bound-test.c - offline proof that WaitForQdb's timeout COVERS THE CALL.
 *
 * The defect this exists for (findings/issues.md QDBWAITBOUNDISINERTWHILETHEDAEMONISSILENT): the
 * 360 s bound was tested only BETWEEN calls, so a qdb_open that never returned was never
 * interrupted. Measured on win11r-sup 2026-10-24: with the qubesdb daemon alive but not answering,
 * one qdb_open blocked 87063 ms and came back 67 ms after the daemon was resumed; with the daemon
 * ABSENT it returned NULL in 156 ms. Supervision cell L10 held the daemon suspended 421 s against
 * the 360 s bound and got no SCM 7023 at all, because nothing had failed.
 *
 * WHY THIS IS A C TEST AND NOT A GREP. The property is "the function returns ERROR_TIMEOUT even
 * when qdb_open does not return". No source pattern expresses that; only running it does. So the
 * REAL function is extracted from core-agent by the suite (never a copy kept here, which would rot)
 * and driven against three qdb_open stubs, with the Win32 calls it uses implemented over pthreads:
 *
 *   ANSWERS      qdb_open returns a handle at once          -> ERROR_SUCCESS
 *   ABSENT       qdb_open returns NULL at once, forever     -> ERROR_TIMEOUT at the deadline
 *                                                              (the case the OLD code handled too)
 *   SILENT       qdb_open NEVER RETURNS                     -> ERROR_TIMEOUT anyway  <-- THE DEFECT
 *   STOPPED      the stop event is signalled mid-wait       -> ERROR_CANCELLED, promptly
 *
 * SILENT run against the pre-fix function HANGS - which is the defect, and is why the suite runs
 * each case under a hard alarm and reports a hang as a FAIL rather than waiting for it.
 *
 * The timeout is scaled: QDB_WAIT_TIMEOUT_MS is redefined to a small value by the suite, because a
 * test that takes 6 minutes to prove a 6-minute bound would never be run. The SHAPE under test is
 * which wait the budget is attached to, and that is independent of the number.
 */
#include <windows.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>

/* ---- the environment the extracted function expects -------------------------------------------- */
typedef void* qdb_handle_t;

/* Which behaviour qdb_open has this run. Set before the call, read by the stub. */
enum QDB_MODE { QDB_ANSWERS, QDB_ABSENT, QDB_SILENT };
static enum QDB_MODE g_mode = QDB_ANSWERS;
static int g_opens = 0;          /* how many times the function called qdb_open */
static int g_closes = 0;         /* and whether it closed what it got */

qdb_handle_t qdb_open(char *vmname)
{
    (void)vmname;
    g_opens++;
    switch (g_mode)
    {
    case QDB_ANSWERS:
        return (qdb_handle_t)(size_t)0xDB;
    case QDB_ABSENT:
        return NULL;
    case QDB_SILENT:
    default:
        /* The daemon's pipe accepted the connect and nobody is servicing it. The real call sits in
         * a synchronous ReadFile with no timeout; this sits here. Same observable. */
        for (;;)
            Sleep(60 * 1000);
    }
}

void qdb_close(qdb_handle_t h)
{
    if (h == (qdb_handle_t)(size_t)0xDB)
        g_closes++;
}

/* The logger: counted, so the test can assert the function SAID what happened. */
static int g_log_timeout = 0;    /* "timed out after ... connect to qdb server" */
static int g_log_notanswering = 0; /* "... qubesdb is running but not answering" */
static int g_log_stop = 0;       /* "stop requested while waiting for qdb" */

static void test_log(const char *fmt)
{
    if (strstr(fmt, "timed out after"))             g_log_timeout++;
    if (strstr(fmt, "running but not answering"))    g_log_notanswering++;
    if (strstr(fmt, "stop requested"))               g_log_stop++;
}
#define LogDebug(fmt, ...)   test_log(fmt)
#define LogWarning(fmt, ...) test_log(fmt)
#define LogError(fmt, ...)   test_log(fmt)

static DWORD win_perror2(DWORD status, const char *what)
{
    fprintf(stderr, "    (win_perror2 %lu: %s)\n", (unsigned long)status, what);
    return status;
}

/* ---- the function under test, extracted from the shipped source by the suite ------------------- */
#include "qdbwait-extracted.inc"

/* ---- the cases ---------------------------------------------------------------------------------- */
static int failures = 0;

static void expect(const char *name, DWORD got, DWORD want, const char *why)
{
    if (got == want)
        printf("  PASS  %-44s -> %lu\n", name, (unsigned long)got);
    else
    {
        printf("  FAIL  %-44s -> %lu, expected %lu\n", name, (unsigned long)got, (unsigned long)want);
        printf("        why it matters: %s\n", why);
        failures++;
    }
}

/* THE TOTAL BOUND IS THE DOCUMENTED ONE, and this asserts it rather than trusting the arithmetic.
 * The thread's deadline is deliberately EARLIER than the waiter's timeout so the two do not race;
 * putting the grace on the WAITER instead would have stretched the documented 360 s to 362 s, which
 * a fix whose mandate is "make the existing bound real" is not allowed to do. A review scored that
 * disclosure at 0.46 on scope, hence this check. The slack is for the shim's scheduling, not for
 * the code: anything beyond it means the budget was exceeded. */
static void bounded(const char *name, ULONGLONG elapsed)
{
    const ULONGLONG slack = 250;

    if (elapsed > (ULONGLONG)QDB_WAIT_TIMEOUT_MS + slack)
    {
        printf("  FAIL  %s: took %lu ms, past the %u ms budget (+%lu slack)\n",
               name, (unsigned long)elapsed, (unsigned)QDB_WAIT_TIMEOUT_MS, (unsigned long)slack);
        printf("        why it matters: the caller's bound is the documented timeout; exceeding it\n");
        printf("                        is a changed timeout value, not a bug fix\n");
        failures++;
    }
    else
        printf("  PASS  %-44s %lu ms <= %u\n", "bound: it returned within the budget",
               (unsigned long)elapsed, (unsigned)QDB_WAIT_TIMEOUT_MS);
}

static DWORD WINAPI SignalLater(PVOID param)
{
    HANDLE ev = (HANDLE)param;

    Sleep(300);
    SetEvent(ev);
    return 0;
}

int main(void)
{
    HANDLE stopEvent;
    DWORD rc;
    ULONGLONG t0;

    printf("--- WaitForQdb, extracted from core-agent, against three qdb_open behaviours\n");
    printf("    (QDB_WAIT_TIMEOUT_MS = %u ms for this run)\n", (unsigned)QDB_WAIT_TIMEOUT_MS);

    /* 1. the daemon answers */
    stopEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    g_mode = QDB_ANSWERS; g_opens = g_closes = 0;
    rc = WaitForQdb(stopEvent);
    expect("ANSWERS: a handle at once", rc, ERROR_SUCCESS,
           "a working qubesdb must not delay or fail the service start");
    if (g_closes != 1)
    {
        printf("  FAIL  ANSWERS: the handle was not closed (%d closes)\n", g_closes);
        printf("        why it matters: a leaked qdb handle holds the daemon's client pipe open\n");
        failures++;
    }
    else
        printf("  PASS  %-44s closed\n", "ANSWERS: the probe handle");
    CloseHandle(stopEvent);

    /* 2. the daemon is absent - fails fast, retries, and the deadline ends it. This case worked
     *    before the fix too, and must keep working: it is the slow-boot case the bound was for. */
    stopEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    g_mode = QDB_ABSENT; g_opens = g_closes = 0;
    t0 = GetTickCount64();
    rc = WaitForQdb(stopEvent);
    bounded("ABSENT", GetTickCount64() - t0);
    expect("ABSENT: NULL at once, until the deadline", rc, ERROR_TIMEOUT,
           "this is the boot-order case; giving up EARLY would leave a guest with no qrexec");
    if (g_opens < 2)
    {
        printf("  FAIL  ABSENT: only %d qdb_open call(s) - it did not RETRY\n", g_opens);
        printf("        why it matters: a single attempt makes the 360 s wait meaningless\n");
        failures++;
    }
    else
        printf("  PASS  %-44s %d attempts\n", "ABSENT: it retried", g_opens);
    if (!g_log_timeout)
    {
        printf("  FAIL  ABSENT: it did not log the timeout\n");
        printf("        why it matters: the log is the only place a 1460 exit can be attributed\n");
        failures++;
    }
    CloseHandle(stopEvent);

    /* 3. THE DEFECT: the daemon never answers and the call never returns. Pre-fix this hangs. */
    stopEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    g_mode = QDB_SILENT; g_opens = g_closes = 0; g_log_timeout = g_log_notanswering = 0;
    t0 = GetTickCount64();
    rc = WaitForQdb(stopEvent);
    bounded("SILENT", GetTickCount64() - t0);
    expect("SILENT: qdb_open NEVER returns", rc, ERROR_TIMEOUT,
           "THE defect: the service start wedges, the SCM sees no failure, and none of the "
           "installer's restart actions can fire");
    if (!g_log_notanswering)
    {
        printf("  FAIL  SILENT: it did not say the daemon is running but not answering\n");
        printf("        why it matters: this is the line that tells this case apart from an absent daemon\n");
        failures++;
    }
    else
        printf("  PASS  %-44s logged\n", "SILENT: 'running but not answering'");
    CloseHandle(stopEvent);

    /* 4. a stop request must still win, promptly, in the absent case */
    stopEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
    g_mode = QDB_ABSENT; g_opens = 0;
    CloseHandle(CreateThread(NULL, 0, SignalLater, stopEvent, 0, NULL));
    rc = WaitForQdb(stopEvent);
    expect("STOPPED: the stop event mid-wait", rc, ERROR_CANCELLED,
           "a multi-minute wait that ignores a stop request hangs every shutdown");
    CloseHandle(stopEvent);

    /* 5. THE PATH NO OTHER CASE REACHES: a stop request while a call is STUCK. The stuck thread
     *    cannot notice the event - it is not waiting on it, it is inside qdb_open - so the waiter
     *    has to be the one that answers, and it must answer PROMPTLY rather than sit out the whole
     *    budget. Added because a review put 0.28 on "one of the paths is handled wrongly" and this
     *    was the only path the other four cases left untested. */
    {
        ULONGLONG t0, elapsed;

        stopEvent = CreateEvent(NULL, TRUE, FALSE, NULL);
        g_mode = QDB_SILENT; g_opens = 0;
        CloseHandle(CreateThread(NULL, 0, SignalLater, stopEvent, 0, NULL));
        t0 = GetTickCount64();
        rc = WaitForQdb(stopEvent);
        elapsed = GetTickCount64() - t0;
        expect("STOPPED while the call is STUCK", rc, ERROR_CANCELLED,
               "a shutdown must not wait out the full qubesdb budget because one call is wedged");
        if (elapsed >= QDB_WAIT_TIMEOUT_MS)
        {
            printf("  FAIL  STOPPED-while-stuck: took %lu ms, i.e. the whole budget\n",
                   (unsigned long)elapsed);
            printf("        why it matters: the stop was answered by the deadline, not by the event\n");
            failures++;
        }
        else
            printf("  PASS  %-44s %lu ms (budget %u)\n", "STOPPED-while-stuck: answered promptly",
                   (unsigned long)elapsed, (unsigned)QDB_WAIT_TIMEOUT_MS);
        CloseHandle(stopEvent);
    }

    printf("--- %s\n", failures ? "FAILURES" : "all cases passed");
    return failures ? 1 : 0;
}
