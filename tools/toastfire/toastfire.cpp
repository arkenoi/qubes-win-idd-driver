// toastfire.cpp - DETERMINISTIC synthetic unpackaged-toast sender for the toast-bridge
// tests (A0 acceptance + the P3 per-toast split).
//
// WHY THIS EXISTS
// guest/fire-demo-toast.ps1 is the current fixture. It reproduces the right toast CLASSES
// (informational / -RealChoice / -Persistent) but is deliberately NON-deterministic where
// tests need determinism: it stamps a RANDOM per-fire GUID tag (fire-demo-toast.ps1:44,
// [guid]::NewGuid()), and it can only register one way - the AUMID it borrows,
// '{1AC14E77-...}\WindowsPowerShell\v1.0\powershell.exe' (fire-demo-toast.ps1:8), exists
// because PowerShell ships a Start-menu shortcut carrying System.AppUserModel.ID (the
// "Start-shortcut" unpackaged method). Unpackaged apps register for toasts in three
// materially different ways, and the bridge's acquisition tiers (NotificationChanged /
// ETW / wpndatabase AUMID attribution) may behave differently per method. toastfire makes
// each method an explicit, hermetic, idempotent choice, and makes every payload byte-stable.
//
// DETERMINISM CONTRACT (the point of the tool - violating it is a bug):
//   * Identical arguments => byte-IDENTICAL toast XML payload. The payload is built by pure
//     string concatenation from --class/--title/--body only. No GUIDs, no rand(), no
//     GetTickCount(), no timestamps, no locale-dependent formatting anywhere in the payload
//     or in default tags. The only escaping applied to title/body is & < > (in that order),
//     matching fire-demo-toast.ps1:25 byte-for-byte, so the default payloads equal the
//     hand-written fixtures in tools/notifhost/toastclassify_fixtures.h
//     (row3-reminder-two-buttons / row3-persistent-informational / row6-no-actions).
//   * Every FIRED line carries payload_sha256 = SHA-256 (lowercase hex) of the UTF-8 bytes
//     of the exact XML string handed to XmlDocument.LoadXml, so a harness can assert
//     reproducibility across fires/boots/builds. (Windows may re-serialize the doc when it
//     stores the payload in wpndatabase - quoting/whitespace can differ there - but that
//     round-trip is itself a pure function of our input, so it too is reproducible.)
//   * Tags/groups are CALLER-SUPPLIED, never auto-random. Omitted => fixed literal
//     "toastfire". A burst (--count N) derives per-toast tags deterministically as
//     "<tag>-<index>" (0-based decimal); with --count 1 the tag is used verbatim.
//   * COALESCING TRAP (documented, caller-controlled): Windows treats same AUMID + same
//     Tag + same Group as the SAME notification slot - a re-fire REPLACES the toast in
//     place and is NOT raised as a new UserNotificationListener id (the exact P4a false
//     "sent=no" fire-demo-toast.ps1:40-44 randomized tags to dodge). toastfire hands that
//     control to the harness instead: vary --tag per fire you want counted separately,
//     reuse a tag to test replacement on purpose.
//
// REGISTRATION METHODS (--method) - three GENUINELY DISTINCT unpackaged registrations:
//   start-shortcut  a Start-menu .lnk whose property store carries System.AppUserModel.ID
//                   (PKEY_AppUserModel_ID) = the AUMID. This is PowerShell's method - the
//                   one fire-demo-toast.ps1 piggybacks on. File created:
//                   %APPDATA%\Microsoft\Windows\Start Menu\Programs\toastfire-<sanitized-aumid>.lnk
//   com-activator   the ToastNotificationManagerCompat desktop-app scheme used by modern
//                   unpackaged apps (Slack/Discord/Electron):
//                     HKCU\Software\Classes\AppUserModelId\<AUMID>
//                       DisplayName     = "toastfire"           (REG_SZ)
//                       CustomActivator = "{CLSID}"             (REG_SZ)
//                     HKCU\Software\Classes\CLSID\{CLSID}\LocalServer32
//                       (default)       = "<exe> --com-activated"
//                   The CLSID is DERIVED DETERMINISTICALLY from the AUMID (first 16 bytes
//                   of SHA-256(UTF-8 AUMID) with RFC-4122 version/variant bits forced), so
//                   register/unregister/re-register always touch the same keys and the
//                   harness can predict them. Activation CALLBACKS are out of scope - the
//                   registration's existence is what differentiates listener/ETW/AUMID
//                   behavior; a click would launch this exe with -Embedding, which exits 0.
//                   AUMIDs containing '\' are REFUSED for this method (they would nest
//                   registry keys and break hermetic teardown).
//   bare            no registration at all - CreateToastNotifier(aumid) on a never-seen
//                   AUMID. Whether Windows shows/attributes/raises such toasts is exactly
//                   the per-method variance the tests exist to measure.
// --register / --unregister are IDEMPOTENT (re-running either is a no-op success) and
// HERMETIC (--unregister removes exactly what --register created: the one .lnk, the two
// registry trees; nothing else, and missing pieces are not errors).
//
// TOAST CLASSES (--class) -> docs/DESIGN-toast-bridge.md 2.2 decision table (:165-177):
//   informational  <toast> text-only, no actions                          -> bridge, row 6
//   realchoice     scenario="reminder" + OK/Later buttons (window path)   -> window, row 3
//   persistent     scenario="reminder" + one OK button (stays on screen)  -> window, row 3
//   long           <toast duration="long"> text-only (~25s informational) -> bridge, row 6
// The tool SELF-CHECKS every payload through the real classifier
// (tools/notifhost/toastclassify.h, included directly) and refuses to fire if the verdict
// row differs from the intended row - the fixtures can never drift from the classifier.
//
// OUTPUT (one line per action, space-delimited key=value, greppable):
//   FIRED method=<m> aumid=<a> class=<c> tag=<t> group=<g> row=<r> payload_sha256=<64 lowercase hex>
//   REGISTERED / UNREGISTERED / PAYLOAD / ERROR lines analogous; exit 0 ok, 1 usage, 2 failure.
//
// BUILD: plain v143 / /MT / /std:c++17 / SDK-only C++/WinRT - mirrors tools/notifhost
// (notifhost.vcxproj:3-9). No WDK, no nuget. Runs in the interactive user session (toasts
// need one), per-user registration only, no admin. Ships via build.yml's gui-agent job
// ("Build toastfire" + "Collect package" -> package-agent\), same as wgcprobe - the
// helpers-must-be-explicitly-packaged rule: a tool not staged ships nowhere.

