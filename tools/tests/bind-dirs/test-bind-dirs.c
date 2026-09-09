/*
 * Offline tests for core-agent/src/bind-dirs/bind-dirs.c - run by run.sh with gcc on Linux.
 *
 * Every guard is DEMONSTRATED: each refusal below is driven with input that must trip it and
 * asserted on the exact reason token, and for every refusal the fake FS mutation counter must
 * stay at zero (nothing touched). Failure injection covers each step of the seed/bind
 * sequence so the rollback is seen to restore the original directory.
 */
#include "fake-fs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <locale.h>

static int g_Failures = 0;
static int g_Checks = 0;
static const wchar_t *g_Case = L"";

#define CHECK(cond, ...) do { \
    g_Checks++; \
    if (!(cond)) { \
        g_Failures++; \
        wprintf(L"  FAIL [%ls] ", g_Case); wprintf(__VA_ARGS__); wprintf(L"  (%hs:%d)\n", __FILE__, __LINE__); \
    } } while (0)

#define CASE(name) do { g_Case = name; wprintf(L"- %ls\n", name); } while (0)

static FAKE_FS g_Fake;
static BD_FS g_Fs;

static void Fresh(void)
{
    FakeReset(&g_Fake);
    FakeInit(&g_Fake, &g_Fs);
    FakeAddDir(&g_Fake, L"C:\\");
    FakeAddDir(&g_Fake, L"Q:\\");
    FakeAddDir(&g_Fake, L"Q:\\bind-dirs");
    FakeAddDir(&g_Fake, L"C:\\ProgramData");
}

static int ListHas(const BD_LIST *l, const wchar_t *path)
{
    unsigned long i;
    for (i = 0; i < l->count; i++)
        if (wcscmp(l->entries[i].path, path) == 0)
            return 1;
    return 0;
}

// ------------------------------------------------------------------ config parsing

static BD_STATUS Parse(const wchar_t *text, BD_LIST *list, unsigned long *line, const wchar_t **err)
{
    return BdParseConfigText(&g_Fs, L"50_user.conf", text, list, line, err);
}

static void TestParseBasics(void)
{
    BD_LIST list;
    unsigned long line; const wchar_t *err;
    BD_STATUS s;

    CASE(L"parse: append forms, quotes, comments, CRLF, trailing comment");
    Fresh();
    memset(&list, 0, sizeof(list));
    s = Parse(L"# a comment\r\n"
              L"\r\n"
              L"binds+=( 'C:\\ProgramData\\Foo' )\r\n"
              L"binds+=( \"C:\\ProgramData\\Bar\" C:/ProgramData/Baz )   # trailing comment\r\n"
              L"   binds+=('C:\\ProgramData\\Quoted Space')\n"
              L"binds+=( \"C:\\\\ProgramData\\\\Esc\" )\n",
              &list, &line, &err);
    CHECK(s == BD_OK, L"parse failed at line %lu: %ls\n", line, err);
    CHECK(list.count == 5, L"count %lu != 5\n", list.count);
    CHECK(ListHas(&list, L"C:\\ProgramData\\Foo"), L"Foo missing\n");
    CHECK(ListHas(&list, L"C:\\ProgramData\\Bar"), L"Bar missing\n");
    CHECK(ListHas(&list, L"C:\\ProgramData\\Baz"), L"Baz (forward slashes) not normalized\n");
    CHECK(ListHas(&list, L"C:\\ProgramData\\Quoted Space"), L"quoted space missing\n");
    CHECK(ListHas(&list, L"C:\\ProgramData\\Esc"), L"double-quote \\\\ escape not honoured\n");
    CHECK(wcscmp(list.entries[0].source, L"50_user.conf:3") == 0, L"source '%ls' != 50_user.conf:3\n", list.entries[0].source);

    CASE(L"parse: replace, clear, removal idiom (quoted, unquoted, absent), later file removes earlier entry");
    memset(&list, 0, sizeof(list));
    s = Parse(L"binds+=( 'C:\\ProgramData\\A' 'C:\\ProgramData\\B' 'C:\\ProgramData\\C' )\n"
              L"binds=( \"${binds[@]/'C:\\ProgramData\\B'}\" )\n", &list, &line, &err);
    CHECK(s == BD_OK && list.count == 2 && !ListHas(&list, L"C:\\ProgramData\\B"), L"quoted removal idiom failed (count %lu)\n", list.count);
    s = Parse(L"binds=( \"${binds[@]/C:\\ProgramData\\A}\" )\n", &list, &line, &err);
    CHECK(s == BD_OK && list.count == 1 && ListHas(&list, L"C:\\ProgramData\\C"), L"unquoted removal idiom failed\n");
    s = Parse(L"binds=( \"${binds[@]/'c:\\programdata\\c'}\" )\n", &list, &line, &err);
    CHECK(s == BD_OK && list.count == 0, L"case-insensitive removal failed (count %lu)\n", list.count);
    s = Parse(L"binds+=( 'C:\\ProgramData\\X' )\nbinds=( \"${binds[@]/'C:\\ProgramData\\NotThere'}\" )\n", &list, &line, &err);
    CHECK(s == BD_OK && list.count == 1, L"removing an absent entry must be a no-op (bash semantics)\n");
    s = Parse(L"binds=( 'C:\\ProgramData\\Only' )\n", &list, &line, &err);
    CHECK(s == BD_OK && list.count == 1 && ListHas(&list, L"C:\\ProgramData\\Only"), L"binds=( ) replace failed\n");
    s = Parse(L"binds=()\n", &list, &line, &err);
    CHECK(s == BD_OK && list.count == 0, L"binds=() clear failed\n");
    s = Parse(L"binds+=()\n", &list, &line, &err);
    CHECK(s == BD_OK && list.count == 0, L"empty append failed\n");
}

