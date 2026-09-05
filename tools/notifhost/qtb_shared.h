// qtb_shared.h - code shared between the TWO toast-bridge binaries:
//   notifhost.exe  (tools/notifhost/notifhost.cpp) - the user-session bridge/diagnostics.
//                  Links WinRT (windowsapp) + user32/gdi32 for UserNotificationListener,
//                  ShowBanner and the legacy GDI toast windows.
//   etwproxy.exe   (tools/notifhost/etwproxy.cpp) - the least-privilege ETW signal proxy.
//                  MUST NOT import user32.dll or gdi32.dll: it runs under the bare
//                  qubes-etwproxy batch token in session 0, which has NO accessible window
//                  station, and user32/gdi32's DllMain connects to the process winsta at
//                  init -> 0xC0000142 STATUS_DLL_INIT_FAILED before one instruction of ours
//                  runs (rig-measured, 2026-09-05). The console split exists so that
//                  failure is IMPOSSIBLE by construction instead of patched around with
//                  winsta grants.
//
// THEREFORE THIS HEADER IS RESTRICTED TO PURE WIN32 USERLAND WITH NO GUI SURFACE:
// kernel32 + advapi32 + tdh only. No <winrt/...>, no windows.ui.*, no user32/gdi32 API,
// no #pragma comment(lib, ...) at all - each .vcxproj declares its own libs, and
// etwproxy.vcxproj deliberately lists only kernel32/advapi32/tdh. CI enforces the outcome
// with a dumpbin /imports gate on etwproxy.exe (and proves the gate can fail by running it
// against notifhost.exe, which does import user32).
//
// Everything here is `inline` (C++17): each binary is a single TU, so this costs nothing
// and needs no shared .lib. The WIRE CONTRACT section is the one true definition of the
// proxy->bridge frame format and rendezvous names - the "change both or neither" pairs
// live in ONE place now.
#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif
#include <windows.h>
#include <sddl.h>       // ConvertSidToStringSidW (CurrentUserSid)
#include <wmistr.h>     // WNODE_HEADER (evntrace.h prerequisite)
#include <evntrace.h>   // OpenTraceW/ProcessTrace (real-time ETW consume)
#include <evntcons.h>   // EVENT_RECORD consumer definitions
#include <tdh.h>        // TRACE_EVENT_INFO (EtwTiString)
#include <string>
#include <vector>
#include <cstdio>
#include <cstdarg>

// --- small utilities ----------------------------------------------------------------------

inline std::string Utf8(std::wstring const& w)
{
    if (w.empty()) return std::string();
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s(n > 0 ? n : 0, 0);
    if (n > 0) WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), &s[0], n, nullptr, nullptr);
    return s;
}

inline std::wstring StateDir()
{
    wchar_t pd[MAX_PATH];
    if (!GetEnvironmentVariableW(L"ProgramData", pd, RTL_NUMBER_OF(pd)))
        wcscpy_s(pd, L"C:\\ProgramData");
    std::wstring d = std::wstring(pd) + L"\\qubes-toast-bridge";
    CreateDirectoryW(d.c_str(), nullptr);
    return d;
}