#include <windows.h>
#include <initguid.h>       // instantiate PKEY_/FOLDERID_ GUIDs in this (single) TU
#include <shobjidl.h>       // IShellLinkW, IPersistFile, IPropertyStore
#include <propkey.h>        // PKEY_AppUserModel_ID
#include <knownfolders.h>   // FOLDERID_Programs
#include <shlobj.h>         // SHGetKnownFolderPath

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.UI.Notifications.h>

#include <cstdint>
#include <cstdlib>    // exit, wcstol
#include <cstring>
#include <cwchar>
#include <string>
#include <vector>

#include "../notifhost/toastclassify.h"   // the REAL classifier: payload self-check

#pragma comment(lib, "windowsapp.lib")
#pragma comment(lib, "ole32.lib")
#pragma comment(lib, "shell32.lib")
#pragma comment(lib, "advapi32.lib")
#pragma comment(lib, "uuid.lib")

// ---------------------------------------------------------------- deterministic plumbing

// UTF-8 conversion (CP_UTF8 is a fixed mapping - no locale variance).
static std::string Utf8(const std::wstring& w)
{
    if (w.empty()) return {};
    int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0, nullptr, nullptr);
    std::string s((size_t)n, '\0');
    WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), s.data(), n, nullptr, nullptr);
    return s;
}

static void Line(const std::wstring& w)      // one output line, UTF-8, '\n' terminated
{
    std::string s = Utf8(w);
    s += '\n';
    fwrite(s.data(), 1, s.size(), stdout);
    fflush(stdout);
}

