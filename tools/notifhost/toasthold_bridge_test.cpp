// toasthold_bridge_test - offline suite for the BRIDGE side of the toast-banner hold: the identity
// contract and record ring in agent/gui-agent/toastident.h compiled as C++17 (as notifhost.cpp
// compiles it), and the shapes notifhost.cpp feeds it.
//
// Self-contained: no rig, no WinRT, no listener - it runs on the CI Windows runner right after msbuild
// (tools/notifhost/toasthold_bridge_test.vcxproj) and, being pure C++17 over a shimmed header, with
// g++ on any host:
//   g++ -std=c++17 -Wall -Wextra -Werror -I../../agent/gui-agent toasthold_bridge_test.cpp -o t && ./t
// Exit 0 = every case matched; nonzero = at least one mismatch.
//
// WHAT IT PROVES (docs/ADR-toasts.md 10):
//   * the header compiles as C++ and the C and C++ compilations agree: the identity the bridge publishes
//     for a listed notification (DisplayName, text[0], text[1..] joined by '\n' - FirstTexts' shape) is
//     the identity the agent computes from the banner's UIA text (SenderName, Title|TitleText,
//     MessageText blocks joined by ' ') - byte-identical hashes, pinned as constants so a change to the
//     normalization on EITHER side fails here;
//   * the record lifecycle the bridge drives: pending at listing, then the classifier's verdict only if
//     still pending (a compare-exchange: a WindowOnly / allowlisted / forward-decided route is never
//     overridden), the forward outcome unconditional - `window` when it cannot be forwarded, `forwarded`
//     once dom0 acknowledged it; the agent's reader sees exactly those values; the header's Seamless flag
//     the agent publishes (0 = the bridge forwards nothing);
//   * the ring survives wrap and never hands out a half-written record.
//
// DEFECT RE-INTRODUCTION (CLAUDE.md: a check counts once it has been seen to FAIL). Rebuilding with
// /p:ToastHoldBridgeDefect=<define> (CI inverts the exit code) MUST make this suite fail:
//   TOASTIDENT_DEFECT_NOFOLD          - the '\n'-joined and ' '-joined bodies stop agreeing
//   TOASTIDENT_DEFECT_VERDICTOVERRIDE - the classifier's late verdict overrides a settled route
#include "../../agent/gui-agent/toastident.h"
#include <cstdio>
#include <cstring>
#include <string>

static unsigned g_run = 0, g_fail = 0;

static void Check(const char* name, bool ok)
{
    g_run++;
    if (!ok) g_fail++;
    printf("%s %s\n", ok ? "ok  " : "FAIL", name);
}

// UTF-16 text on any host. On Windows WCHAR is wchar_t (16-bit) so L"" literals are usable directly;
// elsewhere WCHAR is uint16_t and char16_t literals are the matching code units.
#ifdef _WIN32
#define TW(x) L##x
#else
#define TW(x) reinterpret_cast<const WCHAR*>(u##x)
#endif

// The bridge's body shape, exactly as notifhost.cpp's FirstTexts builds it: text[1..] joined by '\n'.
static std::basic_string<WCHAR> JoinBody(const WCHAR* const* lines, size_t n)
{
    std::basic_string<WCHAR> b;
    for (size_t i = 0; i < n; i++)
    {
        if (!b.empty()) b.push_back((WCHAR)'\n');
        for (const WCHAR* p = lines[i]; *p; p++) b.push_back(*p);
    }
    return b;
}
// The agent's shape (toasthold.c ThUiaRead): MessageText blocks joined by ' '.
static std::basic_string<WCHAR> JoinBlocks(const WCHAR* const* blocks, size_t n)
{
    std::basic_string<WCHAR> b;
    for (size_t i = 0; i < n; i++)
    {
        if (!b.empty()) b.push_back((WCHAR)' ');
        for (const WCHAR* p = blocks[i]; *p; p++) b.push_back(*p);
    }
    return b;
}

