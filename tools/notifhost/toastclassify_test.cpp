// toastclassify_test - offline unit suite for the P3b pure classifier (toastclassify.h).
//
// Self-contained: no rig, no WinRT, no network - it runs on the CI Windows runner right
// after msbuild (and, being pure C++17, on any host). Exit 0 = every case matched the
// decision table at docs/DESIGN-toast-bridge.md:165-177; nonzero = at least one mismatch.
//
// The suite checks BOTH the route (window/bridge) and the exact table row, so a verdict
// that is right by accident through the wrong rule still fails.
//
// Defect-reintroduction proof (CLAUDE.md: "a check counts as evidence only once it has
// been seen to FAIL"): rebuilding with any TOASTCLASSIFY_DEFECT_* define (vcxproj
// property ToastClassifyDefect, e.g.
//   msbuild ... /t:Rebuild /p:ToastClassifyDefect=TOASTCLASSIFY_DEFECT_ROW4
// ) flips one rule; this suite MUST then exit nonzero, and the CI step inverts the exit
// code to enforce it. A green run under a defect switch is itself reported as FAILURE.
#include "toastclassify.h"
#include "toastclassify_fixtures.h"
#include <cstdio>
#include <cwchar>
#include <string>

static unsigned g_run = 0, g_fail = 0;

static void Check(const wchar_t* name, ToastClass got, int expRoute, int expRow)
{
    g_run++;
    bool ok = ((int)got.route == expRoute) && (got.row == expRow);
    if (!ok) g_fail++;
    // %ls (not %s): wprintf's %s means a NARROW string on glibc but a wide one on MSVC;
    // %ls is the wide-string conversion on both, so the suite prints correctly anywhere.
    wprintf(L"%ls %-44ls expected %ls/row%d  got %ls/row%d  (%ls)\n",
            ok ? L"ok  " : L"FAIL", name,
            expRoute == 1 ? L"bridge" : L"window", expRow,
            ToastRouteName(got.route), got.row, got.reason);
}

int main()
{
#if defined(TOASTCLASSIFY_DEFECT_ROW1) || defined(TOASTCLASSIFY_DEFECT_ROW4) || \
    defined(TOASTCLASSIFY_DEFECT_FAILCLOSED)
    const bool defectBuild = true;
    wprintf(L"NOTE: a TOASTCLASSIFY_DEFECT_* switch is compiled in - this suite MUST fail now.\n"
            L"      A green run under a defect switch means the checks are decoration.\n");
#else
    const bool defectBuild = false;
#endif

    // -- the table corpus (synthetic, toastclassify_fixtures.h) --
    unsigned expWindow = 0, expBridge = 0;
    for (size_t i = 0; i < kToastFixtureCount; i++)
    {
        const ToastFixture& f = kToastFixtures[i];
        if (f.route == 1) expBridge++; else expWindow++;
        Check(f.name, ClassifyToastXml(f.xml, wcslen(f.xml)), f.route, f.row);
    }

    // -- corpus-integrity guard: a wiring bug that emptied or skewed the corpus must
    //    fail the suite, not silently pass a vacuous loop --
    if (expWindow < 20 || expBridge < 10)
    {
        g_fail++;
        wprintf(L"FAIL corpus-coverage: expected >=20 window + >=10 bridge fixtures, "
                L"got %u/%u\n", expWindow, expBridge);
    }

    // -- adversarial cases that cannot be short literals --
    {
        std::wstring deep = L"<toast>";                      // depth bomb: past kMaxDepth
        for (int i = 0; i < 40; i++) deep += L"<a>";
        for (int i = 0; i < 40; i++) deep += L"</a>";
        deep += L"</toast>";
        Check(L"adv-depth-bomb", ClassifyToastXml(deep), 0, 0);
    }
    {
        std::wstring big(tc::kMaxChars + 16, L'x');          // size bomb: past kMaxChars
        big[0] = L'<';
        Check(L"adv-size-bomb", ClassifyToastXml(big), 0, 0);
    }
    {
        std::wstring elems = L"<toast>";                     // element-count bomb
        for (int i = 0; i < 600; i++) elems += L"<a/>";
        elems += L"</toast>";
        Check(L"adv-elem-count-bomb", ClassifyToastXml(elems), 0, 0);
    }

    // -- byte-payload entry (the wpndatabase Payload column is bytes) --
    {
        const char u8[] = "<toast launch=\"caf\xC3\xA9\"><visual/></toast>";     // valid UTF-8
        Check(L"bytes-utf8-valid", ClassifyToastXmlBytes(u8, sizeof(u8) - 1), 1, 6);
        const char u8bom[] = "\xEF\xBB\xBF<toast/>";
        Check(L"bytes-utf8-bom", ClassifyToastXmlBytes(u8bom, sizeof(u8bom) - 1), 1, 6);
        const char bad[] = "<toast><visual>\xC3\x28</visual></toast>";           // invalid seq
        Check(L"bytes-utf8-invalid", ClassifyToastXmlBytes(bad, sizeof(bad) - 1), 0, 0);
        const char overlong[] = "<toast launch=\"\xC0\xAF\"/>";                  // overlong '/'
        Check(L"bytes-utf8-overlong", ClassifyToastXmlBytes(overlong, sizeof(overlong) - 1), 0, 0);
        const wchar_t* w = L"<toast><visual/></toast>";                          // UTF-16LE BOM
        std::string u16;
        u16 += (char)0xFF; u16 += (char)0xFE;
        for (size_t i = 0; w[i]; i++)
        { u16 += (char)(w[i] & 0xFF); u16 += (char)((w[i] >> 8) & 0xFF); }
        Check(L"bytes-utf16le-bom", ClassifyToastXmlBytes(u16.data(), u16.size()), 1, 6);
        u16 += 'x';                                                              // odd length
        Check(L"bytes-utf16le-odd-length", ClassifyToastXmlBytes(u16.data(), u16.size()), 0, 0);
        Check(L"bytes-null-data", ClassifyToastXmlBytes(nullptr, 4), 0, 0);
    }

    wprintf(L"toastclassify_test: %u cases, %u failed%s\n", g_run, g_fail,
            defectBuild ? L" [defect build: nonzero exit is the EXPECTED outcome]" : L"");
    if (defectBuild && g_fail == 0)
    {
        wprintf(L"FAIL defect-proof: a defect switch is active but every check passed - "
                L"the suite cannot detect the rule it claims to test\n");
        return 1;
    }
    return g_fail ? 1 : 0;
}