// Minimal embedded SHA-256 (FIPS 180-4). Embedded rather than BCrypt so the hash path has
// zero API surface that could vary; output is a pure function of the input bytes.
namespace sha256 {
static const uint32_t K[64] = {
    0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
    0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
    0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
    0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
    0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
    0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
    0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
    0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2 };
static inline uint32_t Rot(uint32_t x, int r) { return (x >> r) | (x << (32 - r)); }
static void Hash(const uint8_t* data, size_t len, uint8_t out[32])
{
    uint32_t h[8] = { 0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,
                      0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19 };
    uint64_t bits = (uint64_t)len * 8;
    std::vector<uint8_t> m(data, data + len);
    m.push_back(0x80);
    while (m.size() % 64 != 56) m.push_back(0);
    for (int i = 7; i >= 0; i--) m.push_back((uint8_t)(bits >> (i * 8)));
    for (size_t off = 0; off < m.size(); off += 64)
    {
        uint32_t w[64];
        for (int i = 0; i < 16; i++)
            w[i] = ((uint32_t)m[off + 4 * i] << 24) | ((uint32_t)m[off + 4 * i + 1] << 16) |
                   ((uint32_t)m[off + 4 * i + 2] << 8) | (uint32_t)m[off + 4 * i + 3];
        for (int i = 16; i < 64; i++)
        {
            uint32_t s0 = Rot(w[i - 15], 7) ^ Rot(w[i - 15], 18) ^ (w[i - 15] >> 3);
            uint32_t s1 = Rot(w[i - 2], 17) ^ Rot(w[i - 2], 19) ^ (w[i - 2] >> 10);
            w[i] = w[i - 16] + s0 + w[i - 7] + s1;
        }
        uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], hh = h[7];
        for (int i = 0; i < 64; i++)
        {
            uint32_t S1 = Rot(e, 6) ^ Rot(e, 11) ^ Rot(e, 25);
            uint32_t ch = (e & f) ^ (~e & g);
            uint32_t t1 = hh + S1 + ch + K[i] + w[i];
            uint32_t S0 = Rot(a, 2) ^ Rot(a, 13) ^ Rot(a, 22);
            uint32_t mj = (a & b) ^ (a & c) ^ (b & c);
            uint32_t t2 = S0 + mj;
            hh = g; g = f; f = e; e = d + t1; d = c; c = b; b = a; a = t1 + t2;
        }
        h[0] += a; h[1] += b; h[2] += c; h[3] += d; h[4] += e; h[5] += f; h[6] += g; h[7] += hh;
    }
    for (int i = 0; i < 8; i++)
    {
        out[4 * i]     = (uint8_t)(h[i] >> 24);
        out[4 * i + 1] = (uint8_t)(h[i] >> 16);
        out[4 * i + 2] = (uint8_t)(h[i] >> 8);
        out[4 * i + 3] = (uint8_t)h[i];
    }
}
} // namespace sha256

static std::wstring HexLower(const uint8_t* p, size_t n)
{
    static const wchar_t* d = L"0123456789abcdef";
    std::wstring s;
    s.reserve(n * 2);
    for (size_t i = 0; i < n; i++) { s += d[p[i] >> 4]; s += d[p[i] & 15]; }
    return s;
}

static std::wstring PayloadSha256(const std::wstring& xml)
{
    std::string u = Utf8(xml);                 // no BOM, exact payload bytes
    uint8_t dig[32];
    sha256::Hash((const uint8_t*)u.data(), u.size(), dig);
    return HexLower(dig, 32);
}

// Deterministic CLSID from an AUMID: first 16 bytes of SHA-256(UTF-8 AUMID), RFC-4122
// version nibble forced to 5 and variant to 10x. Not a namespaced UUIDv5, but a stable
// pure function of the AUMID - same AUMID always maps to the same activator CLSID.
static std::wstring DeriveClsid(const std::wstring& aumid)
{
    std::string u = Utf8(aumid);
    uint8_t d[32];
    sha256::Hash((const uint8_t*)u.data(), u.size(), d);
    d[6] = (uint8_t)((d[6] & 0x0F) | 0x50);
    d[8] = (uint8_t)((d[8] & 0x3F) | 0x80);
    wchar_t buf[64];
    swprintf(buf, 64, L"{%02X%02X%02X%02X-%02X%02X-%02X%02X-%02X%02X-%02X%02X%02X%02X%02X%02X}",
             d[0], d[1], d[2], d[3], d[4], d[5], d[6], d[7],
             d[8], d[9], d[10], d[11], d[12], d[13], d[14], d[15]);
    return buf;
}

// ---------------------------------------------------------------- payload construction

// EXACTLY fire-demo-toast.ps1:25 - & first, then < and > - so default payloads are
// byte-identical to the PS fixture shapes and to toastclassify_fixtures.h.
static std::wstring XmlEscapeText(const std::wstring& s)
{
    std::wstring o;
    o.reserve(s.size());
    for (wchar_t c : s)
    {
        if (c == L'&') o += L"&amp;";
        else if (c == L'<') o += L"&lt;";
        else if (c == L'>') o += L"&gt;";
        else o += c;
    }
    return o;
}