static void ExpectSyntaxError(const wchar_t *text, const wchar_t *expectedErr, unsigned long expectedLine)
{
    BD_LIST list;
    unsigned long line = 0; const wchar_t *err = L"";
    BD_STATUS s;

    memset(&list, 0, sizeof(list));
    // Pre-populate so we can prove the list is untouched by a failed file.
    wcscpy(list.entries[0].path, L"C:\\ProgramData\\Pre");
    list.count = 1;
    s = Parse(text, &list, &line, &err);
    CHECK(BD_FAILED(s), L"'%ls' was ACCEPTED, expected error %ls\n", text, expectedErr);
    CHECK(wcscmp(err, expectedErr) == 0, L"'%ls': error '%ls' != expected '%ls'\n", text, err, expectedErr);
    CHECK(line == expectedLine, L"'%ls': line %lu != %lu\n", text, line, expectedLine);
    CHECK(list.count == 1 && wcscmp(list.entries[0].path, L"C:\\ProgramData\\Pre") == 0, L"'%ls': a failed file modified the list\n", text);
}

static void TestParseErrors(void)
{
    CASE(L"parse: every malformed line is refused with its token, list untouched");
    Fresh();
    ExpectSyntaxError(L"bind+=( 'C:\\x' )\n",                 L"unknown-statement", 1);
    ExpectSyntaxError(L"binds+= ( 'C:\\x' )\n",               L"expected-open-paren", 1);
    ExpectSyntaxError(L"binds+=( 'C:\\x'\n'C:\\y' )\n",        L"statement-incomplete", 1);
    ExpectSyntaxError(L"binds+=( 'C:\\x )\n",                  L"unterminated-quote", 1);
    ExpectSyntaxError(L"binds+=( \"C:\\x )\n",                 L"unterminated-quote", 1);
    ExpectSyntaxError(L"# ok\nbinds+=( C:\\ProgramData\\x )\n", L"bare-backslash-quote-the-path", 2);
    ExpectSyntaxError(L"binds+=( \"$HOME\\x\" )\n",             L"expansion-unsupported", 1);
    ExpectSyntaxError(L"binds+=( $HOME )\n",                    L"expansion-unsupported", 1);
    ExpectSyntaxError(L"binds+=( 'C:\\x' ) extra\n",            L"trailing-garbage", 1);
    ExpectSyntaxError(L"binds+=( \"${binds[@]/'C:\\x'}\" )\n",  L"removal-needs-assignment", 1);
    ExpectSyntaxError(L"binds+=( 'C:\\x'junk )\n",              L"bad-token", 1);
    ExpectSyntaxError(L"binds+=( ab'c' )\n",                    L"bad-token", 1);
    ExpectSyntaxError(L"binds=( \"${binds[@]/'C:\\x'\" )\n",    L"malformed-removal", 1);
    ExpectSyntaxError(L"binds+=( '' )\n",                       L"empty-element", 1);
    ExpectSyntaxError(L"echo hi\n",                             L"unknown-statement", 1);
    ExpectSyntaxError(L"binds+=( 'C:\\x' ))\n",                 L"trailing-garbage", 1);
}

static void TestDecode(void)
{
    wchar_t *text = NULL;
    BD_STATUS s;
    static const unsigned char utf8bom[] = { 0xEF, 0xBB, 0xBF, 'a', 'b', 0xC3, 0xA9 };            // "ab" + e-acute
    static const unsigned char utf16[]   = { 0xFF, 0xFE, 'a', 0, 'b', 0, 0xE9, 0 };
    static const unsigned char bad[]     = { 'a', 0xC3 };                                        // truncated sequence
    static const unsigned char overlong[] = { 0xC0, 0x80 };
    static const unsigned char nul[]     = { 'a', 0, 'b' };
    static const unsigned char astral[]  = { 0xF0, 0x9F, 0x98, 0x80 };                          // U+1F600

    CASE(L"decode: UTF-8 (BOM/no BOM), UTF-16LE BOM, invalid UTF-8, NUL, astral");
    Fresh();
    s = BdDecodeText(&g_Fs, utf8bom, sizeof(utf8bom), &text);
    CHECK(s == BD_OK && text && wcscmp(text, L"ab\u00e9") == 0, L"utf8 bom decode\n");
    free(text); text = NULL;
    s = BdDecodeText(&g_Fs, utf8bom + 3, sizeof(utf8bom) - 3, &text);
    CHECK(s == BD_OK && text && wcscmp(text, L"ab\u00e9") == 0, L"utf8 no-bom decode\n");
    free(text); text = NULL;
    s = BdDecodeText(&g_Fs, utf16, sizeof(utf16), &text);
    CHECK(s == BD_OK && text && wcscmp(text, L"ab\u00e9") == 0, L"utf16 decode\n");
    free(text); text = NULL;
    s = BdDecodeText(&g_Fs, bad, sizeof(bad), &text);
    CHECK(BD_FAILED(s) && text == NULL, L"truncated utf8 must fail\n");
    s = BdDecodeText(&g_Fs, overlong, sizeof(overlong), &text);
    CHECK(BD_FAILED(s), L"overlong utf8 must fail\n");
    s = BdDecodeText(&g_Fs, nul, sizeof(nul), &text);
    CHECK(BD_FAILED(s), L"embedded NUL must fail\n");
    s = BdDecodeText(&g_Fs, astral, sizeof(astral), &text);
    CHECK(s == BD_OK && text && (unsigned long)text[0] == 0x1F600UL, L"astral decode (32-bit wchar host)\n");
    free(text);
}

