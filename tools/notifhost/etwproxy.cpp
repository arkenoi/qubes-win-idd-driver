// etwproxy.exe - the least-privilege acquisition process of the toast bridge (P3-ETW),
// SPLIT OUT of notifhost.exe on 2026-09-05 (owner-chosen Option 2, the GUI-DLL-free
// console-proxy split).
//
// WHY A SEPARATE BINARY. The --etw-proxy path is a PURE ETW/pipe consumer with ZERO UI
// need, but notifhost.exe statically imports user32.dll + gdi32.dll (pulled in by the
// WinRT --bridge code: UserNotificationListener, ShowBanner, the legacy GDI toast
// windows). Those DLLs' init connects the process to a window station at startup, and the
// bare qubes-etwproxy batch token in session 0 has NO accessible window station - so the
// proxy died 0xC0000142 STATUS_DLL_INIT_FAILED before its first instruction (rig-measured;
// the SAME binary as SYSTEM, which can reach WinSta0, initialized fine and hit the
// never-SYSTEM guard - proving the imports were the only failure). The former fix was a
// dedicated agent-created window station; this split makes that machinery unnecessary:
// THIS BINARY LINKS NO user32/gdi32 (and no WinRT), never touches a window station, and
// therefore cannot fail 0xC0000142 - no winsta creation, no winsta ACLs, no rights
// widening of any kind. See tools/notifhost/qtb_shared.h for the enforced build rules and
// the CI dumpbin /imports gate.
//
// WHAT IT IS (unchanged semantics from `notifhost --etw-proxy`): the LEAST-PRIVILEGE home
// of the bridge's real-time ETW consumer - a PURE CONSUMER under the two-context split
// (DESIGN-p3-classifier-impl.md secs 10.18/10.19). The SYSTEM agent
// (agent/gui-agent/etwproxy.c) is the session CONTROLLER: it starts QubesToastBridgeEtw,
// enables the providers, and grants this process's account TRACELOG_ACCESS_REALTIME on
// the session GUID (EventAccessControl) BEFORE launching us. This process does OpenTraceW +
// ProcessTrace + TDH property location ONLY, under the dedicated qubes-etwproxy account
// whose token NEVER held Performance Log Users or SeSystemProfilePrivilege: it cannot
// (and must not) StartTrace/EnableTrace/ControlTrace, and it NEVER stops the session
// (the agent does, at park/shutdown/job-kill). It is the SERVER of a kernel-enforced
// one-way pipe (PIPE_ACCESS_OUTBOUND, DACL = the --client-sid bridge user ONLY,
// read-only) and only PUSHES payload-free SIGNAL frames {AUMID, notificationId (string +
// numeric), tag, group, FILETIME} (design 10.20.1 - the rig proved the <toast> payload is
// NEVER in ETW on Win10, so the proxy does not materialize payload bytes at all; the
// bridge answers each signal with ONE targeted wpndatabase read for the payload); it
// reads nothing, accepts no control channel, has no stop file.
//
// Usage: etwproxy.exe [--client-sid <SID>]   (launched only by the SYSTEM gui-agent)
// Exit codes (shared contract with agent/gui-agent/etwproxy.c ETWPROXY_EXIT_*):
//   0 clean stop, 5 consume denied (OpenTrace/ProcessTrace ERROR_ACCESS_DENIED - the
//   per-session DACL grant did not suffice on this build; the agent parks on this TRUE
//   finding), 7 consumer open/thread/event failure, 8 pipe creation failure (incl. a
//   squatter), 9 REFUSED: SYSTEM/admin/elevated token (the never-SYSTEM guard) or a
//   DRIFTED token carrying Performance Log Users / SeSystemProfilePrivilege (running the
//   hostile TDH decode with machine-wide trace capability is forbidden, and group SIDs
//   cannot be shed in-process - the untrusted parse runs on a bare token or not at all).
//
// Threat model: a parser bug in TDH or this code hands the attacker THIS token - not
// admin, not SYSTEM, no user profile, no network role - plus a WRITE-ONLY pipe whose sole
// listener is a measure-only fail-open classifier. Structure:
//   * pipe SERVER, PIPE_ACCESS_OUTBOUND: the kernel refuses reads on the server handle -
//     one-way by construction, not by discipline. nMaxInstances=1 + FIRST_PIPE_INSTANCE;
//     DACL admits ONLY the --client-sid SID (the bridge user; the agent never connects).
//     Without --client-sid the DACL is empty = deny everyone, i.e. locked shut: the
//     bridge tier just reads down and the ladder serves the DB rung.
//   * NO input surface: no reads, no control channel, no stop file (a ProgramData stop
//     file would be a user-writable control into a differently-privileged process). It
//     stops when its ETW session is stopped externally, on console ctrl, or when the
//     agent terminates it.
//   * MINIMAL parsing: TdhGetEventInformation to locate properties BY NAME, raw property
//     bytes via TdhGetProperty - NAME-GATED to the four signal fields {AUMID,
//     notificationId, tag, group}, each markup-rejected and length-capped. No
//     TdhFormatProperty, no XML parse, and NO payload handling at all (design 10.20.1:
//     the payload is not in ETW on Win10 and is never materialized here; the defensive
//     payload parse stays in toastclassify.h on the bridge side, fed by its targeted
//     wpndatabase read).
//
// Build: v143 /MT console, SDK-only, mirrors notifhost.vcxproj MINUS every GUI-adjacent
// dependency - see etwproxy.vcxproj. The ONLY libs are kernel32/advapi32/tdh.
#include "qtb_shared.h"   // pure Win32: log, wire contract, CsGuard, EtwOpen/ProcessTrace
#include <deque>