struct ToastSpec { const wchar_t* cls; int expectRoute; int expectRow; };
static const ToastSpec kClasses[] = {
    { L"informational", ToastRouteBridge, 6 },   // fire-demo-toast.ps1:35 / row6-no-actions
    { L"realchoice",    ToastRouteWindow, 3 },   // fire-demo-toast.ps1:29 / row3-reminder-two-buttons
    { L"persistent",    ToastRouteWindow, 3 },   // fire-demo-toast.ps1:32 / row3-persistent-informational
    { L"long",          ToastRouteBridge, 6 },   // duration="long" text-only: still row 6
};

static std::wstring BuildPayload(const std::wstring& cls,
                                 const std::wstring& title, const std::wstring& body)
{
    std::wstring t = XmlEscapeText(title), b = XmlEscapeText(body);
    std::wstring visual =
        L"<visual><binding template=\"ToastGeneric\"><text>" + t +
        L"</text><text>" + b + L"</text></binding></visual>";
    if (cls == L"informational")
        return L"<toast>" + visual + L"</toast>";
    if (cls == L"long")
        return L"<toast duration=\"long\">" + visual + L"</toast>";
    if (cls == L"realchoice")
        return L"<toast scenario=\"reminder\">" + visual +
               L"<actions><action content=\"OK\" arguments=\"ok\"/>"
               L"<action content=\"Later\" arguments=\"later\"/></actions></toast>";
    if (cls == L"persistent")
        return L"<toast scenario=\"reminder\">" + visual +
               L"<actions><action content=\"OK\" arguments=\"ok\"/></actions></toast>";
    return {};
}

// ---------------------------------------------------------------- registration methods

static std::wstring ExePath()
{
    wchar_t p[MAX_PATH];
    DWORD n = GetModuleFileNameW(nullptr, p, MAX_PATH);
    return std::wstring(p, n);
}

// Deterministic, filesystem/registry-safe token from an AUMID.
static std::wstring Sanitize(const std::wstring& aumid)
{
    std::wstring o;
    for (wchar_t c : aumid)
    {
        bool ok = (c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') ||
                  (c >= L'0' && c <= L'9') || c == L'.' || c == L'_' || c == L'-';
        o += ok ? c : L'_';
        if (o.size() >= 80) break;
    }
    return o;
}

static std::wstring LnkPath(const std::wstring& aumid)
{
    PWSTR programs = nullptr;
    if (FAILED(SHGetKnownFolderPath(FOLDERID_Programs, 0, nullptr, &programs)))
        return {};
    std::wstring p = std::wstring(programs) + L"\\toastfire-" + Sanitize(aumid) + L".lnk";
    CoTaskMemFree(programs);
    return p;
}

static bool RegisterStartShortcut(const std::wstring& aumid, std::wstring& detail)
{
    std::wstring lnk = LnkPath(aumid);
    if (lnk.empty()) { detail = L"SHGetKnownFolderPath(Programs) failed"; return false; }
    winrt::com_ptr<IShellLinkW> link;
    HRESULT hr = CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                  __uuidof(IShellLinkW), link.put_void());
    if (FAILED(hr)) { detail = L"CoCreateInstance(ShellLink) failed"; return false; }
    std::wstring exe = ExePath();
    link->SetPath(exe.c_str());
    link->SetArguments(L"");
    link->SetDescription(L"toastfire deterministic toast sender (test fixture)");
    winrt::com_ptr<IPropertyStore> store = link.as<IPropertyStore>();
    PROPVARIANT pv;
    PropVariantInit(&pv);
    pv.vt = VT_LPWSTR;
    size_t bytes = (aumid.size() + 1) * sizeof(wchar_t);
    pv.pwszVal = (PWSTR)CoTaskMemAlloc(bytes);
    if (!pv.pwszVal) { detail = L"CoTaskMemAlloc failed"; return false; }
    memcpy(pv.pwszVal, aumid.c_str(), bytes);
    hr = store->SetValue(PKEY_AppUserModel_ID, pv);
    PropVariantClear(&pv);
    if (FAILED(hr)) { detail = L"SetValue(PKEY_AppUserModel_ID) failed"; return false; }
    if (FAILED(store->Commit())) { detail = L"IPropertyStore::Commit failed"; return false; }
    winrt::com_ptr<IPersistFile> pf = link.as<IPersistFile>();
    hr = pf->Save(lnk.c_str(), TRUE);        // overwrites an existing .lnk: idempotent
    if (FAILED(hr)) { detail = L"IPersistFile::Save failed"; return false; }
    detail = L"lnk=" + lnk;
    return true;
}