static void TestLoadConfig(void)
{
    BD_LIST list;
    BD_STATUS s;
    const wchar_t *dirs[3] = { L"C:\\Program Files\\Qubes Tools\\qubes-bind-dirs.d", L"C:\\ProgramData\\Qubes\\qubes-bind-dirs.d", L"Q:\\config\\qubes-bind-dirs.d" };

    CASE(L"load: lexical order across files, later file removes earlier entry, non-.conf ignored, missing dir skipped");
    Fresh();
    FakeAddDir(&g_Fake, L"Q:\\config");
    FakeAddDir(&g_Fake, L"Q:\\config\\qubes-bind-dirs.d");
    FakeAddFile(&g_Fake, L"Q:\\config\\qubes-bind-dirs.d\\50_user.conf", "binds+=( 'C:\\ProgramData\\User' )\nbinds=( \"${binds[@]/'C:\\ProgramData\\Early'}\" )\n");
    FakeAddFile(&g_Fake, L"Q:\\config\\qubes-bind-dirs.d\\10_early.conf", "binds+=( 'C:\\ProgramData\\Early' )\n");
    FakeAddFile(&g_Fake, L"Q:\\config\\qubes-bind-dirs.d\\README.txt", "binds+=( 'C:\\ProgramData\\NotConf' )\n");
    FakeAddFile(&g_Fake, L"Q:\\config\\qubes-bind-dirs.d\\90_late.CONF", "binds+=( 'C:\\ProgramData\\Late' )\n");
    FakeAddDir(&g_Fake, L"C:\\ProgramData\\Qubes");
    FakeAddDir(&g_Fake, L"C:\\ProgramData\\Qubes\\qubes-bind-dirs.d");
    FakeAddFile(&g_Fake, L"C:\\ProgramData\\Qubes\\qubes-bind-dirs.d\\30_admin.conf", "binds+=( 'C:\\ProgramData\\Admin' )\n");
    memset(&list, 0, sizeof(list));
    s = BdLoadConfig(&g_Fs, dirs, 3, &list);
    CHECK(s == BD_OK, L"load failed\n");
    CHECK(list.count == 3, L"count %lu != 3\n", list.count);
    CHECK(!ListHas(&list, L"C:\\ProgramData\\Early"), L"50_user.conf must remove 10_early.conf's entry (order)\n");
    CHECK(!ListHas(&list, L"C:\\ProgramData\\NotConf"), L"README.txt must be ignored\n");
    CHECK(ListHas(&list, L"C:\\ProgramData\\Late"), L".CONF (case) must be read\n");
    CHECK(list.count >= 1 && wcscmp(list.entries[0].path, L"C:\\ProgramData\\Admin") == 0, L"ProgramData dir must load before Q:\\config\n");

    CASE(L"load: a malformed file fails the whole load (bash -n semantics)");
    FakeAddFile(&g_Fake, L"Q:\\config\\qubes-bind-dirs.d\\60_bad.conf", "binds+=( C:\\bare )\n");
    memset(&list, 0, sizeof(list));
    s = BdLoadConfig(&g_Fs, dirs, 3, &list);
    CHECK(BD_FAILED(s), L"malformed file must fail the load\n");

    CASE(L"load: binary/invalid text fails the load");
    Fresh();
    FakeAddDir(&g_Fake, L"Q:\\config");
    FakeAddDir(&g_Fake, L"Q:\\config\\qubes-bind-dirs.d");
    FakeAddFile(&g_Fake, L"Q:\\config\\qubes-bind-dirs.d\\50_user.conf", "binds+=( '\xff\xfe' )\n");
    memset(&list, 0, sizeof(list));
    s = BdLoadConfig(&g_Fs, dirs, 3, &list);
    CHECK(BD_FAILED(s), L"invalid UTF-8 must fail the load\n");

    CASE(L"load: no config directories at all -> empty list, success");
    Fresh();
    memset(&list, 0, sizeof(list));
    s = BdLoadConfig(&g_Fs, dirs, 3, &list);
    CHECK(s == BD_OK && list.count == 0, L"empty config must succeed with 0 entries\n");
}

// ------------------------------------------------------------------ path validation

static void ExpectRefused(const wchar_t *input, const wchar_t *expected)
{
    wchar_t out[BD_MAX_PATH];
    const wchar_t *reason = L"";
    BD_STATUS s = BdValidatePath(&g_Fs, input, out, BD_MAX_PATH, &reason);
    CHECK(BD_FAILED(s), L"'%ls' was ACCEPTED (expected %ls)\n", input, expected);
    CHECK(wcscmp(reason, expected) == 0, L"'%ls': reason '%ls' != '%ls'\n", input, reason, expected);
}

static void ExpectAccepted(const wchar_t *input, const wchar_t *normalized)
{
    wchar_t out[BD_MAX_PATH];
    const wchar_t *reason = L"";
    BD_STATUS s = BdValidatePath(&g_Fs, input, out, BD_MAX_PATH, &reason);
    CHECK(s == BD_OK, L"'%ls' refused: %ls\n", input, reason);
    CHECK(s == BD_OK && wcscmp(out, normalized) == 0, L"'%ls' normalized to '%ls' != '%ls'\n", input, out, normalized);
}