#pragma comment(lib, "advapi32.lib")  // token/SID/SDDL APIs + the evntrace consume surface
#pragma comment(lib, "tdh.lib")       // in-box Windows SDK (TDH event decoding) - no WDK/nuget
// DELIBERATELY ABSENT: user32.lib, gdi32.lib, windowsapp.lib, d3d11.lib, dxgi.lib. Adding
// any of them re-introduces the 0xC0000142 winsta-connect failure this binary exists to
// make impossible. CI rejects the binary if user32/gdi32 appear in its import table.

static struct
{
    CRITICAL_SECTION lock;                  // guards q; CsGuard only
    std::deque<std::vector<BYTE>> q;        // encoded wire frames; capped 64
    HANDLE evt = nullptr, stopEvt = nullptr, wrEvt = nullptr;
    volatile LONG captured = 0, dropped = 0, sent = 0;
} g_px;

struct PxRec
{
    std::wstring aumid, notifId, tag, group;   // the SIGNAL metadata - never a payload
    uint64_t notifIdNum = 0;                   // 0 = "does not join by id"
    long long ft = 0;
};

// The old PxLooksLikeToastXml payload SELECTOR, INVERTED into a REJECT (design 10.20.1):
// the rig proved the payload is never in ETW on Win10, so the proxy must not materialize
// payload bytes at all - any markup-bearing property value is skipped, never copied. A
// legitimate AUMID / notification id / tag / group never contains markup, so rejection
// can only fail open (missing field -> the bridge ladder degrades toward the DB rung).
static bool PxLooksLikeMarkup(std::wstring const& v)
{
    return v.find(L'<') != std::wstring::npos || v.find(L'>') != std::wstring::npos;
}

// "notificationId as an integer": PxRawToName renders integral intypes (psz 4/8) as
// decimal, so one all-decimal parse covers BOTH spec cases (integral intype, or a string
// that is all-decimal). Non-decimal / empty / oversized -> 0 = "does not join by id".
static uint64_t PxAllDecimalToU64(std::wstring const& v)
{
    if (v.empty() || v.size() > 20) return 0;
    uint64_t n = 0;
    for (wchar_t c : v)
    {
        if (c < L'0' || c > L'9') return 0;
        n = n * 10 + (uint64_t)(c - L'0');
    }
    return n;
}

// Raw property bytes -> short identifier string (AUMID / notif-id fields only; the payload
// is never run through this). String intypes copy; 4/8-byte scalars print as decimal.
static std::wstring PxRawToName(const BYTE* raw, ULONG psz, USHORT inType)
{
    if (inType == TDH_INTYPE_UNICODESTRING || inType == TDH_INTYPE_COUNTEDSTRING)
    {
        std::wstring w(psz / 2, 0);
        if (!w.empty()) memcpy(&w[0], raw, w.size() * sizeof(wchar_t));
        while (!w.empty() && w.back() == 0) w.pop_back();
        return w;
    }
    if (inType == TDH_INTYPE_ANSISTRING || inType == TDH_INTYPE_COUNTEDANSISTRING)
    {
        std::string s((const char*)raw, psz);
        while (!s.empty() && s.back() == 0) s.pop_back();
        int wn = MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), nullptr, 0);
        std::wstring w(wn > 0 ? (size_t)wn : 0, 0);
        if (wn > 0) MultiByteToWideChar(CP_UTF8, 0, s.data(), (int)s.size(), &w[0], wn);
        return w;
    }
    if (psz == 4) { wchar_t t[16]; swprintf(t, 16, L"%lu", *(const ULONG*)raw); return t; }
    if (psz == 8) { wchar_t t[24]; swprintf(t, 24, L"%llu", *(const unsigned long long*)raw); return t; }
    return L"";
}