static bool UnregisterStartShortcut(const std::wstring& aumid, std::wstring& detail)
{
    std::wstring lnk = LnkPath(aumid);
    if (lnk.empty()) { detail = L"SHGetKnownFolderPath(Programs) failed"; return false; }
    if (!DeleteFileW(lnk.c_str()))
    {
        DWORD e = GetLastError();
        if (e != ERROR_FILE_NOT_FOUND && e != ERROR_PATH_NOT_FOUND)
        { detail = L"DeleteFile failed err=" + std::to_wstring(e); return false; }
        detail = L"lnk=" + lnk + L" (already absent)";
        return true;                          // idempotent
    }
    detail = L"lnk=" + lnk + L" (removed)";
    return true;
}

static bool SetRegSz(const std::wstring& key, const wchar_t* name, const std::wstring& val,
                     std::wstring& detail)
{
    HKEY h;
    LSTATUS st = RegCreateKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, nullptr, 0,
                                 KEY_SET_VALUE, nullptr, &h, nullptr);
    if (st != ERROR_SUCCESS)
    { detail = L"RegCreateKeyEx(" + key + L") err=" + std::to_wstring(st); return false; }
    st = RegSetValueExW(h, name, 0, REG_SZ, (const BYTE*)val.c_str(),
                        (DWORD)((val.size() + 1) * sizeof(wchar_t)));
    RegCloseKey(h);
    if (st != ERROR_SUCCESS)
    { detail = L"RegSetValueEx(" + key + L") err=" + std::to_wstring(st); return false; }
    return true;
}

static bool DeleteRegTree(const std::wstring& key, std::wstring& detail)
{
    LSTATUS st = RegDeleteTreeW(HKEY_CURRENT_USER, key.c_str());
    if (st != ERROR_SUCCESS && st != ERROR_FILE_NOT_FOUND && st != ERROR_PATH_NOT_FOUND)
    { detail = L"RegDeleteTree(" + key + L") err=" + std::to_wstring(st); return false; }
    return true;                              // absent = already clean = idempotent success
}

static bool RegisterComActivator(const std::wstring& aumid, std::wstring& detail)
{
    if (aumid.find(L'\\') != std::wstring::npos)
    { detail = L"AUMID contains '\\' - would nest registry keys; refused for com-activator"; return false; }
    std::wstring clsid = DeriveClsid(aumid);
    std::wstring appKey  = L"Software\\Classes\\AppUserModelId\\" + aumid;
    std::wstring srvKey  = L"Software\\Classes\\CLSID\\" + clsid + L"\\LocalServer32";
    if (!SetRegSz(appKey, L"DisplayName", L"toastfire", detail)) return false;
    if (!SetRegSz(appKey, L"CustomActivator", clsid, detail)) return false;
    if (!SetRegSz(srvKey, nullptr, L"\"" + ExePath() + L"\" --com-activated", detail)) return false;
    detail = L"clsid=" + clsid + L" key=HKCU\\" + appKey;
    return true;
}

static bool UnregisterComActivator(const std::wstring& aumid, std::wstring& detail)
{
    if (aumid.find(L'\\') != std::wstring::npos)
    { detail = L"AUMID contains '\\' - refused for com-activator"; return false; }
    std::wstring clsid = DeriveClsid(aumid);
    if (!DeleteRegTree(L"Software\\Classes\\AppUserModelId\\" + aumid, detail)) return false;
    if (!DeleteRegTree(L"Software\\Classes\\CLSID\\" + clsid, detail)) return false;
    detail = L"clsid=" + clsid + L" (both trees removed or already absent)";
    return true;
}

// ---------------------------------------------------------------- firing