static void TestValidatePath(void)
{
    wchar_t longPath[BD_MAX_PATH + 16];
    size_t i;

    CASE(L"validate: refusals, each with its token");
    Fresh();
    ExpectRefused(L"",                          L"not-absolute-c");
    ExpectRefused(L"C:",                        L"root");
    ExpectRefused(L"C:\\",                      L"root");
    ExpectRefused(L"c:/",                       L"root");
    ExpectRefused(L"C:\\\\",                    L"root");
    ExpectRefused(L"D:\\Data",                  L"cross-volume");
    ExpectRefused(L"Q:\\bind-dirs\\x",          L"cross-volume");
    ExpectRefused(L"\\\\server\\share\\x",      L"unc-or-device-path");
    ExpectRefused(L"\\\\?\\C:\\x",              L"unc-or-device-path");
    ExpectRefused(L"\\\\.\\C:\\x",              L"unc-or-device-path");
    ExpectRefused(L"\\x",                       L"not-absolute-c");
    ExpectRefused(L"foo\\bar",                  L"not-absolute-c");
    ExpectRefused(L"C:foo",                     L"not-absolute-c");
    ExpectRefused(L"C:\\a\\..\\b",              L"dot-component");
    ExpectRefused(L"C:\\a\\.",                  L"dot-component");
    ExpectRefused(L"C:\\..",                    L"dot-component");
    ExpectRefused(L"C:\\a\\\\b",                L"empty-component");
    ExpectRefused(L"C:\\a\\b\\\\",              L"empty-component");
    ExpectRefused(L"C:\\a<b",                   L"bad-character");
    ExpectRefused(L"C:\\a|b",                   L"bad-character");
    ExpectRefused(L"C:\\a*",                    L"bad-character");
    ExpectRefused(L"C:\\a?",                    L"bad-character");
    ExpectRefused(L"C:\\a:b",                   L"bad-character");
    ExpectRefused(L"C:\\a\"b",                  L"bad-character");
    ExpectRefused(L"C:\\a \\b",                 L"bad-character");   // trailing space in component
    ExpectRefused(L"C:\\a.\\b",                 L"bad-character");   // trailing dot in component
    ExpectRefused(L"C:\\a\tb",                  L"bad-character");
    ExpectRefused(L"C:\\Windows",               L"protected");
    ExpectRefused(L"C:\\windows\\System32",     L"protected");
    ExpectRefused(L"C:\\WINDOWS\\Temp\\x",      L"protected");
    ExpectRefused(L"C:\\Program Files\\Qubes Tools",       L"protected");
    ExpectRefused(L"C:\\Program Files\\Qubes Tools\\bin",  L"protected");
    ExpectRefused(L"C:\\Users",                 L"protected");
    ExpectRefused(L"C:\\users\\",               L"protected");
    ExpectRefused(L"C:\\Program Files",         L"protected");
    ExpectRefused(L"C:\\Program Files (x86)",   L"protected");
    ExpectRefused(L"C:\\ProgramData",           L"protected");
    ExpectRefused(L"C:\\Recovery",              L"protected");
    ExpectRefused(L"C:\\System Volume Information", L"protected");
    ExpectRefused(L"C:\\$Recycle.Bin",          L"protected");
    ExpectRefused(L"C:\\a\\foo.qbd-orig",       L"reserved-suffix");
    ExpectRefused(L"C:\\a\\FOO.QBD-SEEDING\\b", L"reserved-suffix");
    for (i = 0; i < BD_MAX_PATH + 10; i++)
        longPath[i] = (i == 1) ? L':' : (i == 2) ? L'\\' : L'a';
    longPath[0] = L'C';
    longPath[BD_MAX_PATH + 10] = 0;
    ExpectRefused(longPath,                     L"too-long");

    CASE(L"validate: accepted forms and normalization");
    ExpectAccepted(L"C:\\ProgramData\\Foo",     L"C:\\ProgramData\\Foo");
    ExpectAccepted(L"c:/ProgramData/Foo/",      L"C:\\ProgramData\\Foo");
    ExpectAccepted(L"C:\\Users\\Public",        L"C:\\Users\\Public");      // subdir OK at validation; runtime ancestor check decides
    ExpectAccepted(L"C:\\Program Files\\Vendor\\App", L"C:\\Program Files\\Vendor\\App");
    ExpectAccepted(L"C:\\Program Files\\Qubes Toolsmith", L"C:\\Program Files\\Qubes Toolsmith"); // not the protected subtree
    ExpectAccepted(L"C:\\Windows2\\x",          L"C:\\Windows2\\x");
    ExpectAccepted(L"C:\\Data\\with space\\a.b", L"C:\\Data\\with space\\a.b");

    CASE(L"rw mapping: C:\\Dir\\Sub -> Q:\\bind-dirs\\Dir\\Sub");
    {
        wchar_t rw[BD_MAX_PATH];
        CHECK(BdRwFromRo(L"C:\\ProgramData\\Foo", rw, BD_MAX_PATH) == BD_OK && wcscmp(rw, L"Q:\\bind-dirs\\ProgramData\\Foo") == 0, L"rw '%ls'\n", rw);
    }
}

// ------------------------------------------------------------------ execution

static void SeedSource(void)
{
    FakeAddDir(&g_Fake, L"C:\\ProgramData\\Foo");
    FakeAddFile(&g_Fake, L"C:\\ProgramData\\Foo\\a.txt", "template-a");
    FakeAddDir(&g_Fake, L"C:\\ProgramData\\Foo\\sub");
    FakeAddFile(&g_Fake, L"C:\\ProgramData\\Foo\\sub\\b.txt", "template-b");
}

static int IsOurJunction(const wchar_t *ro, const wchar_t *rw)
{
    FAKE_NODE *n = FakeFind(&g_Fake, ro);
    wchar_t want[BD_MAX_PATH];
    if (!n || n->kind != FN_JUNCTION)
        return 0;
    wcscpy(want, L"\\??\\");
    wcscat(want, rw);
    return wcscmp(n->target, want) == 0;
}

static int SourceIntact(void)
{
    FAKE_NODE *n = FakeFind(&g_Fake, L"C:\\ProgramData\\Foo");
    return n && n->kind == FN_DIR &&
           FakeFileHas(&g_Fake, L"C:\\ProgramData\\Foo\\a.txt", "template-a") &&
           FakeFileHas(&g_Fake, L"C:\\ProgramData\\Foo\\sub\\b.txt", "template-b") &&
           FakeFind(&g_Fake, L"C:\\ProgramData\\Foo.qbd-orig") == NULL;
}