// TDH-locate the SIGNAL metadata {AUMID, notificationId (string + numeric), tag, group}
// in one event; raw bytes only, NAME-GATED: a property whose name matches none of the
// wanted fields is never even fetched, so payload bytes are never materialized in this
// process (design 10.20.1 - the untrusted-parse surface SHRINKS: metadata fields only,
// each markup-rejected and length-capped). Every failure path returns false = "this
// event carries nothing" - the ladder in the bridge degrades. Emission rule: an event is
// worth a frame iff it carries an AUMID or a numeric notificationId (the old
// !payload.empty() rule was ZERO frames forever on Win10 - the latent proxy-killer).
static bool PxHarvest(EVENT_RECORD* er, PxRec* out)
{
    out->ft = er->EventHeader.TimeStamp.QuadPart;    // FILETIME (no RAW_TIMESTAMP mode)
    ULONG sz = 0;
    ULONG rc = TdhGetEventInformation(er, 0, nullptr, nullptr, &sz);
    if (rc != ERROR_INSUFFICIENT_BUFFER || sz == 0 || sz > 1024 * 1024) return false;
    std::vector<BYTE> buf(sz);
    TRACE_EVENT_INFO* ti = (TRACE_EVENT_INFO*)buf.data();
    if (TdhGetEventInformation(er, 0, nullptr, ti, &sz) != ERROR_SUCCESS) return false;
    ULONG nProps = ti->TopLevelPropertyCount;
    if (nProps > 64) nProps = 64;                    // adversarial bound
    for (ULONG i = 0; i < nProps; i++)
    {
        EVENT_PROPERTY_INFO const& epi = ti->EventPropertyInfoArray[i];
        if (epi.Flags & (PropertyStruct | PropertyParamCount)) continue;
        std::wstring name = EtwLower(EtwTiString(ti, epi.NameOffset));
        // name gate FIRST - unwanted fields (incl. anything payload-shaped) never fetched
        bool wantAumid = out->aumid.empty() &&
            (name.find(L"aumid") != std::wstring::npos ||
             name.find(L"appusermodelid") != std::wstring::npos ||
             name.find(L"appid") != std::wstring::npos ||
             name.find(L"primaryid") != std::wstring::npos);
        bool wantNotif = out->notifId.empty() && out->notifIdNum == 0 &&
            (name.find(L"notificationid") != std::wstring::npos || name == L"id" ||
             name.find(L"trackingid") != std::wstring::npos);
        bool wantTag   = out->tag.empty() && name.find(L"tag") != std::wstring::npos;
        bool wantGroup = out->group.empty() && name.find(L"group") != std::wstring::npos;
        if (!wantAumid && !wantNotif && !wantTag && !wantGroup) continue;
        PROPERTY_DATA_DESCRIPTOR pdd = {};
        pdd.PropertyName = (ULONGLONG)((BYTE*)ti + epi.NameOffset);
        pdd.ArrayIndex = (ULONG)-1;
        ULONG psz = 0;
        if (TdhGetPropertySize(er, 0, nullptr, 1, &pdd, &psz) != ERROR_SUCCESS ||
            psz == 0 || psz > ETW_MAX_AUMID_BYTES)   // metadata-sized values only, AT SOURCE
            continue;
        std::vector<BYTE> raw(psz);
        if (TdhGetProperty(er, 0, nullptr, 1, &pdd, psz, raw.data()) != ERROR_SUCCESS) continue;
        std::wstring v = PxRawToName(raw.data(), psz, epi.nonStructType.InType);
        if (v.empty() || PxLooksLikeMarkup(v)) continue;   // markup: REJECT, never copy
        if (wantAumid && v.size() * sizeof(wchar_t) <= ETW_MAX_AUMID_BYTES)
            out->aumid = v;
        else if (wantNotif)
        {
            out->notifIdNum = PxAllDecimalToU64(v);        // 0 = does not join by id
            if (v.size() * sizeof(wchar_t) <= ETW_MAX_NOTIF_BYTES) out->notifId = v;
        }
        else if (wantTag && v.size() * sizeof(wchar_t) <= ETW_MAX_TAG_BYTES)
            out->tag = v;
        else if (wantGroup && v.size() * sizeof(wchar_t) <= ETW_MAX_GROUP_BYTES)
            out->group = v;
    }
    return !out->aumid.empty() || out->notifIdNum != 0;
}

// ProcessTrace callback. Exception-tight; queues one encoded 'QTS1' SIGNAL frame per
// AUMID-or-id-bearing event and never blocks (a full queue drops the OLDEST - the bridge
// tier misses that toast's signal and its ladder degrades: fail-open, never a wedged
// consumer).
static void CALLBACK EtwProxyEventCb(EVENT_RECORD* er)
{
    try
    {
        PxRec r;
        if (!PxHarvest(er, &r)) return;      // emission rule: !aumid.empty() || notifIdNum
        std::vector<BYTE> f;
        f.reserve(ETW_WIRE_HDR_BYTES +
                  (r.aumid.size() + r.notifId.size() + r.tag.size() + r.group.size()) * 2);
        PutU32(f, ETW_WIRE_MAGIC);
        PutU32(f, (uint32_t)(r.aumid.size() * sizeof(wchar_t)));
        PutU32(f, (uint32_t)(r.notifId.size() * sizeof(wchar_t)));
        PutU32(f, (uint32_t)(r.tag.size() * sizeof(wchar_t)));
        PutU32(f, (uint32_t)(r.group.size() * sizeof(wchar_t)));
        PutU64(f, r.notifIdNum);
        PutU64(f, (uint64_t)r.ft);
        auto putw = [&f](std::wstring const& s) {
            f.insert(f.end(), (const BYTE*)s.data(), (const BYTE*)(s.data() + s.size()));
        };
        putw(r.aumid); putw(r.notifId); putw(r.tag); putw(r.group);
        LONG n = InterlockedIncrement(&g_px.captured);
        {
            CsGuard g(&g_px.lock);           // RAII (review must-fix applies here too)
            g_px.q.push_back(std::move(f));
            while (g_px.q.size() > 64) { g_px.q.pop_front(); InterlockedIncrement(&g_px.dropped); }
        }
        SetEvent(g_px.evt);
        if (n <= 50 || (n % 20) == 0)        // human-rate log
            BLog(L"ETWPROXY SIG #%ld aumid=%s idnum=%llu notif=%s tag=%s group=%s", n,
                 r.aumid.empty() ? L"-" : r.aumid.c_str(), (ULONGLONG)r.notifIdNum,
                 r.notifId.empty() ? L"-" : r.notifId.c_str(),
                 r.tag.empty() ? L"-" : r.tag.c_str(),
                 r.group.empty() ? L"-" : r.group.c_str());
    }
    catch (...) {}
}