// The STANDARD QWT log directory (windows-utils LogInitDefault convention, log.c:235-253):
// HKLM\Software\Invisible Things Lab\Qubes Tools : LogDir if set, else %SYSTEMDRIVE%\Qubes Logs.
// etwproxy.exe routes etw-proxy.log HERE (not the bridge's qubes-toast-bridge state dir): the
// proxy runs as a different, lower-privileged account and must hold write access to its OWN log
// ONLY - never to the bridge's control surfaces (stop file, heartbeat, banner markers). The
// proxy-scoped ACE (Modify on this one log) is granted by guest/provision-etwproxy-account.ps1.
inline std::wstring QwtLogDir()
{
    wchar_t buf[MAX_PATH];
    HKEY k;
    if (!RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"Software\\Invisible Things Lab\\Qubes Tools",
                       0, KEY_READ | KEY_WOW64_64KEY, &k))
    {
        DWORD cb = sizeof(buf), type = 0;
        LONG r = RegQueryValueExW(k, L"LogDir", nullptr, &type, (BYTE*)buf, &cb);
        RegCloseKey(k);
        if (r == ERROR_SUCCESS && (type == REG_SZ || type == REG_EXPAND_SZ) &&
            cb >= sizeof(wchar_t) && buf[0])
        {
            buf[cb / sizeof(wchar_t) < RTL_NUMBER_OF(buf) ? cb / sizeof(wchar_t) : RTL_NUMBER_OF(buf) - 1] = 0;
            std::wstring d(buf);
            if (type == REG_EXPAND_SZ)
            {
                wchar_t ex[MAX_PATH];
                if (ExpandEnvironmentStringsW(d.c_str(), ex, RTL_NUMBER_OF(ex))) d = ex;
            }
            return d;
        }
    }
    // Default: %SYSTEMDRIVE%\Qubes Logs (LOG_DEFAULT_DIR). Derive the system drive from the
    // system directory (e.g. "C:\Windows\System32" -> "C:\").
    wchar_t sysdir[MAX_PATH];
    if (GetSystemDirectoryW(sysdir, RTL_NUMBER_OF(sysdir)) && sysdir[1] == L':')
    {
        std::wstring d(sysdir, 3);   // "C:\"
        d += L"Qubes Logs";
        return d;
    }
    return L"C:\\Qubes Logs";
}

// --- BLog ---------------------------------------------------------------------------------
// Log file basename: bridge.log for every notifhost.exe mode; etwproxy.exe switches BOTH
// values to {QwtLogDir(), etw-proxy.log} BEFORE its first BLog (it runs under a different
// account - the bridge state dir's ACLs may deny it bridge.log, and interleaving two
// accounts' writers would be noise anyway). Empty g_logDirOverride = use StateDir().
inline const wchar_t* g_logName = L"\\bridge.log";
inline std::wstring g_logDirOverride;

inline void BLog(const wchar_t* fmt, ...)
{
    static std::wstring path;
    if (path.empty()) path = (g_logDirOverride.empty() ? StateDir() : g_logDirOverride) + g_logName;
    wchar_t line[2048];
    SYSTEMTIME st; GetLocalTime(&st);
    int off = swprintf(line, RTL_NUMBER_OF(line), L"%02u:%02u:%02u ", st.wHour, st.wMinute, st.wSecond);
    va_list ap; va_start(ap, fmt);
    vswprintf(line + off, RTL_NUMBER_OF(line) - off - 2, fmt, ap);
    va_end(ap);
    wcscat_s(line, L"\r\n");
    // rotate at ~1 MB so a chatty failure can never eat the disk
    WIN32_FILE_ATTRIBUTE_DATA fad;
    if (GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &fad) && fad.nFileSizeLow > 1024 * 1024)
        MoveFileExW(path.c_str(), (path + L".old").c_str(), MOVEFILE_REPLACE_EXISTING);
    // FILE_SHARE_WRITE + bounded retry (2026-09-05): with share-READ-only, two concurrent
    // writers (the main loop's SENT vs the shadow worker's CLASSIFY since 5133293, or a
    // second notifhost process: --restore-banners / relay) collide in ERROR_SHARING_VIOLATION
    // and the losing line was SILENTLY DROPPED. Proven in the 2026-09-05 A0 run: ids 15/20/22
    // were forwarded+acked (FWD_RTT ok=1, dom0 Dismissed callback) but their SENT lines never
    // landed, false-failing P4a/P6b/P7 on SENT-keyed detectors. FILE_APPEND_DATA keeps each
    // WriteFile an atomic append, so write-sharing is safe; the short retry covers an external
    // reader holding a deny-write handle for a moment. A drop after retries still exits
    // silently - logging cannot be allowed to fail the caller.
    HANDLE f = INVALID_HANDLE_VALUE;
    for (int attempt = 0; attempt < 5; attempt++)
    {
        f = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ | FILE_SHARE_WRITE,
                        nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
        if (f != INVALID_HANDLE_VALUE || GetLastError() != ERROR_SHARING_VIOLATION) break;
        Sleep(2);
    }
    if (f == INVALID_HANDLE_VALUE) return;
    std::string u = Utf8(line);
    DWORD wr; WriteFile(f, u.data(), (DWORD)u.size(), &wr, nullptr);
    CloseHandle(f);
}