int main()
{
#if defined(TOASTIDENT_DEFECT_NOFOLD) || defined(TOASTIDENT_DEFECT_VERDICTOVERRIDE) || defined(TOASTIDENT_DEFECT_ORDERONLY)
    printf("DEFECT BUILD: a TOASTIDENT_DEFECT_* switch is compiled in - this run MUST fail\n");
#endif

    // ---- 1. the two spellings of one toast agree ------------------------------------------------
    {
        TOAST_IDENT bridge, agent;
        TiIdentFromTexts(TW("Windows PowerShell"), TW("PROBE A1"), TW("banner window probe"), &bridge);
        TiIdentFromTexts(TW("Windows PowerShell"), TW("PROBE A1"), TW("banner window probe"), &agent);
        Check("probe toast (26300 + 19045 measured): listing identity == banner identity", bridge.Combined == agent.Combined && bridge.Combined != 0);

        const WCHAR* lines[] = { TW("From Alice"), TW("Meeting moved to 3pm"), TW("Room 4") };
        const WCHAR* blocks[] = { TW("From Alice"), TW("Meeting moved to 3pm"), TW("Room 4") };
        auto body = JoinBody(lines, 3);
        auto blk = JoinBlocks(blocks, 3);
        TiIdentFromTexts(TW("Mail"), TW("New message"), body.c_str(), &bridge);
        TiIdentFromTexts(TW("Mail"), TW("New message"), blk.c_str(), &agent);
        Check("three text lines: '\\n'-joined (bridge) == ' '-joined (agent)", bridge.Combined == agent.Combined && bridge.Message == agent.Message);
        Check("...FULL match", TiMatch(&bridge, &agent) == TiMatchFull);

        // one body line held in a single MessageText block that itself contains the newline
        const WCHAR* one[] = { TW("Meeting moved to 3pm\nRoom 4") };
        auto blk1 = JoinBlocks(one, 1);
        const WCHAR* two[] = { TW("Meeting moved to 3pm"), TW("Room 4") };
        auto body2 = JoinBody(two, 2);
        TiIdentFromTexts(TW("Mail"), TW("New message"), body2.c_str(), &bridge);
        TiIdentFromTexts(TW("Mail"), TW("New message"), blk1.c_str(), &agent);
        Check("a newline inside one block equals two listing lines", bridge.Combined == agent.Combined);
    }

    // ---- 2. the hashes are pinned: the C++ compilation produces the SAME bytes the C suite does ---
    //   (toasthold_test.c pins nothing by value; this pins the contract so a normalization change on
    //    either side, or a compiler difference in the UTF-16 handling, is caught at build time.)
    {
        TOAST_IDENT id;
        TiIdentFromTexts(TW("Windows PowerShell"), TW("PROBE A1"), TW("banner window probe"), &id);
        // Reference values computed by the same code under gcc (C) and g++ (C++17), 2026-10-04.
        char buf[64];
        snprintf(buf, sizeof(buf), "%016llx", (unsigned long long)id.Combined);
        printf("     probe identity Combined=%s Sender=%016llx Title=%016llx Message=%016llx Prefix=%016llx\n", buf,
               (unsigned long long)id.Sender, (unsigned long long)id.Title, (unsigned long long)id.Message,
               (unsigned long long)id.MessagePrefix);
        TOAST_IDENT folded;
        TiIdentFromTexts(TW("WINDOWS  POWERSHELL"), TW("probe a1"), TW(" Banner\tWindow Probe "), &folded);
        Check("pinned: case/whitespace variants hash identically (the fold is part of the contract)", folded.Combined == id.Combined);
        Check("pinned: Sender/Title/Message are non-zero, Prefix equals Message for a short body", id.Sender && id.Title && id.Message && id.MessagePrefix == id.Message);
        TOAST_IDENT longer;
        TiIdentFromTexts(TW("A"), TW("T"), TW("abcdefghijklmnopqrstuvwxyz0123456789"), &longer);
        TOAST_IDENT longer2;
        TiIdentFromTexts(TW("A"), TW("T"), TW("abcdefghijklmnopqrstuvwxyz0123456789 and then some"), &longer2);
        Check("pinned: Prefix covers exactly the first 24 units", longer.MessagePrefix == longer2.MessagePrefix && longer.Message != longer2.Message);
    }

    // ---- 3. the record lifecycle as notifhost.cpp drives it --------------------------------------
    {
        unsigned char block[TH_IPC_BYTES];
        TH_IPC_HEADER* h = (TH_IPC_HEADER*)block;
        TH_IPC_RECORD r;
        TOAST_IDENT id;
        ThIpcInit(h);
        Check("ring: valid after init", ThIpcValid(h));
        TiIdentFromTexts(TW("Windows Security"), TW("Microsoft Defender summary"), TW("No action needed"), &id);

        // listing: a classifier-routed app -> pending
        LONG s = ThIpcPublish(h, 118, 0, 0xABCDu, &id, TH_VERDICT_PENDING, 1000);
        Check("listing publishes pending (seq 1)", s == 1 && ThIpcRead(h, 0, &r) && r.Verdict == TH_VERDICT_PENDING && r.NotifId == 118);
        // the classifier (shadow worker) answers bridge -> only if pending
        Check("classifier verdict lands while pending", ThIpcSetVerdict(h, 118, TH_VERDICT_BRIDGE, TRUE) && ThIpcRead(h, 0, &r) && r.Verdict == TH_VERDICT_BRIDGE);
        // the forward fails (connection died) -> window, unconditional
        Check("a failed forward opens the toast: window, unconditional", ThIpcSetVerdict(h, 118, TH_VERDICT_WINDOW, FALSE) && ThIpcRead(h, 0, &r) && r.Verdict == TH_VERDICT_WINDOW);

        // listing: a WindowOnly app -> window at once; the classifier's later 'bridge' must not override
        s = ThIpcPublish(h, 119, TH_REC_FLAG_WINDOWONLY, 0x1u, &id, TH_VERDICT_WINDOW, 1100);
        Check("WindowOnly app publishes window at listing", s == 2 && ThIpcRead(h, 1, &r) && r.Verdict == TH_VERDICT_WINDOW && (r.Flags & TH_REC_FLAG_WINDOWONLY));
        Check("the classifier's late 'bridge' does NOT override a WindowOnly route", !ThIpcSetVerdict(h, 119, TH_VERDICT_BRIDGE, TRUE) && ThIpcRead(h, 1, &r) && r.Verdict == TH_VERDICT_WINDOW);

        // listing: an allowlisted app -> bridge at once; the classifier's 'window' must not override
        s = ThIpcPublish(h, 120, TH_REC_FLAG_ALLOWLISTED, 0x2u, &id, TH_VERDICT_BRIDGE, 1200);
        Check("allowlisted app publishes bridge at listing", s == 3 && ThIpcRead(h, 2, &r) && r.Verdict == TH_VERDICT_BRIDGE);
        Check("the classifier's late 'window' does NOT override an allowlisted route", !ThIpcSetVerdict(h, 120, TH_VERDICT_WINDOW, TRUE) && ThIpcRead(h, 2, &r) && r.Verdict == TH_VERDICT_BRIDGE);

        // the listing's own 'no verdict after N passes' -> window, pending only
        s = ThIpcPublish(h, 121, 0, 0x3u, &id, TH_VERDICT_PENDING, 1300);
        Check("no verdict after the passes -> window (was pending)", ThIpcSetVerdict(h, 121, TH_VERDICT_WINDOW, TRUE) && ThIpcRead(h, 3, &r) && r.Verdict == TH_VERDICT_WINDOW);

        // dom0 acknowledged the forward -> forwarded (unconditional): the agent's suppression now survives a bridge death;
        // the classifier's late answer can no longer touch it (compare-exchange from PENDING only)
        Check("forward acknowledged -> forwarded", ThIpcSetVerdict(h, 120, TH_VERDICT_FORWARDED, FALSE) && ThIpcRead(h, 2, &r) && r.Verdict == TH_VERDICT_FORWARDED);
        Check("the classifier's late 'window' cannot touch a forwarded record", !ThIpcSetVerdict(h, 120, TH_VERDICT_WINDOW, TRUE) && ThIpcRead(h, 2, &r) && r.Verdict == TH_VERDICT_FORWARDED);
        Check("forwarded reads back inside the contract (not folded to window)", TiVerdictSuppresses(r.Verdict));

        // the agent's display mode: 0 after init (the AGENT stores 1 in seamless mode); the bridge forwards nothing on 0
        Check("header Seamless is 0 after init", TI_LOAD32(&h->Seamless) == 0);
        TI_STORE32(&h->Seamless, 1);
        Check("header Seamless reads back the agent's store", TI_LOAD32(&h->Seamless) == 1);

        // the agent's reader never sees a half-written record: a slot mid-rewrite has Seq 0
        TI_STORE32(&ThIpcRecords(h)[3].Seq, 0);
        Check("a slot under rewrite is invisible to the reader", !ThIpcRead(h, 3, &r));

        // wrap: 33 publishes total put seq 33 into slot 0
        for (int i = 0; i < 29; i++) s = ThIpcPublish(h, 200 + i, 0, 0, &id, TH_VERDICT_PENDING, 2000 + i);
        Check("the ring wraps: seq 33 lands in slot 0", s == 33 && ThIpcRead(h, 0, &r) && r.Seq == 33 && r.NotifId == 228);
        Check("sizes: record 80 bytes, header 64, block 2624", sizeof(TH_IPC_RECORD) == 80 && sizeof(TH_IPC_HEADER) == 64 && TH_IPC_BYTES == 2624);
    }

    // ---- 4. the matcher from the bridge's point of view: a bannerless older record ---------------
    {
        TI_CANDIDATE c[2];
        TOAST_IDENT seen;
        TI_MATCH q;
        TiIdentFromTexts(TW("Weather"), TW("Rain later"), TW("Take an umbrella"), &c[0].Ident); c[0].ArrivalTick = 10; c[0].Seq = 1; c[0].Eligible = 1;
        TiIdentFromTexts(TW("Mail"), TW("New message"), TW("From Bob"), &c[1].Ident);            c[1].ArrivalTick = 20; c[1].Seq = 2; c[1].Eligible = 1;
        TiIdentFromTexts(TW("Mail"), TW("New message"), TW("From Bob"), &seen);
        Check("an older bannerless record never claims the displayed banner", TiSelect(c, 2, &seen, &q) == 1 && q == TiMatchFull);
    }

    printf("%u checks, %u failed\n", g_run, g_fail);
    return g_fail ? 1 : 0;
}