// Overlapped write with stop/session-death abort, so a connected-but-never-reading client
// can stall only the serve loop (which the agent supervises), never the ETW consumer.
static bool PxWrite(HANDLE pipe, HANDLE etwThread, const BYTE* b, DWORD n)
{
    DWORD done = 0;
    while (done < n)
    {
        OVERLAPPED ov = {}; ov.hEvent = g_px.wrEvt; ResetEvent(g_px.wrEvt);
        if (!WriteFile(pipe, b + done, n - done, nullptr, &ov) &&
            GetLastError() != ERROR_IO_PENDING) return false;
        HANDLE hs[3] = { g_px.wrEvt, g_px.stopEvt, etwThread };
        DWORD w = WaitForMultipleObjects(3, hs, FALSE, INFINITE);
        if (w != WAIT_OBJECT_0)
        {
            CancelIoEx(pipe, &ov);
            DWORD x; GetOverlappedResult(pipe, &ov, &x, TRUE);
            return false;
        }
        DWORD got = 0;
        if (!GetOverlappedResult(pipe, &ov, &got, FALSE) || got == 0) return false;
        done += got;
    }
    return true;
}

static BOOL WINAPI PxCtrlHandler(DWORD)
{
    // Pure consumer: NEVER stop the session (the SYSTEM agent owns its lifecycle). The
    // serve loop notices stopEvt and falls into teardown, whose CloseTrace ends
    // ProcessTrace (ERROR_CTX_CLOSE_PENDING: it drains and returns).
    SetEvent(g_px.stopEvt);
    return TRUE;
}

// ---- least-privilege enforcement -----------------------------------------------------------
// The untrusted TDH/property decode (PxHarvest) parses attacker-influenceable event bytes.
// Three code-enforced guarantees complement the account provisioning + the architect's
// control/consume split (design sec 10.10.1 / 10.17):
//   * the never-SYSTEM/admin guard REFUSES to run under a privileged token (exit 9);
//   * the token census LOGS the group/priv set once and REFUSES (exit 9, same hard-refuse
//     class) on drift - Performance Log Users SID or SeSystemProfilePrivilege present
//     (the sec 10.17.2 residual: the consumer gains consume via the per-session DACL
//     grant ONLY; a drifted token has machine-wide trace capability that group SIDs make
//     unsheddable, so it must never reach the decode loop);
//   * EtwProxyShedAllPrivileges IRREVERSIBLY strips every privilege before the decode loop.

// Refuse to run the hostile parse under SYSTEM / admin / an elevated token. Fail CLOSED
// (a token we cannot inspect is treated as forbidden). Sets `why` to a human reason.
static bool EtwProxyTokenIsForbidden(std::wstring& why)
{
    HANDLE tok = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok))
    { why = L"OpenProcessToken(TOKEN_QUERY) failed - cannot verify the token is unprivileged"; return true; }

    bool bad = false;
    SID_IDENTIFIER_AUTHORITY nt = SECURITY_NT_AUTHORITY;

    // 1. Token user is LocalSystem (S-1-5-18)?
    DWORD cb = 0; GetTokenInformation(tok, TokenUser, nullptr, 0, &cb);
    std::vector<BYTE> ub(cb ? cb : 1);
    if (cb && GetTokenInformation(tok, TokenUser, ub.data(), cb, &cb))
    {
        PSID sys = nullptr;
        if (AllocateAndInitializeSid(&nt, 1, SECURITY_LOCAL_SYSTEM_RID, 0, 0, 0, 0, 0, 0, 0, &sys))
        {
            if (EqualSid(((TOKEN_USER*)ub.data())->User.Sid, sys))
            { bad = true; why = L"token user is LocalSystem (S-1-5-18)"; }
            FreeSid(sys);
        }
    }
    // 2. Elevated (a full-token admin process)?
    if (!bad)
    {
        TOKEN_ELEVATION el = {}; DWORD n = 0;
        if (GetTokenInformation(tok, TokenElevation, &el, sizeof(el), &n) && el.TokenIsElevated)
        { bad = true; why = L"token is elevated (TokenElevation)"; }
    }
    // 3. BUILTIN\Administrators present AND enabled in the effective token?
    if (!bad)
    {
        PSID admins = nullptr;
        if (AllocateAndInitializeSid(&nt, 2, SECURITY_BUILTIN_DOMAIN_RID,
                DOMAIN_ALIAS_RID_ADMINS, 0, 0, 0, 0, 0, 0, &admins))
        {
            BOOL isMember = FALSE;
            if (CheckTokenMembership(nullptr, admins, &isMember) && isMember)
            { bad = true; why = L"BUILTIN\\Administrators present and enabled"; }
            FreeSid(admins);
        }
    }
    CloseHandle(tok);
    return bad;
}

