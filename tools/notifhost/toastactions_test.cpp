// toastactions_test - offline suite for the actionable-buttons route's pure rules (toastactions.h,
// docs/ADR-toasts.md 11): XML -> action list under the scope rules, key generation and validity, the
// all-or-nothing plan, the wire shape, the bounded per-notification table, ActionInvoked parsing and
// dispatch through a fake activator, and the choice after a failed activation (banner reopened vs dom0
// notice).
//
// Self-contained: no rig, no WinRT, no COM - runs on the CI Windows runner right after msbuild
// (tools/notifhost/toastactions_test.vcxproj) and, being pure C++17, with g++ on any host:
//   g++ -std=c++17 -Wall -Wextra -Werror toastactions_test.cpp -o t && ./t
// Exit 0 = every case matched; nonzero = at least one mismatch.
//
// Defect-reintroduction proof (CLAUDE.md: a check counts as evidence only once it has been seen to FAIL):
// rebuilding with any TOASTACT_DEFECT_* define (vcxproj property ToastActDefect; tools/tests/
// toastactions-selftest.sh runs the matrix with g++) MUST make this suite exit nonzero, and a green run
// under a defect switch is itself reported as FAILURE.
#include "toastactions.h"
#include <chrono>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <memory>
#include <thread>

static unsigned g_run = 0, g_fail = 0;

static void Check(const char* name, bool ok)
{
    g_run++;
    if (!ok) g_fail++;
    printf("%s %s\n", ok ? "ok  " : "FAIL", name);
}

static const ToastActActivator ActivatorYes = ToastActActivator::Known;
static const ToastActActivator ActivatorNo = ToastActActivator::None;
static const ToastActActivator ActivatorPending = ToastActActivator::Unknown;

static ToastActPlan Build(const wchar_t* xml, bool packaged, ToastActActivator act)
{
    ToastClass k = ClassifyToastXml(xml, wcslen(xml));
    ToastActCtx ctx{ packaged, act };
    return ToastActionsBuild(xml, wcslen(xml), k, ctx);
}
static bool NeedsActivator(const wchar_t* xml, bool packaged)
{
    ToastClass k = ClassifyToastXml(xml, wcslen(xml));
    return ToastActRouteNeedsActivator(xml, wcslen(xml), k, packaged);
}

static bool SlugIs(ToastActPlan const& p, const wchar_t* want) { return ToastActSlug(p) == want; }

// A recording fake of the Windows side.
struct FakeActivator : ToastActivator
{
    std::wstring lastUri, lastClsid, lastAumid, lastArgs;
    int protocolCalls = 0, comCalls = 0;
    bool failNext = false;
    bool Protocol(std::wstring const& uri, std::wstring& detail) override
    { protocolCalls++; lastUri = uri; if (failNext) { detail = L"ShellExecute failed (fake)"; return false; } return true; }
    bool Com(std::wstring const& clsid, std::wstring const& aumid, std::wstring const& args, std::wstring& detail) override
    { comCalls++; lastClsid = clsid; lastAumid = aumid; lastArgs = args; if (failNext) { detail = L"Activate failed (fake)"; return false; } return true; }
};

