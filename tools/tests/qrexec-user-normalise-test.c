/*
 * qrexec-user-normalise-test.c - offline suite for RELAYLOGONSYSTEM (findings/issues.md): qrexec-agent's
 * StartChild must hand qrexec-wrapper the literal "(null)" user - the wrapper's own-token spelling - for a
 * request that names the service's own account ("SYSTEM", dom0's "root", any case), on EVERY path.
 * Measured 2026-10-10 on win10-acc: the guest-originated qrexec-client-vm path passed "SYSTEM" through
 * verbatim, the wrapper called LogonUser("SYSTEM"), got 0x52e, and the dom0 toast relay never started. The
 * dom0-originated exec path had carried its own copy of the mapping since 2014 (ParseUtf8Command), so the
 * same string meant two things depending on which side asked.
 *
 * gcc on the dev qube, no Windows: tools/tests/qrexec-user-normalise-selftest.sh extracts NormalizeUserName
 * and StartChild VERBATIM from core-agent/src/qrexec-agent/qrexec-agent.c into startchild.c next to this
 * file - from the working tree, from the pre-fix revision, and from the fixed source with the normaliser
 * call cut out - and this file #includes it. CreateNormalProcessAsCurrentUser is stubbed to CAPTURE the
 * wrapper command line StartChild built, so every check reads the user field the real qrexec-wrapper would
 * parse (exec.c GetArgument splits on '|'; wmain maps only the literal "(null)" to its own token, and an
 * empty field reaches it as "" and takes the run-as path). _LogFormat is stubbed to keep the INFO line.
 * Prints "ok <case>" / "FAIL <case>"; exit 0 iff no FAIL. Case names that start with "pseudo:" are the
 * ones the defect breaks; the selftest requires that nothing else fails on the defect builds.
 *
 * What the stub printf MODELS rather than proves: MSVC's wide "%s" prints "(null)" for a NULL argument.
 * glibc's "%ls" does the same (the selftest probes it on this machine), the wrapper's own
 * wcscmp(userName, L"(null)") is the other end of that contract, and the dom0 path has run SYSTEM
 * services through it for years (qubes.VMShell as SYSTEM: whoami = nt authority\system).
 */
#include <stdio.h>
#include <stdarg.h>
#include <string.h>
#include <wchar.h>
#include <wctype.h>

#include <windows.h>    /* tools/tests/win32stub: types and arities only */
#include <strsafe.h>    /* tools/tests/win32stub: StringCchPrintf with MSVC's %s-is-wide idiom */
#include <log.h>        /* the REAL windows-utils header at the ref CI builds, so LogInfo/LogDebug are the shipped macros */

typedef WCHAR *PWSTR;
typedef const WCHAR *PCWSTR;
#define MAX_PATH_LONG 32768             /* qubes-io.h; only the command buffer's size, not under test */
#define QUBES_ARGUMENT_SEPARATOR L'|'   /* exec.h; the selftest asserts this against the header at the CI ref */

/* MSVC's CRT; glibc spells it wcscasecmp. ASCII-only lowering is all the two literals need. */
int _wcsicmp(const wchar_t *a, const wchar_t *b)
{
    for (;; a++, b++)
    {
        wint_t x = towlower((wint_t)*a), y = towlower((wint_t)*b);
        if (x != y) return x < y ? -1 : 1;
        if (!x) return 0;
    }
}

/* --- captured effects of the code under test ---------------------------------------------- */
static WCHAR g_command[2048];           /* the wrapper command line StartChild built */
static int g_createCalls;
static HANDLE g_fakeWrapper = (HANDLE)0x77;
static int g_registered, g_regDomain, g_regPort;
static HANDLE g_regHandle;
static WCHAR g_lastInfo[1024];          /* the last INFO line, formatted */
static int g_infoCalls, g_warnCalls, g_errCalls;