// Log the token's privilege + group census ONCE, and return true (= REFUSE, exit 9) if
// the token has DRIFTED: Performance Log Users SID (S-1-5-32-559) or
// SeSystemProfilePrivilege present. Under the control/consume split the consumer gains
// consume via the per-session DACL grant ONLY - either finding means this token carries
// machine-wide trace capability, and a group SID cannot be shed in-process
// (SE_GROUP_MANDATORY), so the hostile TDH decode must never run on it (design
// sec 10.17.2; secure default: refuse-on-drift, never warn-and-proceed).
static bool EtwProxyTokenCensusIsDrifted()
{
    HANDLE tok = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok))
        return true;   // fail closed: a token we cannot inspect must not run the decode

    bool profilePriv = false;
    LUID profLuid = {};
    BOOL haveProfLuid = LookupPrivilegeValueW(nullptr, L"SeSystemProfilePrivilege", &profLuid);

    DWORD cb = 0;
    GetTokenInformation(tok, TokenPrivileges, nullptr, 0, &cb);
    std::vector<BYTE> pb(cb ? cb : 1);
    if (cb && GetTokenInformation(tok, TokenPrivileges, pb.data(), cb, &cb))
    {
        TOKEN_PRIVILEGES* tp = (TOKEN_PRIVILEGES*)pb.data();
        std::wstring names;
        for (DWORD i = 0; i < tp->PrivilegeCount && i < 64; i++)
        {
            if (haveProfLuid && tp->Privileges[i].Luid.LowPart == profLuid.LowPart &&
                tp->Privileges[i].Luid.HighPart == profLuid.HighPart)
                profilePriv = true;
            wchar_t nm[64]; DWORD nl = RTL_NUMBER_OF(nm);
            if (LookupPrivilegeNameW(nullptr, &tp->Privileges[i].Luid, nm, &nl))
            { if (!names.empty()) names += L","; names += nm; }
        }
        printf("ETWPROXY token privileges (%lu): %ls\n", tp->PrivilegeCount,
               names.empty() ? L"<none>" : names.c_str());
        BLog(L"ETWPROXY token privileges (%lu): %s", tp->PrivilegeCount,
             names.empty() ? L"<none>" : names.c_str());
    }

    cb = 0;
    GetTokenInformation(tok, TokenGroups, nullptr, 0, &cb);
    std::vector<BYTE> gb(cb ? cb : 1);
    bool plu = false;
    int enabled = 0;
    if (cb && GetTokenInformation(tok, TokenGroups, gb.data(), cb, &cb))
    {
        TOKEN_GROUPS* tg = (TOKEN_GROUPS*)gb.data();
        SID_IDENTIFIER_AUTHORITY nt = SECURITY_NT_AUTHORITY;
        PSID pluSid = nullptr;
        AllocateAndInitializeSid(&nt, 2, SECURITY_BUILTIN_DOMAIN_RID,
            DOMAIN_ALIAS_RID_LOGGING_USERS, 0, 0, 0, 0, 0, 0, &pluSid);
        for (DWORD i = 0; i < tg->GroupCount; i++)
        {
            // Deliberately counts DISABLED group SIDs too: a deny-only or disabled PLU SID
            // still marks a drifted provisioning, and disabled groups can be re-enabled by
            // anything holding TOKEN_ADJUST_GROUPS - drift is drift.
            if (tg->Groups[i].Attributes & SE_GROUP_ENABLED) enabled++;
            if (pluSid && EqualSid(tg->Groups[i].Sid, pluSid)) plu = true;
        }
        if (pluSid) FreeSid(pluSid);
    }
    printf("ETWPROXY token enabled-groups=%d perf-log-users=%d se-system-profile=%d\n",
           enabled, plu ? 1 : 0, profilePriv ? 1 : 0);
    BLog(L"ETWPROXY token enabled-groups=%d perf-log-users=%d se-system-profile=%d",
         enabled, plu ? 1 : 0, profilePriv ? 1 : 0);
    CloseHandle(tok);
    if (plu || profilePriv)
    {
        printf("ETWPROXY FAIL token DRIFT: %s%spresent - refusing to run the hostile TDH "
               "decode with machine-wide trace capability (the control/consume split grants "
               "consume via the per-session DACL only; group SIDs cannot be shed - "
               "re-run guest/provision-etwproxy-account.ps1; design sec 10.17.2)\n",
               plu ? "Performance-Log-Users " : "",
               profilePriv ? "SeSystemProfilePrivilege " : "");
        BLog(L"ETWPROXY FAIL token DRIFT: %s%spresent - refusing (sec 10.17.2)",
             plu ? L"Performance-Log-Users " : L"",
             profilePriv ? L"SeSystemProfilePrivilege " : L"");
        return true;
    }
    return false;
}