static void TestApplyHappyPaths(void)
{
    BD_ENTRY_RESULT r;
    unsigned long before;

    CASE(L"apply: first use seeds Q:, replaces C: dir with junction, removes moved-aside original");
    Fresh();
    SeedSource();
    BdApplyEntry(&g_Fs, L"C:\\ProgramData\\Foo", &r);
    CHECK(wcscmp(r.result, L"ok") == 0 && wcscmp(r.reason, L"bound") == 0, L"result %ls/%ls\n", r.result, r.reason);
    CHECK(r.seeded == 1, L"seeded flag\n");
    CHECK(IsOurJunction(L"C:\\ProgramData\\Foo", L"Q:\\bind-dirs\\ProgramData\\Foo"), L"C: side is not our junction\n");
    CHECK(FakeFileHas(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo\\a.txt", "template-a"), L"seed a.txt\n");
    CHECK(FakeFileHas(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo\\sub\\b.txt", "template-b"), L"seed sub/b.txt\n");
    CHECK(FakeFind(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo.qbd-seeding") == NULL, L"staging dir left behind\n");
    CHECK(FakeFind(&g_Fake, L"C:\\ProgramData\\Foo.qbd-orig") == NULL, L"moved-aside original left behind\n");
    CHECK(FakeCountUnder(&g_Fake, L"C:\\ProgramData\\Foo") == 0, L"junction must have no children of its own\n");

    CASE(L"apply: idempotent - second run is a no-op with zero mutations and no re-seed");
    before = g_Fake.mutations;
    g_Fake.copyBytes = 0;
    BdApplyEntry(&g_Fs, L"C:\\ProgramData\\Foo", &r);
    CHECK(wcscmp(r.result, L"ok") == 0 && wcscmp(r.reason, L"already-bound") == 0, L"result %ls/%ls\n", r.result, r.reason);
    CHECK(g_Fake.mutations == before, L"%lu mutations on an already-bound path\n", g_Fake.mutations - before);
    CHECK(g_Fake.copyBytes == 0 && r.seeded == 0, L"re-seeded on a no-op run\n");

    CASE(L"apply: never re-seed - existing Q: data wins over C: content (AppVM reboot case)");
    Fresh();
    SeedSource();   // C: is back to template content (volatile root)
    FakeAddDir(&g_Fake, L"Q:\\bind-dirs\\ProgramData");
    FakeAddDir(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo");
    FakeAddFile(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo\\a.txt", "USER-DATA");
    g_Fake.copyBytes = 0;
    BdApplyEntry(&g_Fs, L"C:\\ProgramData\\Foo", &r);
    CHECK(wcscmp(r.result, L"ok") == 0 && r.seeded == 0, L"result %ls/%ls seeded=%d\n", r.result, r.reason, r.seeded);
    CHECK(g_Fake.copyBytes == 0, L"copied %lu bytes although the seed existed\n", g_Fake.copyBytes);
    CHECK(FakeFileHas(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo\\a.txt", "USER-DATA"), L"user data on Q: was overwritten\n");
    CHECK(IsOurJunction(L"C:\\ProgramData\\Foo", L"Q:\\bind-dirs\\ProgramData\\Foo"), L"junction not re-created on the volatile C:\n");
    CHECK(FakeFind(&g_Fake, L"C:\\ProgramData\\Foo.qbd-orig") == NULL, L"template copy left on C:\n");

    CASE(L"apply: rw exists, ro absent -> parents + junction created (Linux mk_parent_dirs case)");
    Fresh();
    FakeAddDir(&g_Fake, L"Q:\\bind-dirs\\Data");
    FakeAddDir(&g_Fake, L"Q:\\bind-dirs\\Data\\App");
    FakeAddDir(&g_Fake, L"Q:\\bind-dirs\\Data\\App\\State");
    BdApplyEntry(&g_Fs, L"C:\\Data\\App\\State", &r);
    CHECK(wcscmp(r.result, L"ok") == 0 && wcscmp(r.reason, L"bound") == 0 && r.seeded == 0, L"result %ls/%ls\n", r.result, r.reason);
    CHECK(FakeFind(&g_Fake, L"C:\\Data") && FakeFind(&g_Fake, L"C:\\Data\\App"), L"parents not created\n");
    CHECK(IsOurJunction(L"C:\\Data\\App\\State", L"Q:\\bind-dirs\\Data\\App\\State"), L"junction\n");

    CASE(L"apply: stale staging dir from an interrupted seed is discarded and the seed redone from C:");
    Fresh();
    SeedSource();
    FakeAddDir(&g_Fake, L"Q:\\bind-dirs\\ProgramData");
    FakeAddDir(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo.qbd-seeding");
    FakeAddFile(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo.qbd-seeding\\a.txt", "half");
    BdApplyEntry(&g_Fs, L"C:\\ProgramData\\Foo", &r);
    CHECK(wcscmp(r.result, L"ok") == 0 && r.seeded == 1, L"result %ls/%ls\n", r.result, r.reason);
    CHECK(FakeFileHas(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo\\a.txt", "template-a"), L"seed must come from C:, not the stale staging\n");
    CHECK(FakeFind(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo.qbd-seeding") == NULL, L"stale staging not removed\n");

    CASE(L"apply: stale .qbd-orig from an interrupted bind is removed (seed is committed, so it is a duplicate)");
    Fresh();
    FakeAddDir(&g_Fake, L"Q:\\bind-dirs\\ProgramData");
    FakeAddDir(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo");
    FakeAddFile(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo\\a.txt", "committed");
    FakeAddDir(&g_Fake, L"C:\\ProgramData\\Foo.qbd-orig");
    FakeAddFile(&g_Fake, L"C:\\ProgramData\\Foo.qbd-orig\\a.txt", "dup");
    BdApplyEntry(&g_Fs, L"C:\\ProgramData\\Foo", &r);
    CHECK(wcscmp(r.result, L"ok") == 0, L"result %ls/%ls\n", r.result, r.reason);
    CHECK(FakeFind(&g_Fake, L"C:\\ProgramData\\Foo.qbd-orig") == NULL, L"stale orig not removed\n");
    CHECK(FakeFileHas(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo\\a.txt", "committed"), L"committed seed disturbed\n");

    CASE(L"apply: bound but the moved-aside original could not be deleted -> ok with warning");
    Fresh();
    SeedSource();
    wcscpy(g_Fake.failDelete, L"C:\\ProgramData\\Foo.qbd-orig");
    BdApplyEntry(&g_Fs, L"C:\\ProgramData\\Foo", &r);
    CHECK(wcscmp(r.result, L"ok") == 0 && r.warning == 1, L"result %ls/%ls warning=%d\n", r.result, r.reason, r.warning);
    CHECK(IsOurJunction(L"C:\\ProgramData\\Foo", L"Q:\\bind-dirs\\ProgramData\\Foo"), L"junction\n");
}

static void ExpectApplyRefusedUntouched(const wchar_t *ro, const wchar_t *reason)
{
    BD_ENTRY_RESULT r;
    unsigned long before = g_Fake.mutations;
    BdApplyEntry(&g_Fs, ro, &r);
    CHECK(wcscmp(r.result, L"failed") == 0, L"%ls: result '%ls' (expected failed/%ls)\n", ro, r.result, reason);
    CHECK(wcscmp(r.reason, reason) == 0, L"%ls: reason '%ls' != '%ls'\n", ro, r.reason, reason);
    CHECK(g_Fake.mutations == before, L"%ls: refusal performed %lu mutation(s)\n", ro, g_Fake.mutations - before);
}

static void TestApplyRefusals(void)
{
    CASE(L"apply: source missing and nothing seeded -> failed/source-missing (Linux would skip silently)");
    Fresh();
    ExpectApplyRefusedUntouched(L"C:\\ProgramData\\Typo", L"source-missing");

    CASE(L"apply: a file -> failed/file-unsupported");
    Fresh();
    FakeAddFile(&g_Fake, L"C:\\ProgramData\\settings.ini", "x");
    ExpectApplyRefusedUntouched(L"C:\\ProgramData\\settings.ini", L"file-unsupported");

    CASE(L"apply: existing reparse point that is not ours (junction elsewhere) -> failed/foreign-reparse-point");
    Fresh();
    FakeAddJunction(&g_Fake, L"C:\\ProgramData\\Foo", L"\\??\\D:\\Elsewhere");
    ExpectApplyRefusedUntouched(L"C:\\ProgramData\\Foo", L"foreign-reparse-point");

    CASE(L"apply: existing symlink even to the right target (wrong tag) -> failed/foreign-reparse-point");
    Fresh();
    FakeAddSymlink(&g_Fake, L"C:\\ProgramData\\Foo", L"\\??\\Q:\\bind-dirs\\ProgramData\\Foo");
    ExpectApplyRefusedUntouched(L"C:\\ProgramData\\Foo", L"foreign-reparse-point");

    CASE(L"apply: our junction to a different bind-dirs path -> failed/foreign-reparse-point");
    Fresh();
    FakeAddJunction(&g_Fake, L"C:\\ProgramData\\Foo", L"\\??\\Q:\\bind-dirs\\ProgramData\\Other");
    ExpectApplyRefusedUntouched(L"C:\\ProgramData\\Foo", L"foreign-reparse-point");

    CASE(L"apply: ancestor is a reparse point (C:\\Users after MoveUsers) -> failed/reparse-ancestor");
    Fresh();
    FakeAddSymlink(&g_Fake, L"C:\\Users", L"\\??\\Q:\\Users");
    ExpectApplyRefusedUntouched(L"C:\\Users\\Public\\Documents", L"reparse-ancestor");
    FakeAddDir(&g_Fake, L"C:\\Links");
    FakeAddJunction(&g_Fake, L"C:\\Links\\J", L"\\??\\C:\\ProgramData");
    ExpectApplyRefusedUntouched(L"C:\\Links\\J\\Deep", L"reparse-ancestor");

    CASE(L"apply: our junction dangling (Q: side removed) -> failed/target-missing, no re-seed");
    Fresh();
    FakeAddJunction(&g_Fake, L"C:\\ProgramData\\Foo", L"\\??\\Q:\\bind-dirs\\ProgramData\\Foo");
    ExpectApplyRefusedUntouched(L"C:\\ProgramData\\Foo", L"target-missing");

    CASE(L"apply: Q: side exists but is a file / a reparse point -> failed/target-not-directory");
    Fresh();
    SeedSource();
    FakeAddDir(&g_Fake, L"Q:\\bind-dirs\\ProgramData");
    FakeAddFile(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo", "not a dir");
    ExpectApplyRefusedUntouched(L"C:\\ProgramData\\Foo", L"target-not-directory");
    Fresh();
    SeedSource();
    FakeAddDir(&g_Fake, L"Q:\\bind-dirs\\ProgramData");
    FakeAddJunction(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo", L"\\??\\C:\\ProgramData\\Foo");
    ExpectApplyRefusedUntouched(L"C:\\ProgramData\\Foo", L"target-not-directory");

    CASE(L"apply: stat failure is reported, not skipped");
    Fresh();
    SeedSource();
    wcscpy(g_Fake.failStat, L"C:\\ProgramData\\Foo");
    ExpectApplyRefusedUntouched(L"C:\\ProgramData\\Foo", L"stat-source");
}

static void TestApplyFailureInjection(void)
{
    BD_ENTRY_RESULT r;

    CASE(L"inject: seed copy fails half-way -> partial copy removed, C: untouched, failed/seed-copy");
    Fresh();
    SeedSource();
    wcscpy(g_Fake.failCopyTo, L"Q:\\bind-dirs\\ProgramData\\Foo.qbd-seeding");
    g_Fake.copyPartialNodes = 1;
    BdApplyEntry(&g_Fs, L"C:\\ProgramData\\Foo", &r);
    CHECK(wcscmp(r.result, L"failed") == 0 && wcscmp(r.reason, L"seed-copy") == 0, L"result %ls/%ls\n", r.result, r.reason);
    CHECK(SourceIntact(), L"C: source damaged\n");
    CHECK(FakeFind(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo") == NULL, L"a failed seed must not leave Q:\\bind-dirs\\...\\Foo (it would be mistaken for a complete seed)\n");
    CHECK(FakeFind(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo.qbd-seeding") == NULL, L"partial staging not removed\n");

    CASE(L"inject: seed commit (rename) fails -> staging removed, C: untouched, failed/seed-commit");
    Fresh();
    SeedSource();
    wcscpy(g_Fake.failRenameFrom, L"Q:\\bind-dirs\\ProgramData\\Foo.qbd-seeding");
    BdApplyEntry(&g_Fs, L"C:\\ProgramData\\Foo", &r);
    CHECK(wcscmp(r.reason, L"seed-commit") == 0, L"reason %ls\n", r.reason);
    CHECK(SourceIntact(), L"C: source damaged\n");
    CHECK(FakeFind(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo") == NULL && FakeFind(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo.qbd-seeding") == NULL, L"Q: side not cleaned\n");

    CASE(L"inject: cannot create Q:\\bind-dirs parent -> failed/seed-parent, C: untouched");
    Fresh();
    SeedSource();
    wcscpy(g_Fake.failMkdir, L"Q:\\bind-dirs\\ProgramData");
    BdApplyEntry(&g_Fs, L"C:\\ProgramData\\Foo", &r);
    CHECK(wcscmp(r.reason, L"seed-parent") == 0, L"reason %ls\n", r.reason);
    CHECK(SourceIntact(), L"C: source damaged\n");

    CASE(L"inject: move-aside fails (dir in use) -> C: untouched, seed kept on Q:, failed/move-aside");
    Fresh();
    SeedSource();
    wcscpy(g_Fake.failRenameFrom, L"C:\\ProgramData\\Foo");
    BdApplyEntry(&g_Fs, L"C:\\ProgramData\\Foo", &r);
    CHECK(wcscmp(r.reason, L"move-aside") == 0, L"reason %ls\n", r.reason);
    CHECK(SourceIntact(), L"C: source damaged\n");
    CHECK(r.seeded == 1 && FakeFileHas(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo\\a.txt", "template-a"), L"a completed seed must be kept\n");

    CASE(L"inject: mkdir after move-aside fails -> original renamed back, failed/mkdir");
    Fresh();
    SeedSource();
    wcscpy(g_Fake.failMkdir, L"C:\\ProgramData\\Foo");
    BdApplyEntry(&g_Fs, L"C:\\ProgramData\\Foo", &r);
    CHECK(wcscmp(r.reason, L"mkdir") == 0, L"reason %ls\n", r.reason);
    CHECK(SourceIntact(), L"rollback did not restore the original\n");
    CHECK(r.rollbackFailed == 0, L"rollbackFailed set although rollback worked\n");

    CASE(L"inject: junction fails -> empty dir removed, original renamed back, failed/junction");
    Fresh();
    SeedSource();
    wcscpy(g_Fake.failJunction, L"C:\\ProgramData\\Foo");
    BdApplyEntry(&g_Fs, L"C:\\ProgramData\\Foo", &r);
    CHECK(wcscmp(r.reason, L"junction") == 0, L"reason %ls\n", r.reason);
    CHECK(SourceIntact(), L"rollback did not restore the original\n");

    CASE(L"inject: junction fails on the next boot too, then succeeds - seed is reused, never redone");
    g_Fake.failJunction[0] = 0;
    g_Fake.copyBytes = 0;
    BdApplyEntry(&g_Fs, L"C:\\ProgramData\\Foo", &r);
    CHECK(wcscmp(r.result, L"ok") == 0 && r.seeded == 0 && g_Fake.copyBytes == 0, L"retry after a failed bind re-seeded (%lu bytes)\n", g_Fake.copyBytes);
    CHECK(IsOurJunction(L"C:\\ProgramData\\Foo", L"Q:\\bind-dirs\\ProgramData\\Foo"), L"junction\n");

    CASE(L"inject: junction fails AND the rename-back fails -> rollbackFailed=1, reported loudly");
    Fresh();
    SeedSource();
    wcscpy(g_Fake.failJunction, L"C:\\ProgramData\\Foo");
    wcscpy(g_Fake.failRenameFrom, L"C:\\ProgramData\\Foo.qbd-orig");
    BdApplyEntry(&g_Fs, L"C:\\ProgramData\\Foo", &r);
    CHECK(wcscmp(r.result, L"failed") == 0 && wcscmp(r.reason, L"junction") == 0, L"result %ls/%ls\n", r.result, r.reason);
    CHECK(r.rollbackFailed == 1, L"rollbackFailed must be set\n");
    CHECK(FakeFind(&g_Fake, L"C:\\ProgramData\\Foo.qbd-orig") != NULL, L"the data must still exist under the moved-aside name\n");

    CASE(L"inject: FSCTL 'succeeds' but the junction did not take (verify) -> rolled back, failed/verify");
    Fresh();
    SeedSource();
    g_Fake.junctionSilentNoop = 1;
    BdApplyEntry(&g_Fs, L"C:\\ProgramData\\Foo", &r);
    CHECK(wcscmp(r.result, L"failed") == 0 && wcscmp(r.reason, L"verify") == 0, L"result %ls/%ls\n", r.result, r.reason);
    CHECK(SourceIntact(), L"rollback did not restore the original\n");
    CHECK(FakeFileHas(&g_Fake, L"Q:\\bind-dirs\\ProgramData\\Foo\\a.txt", "template-a"), L"the committed seed must be kept\n");
}

static void TestRun(void)
{
    BD_LIST list;
    BD_ENTRY_RESULT results[8];
    BD_REPORT report;
    BD_STATUS s;

    CASE(L"run: validation failures, duplicates, nesting decided BEFORE anything is applied");
    Fresh();
    SeedSource();
    FakeAddDir(&g_Fake, L"C:\\ProgramData\\Nest");
    FakeAddDir(&g_Fake, L"C:\\ProgramData\\Nest\\Inner");
    memset(&list, 0, sizeof(list));
    wcscpy(list.entries[0].path, L"C:\\ProgramData\\Foo");         wcscpy(list.entries[0].source, L"a.conf:1");
    wcscpy(list.entries[1].path, L"C:\\Windows\\Temp");             wcscpy(list.entries[1].source, L"a.conf:2");
    wcscpy(list.entries[2].path, L"c:\\programdata\\foo");         wcscpy(list.entries[2].source, L"b.conf:1"); // duplicate
    wcscpy(list.entries[3].path, L"C:\\ProgramData\\Nest");        wcscpy(list.entries[3].source, L"b.conf:2");
    wcscpy(list.entries[4].path, L"C:\\ProgramData\\Nest\\Inner"); wcscpy(list.entries[4].source, L"b.conf:3"); // nested
    wcscpy(list.entries[5].path, L"D:\\x");                        wcscpy(list.entries[5].source, L"b.conf:4");
    list.count = 6;
    s = BdRun(&g_Fs, &list, results, &report);
    CHECK(BD_FAILED(s), L"a run with failures must fail overall\n");
    CHECK(wcscmp(results[0].result, L"ok") == 0 && wcscmp(results[0].reason, L"bound") == 0, L"[0] %ls/%ls\n", results[0].result, results[0].reason);
    CHECK(wcscmp(results[1].reason, L"protected") == 0, L"[1] %ls\n", results[1].reason);
    CHECK(wcscmp(results[2].result, L"ok") == 0 && wcscmp(results[2].reason, L"duplicate") == 0, L"[2] %ls/%ls\n", results[2].result, results[2].reason);
    CHECK(wcscmp(results[3].reason, L"nested") == 0 && wcscmp(results[3].result, L"failed") == 0, L"[3] %ls/%ls\n", results[3].result, results[3].reason);
    CHECK(wcscmp(results[4].reason, L"nested") == 0, L"[4] %ls\n", results[4].reason);
    CHECK(wcscmp(results[5].reason, L"cross-volume") == 0, L"[5] %ls\n", results[5].reason);
    CHECK(FakeFind(&g_Fake, L"C:\\ProgramData\\Nest")->kind == FN_DIR, L"nested entries must not be touched\n");
    CHECK(report.total == 6 && report.ok == 2 && report.failed == 4 && report.seeded == 1, L"report total=%lu ok=%lu failed=%lu seeded=%lu\n", report.total, report.ok, report.failed, report.seeded);

    CASE(L"run: all good -> BD_OK; second run all already-bound with zero mutations");
    Fresh();
    SeedSource();
    FakeAddDir(&g_Fake, L"C:\\ProgramData\\Bar");
    memset(&list, 0, sizeof(list));
    wcscpy(list.entries[0].path, L"C:\\ProgramData\\Foo");
    wcscpy(list.entries[1].path, L"C:\\ProgramData\\Bar");
    list.count = 2;
    s = BdRun(&g_Fs, &list, results, &report);
    CHECK(s == BD_OK && report.ok == 2 && report.seeded == 2, L"first run\n");
    {
        unsigned long before = g_Fake.mutations;
        s = BdRun(&g_Fs, &list, results, &report);
        CHECK(s == BD_OK && report.ok == 2 && report.seeded == 0 && g_Fake.mutations == before, L"second run: ok=%lu seeded=%lu mutations=%lu\n", report.ok, report.seeded, g_Fake.mutations - before);
    }

    CASE(L"run: empty list -> BD_OK, nothing touched");
    memset(&list, 0, sizeof(list));
    {
        unsigned long before = g_Fake.mutations;
        s = BdRun(&g_Fs, &list, results, &report);
        CHECK(s == BD_OK && report.total == 0 && g_Fake.mutations == before, L"empty run\n");
    }

    CASE(L"init: Q:\\ missing -> fail; Q:\\bind-dirs created when absent; refused when a file");
    FakeReset(&g_Fake);
    FakeInit(&g_Fake, &g_Fs);
    FakeAddDir(&g_Fake, L"C:\\");
    CHECK(BD_FAILED(BdInitRwRoot(&g_Fs)), L"no Q: must fail\n");
    FakeAddDir(&g_Fake, L"Q:\\");
    CHECK(BdInitRwRoot(&g_Fs) == BD_OK && FakeFind(&g_Fake, L"Q:\\bind-dirs") != NULL, L"Q:\\bind-dirs not created\n");
    FakeReset(&g_Fake);
    FakeInit(&g_Fake, &g_Fs);
    FakeAddDir(&g_Fake, L"Q:\\");
    FakeAddFile(&g_Fake, L"Q:\\bind-dirs", "x");
    CHECK(BD_FAILED(BdInitRwRoot(&g_Fs)), L"Q:\\bind-dirs as a file must fail\n");
}

int main(void)
{
    setlocale(LC_ALL, "C.UTF-8");
    wprintf(L"bind-dirs offline tests\n");
    TestParseBasics();
    TestParseErrors();
    TestDecode();
    TestLoadConfig();
    TestValidatePath();
    TestApplyHappyPaths();
    TestApplyRefusals();
    TestApplyFailureInjection();
    TestRun();
    wprintf(L"\n%d checks, %d failed\n", g_Checks, g_Failures);
    return g_Failures ? 1 : 0;
}