// DIAGNOSTIC (2026-09-05 silent-vanish localization): last-chance crash breadcrumb. Under
// /EHsc catch(...) sees only C++ exceptions; an SEH fault (AV etc.) bypasses every guard and
// killed the process with no log line. This filter logs the code+address+thread before the
// process dies. A __fastfail/heap-corruption fail-fast BYPASSES even this filter - so a vanish
// with NO CRASH line and NO guard line is itself a signal (memory-safety class). Process still
// terminates (fail-open: supervision relaunches, and recovery paths undo standing state).
inline LONG WINAPI BridgeCrashFilter(EXCEPTION_POINTERS* ep)
{
    if (ep && ep->ExceptionRecord)
        BLog(L"CRASH code=0x%08lX addr=%p tid=%lu (unhandled - terminating)",
             ep->ExceptionRecord->ExceptionCode,
             ep->ExceptionRecord->ExceptionAddress,
             GetCurrentThreadId());
    else
        BLog(L"CRASH (no exception record) tid=%lu (unhandled - terminating)",
             GetCurrentThreadId());
    return EXCEPTION_EXECUTE_HANDLER;
}

inline std::wstring CurrentUserSid()
{
    HANDLE tok = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &tok)) return L"unknown";
    DWORD cb = 0; GetTokenInformation(tok, TokenUser, nullptr, 0, &cb);
    std::vector<BYTE> buf(cb ? cb : 1);
    std::wstring out = L"unknown";
    if (cb && GetTokenInformation(tok, TokenUser, buf.data(), cb, &cb))
    {
        LPWSTR s = nullptr;
        if (ConvertSidToStringSidW(((TOKEN_USER*)buf.data())->User.Sid, &s) && s)
        { out = s; LocalFree(s); }
    }
    CloseHandle(tok);
    return out;
}

// --- little-endian scalar codec (wire frames both sides of the pipe, bincode port) --------

inline void PutU32(std::vector<BYTE>& v, uint32_t x)
{ v.push_back((BYTE)x); v.push_back((BYTE)(x >> 8)); v.push_back((BYTE)(x >> 16)); v.push_back((BYTE)(x >> 24)); }
inline void PutU64(std::vector<BYTE>& v, uint64_t x)
{ PutU32(v, (uint32_t)x); PutU32(v, (uint32_t)(x >> 32)); }
inline uint32_t GetU32(const BYTE* b) { return b[0] | (b[1] << 8) | (b[2] << 16) | ((uint32_t)b[3] << 24); }
inline uint64_t GetU64(const BYTE* b) { return GetU32(b) | ((uint64_t)GetU32(b + 4) << 32); }

// --- RAII critical-section guard (review must-fix) ----------------------------------------
// LeaveCriticalSection on EVERY exit path, including a throw between an Enter and its
// Leave - the previous bare pair in the event callback leaked the lock if push_back threw,
// deadlocking the next ring lookup forever. EVERY shared-state lock take in both binaries
// goes through this guard.
struct CsGuard
{
    CRITICAL_SECTION* cs;
    explicit CsGuard(CRITICAL_SECTION* c) : cs(c) { EnterCriticalSection(cs); }
    ~CsGuard() { LeaveCriticalSection(cs); }
    CsGuard(CsGuard const&) = delete;
    CsGuard& operator=(CsGuard const&) = delete;
};

// --- THE WIRE CONTRACT: proxy -> bridge, one-way, over a byte pipe ------------------------
// 'QTS1' SIGNAL frame (design 10.20.1; replaces the 'QTE1' payload frame - the payload
// field is DELETED because the payload is not in ETW on Win10, proven by the 732-event
// broadcap). One frame per AUMID-bearing event, little-endian, every length bound-checked
// on receive:
//   off  0  u32 magic 'QTS1'
//        4  u32 aumidBytes    (UTF-16LE, <= 1024; 0 allowed only when notifIdNum != 0)
//        8  u32 notifIdBytes  (UTF-16LE raw string form, <= 64; may be 0)
//       12  u32 tagBytes      (UTF-16LE, <= 256; may be 0)
//       16  u32 groupBytes    (UTF-16LE, <= 256; may be 0)
//       20  u64 notifIdNum    (the notificationId as an integer when its TDH intype was
//                              integral or the string is all-decimal; 0 = no id join)
//       28  u64 eventFiletime (EVENT_RECORD FILETIME)
//       36  aumid | notifId | tag | group bytes, in that order
// This header is included by BOTH binaries, so the frame layout, the pipe name and the
// session name can no longer drift apart ("change both or neither" is now "change here").
#define ETW_WIRE_MAGIC        0x31535451u          // 'Q','T','S','1' read LE
#define ETW_WIRE_HDR_BYTES    36u
#define ETW_MAX_AUMID_BYTES   1024u
#define ETW_MAX_NOTIF_BYTES   64u
#define ETW_MAX_TAG_BYTES     256u
#define ETW_MAX_GROUP_BYTES   256u
#define ETW_MAX_FRAME_BYTES   2048u                // total frame cap (down from 64 KB: no payload)
inline const wchar_t* const kEtwProxyPipe = L"\\\\.\\pipe\\qubes-toast-etw";