// Irreversibly strip EVERY privilege from our own primary token. SE_PRIVILEGE_REMOVED (unlike
// SE_PRIVILEGE_DISABLED) cannot be re-enabled by AdjustTokenPrivileges, so once the decode
// loop runs no privilege remains for a parser bug to abuse. Belt-and-braces to the split: the
// split closes the PLU-GROUP residual (a group SID cannot be shed from a primary token); this
// closes the privilege one. Removed one-at-a-time so a single unremovable entry cannot void
// the whole batch.
static void EtwProxyShedAllPrivileges()
{
    HANDLE tok = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_ADJUST_PRIVILEGES | TOKEN_QUERY, &tok))
    { BLog(L"ETWPROXY WARN OpenProcessToken(adjust) failed %lu - privileges NOT shed", GetLastError()); return; }

    DWORD cb = 0;
    GetTokenInformation(tok, TokenPrivileges, nullptr, 0, &cb);
    std::vector<BYTE> buf(cb ? cb : 1);
    if (cb && GetTokenInformation(tok, TokenPrivileges, buf.data(), cb, &cb))
    {
        TOKEN_PRIVILEGES* tp = (TOKEN_PRIVILEGES*)buf.data();
        int removed = 0;
        for (DWORD i = 0; i < tp->PrivilegeCount; i++)
        {
            TOKEN_PRIVILEGES one = {};
            one.PrivilegeCount = 1;
            one.Privileges[0] = tp->Privileges[i];
            one.Privileges[0].Attributes = SE_PRIVILEGE_REMOVED;
            if (AdjustTokenPrivileges(tok, FALSE, &one, 0, nullptr, nullptr) &&
                GetLastError() == ERROR_SUCCESS)
                removed++;
        }
        printf("ETWPROXY privileges shed: %d of %lu removed (SE_PRIVILEGE_REMOVED - irreversible)\n",
               removed, tp->PrivilegeCount);
        BLog(L"ETWPROXY privileges shed: %d of %lu removed (irreversible) - decode loop runs unprivileged",
             removed, tp->PrivilegeCount);
    }
    else
        BLog(L"ETWPROXY WARN could not read token privileges %lu - none shed", GetLastError());
    CloseHandle(tok);
}

