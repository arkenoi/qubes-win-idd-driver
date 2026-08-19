/*
 * qubesdb-read - a minimal, correct guest-side qubesdb value reader.
 *
 * Why this exists: the stock qubesdb-cmd.exe CLI mis-parses '/'-prefixed keys on Windows - its
 * getopt treats the leading '/' of every qubesdb key as a Windows slash-option, so e.g.
 * `qubesdb-cmd -c read /name` fails ("/n" -> option -n). The qubesdb CLIENT library is fine; only
 * that CLI's argument parsing is broken. This tool loads qubesdb-client.dll (shipped in System32)
 * at runtime via LoadLibrary/GetProcAddress and reads keys directly - no getopt, no build-time
 * dependency on core-qubesdb, so it builds as a plain console exe like the other tools/.
 *
 * The same read the C gui-agent does and that guest/qubesdb-read.ps1 does from PowerShell.
 *
 * Usage:  qubesdb-read <key> [<key> ...]
 *   Prints each key's value on its own line. A key with no value prints nothing (to stdout) and
 *   notes it on stderr. Exit code: 0 = every key read; 1 = at least one key absent; >=2 = setup
 *   error (bad usage / DLL / daemon).
 */
#include <windows.h>
#include <stdio.h>

typedef void *qdb_handle_t;
typedef qdb_handle_t(__cdecl *qdb_open_fn)(char *);
typedef char *(__cdecl *qdb_read_fn)(qdb_handle_t, char *, unsigned int *);
typedef void(__cdecl *qdb_close_fn)(qdb_handle_t);

int main(int argc, char **argv)
{
    if (argc < 2) {
        fprintf(stderr, "usage: qubesdb-read <key> [<key> ...]\n");
        return 2;
    }

    HMODULE lib = LoadLibraryA("qubesdb-client.dll");
    if (!lib) {
        fprintf(stderr, "qubesdb-read: cannot load qubesdb-client.dll (error %lu)\n",
                (unsigned long)GetLastError());
        return 3;
    }

    qdb_open_fn  qdb_open  = (qdb_open_fn)(void *)GetProcAddress(lib, "qdb_open");
    qdb_read_fn  qdb_read  = (qdb_read_fn)(void *)GetProcAddress(lib, "qdb_read");
    qdb_close_fn qdb_close = (qdb_close_fn)(void *)GetProcAddress(lib, "qdb_close");
    if (!qdb_open || !qdb_read || !qdb_close) {
        fprintf(stderr, "qubesdb-read: qubesdb-client.dll is missing expected exports\n");
        return 3;
    }

    qdb_handle_t h = qdb_open(NULL); /* NULL = the local daemon */
    if (!h) {
        fprintf(stderr, "qubesdb-read: qdb_open(local) failed - is qubesdb-daemon running?\n");
        return 4;
    }

    int rc = 0;
    for (int i = 1; i < argc; i++) {
        unsigned int len = 0;
        char *val = qdb_read(h, argv[i], &len);
        if (val) {
            fwrite(val, 1, len, stdout);
            fputc('\n', stdout);
            /* val is heap-allocated by qubesdb-client; no qdb_free is exported and the process is
             * short-lived, so leaking it is intentional. */
        } else {
            fprintf(stderr, "qubesdb-read: %s: <absent>\n", argv[i]);
            rc = 1;
        }
    }

    qdb_close(h);
    return rc;
}
