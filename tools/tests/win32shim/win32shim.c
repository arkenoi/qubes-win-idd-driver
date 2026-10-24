/* win32shim.c - the few Win32 primitives an offline C test needs, over pthreads.
 *
 * tools/tests/win32stub/windows.h DECLARES these; nothing implemented them, so a test could only
 * ever be -fsyntax-only'd. qdbwait-bound-test.c has to RUN the function under test - the property
 * is "it returns ERROR_TIMEOUT even when the call it waits on never returns", and no source
 * pattern expresses that. Hence this.
 *
 * SCOPE, deliberately narrow: manual-reset events, threads with an exit code, a waitable set of
 * both, a monotonic tick and Sleep. Enough for a wait-and-deadline shape. It is NOT a Win32
 * emulation - no auto-reset events, no WaitAll, no APCs, no cancellation - and anything it does not
 * implement is left undeclared here so a test that needs it fails to LINK rather than silently
 * behaving differently from Windows.
 *
 * The semantics that matter and are honoured: WaitForMultipleObjects with bWaitAll FALSE returns
 * WAIT_OBJECT_0 + <index of the LOWEST signalled handle>, WAIT_TIMEOUT when none signals in time;
 * a thread handle becomes signalled when the thread returns and stays signalled; a manual-reset
 * event stays signalled until reset; GetExitCodeThread gives the thread's return value.
 */
#include <windows.h>
#include <pthread.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <errno.h>

enum SHIM_KIND { SHIM_EVENT, SHIM_THREAD };

struct SHIM_OBJECT
{
    enum SHIM_KIND kind;
    int signalled;
    /* thread only */
    pthread_t tid;
    int joined;
    DWORD exitCode;
    LPTHREAD_START_ROUTINE start;
    void *param;
};

/* One lock and one condition for every object: a waiter must be woken by ANY of them, and a test
 * this small does not need per-object queues. */
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cond = PTHREAD_COND_INITIALIZER;
static DWORD g_lastError = 0;

static struct SHIM_OBJECT *obj(HANDLE h) { return (struct SHIM_OBJECT *)h; }

DWORD GetLastError(void) { return g_lastError; }

static ULONGLONG now_ms(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);
    return (ULONGLONG)ts.tv_sec * 1000ULL + (ULONGLONG)(ts.tv_nsec / 1000000L);
}

ULONGLONG GetTickCount64(void) { return now_ms(); }

void Sleep(DWORD ms)
{
    struct timespec ts;

    ts.tv_sec = (time_t)(ms / 1000);
    ts.tv_nsec = (long)(ms % 1000) * 1000000L;
    nanosleep(&ts, NULL);
}

HANDLE CreateEvent(void *sa, BOOL manualReset, BOOL initial, LPCWSTR name)
{
    struct SHIM_OBJECT *o = (struct SHIM_OBJECT *)calloc(1, sizeof(*o));

    (void)sa; (void)name;
    if (!o)
        return NULL;
    /* Auto-reset is not implemented: a test that asks for it would get manual-reset behaviour
     * silently, so refuse instead. */
    if (!manualReset)
    {
        free(o);
        g_lastError = 87; /* ERROR_INVALID_PARAMETER */
        return NULL;
    }
    o->kind = SHIM_EVENT;
    o->signalled = initial ? 1 : 0;
    return (HANDLE)o;
}

BOOL SetEvent(HANDLE h)
{
    if (!h)
        return 0;
    pthread_mutex_lock(&g_lock);
    obj(h)->signalled = 1;
    pthread_cond_broadcast(&g_cond);
    pthread_mutex_unlock(&g_lock);
    return 1;
}

BOOL ResetEvent(HANDLE h)
{
    if (!h)
        return 0;
    pthread_mutex_lock(&g_lock);
    obj(h)->signalled = 0;
    pthread_mutex_unlock(&g_lock);
    return 1;
}