static int EtwProxyMain(const wchar_t* clientSid)
{
    // Logs go to the STANDARD QWT log dir (QwtLogDir: registry LogDir else
    // %SYSTEMDRIVE%\Qubes Logs), NOT the bridge's qubes-toast-bridge state dir. Set BEFORE
    // the first BLog. The proxy holds a Modify ACE on THIS log only (provisioning script) and
    // no write access to the bridge's control surfaces.
    g_logDirOverride = QwtLogDir();
    CreateDirectoryW(g_logDirOverride.c_str(), nullptr);   // best-effort; provisioning pre-creates + ACEs
    g_logName = L"\\etw-proxy.log";

    // NEVER-SYSTEM/ADMIN GUARD (code-enforced, complements the privilege drop below): the
    // untrusted TDH/property decode must never run as SYSTEM/admin/elevated. notifhost
    // --dump-etw is the sanctioned SYSTEM diagnostic; etwproxy.exe is the ship posture and
    // must be the least-privilege qubes-etwproxy account only (design sec 10.10.1 / 10.17).
    // Refuse loudly.
    std::wstring why;
    if (EtwProxyTokenIsForbidden(why))
    {
        printf("ETWPROXY FAIL refusing to run the untrusted ETW/TDH parse under a privileged "
               "token: %ls (this path must be the least-privilege qubes-etwproxy account only)\n",
               why.c_str());
        BLog(L"ETWPROXY FAIL never-SYSTEM guard tripped: %s - refusing", why.c_str());
        return 9;
    }

    InitializeCriticalSection(&g_px.lock);
    g_px.evt = CreateEventW(nullptr, FALSE, FALSE, nullptr);
    g_px.stopEvt = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    g_px.wrEvt = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    HANDLE connEvt = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!g_px.evt || !g_px.stopEvt || !g_px.wrEvt || !connEvt)
    { printf("ETWPROXY FAIL event create %lu\n", GetLastError()); return 7; }
    std::wstring tok = CurrentUserSid();
    printf("ETWPROXY start token=%ls client_sid=%ls\n", tok.c_str(),
           clientSid ? clientSid : L"<none>");
    BLog(L"ETWPROXY start token=%s client_sid=%s", tok.c_str(),
         clientSid ? clientSid : L"<none>");
    // TOKEN-DRIFT REFUSE (secure default, same hard-refuse class as the guard above): a
    // consumer token carrying Performance Log Users or SeSystemProfilePrivilege has
    // machine-wide trace capability that cannot be shed (group SIDs are mandatory), so it
    // must never reach the decode loop. The census logs the group/priv set once either way.
    if (EtwProxyTokenCensusIsDrifted())
        return 9;

    // --- PURE CONSUMER: the SYSTEM agent (agent/gui-agent/etwproxy.c) is the session
    //     CONTROLLER - it already started QubesToastBridgeEtw (kEtwBridgeSession ==
    //     etwproxy.c's ETWPROXY_SESSION_NAME, a change-both-or-neither contract), enabled
    //     the providers, and granted this account TRACELOG_ACCESS_REALTIME on the session
    //     GUID (EventAccessControl) before launching us. This process holds NO session
    //     control by design: no StartTrace, no EnableTrace, no ControlTrace - OpenTraceW
    //     by logger name is everything it does with the session.
    TRACEHANDLE cons = EtwOpen(kEtwBridgeSession, EtwProxyEventCb);
    if (cons == INVALID_PROCESSTRACE_HANDLE || cons == 0)
    {
        DWORD gle = GetLastError();
        if (gle == ERROR_ACCESS_DENIED)
        {
            // The consume-denied datum: the per-session DACL grant did not authorize
            // real-time consumption on this build. The agent parks the tier on exit 5.
            printf("ETWPROXY FAIL OpenTrace/ProcessTrace denied - per-session DACL grant "
                   "insufficient\n");
            BLog(L"ETWPROXY FAIL OpenTrace/ProcessTrace denied - per-session DACL grant insufficient");
            return 5;
        }
        printf("ETWPROXY FAIL OpenTrace %lu (agent-started session absent?)\n", gle);
        BLog(L"ETWPROXY FAIL OpenTrace %lu (agent-started session absent?)", gle);
        return 7;
    }
    SetConsoleCtrlHandler(PxCtrlHandler, TRUE);

    // The pipe (needs no privilege). OUTBOUND = kernel-enforced one-way (this handle CANNOT
    // read); protected DACL (D:P - no inherited ACEs can widen it) admitting ONLY the bridge
    // user's SID, read-only (FR) - no SYSTEM ACE. The --client-sid is round-tripped through
    // ConvertStringSidToSidW / ConvertSidToStringSidW BEFORE it is spliced into the SDDL, so a
    // crafted --client-sid can neither inject SDDL text nor overflow the buffer; the CANONICAL
    // form is what gets spliced. No valid SID => DACL D:P (deny everyone): the pipe is locked
    // shut and the bridge tier stays down (fail-open). FIRST_PIPE_INSTANCE so a later squatter
    // cannot shadow us (and a squatter that got the name first => loud exit 8, not serve beside).
    wchar_t sddl[256];
    PSID psid = nullptr; LPWSTR canon = nullptr;
    bool sidOk = false;
    if (clientSid && *clientSid && ConvertStringSidToSidW(clientSid, &psid))
    {
        if (IsValidSid(psid) && ConvertSidToStringSidW(psid, &canon)) sidOk = true;
        LocalFree(psid);
    }
    if (sidOk)
        swprintf(sddl, RTL_NUMBER_OF(sddl), L"D:P(A;;FR;;;%s)", canon);
    else
    {
        wcscpy_s(sddl, L"D:P");
        if (clientSid && *clientSid)
        {
            printf("ETWPROXY WARN --client-sid '%ls' is not a valid SID - pipe DACL empty "
                   "(deny everyone), bridge tier stays down\n", clientSid);
            BLog(L"ETWPROXY WARN --client-sid invalid - pipe DACL empty (deny everyone)");
        }
        else
        {
            printf("ETWPROXY WARN no --client-sid: pipe DACL empty - nobody can connect (bridge tier stays down)\n");
            BLog(L"ETWPROXY WARN no --client-sid: pipe DACL empty - nobody can connect");
        }
    }
    if (canon) LocalFree(canon);

    SECURITY_ATTRIBUTES sa = { sizeof(sa) };
    if (!ConvertStringSecurityDescriptorToSecurityDescriptorW(sddl, SDDL_REVISION_1,
                                                              &sa.lpSecurityDescriptor, nullptr))
    {
        printf("ETWPROXY FAIL SDDL %lu\n", GetLastError());
        CloseTrace(cons);   // never the session - the agent owns it
        return 8;
    }
    HANDLE pipe = CreateNamedPipeW(kEtwProxyPipe,
        PIPE_ACCESS_OUTBOUND | FILE_FLAG_OVERLAPPED | FILE_FLAG_FIRST_PIPE_INSTANCE,
        PIPE_TYPE_BYTE | PIPE_WAIT, 1, 128 * 1024, 0, 0, &sa);
    LocalFree(sa.lpSecurityDescriptor);
    if (pipe == INVALID_HANDLE_VALUE)
    {
        printf("ETWPROXY FAIL CreateNamedPipe %lu (squatter holding the name?)\n", GetLastError());
        BLog(L"ETWPROXY FAIL CreateNamedPipe %lu", GetLastError());
        CloseTrace(cons);   // never the session - the agent owns it
        return 8;
    }

    // === PRIVILEGE DROP =====================================================================
    // OpenTrace and the pipe DACL are done; nothing left needs any privilege (the bare
    // qubes-etwproxy token should hold none to begin with - the split's whole point).
    // Irreversibly strip EVERY privilege from our token BEFORE the ProcessTrace/PxHarvest
    // decode loop consumes one attacker-influenceable byte. If real-time consumption is
    // refused despite the agent's per-session DACL grant, ProcessTrace returns
    // ERROR_ACCESS_DENIED and this process exits 5 => the agent parks on a TRUE finding
    // (design sec 10.16.3b's datum under the split). (The architect's control/consume split
    // is what closes the PLU-GROUP residual sec 10.17.2; this in-process drop is its
    // belt-and-braces.)
    EtwProxyShedAllPrivileges();

    HANDLE etwThread = CreateThread(nullptr, 0, EtwProcessTraceThread, &cons, 0, nullptr);
    if (!etwThread)
    {
        printf("ETWPROXY FAIL consumer thread %lu\n", GetLastError());
        BLog(L"ETWPROXY FAIL consumer thread %lu", GetLastError());
        CloseTrace(cons);   // never the session - the agent owns it
        CloseHandle(pipe);
        return 7;
    }
    printf("ETWPROXY LIVE session=%ls pipe=%ls (pure consumer: session/providers/grant "
           "are agent-owned)\n", kEtwBridgeSession, kEtwProxyPipe);
    BLog(L"ETWPROXY LIVE session=%s pipe=%s (pure consumer)", kEtwBridgeSession, kEtwProxyPipe);

    // Serve loop: wait for the (single) client, push frames, on client loss disconnect
    // and wait again. Ends when the ETW session dies (etwThread signaled) or on ctrl/stop.
    int exitCode = 0;
    for (;;)
    {
        OVERLAPPED ov = {}; ov.hEvent = connEvt; ResetEvent(connEvt);
        BOOL c = ConnectNamedPipe(pipe, &ov);
        DWORD ce = c ? ERROR_PIPE_CONNECTED : GetLastError();
        if (ce == ERROR_IO_PENDING)
        {
            HANDLE hs[3] = { connEvt, g_px.stopEvt, etwThread };
            DWORD w = WaitForMultipleObjects(3, hs, FALSE, INFINITE);
            if (w != WAIT_OBJECT_0)
            {
                CancelIoEx(pipe, &ov);
                DWORD x; GetOverlappedResult(pipe, &ov, &x, TRUE);
                break;
            }
            DWORD x;
            if (!GetOverlappedResult(pipe, &ov, &x, FALSE) &&
                GetLastError() != ERROR_PIPE_CONNECTED)
            { BLog(L"ETWPROXY connect completion failed %lu", GetLastError()); break; }
        }
        else if (ce != ERROR_PIPE_CONNECTED)
        { BLog(L"ETWPROXY ConnectNamedPipe failed %lu", ce); exitCode = 8; break; }
        ULONG cp = 0;
        GetNamedPipeClientProcessId(pipe, &cp);
        BLog(L"ETWPROXY CLIENT connected pid=%lu", cp);
        bool clientOk = true;
        while (clientOk)
        {
            HANDLE hs[3] = { g_px.evt, g_px.stopEvt, etwThread };
            if (WaitForMultipleObjects(3, hs, FALSE, INFINITE) != WAIT_OBJECT_0)
            { clientOk = false; break; }             // stop / session death
            for (;;)
            {
                std::vector<BYTE> f;
                {
                    CsGuard g(&g_px.lock);
                    if (g_px.q.empty()) break;
                    f = std::move(g_px.q.front());
                    g_px.q.pop_front();
                }
                if (!PxWrite(pipe, etwThread, f.data(), (DWORD)f.size()))
                { BLog(L"ETWPROXY client write failed - disconnecting"); clientOk = false; break; }
                InterlockedIncrement(&g_px.sent);
            }
        }
        DisconnectNamedPipe(pipe);
        if (WaitForSingleObject(g_px.stopEvt, 0) == WAIT_OBJECT_0 ||
            WaitForSingleObject(etwThread, 0) == WAIT_OBJECT_0) break;
    }

    // Pure-consumer teardown: NEVER stop the session - the SYSTEM agent owns its whole
    // lifecycle (park/shutdown stop it; job-kill + the agent's next-launch stop-by-name
    // reap cover every crash path). Closing OUR consumer handle is what ends ProcessTrace
    // (ERROR_CTX_CLOSE_PENDING = success: it drains and returns; process exit covers a
    // straggler past the bounded wait).
    CloseTrace(cons);
    WaitForSingleObject(etwThread, 5000);
    DWORD ptrc = (DWORD)-1;
    GetExitCodeThread(etwThread, &ptrc);   // EtwProcessTraceThread returns ProcessTrace's rc
    CloseHandle(etwThread);
    CloseHandle(pipe);
    if (ptrc == ERROR_ACCESS_DENIED)
    {
        // ProcessTrace itself was refused: real-time consumption is denied despite the
        // agent's per-session DACL grant. This must surface as the consume-denied exit so
        // the agent parks on a TRUE finding - never a masquerading clean exit 0.
        printf("ETWPROXY FAIL OpenTrace/ProcessTrace denied - per-session DACL grant "
               "insufficient\n");
        BLog(L"ETWPROXY FAIL OpenTrace/ProcessTrace denied - per-session DACL grant insufficient");
        exitCode = 5;
    }
    printf("ETWPROXY stop rc=%d captured=%ld sent=%ld dropped=%ld\n",
           exitCode, g_px.captured, g_px.sent, g_px.dropped);
    BLog(L"ETWPROXY stop rc=%d captured=%ld sent=%ld dropped=%ld",
         exitCode, g_px.captured, g_px.sent, g_px.dropped);
    return exitCode;
}

int wmain(int argc, wchar_t** argv)
{
    SetUnhandledExceptionFilter(BridgeCrashFilter);   // crash leaves a breadcrumb in the log
    const wchar_t* clientSid = nullptr;
    for (int i = 1; i < argc; i++)
    {
        if (_wcsicmp(argv[i], L"--client-sid") == 0 && i + 1 < argc) clientSid = argv[++i];
        else if (_wcsicmp(argv[i], L"--etw-proxy") == 0) { /* legacy flag: this binary IS the proxy */ }
    }
    return EtwProxyMain(clientSid);
}