int main()
{
#if defined(TOASTACT_DEFECT_BACKGROUND_CARRIED) || defined(TOASTACT_DEFECT_PARTIAL_FORWARD) || \
    defined(TOASTACT_DEFECT_PACKAGED_COM) || defined(TOASTACT_DEFECT_BADKEY) || \
    defined(TOASTACT_DEFECT_NONOTICE) || defined(TOASTACT_DEFECT_UNBOUNDED_TABLE) || \
    defined(TOASTACT_DEFECT_KEY_BY_SEQ) || defined(TOASTACT_DEFECT_NOCLICKBOUND) || \
    defined(TOASTACT_DEFECT_DOUBLE_OUTCOME) || defined(TOASTACT_DEFECT_NOLOOKUPBOUND) || \
    defined(TOASTACT_DEFECT_NOKILL) || defined(TOASTACT_DEFECT_AWAIT_FOR_INFO) || \
    defined(TOASTACT_DEFECT_UNKNOWN_REFUSES) || defined(TOASTACT_DEFECT_UNKNOWN_AS_KNOWN) || \
    defined(TOASTACT_DEFECT_SCAN_PER_SENDER) || defined(TOASTACT_DEFECT_SCAN_NORMAL_PRIORITY) || \
    defined(TOASTACT_DEFECT_ALLOWLIST_BLIND)
    const bool defectBuild = true;
    printf("DEFECT BUILD: a TOASTACT_DEFECT_* switch is compiled in - this run MUST fail\n");
#else
    const bool defectBuild = false;
#endif

    // ---- 1. the scope rules over the XML + sender facts ------------------------------------------
    {
        // Row 4: two foreground buttons (one with the schema-default activationType) + a system dismiss, on an
        // unpackaged sender with a registered activator: carried - default click (COM, empty launch), b0, b1.
        const wchar_t* two =
            L"<toast><visual><binding template=\"ToastGeneric\"><text>Meeting</text><text>in 5 min</text></binding></visual>"
            L"<actions><action content=\"OK\" activationType=\"foreground\" arguments=\"ok\"/>"
            L"<action content=\"Later\" arguments=\"later\"/>"
            L"<action content=\"Dismiss\" activationType=\"system\" arguments=\"dismiss\"/></actions></toast>";
        ToastActPlan p = Build(two, false, ActivatorYes);
        Check("row4 two com buttons on a Win32 sender with an activator: forwarded with actions", p.ok && p.buttons == 2 && p.actions.size() == 3);
        Check("...the default click is carried as COM with the (empty) launch arguments", p.hasDefault && p.actions[0].key == "default" && p.actions[0].kind == ToastActKind::Com && p.actions[0].arg.empty());
        Check("...b0/b1 carry the buttons' arguments and labels", p.actions[1].key == "b0" && p.actions[1].arg == L"ok" && p.actions[1].label == L"OK" &&
                                                                 p.actions[2].key == "b1" && p.actions[2].arg == L"later" && p.actions[2].label == L"Later");
        Check("...the system dismiss button is not an action (dom0's close is)", p.actions.size() == 3);
        Check("...slug", SlugIs(p, L"default:com,b0:com,b1:com"));
        Check("...every generated key passes the proxy's is_valid_action_name", ta::KeyValid(p.actions[0].key) && ta::KeyValid(p.actions[1].key) && ta::KeyValid(p.actions[2].key));

        // the same toast, the sender has NO activator: nothing can be carried -> window path, no half-way
        ToastActPlan q = Build(two, false, ActivatorNo);
        Check("row4 com buttons, no activator registered: REFUSED (window path)", !q.ok && q.actions.empty() && q.refusal);
        Check("...slug names the refusal", ToastActSlug(q).rfind(L"refused:", 0) == 0);

        // a packaged (UWP) sender: its foreground activation is UWP's even if something answers the activator question
        ToastActPlan u = Build(two, true, ActivatorYes);
        Check("row4 com buttons on a PACKAGED sender: refused (UWP activation is not carried)", !u.ok && u.actions.empty());

        // THE LOOKUP IS NEVER AWAITED BY THE BUILDER (guest-test regression 2026-10-07): with the sender's activator
        // not known yet, a row-4 COM toast is refused (the caller may have waited within its budget first) ...
        ToastActPlan w = Build(two, false, ActivatorPending);
        Check("row4 com buttons with the activator lookup pending: refused (window path; the late result warms the cache)", !w.ok && w.actions.empty() && w.refusal && wcsstr(w.refusal, L"not known yet") != nullptr);
        // ... and its ROUTE is the one kind that may wait for the lookup, within the listing's budget
        Check("route: row-4 com buttons on a Win32 sender depend on the activator (may wait within the budget)", NeedsActivator(two, false));
        Check("route: ...but not on a packaged sender (refused regardless, nothing to wait for)", !NeedsActivator(two, true));
    }
    {
        // AN INFORMATIONAL TOAST NEVER WAITS FOR THE LOOKUP (the regression: S0 of a sender without an activator took
        // the window path because its verdict waited 3.4 s for a cold Start-menu scan)
        const wchar_t* info = L"<toast launch=\"ctx=7\"><visual><binding template=\"ToastGeneric\"><text>t</text></binding></visual></toast>";
        ToastActPlan p = Build(info, false, ActivatorPending);
        Check("row6 with the activator lookup pending: FORWARDED, without the default click, the reason noted", p.ok && !p.hasDefault && p.actions.empty() && p.defaultNote && wcsstr(p.defaultNote, L"not known yet") != nullptr);
        Check("route: a row-6 toast's route never depends on the activator (never waits for the lookup)", !NeedsActivator(info, false));
        const wchar_t* r5 = L"<toast><actions><action content=\"Open\" activationType=\"protocol\" arguments=\"https://e/\"/></actions></toast>";
        ToastActPlan q = Build(r5, false, ActivatorPending);
        Check("row5 protocol button with the lookup pending: forwarded with the button, default not carried", q.ok && q.buttons == 1 && !q.hasDefault && SlugIs(q, L"b0:protocol"));
        Check("route: a row-5 toast never waits either", !NeedsActivator(r5, false));
        const wchar_t* mix = L"<toast><actions><action content=\"Open\" activationType=\"protocol\" arguments=\"https://e/\"/>"
                             L"<action content=\"Reply\" arguments=\"r\"/></actions></toast>";
        Check("route: a row-4 mix with one schema-default (foreground) button depends on the activator", NeedsActivator(mix, false));
        const wchar_t* bg = L"<toast><actions><action content=\"Archive\" activationType=\"background\" arguments=\"a\"/></actions></toast>";
        Check("route: a row-4 background-only toast does not (refused regardless)", !NeedsActivator(bg, false));
        Check("budget: the route wait is inside the listing's budget (under 1.25 s) and the hold's 3 s", kToastActRouteLookupBudgetMs < 1250 && kToastActRouteLookupBudgetMs < 3000);
    }
    {
        // mixed: a protocol button + a foreground button without an activator -> ALL OR NOTHING: refused
        const wchar_t* mixed =
            L"<toast><actions><action content=\"Open\" activationType=\"protocol\" arguments=\"https://example.com/a\"/>"
            L"<action content=\"Reply\" activationType=\"foreground\" arguments=\"r\"/></actions></toast>";
        ToastActPlan p = Build(mixed, false, ActivatorNo);
        Check("row4 protocol + uncarriable com button: refused as a whole (never half-way)", !p.ok && p.actions.empty());
        // background buttons are out of scope by decision, activator or not
        const wchar_t* bg = L"<toast><actions><action content=\"Archive\" activationType=\"background\" arguments=\"a\"/></actions></toast>";
        ToastActPlan b = Build(bg, false, ActivatorYes);
        Check("row4 background button: refused even with an activator (out of scope)", !b.ok && b.actions.empty());
        // a background DEFAULT click does not refuse the toast; it is just not carried, with a note
        const wchar_t* bgdef = L"<toast activationType=\"background\" launch=\"x\"><actions>"
                               L"<action content=\"Open\" activationType=\"protocol\" arguments=\"https://example.com/\"/></actions></toast>";
        ToastActPlan d = Build(bgdef, false, ActivatorNo);
        Check("row5 protocol button + background default click: forwarded, default not carried, noted", d.ok && !d.hasDefault && d.defaultNote && d.buttons == 1 && SlugIs(d, L"b0:protocol"));
    }
    {
        // Row 5: protocol-only buttons on a packaged sender (URI launch needs no activator), a protocol launch
        const wchar_t* r5 =
            L"<toast launch=\"ms-settings:windowsupdate\" activationType=\"protocol\"><actions>"
            L"<action content=\"Open\" activationType=\"protocol\" arguments=\"https://example.com/a\"/>"
            L"<action content=\"Docs\" activationType=\"protocol\" arguments=\"file:///C:/shots\"/>"
            L"<action content=\"Settings\" placement=\"contextMenu\" activationType=\"foreground\" arguments=\"cfg\"/>"
            L"</actions></toast>";
        ToastActPlan p = Build(r5, true, ActivatorNo);
        Check("row5 protocol buttons on a packaged sender: carried (URI launch needs no activator)", p.ok && p.buttons == 2);
        Check("...the protocol launch is the default click", p.hasDefault && p.actions[0].kind == ToastActKind::Protocol && p.actions[0].arg == L"ms-settings:windowsupdate");
        Check("...the contextMenu action is not a banner button and is not carried", p.actions.size() == 3 && SlugIs(p, L"default:protocol,b0:protocol,b1:protocol"));
        // a protocol button whose URI is not launchable: refused (the shell could not launch it either; no half-way)
        const wchar_t* bad = L"<toast><actions><action content=\"Open\" activationType=\"protocol\" arguments=\"not a uri\"/></actions></toast>";
        ToastActPlan q = Build(bad, false, ActivatorNo);
        Check("row5 protocol button without a launchable URI: refused", !q.ok);
    }
    {
        // Row 6: the deep link enriches the default click; dismiss-only carries nothing; actionless Win32 with
        // an activator gets a default click
        const wchar_t* deep = L"<toast launch=\"snippingtool://open?id=42\" activationType=\"protocol\">"
                              L"<visual><binding template=\"ToastGeneric\"><text>Screenshot saved</text></binding></visual></toast>";
        ToastActPlan p = Build(deep, true, ActivatorNo);
        Check("row6 protocol deep link: default click carried, no buttons", p.ok && p.hasDefault && p.buttons == 0 && SlugIs(p, L"default:protocol"));
        const wchar_t* dis = L"<toast><actions><action content=\"Dismiss\" activationType=\"system\" arguments=\"dismiss\"/></actions></toast>";
        ToastActPlan q = Build(dis, true, ActivatorNo);
        Check("row6 dismiss-only, packaged: forwarded with no actions (as before)", q.ok && q.actions.empty() && SlugIs(q, L"none") && q.defaultNote);
        const wchar_t* plain = L"<toast launch=\"ctx=7\"><visual><binding template=\"ToastGeneric\"><text>t</text></binding></visual></toast>";
        ToastActPlan r = Build(plain, false, ActivatorYes);
        Check("row6 actionless Win32 sender with an activator: default click carried as COM with the launch args", r.ok && r.hasDefault && r.actions[0].kind == ToastActKind::Com && r.actions[0].arg == L"ctx=7");
        ToastActPlan s = Build(plain, false, ActivatorNo);
        Check("row6 actionless Win32 sender without an activator: forwarded without a default (as before), noted", s.ok && !s.hasDefault && s.actions.empty() && s.defaultNote);
    }
    {
        // bounds and malformed buttons
        std::wstring six = L"<toast><actions>";
        for (int i = 0; i < 6; i++) six += L"<action content=\"B\" activationType=\"protocol\" arguments=\"https://e/\"/>";
        six += L"</actions></toast>";
        ToastActPlan p = Build(six.c_str(), false, ActivatorNo);
        Check("six banner buttons (past the schema's five): refused", !p.ok);
        const wchar_t* nolabel = L"<toast><actions><action content=\"\" activationType=\"protocol\" arguments=\"https://e/\"/></actions></toast>";
        Check("a button without a label: refused", !Build(nolabel, false, ActivatorNo).ok);
        const wchar_t* row3 = L"<toast scenario=\"reminder\"><actions><action content=\"OK\" arguments=\"ok\"/></actions></toast>";
        Check("a row-3 toast (reminder) is not a candidate: refused by the plan too", !Build(row3, false, ActivatorYes).ok);
        const wchar_t* row1 = L"<toast><actions><input id=\"tb\" type=\"text\"/><action content=\"Send\" activationType=\"foreground\" arguments=\"s\"/></actions></toast>";
        Check("a row-1 toast (text input) is not a candidate", !Build(row1, false, ActivatorYes).ok);
    }

    // ---- 2. keys and URIs --------------------------------------------------------------------
    {
        Check("key 'default' valid", ta::KeyValid("default"));
        Check("key 'b0' valid", ta::KeyValid("b0"));
        Check("key 'x:y.z-w_1' valid", ta::KeyValid("x:y.z-w_1"));
        Check("key '0' invalid (must start with a letter)", !ta::KeyValid("0"));
        Check("key '' invalid", !ta::KeyValid(""));
        Check("key 'a b' invalid", !ta::KeyValid("a b"));
        Check("key of 256 bytes invalid", !ta::KeyValid(std::string(256, 'a')));
        Check("the generated button keys are valid", ta::KeyValid(ta::ButtonKey(0)) && ta::KeyValid(ta::ButtonKey(4)));
        Check("uri https://e/ valid", ta::UriValid(L"https://e/"));
        Check("uri ms-settings:about valid", ta::UriValid(L"ms-settings:about"));
        Check("uri file:///C:/x valid", ta::UriValid(L"file:///C:/x"));
        Check("uri 'nope' (no scheme) invalid", !ta::UriValid(L"nope"));
        Check("uri '1x:y' (scheme starts with a digit) invalid", !ta::UriValid(L"1x:y"));
        Check("uri 'a:' (nothing after the colon) invalid", !ta::UriValid(L"a:"));
        Check("uri with a space invalid", !ta::UriValid(L"ht tp://x"));
        Check("uri with a control character invalid", !ta::UriValid(L"https://e/\n"));
    }

    // ---- 3. the wire shape: Vec<String> of alternating key, label ------------------------------
    {
        ToastActPlan p;
        p.ok = true;
        p.actions.push_back({ "default", L"Open", ToastActKind::Com, L"" });
        p.actions.push_back({ "b0", L"Sp\x00E4ter", ToastActKind::Com, L"later" });   // "Später"
        auto flat = ToastActFlatten(p);
        Check("flatten: 2 actions -> 4 strings, key then label", flat.size() == 4 && flat[0] == "default" && flat[1] == "Open" && flat[2] == "b0");
        Check("flatten: labels are UTF-8 on the wire", flat[3] == std::string("Sp\xC3\xA4ter"));
        std::vector<unsigned char> m;
        ToastActPutVec(m, flat);
        // u64 count 4, then (u64 len + bytes) x4
        Check("encode: count 4 LE", m.size() > 8 && m[0] == 4 && m[1] == 0 && m[7] == 0);
        Check("encode: first string len 7 'default'", m[8] == 7 && m[9] == 0 && memcmp(&m[16], "default", 7) == 0);
        Check("encode: total bytes = 8 + sum(8 + len)", m.size() == 8 + (8 + 7) + (8 + 4) + (8 + 2) + (8 + 7));
        std::vector<unsigned char> none;
        ToastActPutVec(none, {});
        Check("encode: no actions -> u64 0 (the pre-4.3.36 frame byte for byte)", none.size() == 8 && none[0] == 0);
    }

    // ---- 4. the per-notification table is bounded, and keyed by the PROXY's id ---------------------
    {
        ToastActTable t;
        // three id spaces, all different, so a lookup in the wrong one cannot pass by coincidence:
        // sequence (ours) = i, Windows notification id = 1000 + i, the proxy's id = 500 + i
        for (uint32_t i = 1; i <= 70; i++)
        {
            ToastActEntry e; e.seq = i; e.guestId = 1000 + i; e.dom0Id = 500 + i;
            t.Put(std::move(e), 1000 + i);
        }
        Check("table: 70 puts keep at most 64 entries (oldest out)", t.Size() == ToastActTable::kMax);
        Check("table: the oldest were evicted, the newest kept", t.FindDom0(501) == nullptr && t.FindDom0(570) != nullptr && t.FindDom0(507) != nullptr);
        Check("table: lookup by the PROXY's id returns the right entry", t.FindDom0(570) != nullptr && t.FindDom0(570)->guestId == 1070 && t.FindDom0(570)->seq == 70);
        Check("table: a lookup with our sequence or the Windows id finds nothing (other id spaces)", t.FindDom0(70) == nullptr && t.FindDom0(1070) == nullptr);
        Check("table: dom0 id 0 never matches (not yet known / uncorrelated coalesced bursts)", t.FindDom0(0) == nullptr);
        // the entry is put BEFORE the frame is sent (dom0 id 0) and the Id reply fills the id in by sequence
        ToastActEntry early; early.seq = 71; early.guestId = 1071; early.dom0Id = 0;
        t.Put(std::move(early), 1071);
        Check("table: before the Id reply the entry is unreachable by any id", t.FindDom0(0) == nullptr && t.FindDom0(71) == nullptr);
        Check("table: the Id reply sets the proxy's id by sequence; the click then finds it", t.SetDom0Id(71, 9071) && t.FindDom0(9071) != nullptr && t.FindDom0(9071)->guestId == 1071);
        Check("table: a forward that was not acknowledged is removed by sequence", t.RemoveSeq(71) && t.FindDom0(9071) == nullptr && !t.RemoveSeq(71));
        // dismissal grace: a Dismissed arriving before its ActionInvoked keeps the entry for kDismissGraceMs
        Check("table: dismiss marks, the entry survives the grace", t.Dismiss(570, 2000) && t.FindDom0(570) != nullptr);
        t.Expire(2000 + ToastActTable::kDismissGraceMs - 1);
        Check("table: ...still there just before the grace ends", t.FindDom0(570) != nullptr);
        size_t n = t.Expire(2000 + ToastActTable::kDismissGraceMs);
        Check("table: ...gone at the grace", n == 1 && t.FindDom0(570) == nullptr);
        // TTL
        n = t.Expire(1000 + ToastActTable::kTtlMs + 100);
        Check("table: the TTL expires everything born an hour ago", n == ToastActTable::kMax - 2 && t.Size() == 0);   // 64, less the early entry removed and the dismissed one
        ToastActEntry e; e.seq = 5; e.dom0Id = 5;
        t.Put(std::move(e), 10);
        t.Clear();
        Check("table: Clear empties it (connection drop: dom0 ids are per connection)", t.Size() == 0);
    }

    // ---- 4b. clicks in flight: the cap, one outcome, and what the main loop does with a child each pass ----
    {
        ToastActClickLedger L;
        const wchar_t* why = nullptr;
        const uint64_t t0 = 50000;
        Check("ledger: a first click is admitted", L.Admit(1, t0, &why) && L.Inflight() == 1);
        Check("ledger: its child exits -> that outcome is owned, nothing left", L.Done(1) && L.Size() == 0);
        Check("ledger: a click is admitted", L.Admit(2, t0, &why));
        Check("ledger: the bound took the outcome (the child was killed): owned once", L.Done(2) && L.Inflight() == 0);
        Check("ledger: a second outcome for the same click is nobody's (no second notice, no success after a failure)", !L.Done(2));
        Check("ledger: an unknown token's outcome is nobody's", !L.Done(12345));
        // the cap: four children at once refuse a fifth (a failure the user is told about); an outcome frees a slot
        for (uint64_t k = 10; k < 10 + kToastActInflightMax; k++) Check("ledger: admit within the cap", L.Admit(k, t0, &why));
        Check("ledger: the fifth click is refused, with a reason", !L.Admit(99, t0, &why) && why != nullptr);
        Check("ledger: one child's outcome (exit or kill) frees the slot for a new click", L.Done(10) && L.Admit(100, t0 + 1, &why) && L.Inflight() == kToastActInflightMax);

        // the per-pass rule for one child
        Check("child: an exited child is reaped (its exit code is the outcome)", ToastActChildDecide(true, t0 + 10, t0) == ToastActChildStep::Reap);
        Check("child: an exited child is reaped even past the bound (never killed for nothing)", ToastActChildDecide(true, t0 + kToastActClickBoundMs + 5000, t0) == ToastActChildStep::Reap);
        Check("child: a running child before the bound is kept (its handle is in the wait array)", ToastActChildDecide(false, t0 + kToastActClickBoundMs - 1, t0) == ToastActChildStep::Keep);
        Check("child: AT THE BOUND a running child is KILLED and the click fails - the decision-3 path, no leak", ToastActChildDecide(false, t0 + kToastActClickBoundMs, t0) == ToastActChildStep::Kill);
        Check("child: ...and well past it too", ToastActChildDecide(false, t0 + 10 * kToastActClickBoundMs, t0) == ToastActChildStep::Kill);
        Check("child: a step is never FailLeave (a failure reported with the child left alive)", ToastActChildDecide(false, t0 + kToastActClickBoundMs, t0) != ToastActChildStep::FailLeave);

        // the child's exit code -> the outcome
        const wchar_t* d = nullptr;
        Check("exit: 0 -> done", ToastActExitOutcome(kToastActExitOk, &d) == ToastActResult::Done);
        Check("exit: 2 -> failed (the child logged the HRESULT)", ToastActExitOutcome(kToastActExitFailed, &d) == ToastActResult::Failed && d && wcslen(d) > 0);
        Check("exit: 3 -> failed (bad instructions)", ToastActExitOutcome(kToastActExitBadInput, &d) == ToastActResult::Failed);
        Check("exit: STILL_ACTIVE -> failed", ToastActExitOutcome(259, &d) == ToastActResult::Failed);
        Check("exit: a crash code -> failed", ToastActExitOutcome(0xC0000005ul, &d) == ToastActResult::Failed);
    }

    // ---- 4c. the activator lookup is answered within its bound, or treated as none this time -------------
    {
        auto h = std::make_shared<ToastActLookupHandoff>();
        std::thread slow([h] { std::this_thread::sleep_for(std::chrono::milliseconds(400)); h->Publish(L"{11111111-2222-3333-4444-555555555555}", L"shortcut"); });
        std::wstring clsid; const wchar_t* source = nullptr;
        auto t0 = std::chrono::steady_clock::now();
        const bool got = h->WaitFor(50, clsid, source);
        auto ms = std::chrono::duration_cast<std::chrono::milliseconds>(std::chrono::steady_clock::now() - t0).count();
        Check("lookup: a slow lookup is NOT waited for past the bound (none this time)", !got && ms < 300);
        slow.join();
        Check("lookup: the late result is there for a caller that asks after it landed", h->WaitFor(0, clsid, source) && clsid == L"{11111111-2222-3333-4444-555555555555}" && source && wcscmp(source, L"shortcut") == 0);
        auto h2 = std::make_shared<ToastActLookupHandoff>();
        std::thread fast([h2] { h2->Publish(L"", L"none"); });
        Check("lookup: a prompt answer is taken as is", h2->WaitFor(2000, clsid, source) && clsid.empty() && source && wcscmp(source, L"none") == 0);
        fast.join();

        // THE SHORTCUT MAP: one scan per run at the lowest priority, per-sender lookups a registry read + a map read
        // (guest measurement 2026-10-07: a per-sender scan beside the classifier tripled the first toast's latency)
        const ToastActScanPolicy pol = ToastActScanPolicyGet();
        Check("scan: runs at the LOWEST priority in background mode (never competing with the classifier)", pol.prio == ToastActScanPrio::Lowest && pol.backgroundIo);
        ToastActShortcutMap M;
        const wchar_t* why = nullptr;
        const uint64_t s0 = 700000;
        std::wstring c; const wchar_t* src = nullptr; bool refresh = false;
        Check("map: with no map and no scan, a lookup asks for the scan to start (Unknown)", M.Resolve(L"x", L"", s0, c, src, &refresh) == ToastActActivator::Unknown && refresh && wcscmp(src, L"scan-not-started") == 0);
        Check("scan: begins at bridge start", M.BeginScan(s0, &why) && M.Building() && !M.Ready());
        Check("scan: a second begin while it runs is refused, with a reason", !M.BeginScan(s0 + 1, &why) && why != nullptr);
        Check("map: a registry-known sender is Known at once, scan or no scan", M.Resolve(L"a", L"{AAAAAAAA-0000-0000-0000-000000000000}", s0 + 2, c, src, &refresh) == ToastActActivator::Known && wcscmp(src, L"registry") == 0 && !refresh);
        Check("map: a sender the registry does not know reads Unknown while the scan runs - no second scan asked", M.Resolve(L"b", L"", s0 + 2, c, src, &refresh) == ToastActActivator::Unknown && wcscmp(src, L"scan-pending") == 0 && !refresh);
        Check("scan: its hand-off is not done yet (a row-4 toast waits within its budget, an informational one not at all)", M.ScanHandoff() && !M.ScanHandoff()->WaitFor(0, c, src));
        std::unordered_map<std::wstring, std::wstring> entries;
        entries[L"b"] = L"{BBBBBBBB-0000-0000-0000-000000000000}";
        entries[L"d"] = L"";
        M.EndScan(std::move(entries), s0 + 3000);
        Check("scan: done - the map is ready, the hand-off answered", M.Ready() && !M.Building() && M.Size() == 2 && M.ScanHandoff()->WaitFor(0, c, src));
        Check("map: after ONE scan a sender with a shortcut activator is Known from the map", M.Resolve(L"b", L"", s0 + 3100, c, src, &refresh) == ToastActActivator::Known && c == L"{BBBBBBBB-0000-0000-0000-000000000000}" && wcscmp(src, L"shortcut") == 0 && !refresh);
        Check("map: a shortcut carrying the AUMID without an activator is None from the map (no registry, no scan)", M.Resolve(L"d", L"", s0 + 3100, c, src, &refresh) == ToastActActivator::None && wcscmp(src, L"shortcut-no-activator") == 0 && !refresh);
        Check("map: a sender in neither place is None, and a FRESH map is NOT re-scanned for it (no per-sender scan)", M.Resolve(L"e", L"", s0 + 3100, c, src, &refresh) == ToastActActivator::None && wcscmp(src, L"none") == 0 && !refresh);
        Check("map: a miss against a map older than the TTL asks for ONE refresh", M.Resolve(L"e", L"", s0 + 3000 + kToastActScanTtlMs, c, src, &refresh) == ToastActActivator::None && refresh);
        Check("scan: the refresh may begin (a TTL has passed since the last one)", M.BeginScan(s0 + 3000 + kToastActScanTtlMs, &why));
        Check("map: the OLD map serves while the refresh runs, and asks for nothing more", M.Resolve(L"b", L"", s0 + 3001 + kToastActScanTtlMs, c, src, &refresh) == ToastActActivator::Known && !refresh &&
                                                                                      M.Resolve(L"e", L"", s0 + 3001 + kToastActScanTtlMs, c, src, &refresh) == ToastActActivator::None && !refresh);
        std::unordered_map<std::wstring, std::wstring> entries2;
        entries2[L"b"] = L"{CCCCCCCC-0000-0000-0000-000000000000}";
        M.EndScan(std::move(entries2), s0 + 3500 + kToastActScanTtlMs);
        Check("map: the refresh REPLACED the map (a shortcut gone from the Start menu is gone; a changed CLSID is the new one)", M.Resolve(L"d", L"", s0 + 3600 + kToastActScanTtlMs, c, src, &refresh) == ToastActActivator::None && wcscmp(src, L"none") == 0 &&
                                                                                                                                       M.Resolve(L"b", L"", s0 + 3600 + kToastActScanTtlMs, c, src, &refresh) == ToastActActivator::Known && c == L"{CCCCCCCC-0000-0000-0000-000000000000}");
        Check("scan: rate-limited - a miss right after a refresh asks for nothing and a begin is refused", !refresh && !M.BeginScan(s0 + 3700 + kToastActScanTtlMs, &why) && why != nullptr);
        ToastActShortcutMap A;
        Check("scan: an aborted scan (no thread) releases its waiters and leaves the map unbuilt for the next attempt", A.BeginScan(s0, &why) && (A.AbortScan(), A.ScanHandoff()->WaitFor(0, c, src) && !A.Ready() && !A.Building()));
    }

    // ---- 5. ActionInvoked parsing -------------------------------------------------------------
    {
        auto frame = [](uint32_t tag, uint32_t id, std::string const& key, bool lieAboutLen) {
            std::vector<unsigned char> f;
            auto p32 = [&](uint32_t x) { for (int i = 0; i < 4; i++) f.push_back((unsigned char)(x >> (8 * i))); };
            p32(tag); p32(id);
            uint64_t n = key.size() + (lieAboutLen ? 3 : 0);
            p32((uint32_t)n); p32((uint32_t)(n >> 32));
            f.insert(f.end(), key.begin(), key.end());
            return f;
        };
        uint32_t id = 0; std::string key;
        auto ok = frame(4, 7, "b1", false);
        Check("invoked: tag 4, id, 'b1' parsed", ToastActParseInvoked(ok.data(), (uint32_t)ok.size(), id, key) && id == 7 && key == "b1");
        auto wrongTag = frame(3, 7, "b1", false);
        Check("invoked: another tag is not an ActionInvoked", !ToastActParseInvoked(wrongTag.data(), (uint32_t)wrongTag.size(), id, key));
        auto lie = frame(4, 7, "b1", true);
        Check("invoked: a length that does not match the frame is malformed", !ToastActParseInvoked(lie.data(), (uint32_t)lie.size(), id, key));
        Check("invoked: a truncated frame is malformed", !ToastActParseInvoked(ok.data(), 12, id, key));
        auto badKey = frame(4, 7, "b 1", false);
        Check("invoked: a key the proxy could never have accepted is refused", !ToastActParseInvoked(badKey.data(), (uint32_t)badKey.size(), id, key));
        auto longKey = frame(4, 7, std::string(300, 'a'), false);
        Check("invoked: a 300-byte key is refused", !ToastActParseInvoked(longKey.data(), (uint32_t)longKey.size(), id, key));
    }

    // ---- 6. dispatch through the fake activator --------------------------------------------------
    {
        FakeActivator fa;
        ToastActEntry e;
        e.aumid = L"Vendor.App"; e.clsid = L"{11111111-2222-3333-4444-555555555555}"; e.title = L"Meeting"; e.app = L"Calendar";
        e.plan.ok = true;
        e.plan.actions.push_back({ "default", L"Open", ToastActKind::Com, L"" });
        e.plan.actions.push_back({ "b0", L"Open folder", ToastActKind::Protocol, L"file:///C:/shots" });
        e.plan.actions.push_back({ "b1", L"Later", ToastActKind::Com, L"later" });
        const ToastAct* which = nullptr; std::wstring detail;
        Check("dispatch b0 -> Protocol(uri)", ToastActDispatch(e, "b0", fa, &which, detail) == ToastActResult::Done && fa.protocolCalls == 1 && fa.lastUri == L"file:///C:/shots" && which && which->key == "b0");
        Check("dispatch b1 -> Com(clsid, aumid, args)", ToastActDispatch(e, "b1", fa, &which, detail) == ToastActResult::Done && fa.comCalls == 1 &&
              fa.lastClsid == e.clsid && fa.lastAumid == L"Vendor.App" && fa.lastArgs == L"later");
        Check("dispatch default -> Com with the (empty) launch args", ToastActDispatch(e, "default", fa, &which, detail) == ToastActResult::Done && fa.comCalls == 2 && fa.lastArgs.empty());
        Check("dispatch an unknown key -> UnknownKey, nothing run", ToastActDispatch(e, "b7", fa, &which, detail) == ToastActResult::UnknownKey && which == nullptr && fa.comCalls == 2 && fa.protocolCalls == 1);
        fa.failNext = true;
        Check("dispatch: the activator's failure is Failed with its detail", ToastActDispatch(e, "b1", fa, &which, detail) == ToastActResult::Failed && detail == L"Activate failed (fake)");

        std::wstring summary, body;
        ToastActNoticeText(e, which, detail, summary, body);
        Check("notice text names the button, the toast and the app, and the detail",
              summary == L"A notification action did not run" &&
              body.find(L"'Later' on 'Meeting' (Calendar)") != std::wstring::npos && body.find(L"Activate failed (fake)") != std::wstring::npos &&
              body.find(L"Notification Center") != std::wstring::npos);
    }

    // ---- 6b. the listing's route, allowlisted or not (guest finding 2026-10-07: the blind shortcut) -------
    {
        ToastActPlan okPlan; okPlan.ok = true; okPlan.actions.push_back({ "b0", L"OK", ToastActKind::Com, L"ok" }); okPlan.buttons = 1;
        ToastActPlan refused; refused.ok = false; refused.refusal = L"the sender registered no toast activator";
        ToastActPlan none; none.ok = true;   // informational: no actions
        const int maxP = 3;
        Check("listing: allowlisted row-4 toast, plan carried -> forwarded WITH its plan (never blind)", ToastActListingDecide(true, true, true, okPlan, 1, maxP) == ToastActListingRoute::ForwardWithPlan);
        Check("listing: allowlisted row-4 toast, plan refused -> WINDOW path (the user keeps the guest's buttons)", ToastActListingDecide(true, true, false, refused, 1, maxP) == ToastActListingRoute::Window);
        Check("listing: allowlisted informational toast with its verdict -> forwarded at once (no actions)", ToastActListingDecide(true, true, true, none, 1, maxP) == ToastActListingRoute::ForwardWithPlan);
        Check("listing: allowlisted toast, verdict pending, passes left -> await (not forwarded blind)", ToastActListingDecide(true, false, false, none, 1, maxP) == ToastActListingRoute::AwaitVerdict);
        Check("listing: allowlisted toast, no verdict after the passes -> the shortcut's blind forward (logged loudly)", ToastActListingDecide(true, false, false, none, 3, maxP) == ToastActListingRoute::ForwardBlind);
        Check("listing: classifier-routed toast, no verdict after the passes -> window (ADR 2 rule 3)", ToastActListingDecide(false, false, false, none, 3, maxP) == ToastActListingRoute::Window);
        Check("listing: classifier-routed toast, verdict bridge -> forwarded with its plan", ToastActListingDecide(false, true, true, okPlan, 1, maxP) == ToastActListingRoute::ForwardWithPlan);
        Check("listing: classifier-routed toast, verdict window -> window", ToastActListingDecide(false, true, false, refused, 1, maxP) == ToastActListingRoute::Window);
        Check("sent: a row-4 toast sent with no actions is the anomaly", ToastActSentAnomaly(4, 0));
        Check("sent: a row-4 toast sent with actions, or a row-6 toast without, is not", !ToastActSentAnomaly(4, 2) && !ToastActSentAnomaly(6, 0));
    }

    // ---- 7. after a failed activation: banner reopened, or the dom0 notice --------------------------
    {
        const uint64_t t0 = 100000;
        Check("fail: the agent marked the record shown -> the guest banner has the buttons, no notice",
              ToastActFailChoice(true, 1, true, t0 + 10, t0) == ToastActAfterFail::BannerShown);
        Check("fail: record found, no mark yet, within the bound -> wait",
              ToastActFailChoice(true, 0, true, t0 + kToastActShowBoundMs - 1, t0) == ToastActAfterFail::Wait);
        Check("fail: no mark at the bound, dom0 reachable -> notice",
              ToastActFailChoice(true, 0, true, t0 + kToastActShowBoundMs, t0) == ToastActAfterFail::Notice);
        Check("fail: the record was gone (nothing to reopen), dom0 reachable -> notice at once",
              ToastActFailChoice(false, 0, true, t0, t0) == ToastActAfterFail::Notice);
        Check("fail: a mark on a record that was not found is not believed",
              ToastActFailChoice(false, 1, true, t0, t0) == ToastActAfterFail::Notice);
        Check("fail: dom0 unreachable -> keep waiting for the connection",
              ToastActFailChoice(true, 0, false, t0 + kToastActShowBoundMs, t0) == ToastActAfterFail::Wait);
        Check("fail: dom0 unreachable for the whole give-up window -> give up, loudly",
              ToastActFailChoice(true, 0, false, t0 + kToastActNoticeGiveUpMs, t0) == ToastActAfterFail::GiveUp);
        Check("fail: a late mark still wins over the notice while waiting",
              ToastActFailChoice(true, 1, true, t0 + kToastActShowBoundMs + 500, t0) == ToastActAfterFail::BannerShown);
    }

    printf("toastactions_test: %u checks, %u failed%s\n", g_run, g_fail,
           defectBuild ? " [defect build: nonzero exit is the EXPECTED outcome]" : "");
    if (defectBuild && g_fail == 0)
    {
        printf("FAIL defect-proof: a defect switch is active but every check passed - the suite cannot detect the rule it claims to test\n");
        return 1;
    }
    return g_fail ? 1 : 0;
}