static bool FireOne(const std::wstring& aumid, const std::wstring& xml,
                    const std::wstring& tag, const std::wstring& group, std::wstring& detail)
{
    try
    {
        winrt::Windows::Data::Xml::Dom::XmlDocument doc;
        doc.LoadXml(winrt::hstring(xml));
        winrt::Windows::UI::Notifications::ToastNotification n(doc);
        n.Tag(winrt::hstring(tag));
        n.Group(winrt::hstring(group));
        winrt::Windows::UI::Notifications::ToastNotificationManager
            ::CreateToastNotifier(winrt::hstring(aumid)).Show(n);
        return true;
    }
    catch (winrt::hresult_error const& e)
    {
        wchar_t buf[16];
        swprintf(buf, 16, L"0x%08X", (uint32_t)e.code().value);
        detail = std::wstring(L"hr=") + buf + L" msg=" + std::wstring(e.message());
        return false;
    }
}

// ---------------------------------------------------------------- CLI

static void Usage()
{
    Line(L"toastfire - deterministic synthetic unpackaged toast sender (toast-bridge test fixture)");
    Line(L"  toastfire --register   --method start-shortcut|com-activator|bare [--aumid A]");
    Line(L"  toastfire --unregister --method start-shortcut|com-activator|bare [--aumid A]");
    Line(L"  toastfire --fire [--method M] [--aumid A] [--class informational|realchoice|persistent|long]");
    Line(L"            [--title S] [--body S] [--tag S] [--group S] [--count N] [--interval-ms M]");
    Line(L"  toastfire --print-xml [--class C] [--title S] [--body S]   (offline: payload + sha, no fire)");
    Line(L"defaults: class=informational title='demo toast' body='demo body' tag=toastfire group=toastfire");
    Line(L"          count=1 interval-ms=250; per-method default AUMIDs:");
    Line(L"          start-shortcut=QubesToastfire.StartShortcut com-activator=QubesToastfire.ComActivator");
    Line(L"          bare=QubesToastfire.Bare");
    Line(L"determinism: identical args => byte-identical payload; FIRED prints payload_sha256;");
    Line(L"          tags are caller-controlled (same aumid+tag+group REPLACES, never a new toast);");
    Line(L"          burst tags derive as <tag>-<index>.");
}