DWORD CreateNormalProcessAsCurrentUser(IN WCHAR *commandLine, OUT HANDLE *process)
{
    g_createCalls++;
    wcsncpy(g_command, commandLine, RTL_NUMBER_OF(g_command) - 1);
    g_command[RTL_NUMBER_OF(g_command) - 1] = 0;
    *process = g_fakeWrapper;
    return ERROR_SUCCESS;
}
static void register_vchan_connection(HANDLE handle, int domain, int port)
{
    g_registered++; g_regHandle = handle; g_regDomain = domain; g_regPort = port;
}
void _LogFormat(IN int level, IN BOOL raw, IN const char *functionName, IN const WCHAR *format, ...)
{
    va_list ap;
    (void)raw; (void)functionName;
    if (level == LOG_LEVEL_INFO)
    {
        g_infoCalls++;
        va_start(ap, format);
        StringCchVPrintfW(g_lastInfo, RTL_NUMBER_OF(g_lastInfo), format, ap);
        va_end(ap);
    }
    if (level == LOG_LEVEL_WARNING) g_warnCalls++;
    if (level == LOG_LEVEL_ERROR) g_errCalls++;
}

#include "startchild.c"   /* the functions the selftest extracted: fixed, pre-fix, or the knob */

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
    g_command[0] = 0; g_createCalls = 0; g_registered = 0; g_regDomain = g_regPort = 0; g_regHandle = NULL;
    g_lastInfo[0] = 0; g_infoCalls = g_warnCalls = g_errCalls = 0;
}
/* qrexec-wrapper.exe <domain>|<port>|<user>|<flags>|<command_line>: the five fields GetArgument would return */
static WCHAR g_field[5][1024];
static int split(void)
{
    const WCHAR *p = g_command;
    int n = 0;
    while (n < 5)
    {
        const WCHAR *sep = wcschr(p, QUBES_ARGUMENT_SEPARATOR);
        size_t len = sep && n < 4 ? (size_t)(sep - p) : wcslen(p);
        if (len >= RTL_NUMBER_OF(g_field[0])) len = RTL_NUMBER_OF(g_field[0]) - 1;
        wmemcpy(g_field[n], p, len); g_field[n][len] = 0;
        n++;
        if (!sep || n == 5) break;
        p = sep + 1;
    }
    return n;
}
static const WCHAR *g_cmd = L"\"C:\\Program Files\\Qubes Tools\\bin\\notifhost.exe\" --relay \\\\.\\pipe\\qubes-toast-bridge-1";
static DWORD run(const WCHAR *user, BOOL isServer, BOOL piped, BOOL interactive)
{
    DWORD rc;
    reset();
    /* StartChild takes PWSTR and never writes through either; the casts drop const on literals only */
    rc = StartChild(0, 514, (PWSTR)user, (PWSTR)g_cmd, isServer, piped, interactive);
    split();
    return rc;
}
static int user_is(const WCHAR *want) { return wcscmp(g_field[2], want) == 0; }
static int frame_intact(const WCHAR *flags)
{
    return wcscmp(g_field[0], L"qrexec-wrapper.exe 0") == 0 && wcscmp(g_field[1], L"514") == 0
        && wcscmp(g_field[3], flags) == 0 && wcscmp(g_field[4], g_cmd) == 0;
}