static void *shim_thread_main(void *param)
{
    struct SHIM_OBJECT *o = (struct SHIM_OBJECT *)param;
    DWORD rc = o->start(o->param);

    pthread_mutex_lock(&g_lock);
    o->exitCode = rc;
    o->signalled = 1;
    pthread_cond_broadcast(&g_cond);
    pthread_mutex_unlock(&g_lock);
    return NULL;
}

HANDLE CreateThread(void *sa, size_t stack, LPTHREAD_START_ROUTINE start, void *param,
                    DWORD flags, DWORD *idOut)
{
    struct SHIM_OBJECT *o = (struct SHIM_OBJECT *)calloc(1, sizeof(*o));

    (void)sa; (void)stack; (void)flags;
    if (!o)
        return NULL;
    o->kind = SHIM_THREAD;
    o->start = start;
    o->param = param;
    o->exitCode = 259; /* STILL_ACTIVE */
    if (pthread_create(&o->tid, NULL, shim_thread_main, o) != 0)
    {
        free(o);
        g_lastError = 8; /* ERROR_NOT_ENOUGH_MEMORY */
        return NULL;
    }
    /* Detached: a thread the code under test ABANDONS must not keep this process from exiting,
     * which is exactly the case being tested. */
    pthread_detach(o->tid);
    if (idOut)
        *idOut = 0;
    return (HANDLE)o;
}

BOOL GetExitCodeThread(HANDLE h, DWORD *code)
{
    if (!h || !code)
        return 0;
    pthread_mutex_lock(&g_lock);
    *code = obj(h)->exitCode;
    pthread_mutex_unlock(&g_lock);
    return 1;
}

DWORD WaitForMultipleObjects(DWORD count, const HANDLE *handles, BOOL waitAll, DWORD ms)
{
    ULONGLONG deadline = now_ms() + (ULONGLONG)ms;
    DWORD i;

    if (!handles || count == 0)
    {
        g_lastError = 6; /* ERROR_INVALID_HANDLE */
        return WAIT_FAILED;
    }
    if (waitAll)
    {
        /* Not implemented - see the header comment. Fail loudly rather than wait wrongly. */
        g_lastError = 87;
        return WAIT_FAILED;
    }

    pthread_mutex_lock(&g_lock);
    for (;;)
    {
        struct timespec ts;
        ULONGLONG left;

        for (i = 0; i < count; i++)
        {
            if (!handles[i])
            {
                pthread_mutex_unlock(&g_lock);
                g_lastError = 6;
                return WAIT_FAILED;
            }
            if (obj(handles[i])->signalled)
            {
                pthread_mutex_unlock(&g_lock);
                return WAIT_OBJECT_0 + i;
            }
        }
        if (ms != INFINITE)
        {
            ULONGLONG t = now_ms();

            if (t >= deadline)
            {
                pthread_mutex_unlock(&g_lock);
                return WAIT_TIMEOUT;
            }
            left = deadline - t;
        }
        else
            left = 50;

        clock_gettime(CLOCK_REALTIME, &ts);
        ts.tv_sec += (time_t)(left / 1000);
        ts.tv_nsec += (long)(left % 1000) * 1000000L;
        if (ts.tv_nsec >= 1000000000L) { ts.tv_sec++; ts.tv_nsec -= 1000000000L; }
        pthread_cond_timedwait(&g_cond, &g_lock, &ts);
    }
}

DWORD WaitForSingleObject(HANDLE h, DWORD ms)
{
    HANDLE one[1];

    one[0] = h;
    return WaitForMultipleObjects(1, one, 0, ms);
}

BOOL CloseHandle(HANDLE h)
{
    /* NOT freed. A thread this process abandoned may still write through its object, and freeing
     * here would turn the abandon case - the one under test - into a use-after-free that the test
     * would report as the code's fault. Leaked on purpose, for the life of a short test run. */
    (void)h;
    return 1;
}