int wmain(int argc, wchar_t** argv)
{
    // COM local-server activation (a click on a com-activator toast, or manual). We are a
    // registration fixture, not a real activator: acknowledge and exit clean.
    for (int i = 1; i < argc; i++)
        if (wcscmp(argv[i], L"-Embedding") == 0 || wcscmp(argv[i], L"/Embedding") == 0 ||
            wcscmp(argv[i], L"--com-activated") == 0)
        { Line(L"COM-ACTIVATED (toastfire is a registration fixture; no activator implemented)"); return 0; }

    std::wstring mode, method = L"start-shortcut", aumid, cls = L"informational";
    std::wstring title = L"demo toast", body = L"demo body", tag = L"toastfire", group = L"toastfire";
    long count = 1, intervalMs = 250;

    auto need = [&](int& i) -> const wchar_t* {
        if (i + 1 >= argc) { Line(std::wstring(L"ERROR missing value for ") + argv[i]); exit(1); }
        return argv[++i];
    };
    for (int i = 1; i < argc; i++)
    {
        std::wstring a = argv[i];
        if (a == L"--register" || a == L"--unregister" || a == L"--fire" || a == L"--print-xml")
        {
            if (!mode.empty()) { Line(L"ERROR more than one mode given"); return 1; }
            mode = a.substr(2);
        }
        else if (a == L"--method")      method = need(i);
        else if (a == L"--aumid")       aumid  = need(i);
        else if (a == L"--class")       cls    = need(i);
        else if (a == L"--title")       title  = need(i);
        else if (a == L"--body")        body   = need(i);
        else if (a == L"--tag")         tag    = need(i);
        else if (a == L"--group")       group  = need(i);
        else if (a == L"--count")       count      = wcstol(need(i), nullptr, 10);
        else if (a == L"--interval-ms") intervalMs = wcstol(need(i), nullptr, 10);
        else if (a == L"--help" || a == L"-h" || a == L"/?") { Usage(); return 0; }
        else { Line(L"ERROR unknown argument: " + a); Usage(); return 1; }
    }
    if (mode.empty()) { Usage(); return 1; }

    // validate method + per-method deterministic default AUMID
    if (method == L"start-shortcut")      { if (aumid.empty()) aumid = L"QubesToastfire.StartShortcut"; }
    else if (method == L"com-activator")  { if (aumid.empty()) aumid = L"QubesToastfire.ComActivator"; }
    else if (method == L"bare")           { if (aumid.empty()) aumid = L"QubesToastfire.Bare"; }
    else { Line(L"ERROR unknown --method: " + method); return 1; }

    const ToastSpec* spec = nullptr;
    for (auto const& s : kClasses) if (cls == s.cls) { spec = &s; break; }
    if (!spec) { Line(L"ERROR unknown --class: " + cls); return 1; }

    if (count < 1 || count > 1000) { Line(L"ERROR --count out of range 1..1000"); return 1; }
    if (intervalMs < 0 || intervalMs > 60000) { Line(L"ERROR --interval-ms out of range 0..60000"); return 1; }
    // Windows caps Tag/Group at 64 chars (16 pre-1903). Fail loudly, never truncate silently.
    if (tag.empty() || group.empty()) { Line(L"ERROR --tag/--group must be non-empty"); return 1; }
    if (group.size() > 64) { Line(L"ERROR --group exceeds 64 chars"); return 1; }
    {
        std::wstring worst = (count > 1) ? tag + L"-" + std::to_wstring(count - 1) : tag;
        if (worst.size() > 64) { Line(L"ERROR --tag (with burst suffix) exceeds 64 chars"); return 1; }
    }

    // payload + self-check through the REAL classifier: intended row must match, always.
    std::wstring xml = BuildPayload(cls, title, body);
    ToastClass verdict = ClassifyToastXml(xml);
    if (verdict.row != spec->expectRow || (int)verdict.route != spec->expectRoute)
    {
        Line(L"ERROR self-check failed: class=" + cls +
             L" expected row=" + std::to_wstring(spec->expectRow) +
             L" got row=" + std::to_wstring(verdict.row) +
             L" route=" + std::wstring(ToastRouteName(verdict.route)) +
             L" (payload drifted from tools/notifhost/toastclassify.h)");
        return 2;
    }
    std::wstring sha = PayloadSha256(xml);

    if (mode == L"print-xml")
    {
        Line(xml);
        Line(L"PAYLOAD class=" + cls + L" route=" + ToastRouteName(verdict.route) +
             L" row=" + std::to_wstring(verdict.row) + L" payload_sha256=" + sha);
        return 0;
    }

    winrt::init_apartment(winrt::apartment_type::single_threaded);

    if (mode == L"register" || mode == L"unregister")
    {
        bool reg = (mode == L"register");
        bool ok = true;
        std::wstring detail;
        try
        {
            if (method == L"start-shortcut")
                ok = reg ? RegisterStartShortcut(aumid, detail) : UnregisterStartShortcut(aumid, detail);
            else if (method == L"com-activator")
                ok = reg ? RegisterComActivator(aumid, detail) : UnregisterComActivator(aumid, detail);
            else
                detail = L"(bare: no registration by design)";
        }
        catch (winrt::hresult_error const& e)
        {
            ok = false;
            wchar_t buf[16];
            swprintf(buf, 16, L"0x%08X", (uint32_t)e.code().value);
            detail = std::wstring(L"hr=") + buf + L" msg=" + std::wstring(e.message());
        }
        if (!ok) { Line(L"ERROR " + mode + L" method=" + method + L" aumid=" + aumid + L" " + detail); return 2; }
        Line((reg ? L"REGISTERED method=" : L"UNREGISTERED method=") + method +
             L" aumid=" + aumid + L" " + detail);
        return 0;
    }

    // --fire (single or deterministic burst; the PAYLOAD is identical for every toast in a
    // burst - only the Tag varies, and Tag is a notification property, not payload XML)
    for (long i = 0; i < count; i++)
    {
        std::wstring t = (count > 1) ? tag + L"-" + std::to_wstring(i) : tag;
        std::wstring detail;
        if (!FireOne(aumid, xml, t, group, detail))
        {
            Line(L"ERROR fire method=" + method + L" aumid=" + aumid + L" class=" + cls +
                 L" tag=" + t + L" " + detail);
            return 2;
        }
        Line(L"FIRED method=" + method + L" aumid=" + aumid + L" class=" + cls +
             L" tag=" + t + L" group=" + group +
             L" row=" + std::to_wstring(verdict.row) + L" payload_sha256=" + sha);
        if (i + 1 < count && intervalMs > 0) Sleep((DWORD)intervalMs);
    }
    return 0;
}