// STARTED/OWNED by the SYSTEM agent (shared contract with agent/gui-agent/etwproxy.c
// ETWPROXY_SESSION_NAME - change both or neither); etwproxy.exe only OpenTraceW's it, and
// notifhost --dump-etw never touches it (it owns its own kEtwDumpSession).
inline const wchar_t* const kEtwBridgeSession = L"QubesToastBridgeEtw";

// --- real-time ETW consume plumbing (shared by --dump-etw and etwproxy.exe) ---------------

inline std::wstring EtwTiString(TRACE_EVENT_INFO* ti, ULONG off)
{
    return off ? std::wstring((const wchar_t*)((BYTE*)ti + off)) : std::wstring();
}

inline std::wstring EtwLower(std::wstring s)
{
    for (auto& c : s) if (c >= L'A' && c <= L'Z') c = (wchar_t)(c + 32);
    return s;
}

// Per-delivery buffer instrumentation (design 10.20.4 hardening): logs BuffersRead /
// EventsLost so "no events" is distinguishable as "no deliveries at all" (pacing/session
// problem) vs "deliveries with zero events" (provider silence). Rate-bounded: always on
// loss, else first 3 deliveries and every 100th. Both stdout (the --dump-etw / proxy
// console) and BLog. Returning TRUE continues ProcessTrace.
inline volatile LONG g_etwBufCount = 0;
inline ULONG WINAPI EtwBufferCb(PEVENT_TRACE_LOGFILEW lf)
{
    LONG n = InterlockedIncrement(&g_etwBufCount);
    if (lf && (lf->EventsLost > 0 || n <= 3 || (n % 100) == 0))
    {
        printf("ETWBUF delivery=%ld buffers_read=%lu events_lost=%lu\n",
               n, lf->BuffersRead, lf->EventsLost);
        BLog(L"ETWBUF delivery=%ld buffers_read=%lu events_lost=%lu",
             n, lf->BuffersRead, lf->EventsLost);
    }
    return TRUE;
}

// The real-time consume setup (verified correct per design 10.20.4: LoggerName - not
// LogFileName - plus REAL_TIME|EVENT_RECORD and the record callback; the events=0 datum
// was delivery pacing, fixed by FlushTimer on the session, not this struct).
inline TRACEHANDLE EtwOpen(const wchar_t* name, PEVENT_RECORD_CALLBACK cb)
{
    EVENT_TRACE_LOGFILEW lf = {};
    lf.LoggerName = const_cast<LPWSTR>(name);
    lf.ProcessTraceMode = PROCESS_TRACE_MODE_REAL_TIME | PROCESS_TRACE_MODE_EVENT_RECORD;
    lf.EventRecordCallback = cb;
    lf.BufferCallback = EtwBufferCb;
    return OpenTraceW(&lf);
}

inline DWORD WINAPI EtwProcessTraceThread(LPVOID p)
{
    TRACEHANDLE h = *(TRACEHANDLE*)p;
    // The rc IS the thread exit code: etwproxy.exe reads it with GetExitCodeThread to tell
    // a consume denial (ERROR_ACCESS_DENIED -> its exit 5, the grant-insufficiency datum)
    // from a clean externally-ended trace. Discarding it here once let a denied consumer
    // masquerade as a clean exit 0.
    return ProcessTrace(&h, 1, nullptr, nullptr);
}