int main(void)
{
    DWORD rc;

    /* 1. THE DEFECT: the relay's request, exactly as win10-acc logged it (flags 7 = server|piped|interactive) */
    rc = run(L"SYSTEM", TRUE, TRUE, TRUE);
    check("pseudo: SYSTEM -> the wrapper's own-token spelling (null)", user_is(L"(null)"));
    check("pseudo: SYSTEM: one INFO line names the account that was requested", g_infoCalls == 1 && wcsstr(g_lastInfo, L"'SYSTEM'") != NULL);
    check("pseudo: SYSTEM: the INFO line says the service's own token is used instead", wcsstr(g_lastInfo, L"own account") != NULL && wcsstr(g_lastInfo, L"token") != NULL);
    printf("     wrapper line: %ls\n     info line:    %ls\n", g_command, g_lastInfo[0] ? g_lastInfo : L"(none)");
    check("SYSTEM: the rest of the wrapper line is untouched (domain, port, flags 7, command)", frame_intact(L"7"));
    check("SYSTEM: the wrapper was started once and registered on the data vchan", rc == ERROR_SUCCESS && g_createCalls == 1 && g_registered == 1 && g_regHandle == g_fakeWrapper && g_regDomain == 0 && g_regPort == 514);
    check("SYSTEM: an expected mapping is not an anomaly - nothing at WARNING or ERROR", g_warnCalls == 0 && g_errCalls == 0);

    /* 2. the account name is case-insensitive on Windows, so a dom0 service definition saying "system" names the same account */
    run(L"system", TRUE, TRUE, TRUE);
    check("pseudo: system (lower case) -> (null)", user_is(L"(null)") && g_infoCalls == 1);
    run(L"System", TRUE, TRUE, TRUE);
    check("pseudo: System (mixed case) -> (null)", user_is(L"(null)"));

    /* 3. dom0's Linux-side name for the same account */
    run(L"root", FALSE, TRUE, TRUE);
    check("pseudo: root -> (null)", user_is(L"(null)") && g_infoCalls == 1 && wcsstr(g_lastInfo, L"'root'") != NULL);
    run(L"ROOT", FALSE, TRUE, TRUE);
    check("pseudo: ROOT -> (null)", user_is(L"(null)"));

    /* 4. A REAL ACCOUNT TAKES THE RUN-AS PATH EXACTLY AS TODAY: the name goes through verbatim, no INFO line,
          so qrexec-wrapper's LogonUser / logged-on-token match and its degrade-to-SYSTEM warning stay reachable */
    run(L"user", TRUE, TRUE, TRUE);
    check("real: user -> user, verbatim", user_is(L"user") && frame_intact(L"7"));
    check("real: user: no INFO line, nothing at WARNING or ERROR", g_infoCalls == 0 && g_warnCalls == 0 && g_errCalls == 0);
    run(L"Max Mustermann", TRUE, TRUE, TRUE);
    check("real: a name with a space -> verbatim", user_is(L"Max Mustermann"));
    run(L"Administrator", FALSE, FALSE, FALSE);
    check("real: Administrator, flags 0 -> verbatim, flags 0", user_is(L"Administrator") && frame_intact(L"0"));

    /* 5. only the whole name: a prefix or a superstring is some other account */
    run(L"SYSTEMX", TRUE, TRUE, TRUE);
    check("real: SYSTEMX -> verbatim (no prefix match)", user_is(L"SYSTEMX") && g_infoCalls == 0);
    run(L"rootkit", TRUE, TRUE, TRUE);
    check("real: rootkit -> verbatim (no prefix match)", user_is(L"rootkit") && g_infoCalls == 0);
    run(L" SYSTEM", TRUE, TRUE, TRUE);
    check("real: ' SYSTEM' with a leading space -> verbatim (no trimming invented)", user_is(L" SYSTEM") && g_infoCalls == 0);

    /* 6. AN EMPTY NAME IS NOT MADE TO MEAN SYSTEM (Jev empty_field_is_safe 0.17): it goes through as the empty
          field it was; GetArgument returns "" for it and the wrapper takes the run-as path, as today */
    run(L"", TRUE, TRUE, TRUE);
    check("edge: empty name -> empty field, unchanged", user_is(L"") && g_infoCalls == 0 && frame_intact(L"7"));

    /* 7. a caller that already has no account (ParseUtf8Command failed, the dummy child) is unchanged */
    rc = run(NULL, FALSE, TRUE, TRUE);
    check("edge: NULL -> (null), as before", rc == ERROR_SUCCESS && user_is(L"(null)") && frame_intact(L"6"));
    check("edge: NULL: no INFO line (nothing was requested)", g_infoCalls == 0 && g_warnCalls == 0 && g_errCalls == 0);

    /* 8. pre-existing, neither added nor removed by this change: a client can already spell the own-token
          path as the literal "(null)" and the wrapper honours it (wmain: wcscmp(userName, L"(null)")) */
    run(L"(null)", TRUE, TRUE, TRUE);
    check("edge: the literal '(null)' from a client -> (null), verbatim, no INFO line", user_is(L"(null)") && g_infoCalls == 0);

    printf("%d checks, %d failed\n", g_run, g_fail);
    return g_fail ? 1 : 0;
}
