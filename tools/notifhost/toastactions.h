// toastactions.h - PURE rules of the ACTIONABLE-BUTTONS route (docs/ADR-toasts.md 11): a forwarded
// toast's buttons and its default click travel to dom0 as freedesktop actions, and a dom0 click comes
// back as the proxy's ActionInvoked{id, action} and is carried out in the guest the way Windows would
// have carried it out.
//
// Layered on toastclassify.h, which stays the decision table over the XML ALONE (rows 1-6, fail-open).
// What that table cannot know is whether a button's activation can be reproduced from outside the
// shell, which depends on the SENDER (packaged or not, a registered toast activator or not) as much as
// on the XML. This header adds exactly that: given the classifier's row and the sender facts, it builds
// the action list the bridge sends, or refuses so the toast takes the window path.
//
// SCOPE (Jev 2026-10-02, 1.00; fixed by the owner's queueing of the enhancement): carried are
//   * PROTOCOL activations - `activationType="protocol"` with a URI in `arguments` (a button) or in
//     `launch` (the default click): the shell launches the URI, so does the bridge (ShellExecute as
//     the user);
//   * Win32 COM-ACTIVATOR foreground activations - `activationType="foreground"` (the schema default)
//     on an UNPACKAGED sender that registered a toast activator (HKCR\AppUserModelId\<AUMID>
//     CustomActivator, or a Start-menu shortcut carrying System.AppUserModel.ToastActivatorCLSID next
//     to the AUMID): the shell CoCreates that CLSID and calls
//     INotificationActivationCallback::Activate(aumid, arguments, inputs, count); so does the bridge.
// Everything else keeps the guest-window path exactly as before: packaged (UWP) foreground or
// background activation (a UWP activation is not a COM call anyone else can make), background
// activation of any sender, system actions other than dismiss (snooze is shell-internal), any <input>
// (rows 1-2), time-critical scenarios (row 3), anything unrecognised.
//
// THE OWNER'S RULES: no doubles, nothing lost; a toast with buttons that cannot be carried is NOT
// forwarded half-way - it takes the window path, where its buttons work (rule 4 of the hold, ADR §10).
// So the plan is all-or-nothing over the BANNER buttons (contextMenu actions are invisible on the
// banner and never carried); the default click is an enrichment - when it cannot be carried the toast
// is still forwarded, without a "default" action, which is what shipped since 4.3.30 (the deep link
// "only enriches the default click", DESIGN-toast-bridge.md 2.2) - and the reason is logged.
//
// CAPABILITY (Jev 2026-10-06, 0.76): the guest cannot learn whether dom0's daemon renders actions, so an
// in-scope toast is forwarded WITH its actions regardless (the stock Linux client advertises actions
// unconditionally too); the SENT line says what went.
//
// ACTIVATION FAILURE (Jev 2026-10-06, 0.71): when the click's activation fails in the guest, the toast's
// hold record turns `window` (the agent reopens the banner if it is still displayed - rule 4 of ADR §10 -
// and marks the record TH_AGENT_SHOWN); no mark within the bound means the banner had gone, and the user
// is told through a dom0 ERROR notice (stays until dismissed) that the action did not run. Both loud.
//
// Keys are BRIDGE-GENERATED ("default", "b0".."b4"), never taken from the toast: the proxy refuses a
// whole notification over one invalid action name (is_valid_action_name: an ASCII letter first, then
// letters, digits, '-', '.', '_', ':'; 1..255 bytes), and `arguments` is the app's own opaque string.
// Labels are the buttons' `content`; dom0 sanitizes them like every other guest text.
//
// Pure C++17, no Windows headers (the activator lookup and the activation itself are in notifhost.cpp
// behind the ToastActivator interface below); compiles with g++ for toastactions_test.cpp.
//
// BOUNDS (review 2026-10-07, two rounds): a click is carried out by a short-lived child process and reaches a
// defined outcome within kToastActClickBoundMs - the child's exit, or its termination at the bound
// (ToastActClickLedger: the admission cap and exactly one outcome per click; ToastActChildDecide: reap, kill
// or keep, per pass); the sender's activator lookup is answered within kToastActLookupBoundMs or treated as
// "none, this time" (ToastActLookupHandoff).
//
// ==== defect-reintroduction switches (proof the suite can FAIL) ============================
//   TOASTACT_DEFECT_BACKGROUND_CARRIED  background activations treated as carriable (out of scope by decision)
//   TOASTACT_DEFECT_PARTIAL_FORWARD     a row-4 toast with an uncarriable button forwards the carriable subset
//                                       (the owner's "never half-way")
//   TOASTACT_DEFECT_PACKAGED_COM        a packaged sender's foreground activation is treated as a COM activator's
//   TOASTACT_DEFECT_BADKEY              generated keys start with a digit (the proxy refuses the notification)
//   TOASTACT_DEFECT_NONOTICE            a failed click whose banner is gone is never reported to dom0 (silent loss)
//   TOASTACT_DEFECT_UNBOUNDED_TABLE     the per-notification table never evicts
//   TOASTACT_DEFECT_KEY_BY_SEQ          the table is looked up by the bridge's own sequence instead of the proxy's
//                                       id (the id space ActionInvoked and Dismissed carry): a click lands on the
//                                       wrong toast or on none
//   TOASTACT_DEFECT_NOCLICKBOUND        a click whose child never exits is never resolved: no outcome, and the
//                                       in-flight cap stays taken for good
//   TOASTACT_DEFECT_NOKILL              the bound reports the failure but leaves the hung child process alive
//                                       (the leak the round-2 review named)
//   TOASTACT_DEFECT_DOUBLE_OUTCOME      a click already reported (the bound killed its child) gets a second
//                                       outcome (two notices, or a success after a failure)
//   TOASTACT_DEFECT_NOLOOKUPBOUND       the asking thread waits for the activator lookup without a bound
//   TOASTACT_DEFECT_AWAIT_FOR_INFO      an informational toast's route waits for the activator lookup (the 2026-10-07
//                                       guest-test regression: a cold lookup pushed the verdict past the listing's budget)
//   TOASTACT_DEFECT_UNKNOWN_REFUSES     an informational toast with the lookup pending is refused (window) instead of
//                                       forwarded without its default click
//   TOASTACT_DEFECT_UNKNOWN_AS_KNOWN    a pending lookup is treated as a registered activator (COM buttons forwarded
//                                       with no CLSID to call)
//   TOASTACT_DEFECT_LATE_RESULT_DROPPED a lookup result nobody waited for is not cached (the next toast asks again)
//   TOASTACT_DEFECT_ALLOWLIST_BLIND     the allowlist shortcut forwards a toast without its plan whatever the classifier
//                                       said (guest finding 2026-10-07: a row-4 toast from an allowlisted sender went to
//                                       dom0 WITHOUT its buttons while the hold suppressed its banner - the choice lost)
#pragma once
#include "toastclassify.h"
#include <chrono>
#include <condition_variable>
#include <cstdint>
#include <memory>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

#if (defined(TOASTACT_DEFECT_BACKGROUND_CARRIED) + defined(TOASTACT_DEFECT_PARTIAL_FORWARD) + \
     defined(TOASTACT_DEFECT_PACKAGED_COM) + defined(TOASTACT_DEFECT_BADKEY) + \
     defined(TOASTACT_DEFECT_NONOTICE) + defined(TOASTACT_DEFECT_UNBOUNDED_TABLE) + \
     defined(TOASTACT_DEFECT_KEY_BY_SEQ) + defined(TOASTACT_DEFECT_NOCLICKBOUND) + \
     defined(TOASTACT_DEFECT_DOUBLE_OUTCOME) + defined(TOASTACT_DEFECT_NOLOOKUPBOUND) + \
     defined(TOASTACT_DEFECT_NOKILL) + defined(TOASTACT_DEFECT_AWAIT_FOR_INFO) + \
     defined(TOASTACT_DEFECT_UNKNOWN_REFUSES) + defined(TOASTACT_DEFECT_UNKNOWN_AS_KNOWN) + \
     defined(TOASTACT_DEFECT_LATE_RESULT_DROPPED) + defined(TOASTACT_DEFECT_ALLOWLIST_BLIND)) > 1
#error define at most one TOASTACT_DEFECT_* switch
#endif

enum class ToastActKind { Protocol = 1, Com = 2 };

struct ToastAct
{
    std::string  key;      // "default" or "bN" - the freedesktop action key the click comes back with
    std::wstring label;    // the button's content (the default click's label is a fixed "Open")
    ToastActKind kind;
    std::wstring arg;      // Protocol: the URI; Com: the `arguments` string Activate() receives (may be empty)
};

struct ToastActPlan
{
    bool ok = false;                        // the toast may be forwarded, with `actions` (possibly none)
    const wchar_t* refusal = nullptr;       // static: why not (the toast takes the window path)
    bool hasDefault = false;                // actions[0] is the "default" (body click)
    const wchar_t* defaultNote = nullptr;   // static: why the default click was NOT carried (nullptr = carried, or none declared)
    unsigned buttons = 0;                   // banner buttons carried (not counting the default)
    std::vector<ToastAct> actions;
};

// The sender's toast activator as the caller KNOWS it when the plan is built - never something the builder
// waits for (guest-test regression 2026-10-07: a lookup awaited here pushed an informational toast's verdict
// past the listing's budget and it lost forwarding). Unknown = a lookup is pending or has not been started;
// the builder then carries nothing that depends on it and says so, and the caller decides whether THIS
// toast's route may wait for the result (ToastActRouteNeedsActivator) or not.
enum class ToastActActivator { Unknown = 0, None = 1, Known = 2 };

struct ToastActCtx
{
    bool packaged;                          // a packaged (PFN!App) sender: its foreground activation is UWP's, out of scope
    ToastActActivator activator;            // the cache's answer for the sender, as of now
};

// Does THIS toast's ROUTE depend on the sender's activator - i.e. may the caller wait (within the listing's
// budget) for a pending lookup before deciding? Only a row-4 toast with a foreground (COM) banner button on an
// unpackaged sender: without the activator it is the window path, with it the bridge. An informational toast
// (rows 5-6) never waits: its default click is an enrichment that the lookup's result enriches next time.
inline bool ToastActRouteNeedsActivator(const wchar_t* xml, size_t len, ToastClass const& k, bool packaged)
{
#ifdef TOASTACT_DEFECT_AWAIT_FOR_INFO
    if (k.row >= 4 && k.row <= 6 && !packaged) return true;   // DEFECT: every candidate waits for the lookup (the regression)
#endif
    if (k.row != 4 || packaged) return false;
    std::vector<tc::Elem> els;
    std::wstring root;
    if (!tc::Parse(xml, len, els, root) || !tc::IEq(root, L"toast")) return false;
    for (auto const& e : els)
    {
        if (!tc::IEq(e.name, L"action")) continue;
        const tc::Attr* pl = tc::FindAttr(e, L"placement");
        if (pl && pl->value == L"contextMenu") continue;
        const tc::Attr* at = tc::FindAttr(e, L"activationType");
        if (!at || tc::IEq(at->value, L"foreground")) return true;
    }
    return false;
}

// How long a toast whose route depends on a pending lookup may wait for it: inside the listing's own budget (its
// 3 verdict passes elapse within about 1.25 s on the push-retry pattern; the agent's hold fails open at 3 s).
// A lookup not done by then sends the toast to the window path (the user keeps the guest's buttons) and its
// late result still warms the cache for the sender's next toast.
constexpr uint64_t kToastActRouteLookupBudgetMs = 750;

namespace ta {

constexpr unsigned kMaxButtons = 5;         // the toast schema's own ceiling
constexpr size_t   kMaxLabelChars = 256;
constexpr size_t   kMaxUriChars = 2048;
constexpr size_t   kMaxArgChars = 4096;

// is_valid_action_name (qubes-notification-proxy lib.rs / server.rs), byte for byte.
inline bool KeyValid(std::string const& k)
{
    if (k.empty() || k.size() > 255) return false;
    unsigned char c0 = (unsigned char)k[0];
    if (!((c0 >= 'a' && c0 <= 'z') || (c0 >= 'A' && c0 <= 'Z'))) return false;
    for (size_t i = 1; i < k.size(); i++)
    {
        unsigned char c = (unsigned char)k[i];
        if (!((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') ||
              c == '-' || c == '.' || c == '_' || c == ':'))
            return false;
    }
    return true;
}

// A launchable URI: RFC 3986 scheme (a letter, then letters/digits/+/-/.) and a ':' followed by at least
// one more character, no whitespace or control characters anywhere, bounded. The shell would refuse the
// rest too; what it does with the scheme (which app answers it) stays Windows' business, as for any URI
// the user opens in the guest.
inline bool UriValid(std::wstring const& u)
{
    if (u.size() < 3 || u.size() > kMaxUriChars) return false;
    size_t i = 0;
    wchar_t c = u[0];
    if (!((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z'))) return false;
    for (i = 1; i < u.size(); i++)
    {
        c = u[i];
        if (c == L':') break;
        if (!((c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') || (c >= L'0' && c <= L'9') ||
              c == L'+' || c == L'-' || c == L'.'))
            return false;
    }
    if (i >= u.size() - 1) return false;        // no ':' or nothing after it
    for (wchar_t d : u)
        if (d <= 0x20 || d == 0x7F) return false;
    return true;
}

// UTF-16/UTF-32 -> UTF-8 for the wire (labels). Lone surrogates become U+FFFD, never a malformed byte.
inline std::string Utf8(std::wstring const& w)
{
    std::string o;
    o.reserve(w.size());
    for (size_t i = 0; i < w.size(); i++)
    {
        uint32_t cp = (uint32_t)w[i];
        if (sizeof(wchar_t) == 2 && cp >= 0xD800 && cp <= 0xDBFF && i + 1 < w.size() &&
            (uint32_t)w[i + 1] >= 0xDC00 && (uint32_t)w[i + 1] <= 0xDFFF)
        {
            cp = 0x10000 + ((cp - 0xD800) << 10) + ((uint32_t)w[i + 1] - 0xDC00);
            i++;
        }
        else if ((cp >= 0xD800 && cp <= 0xDFFF) || cp > 0x10FFFF)
            cp = 0xFFFD;
        if (cp < 0x80) o += (char)cp;
        else if (cp < 0x800) { o += (char)(0xC0 | (cp >> 6)); o += (char)(0x80 | (cp & 0x3F)); }
        else if (cp < 0x10000) { o += (char)(0xE0 | (cp >> 12)); o += (char)(0x80 | ((cp >> 6) & 0x3F)); o += (char)(0x80 | (cp & 0x3F)); }
        else { o += (char)(0xF0 | (cp >> 18)); o += (char)(0x80 | ((cp >> 12) & 0x3F)); o += (char)(0x80 | ((cp >> 6) & 0x3F)); o += (char)(0x80 | (cp & 0x3F)); }
    }
    return o;
}

inline std::string ButtonKey(unsigned n)
{
#ifdef TOASTACT_DEFECT_BADKEY
    return std::to_string(n);                   // DEFECT: "0", "1" - not an action name the proxy accepts
#else
    return "b" + std::to_string(n);
#endif
}

} // namespace ta

// ==== the plan ============================================================================

// Builds the action plan for ONE toast from its payload XML, the classifier's verdict over that XML and
// the sender facts. Only rows 4, 5 and 6 are candidates (rows 0-3 are the window path by content, and
// stay so); the result decides the toast's route: ok -> bridge (with plan.actions), !ok -> window.
inline ToastActPlan ToastActionsBuild(const wchar_t* xml, size_t len, ToastClass const& k, ToastActCtx const& ctx)
{
    ToastActPlan p;
    if (k.row < 4 || k.row > 6) { p.refusal = L"not an actions candidate (classifier rows 0-3 are the window path)"; return p; }
    std::vector<tc::Elem> els;
    std::wstring root;
    if (!tc::Parse(xml, len, els, root) || !tc::IEq(root, L"toast"))
    { p.refusal = L"payload unparseable for the action list (fail-open)"; return p; }

    // The activation a foreground (COM) request resolves to, or the static reason it cannot be carried. Unknown
    // (a lookup pending) carries nothing: for a button that refuses the toast (the caller waited within its
    // budget first, if the route depended on it); for the default click it only leaves the enrichment out.
    auto comAllowed = [&](const wchar_t** why) -> bool {
#ifdef TOASTACT_DEFECT_PACKAGED_COM
        (void)0;
#else
        if (ctx.packaged) { *why = L"packaged sender: a UWP foreground activation is not carried"; return false; }
#endif
        if (ctx.activator == ToastActActivator::None) { *why = L"the sender registered no toast activator (no CustomActivator, no ToastActivatorCLSID shortcut)"; return false; }
#ifdef TOASTACT_DEFECT_UNKNOWN_AS_KNOWN
        return true;   // DEFECT: a pending lookup treated as a registered activator (COM buttons forwarded without a CLSID)
#else
        if (ctx.activator == ToastActActivator::Unknown) { *why = L"the sender's toast activator is not known yet (lookup pending in the background; the next toast finds it cached)"; return false; }
        return true;
#endif
    };

    // ---- the default click: the toast element's own launch/activationType ----------------------
    {
        const tc::Attr* at = tc::FindAttr(els.front(), L"activationType");
        const tc::Attr* launch = tc::FindAttr(els.front(), L"launch");
        std::wstring arg = launch ? launch->value : L"";
        if (at && at->value == L"protocol")
        {
            if (ta::UriValid(arg)) p.actions.push_back({ "default", L"Open", ToastActKind::Protocol, arg });
            else p.defaultNote = L"protocol default click without a launchable URI";
        }
        else if (!at || tc::IEq(at->value, L"foreground"))
        {
            const wchar_t* why = nullptr;
            if (arg.size() > ta::kMaxArgChars) p.defaultNote = L"default click arguments too long";
            else if (comAllowed(&why)) p.actions.push_back({ "default", L"Open", ToastActKind::Com, arg });
            else
            {
                p.defaultNote = why;
#ifdef TOASTACT_DEFECT_UNKNOWN_REFUSES
                // DEFECT (the 2026-10-07 regression's shape): an informational toast whose sender's activator is not
                // known yet is REFUSED instead of forwarded without its default click
                if (!ctx.packaged && ctx.activator == ToastActActivator::Unknown) { p.refusal = why; p.actions.clear(); return p; }
#endif
            }
        }
        else if (tc::IEq(at->value, L"background"))
            p.defaultNote = L"background default click is not carried";
        else
            p.defaultNote = L"unrecognized toast activationType for the default click";
        p.hasDefault = !p.actions.empty();
    }

    // ---- the banner buttons: all or nothing ----------------------------------------------------
    unsigned n = 0;
    for (auto const& e : els)
    {
        if (!tc::IEq(e.name, L"action")) continue;
        const tc::Attr* pl = tc::FindAttr(e, L"placement");
        if (pl && pl->value == L"contextMenu") continue;              // invisible on the banner (classifier's exemption)
        const tc::Attr* at = tc::FindAttr(e, L"activationType");
        const tc::Attr* ar = tc::FindAttr(e, L"arguments");
        const tc::Attr* content = tc::FindAttr(e, L"content");
        std::wstring arg = ar ? ar->value : L"";
        if (at && at->value == L"system" && ar && ar->value == L"dismiss") continue;   // dom0's own close is this button
        const wchar_t* refusal = nullptr;
        ToastActKind kind = ToastActKind::Protocol;
        if (at && at->value == L"protocol")
        {
            if (!ta::UriValid(arg)) refusal = L"protocol button without a launchable URI";
        }
        else if (!at || tc::IEq(at->value, L"foreground"))
        {
            kind = ToastActKind::Com;
            if (arg.size() > ta::kMaxArgChars) refusal = L"button arguments too long";
            else { const wchar_t* why = nullptr; if (!comAllowed(&why)) refusal = why; }
        }
        else if (tc::IEq(at->value, L"background"))
        {
#ifdef TOASTACT_DEFECT_BACKGROUND_CARRIED
            kind = ToastActKind::Com;
            { const wchar_t* why = nullptr; if (!comAllowed(&why)) refusal = why; }
#else
            refusal = L"background button activation is not carried";
#endif
        }
        else
            refusal = L"unrecognized button activationType";
        if (!refusal && (!content || content->value.empty())) refusal = L"button without a label";
        if (!refusal && content->value.size() > ta::kMaxLabelChars) refusal = L"button label too long";
        if (!refusal && n >= ta::kMaxButtons) refusal = L"more banner buttons than the toast schema allows";
        if (refusal)
        {
#ifdef TOASTACT_DEFECT_PARTIAL_FORWARD
            (void)refusal;   // DEFECT: the uncarriable button is silently dropped, the rest forwards
            continue;
#else
            p.ok = false;
            p.refusal = refusal;
            p.actions.clear();
            p.hasDefault = false;
            p.buttons = 0;
            return p;
#endif
        }
        p.actions.push_back({ ta::ButtonKey(n), content->value, kind, arg });
        n++;
    }
    p.buttons = n;
#ifndef TOASTACT_DEFECT_BADKEY
    for (auto const& a : p.actions)
        if (!ta::KeyValid(a.key)) { p.ok = false; p.refusal = L"generated action key invalid (a bug of ours)"; p.actions.clear(); p.hasDefault = false; p.buttons = 0; return p; }
#endif
    p.ok = true;
    return p;
}

// The wire list: Vec<String> as alternating key, label (bincode: u64 count of strings, each u64 length +
// UTF-8 bytes). The proxy validates every key and sanitizes every label.
inline std::vector<std::string> ToastActFlatten(ToastActPlan const& p)
{
    std::vector<std::string> flat;
    for (auto const& a : p.actions) { flat.push_back(a.key); flat.push_back(ta::Utf8(a.label)); }
    return flat;
}

inline void ToastActPutVec(std::vector<unsigned char>& m, std::vector<std::string> const& flat)
{
    auto put64 = [&](uint64_t x) { for (int i = 0; i < 8; i++) m.push_back((unsigned char)(x >> (8 * i))); };
    put64((uint64_t)flat.size());
    for (auto const& s : flat) { put64((uint64_t)s.size()); m.insert(m.end(), s.begin(), s.end()); }
}

// Grep-safe summary for the CLASSIFY / SENT lines: "default:com,b0:protocol,b1:com", "none", or
// "refused:<reason-slug>".
inline std::wstring ToastActSlug(ToastActPlan const& p)
{
    if (!p.ok)
    {
        std::wstring s = L"refused:";
        bool dash = false;
        for (const wchar_t* q = p.refusal; q && *q; q++)
        {
            wchar_t c = *q;
            if (c >= L'A' && c <= L'Z') c = (wchar_t)(c + 32);
            if ((c >= L'a' && c <= L'z') || (c >= L'0' && c <= L'9')) { s += c; dash = false; }
            else if (!dash && s.back() != L':') { s += L'-'; dash = true; }
        }
        while (!s.empty() && s.back() == L'-') s.pop_back();
        return s;
    }
    if (p.actions.empty()) return L"none";
    std::wstring s;
    for (auto const& a : p.actions)
    {
        if (!s.empty()) s += L',';
        for (char c : a.key) s += (wchar_t)c;
        s += (a.kind == ToastActKind::Protocol) ? L":protocol" : L":com";
    }
    return s;
}

// ==== the per-notification table (bounded) ================================================

struct ToastActEntry
{
    uint64_t     seq = 0;         // the forward's sequence (Message.id)
    uint32_t     guestId = 0;     // the guest notification id (the hold record it corrects)
    uint32_t     dom0Id = 0;      // the proxy's id for it (ActionInvoked/Dismissed carry this)
    std::wstring aumid, app, title;
    std::wstring clsid;           // the resolved toast activator, "{...}", when any action is Com
    ToastActPlan plan;
    uint64_t     born = 0;
    uint64_t     dismissedAt = 0; // dom0 closed it (user/CloseNotification): kept kDismissGraceMs for a late ActionInvoked
};

// Entries live until dom0 dismisses the notification (plus a grace for the daemon's ActionInvoked arriving
// after its NotificationClosed - two signals, two relay tasks), until the TTL (a daemon that keeps
// notifications in a list - GNOME - can invoke an action long after the banner), or until the table is
// full (oldest out, counted so the caller logs it). Cleared when the connection drops: dom0 ids are
// per connection, exactly like the dismissal correlation table.
//
// THE ID SPACES (review 2026-10-07): an entry is put BEFORE its frame is sent, keyed by the bridge's own
// sequence (Message.id), with no dom0 id yet; the proxy's Id{id, sequence} reply - which the reader
// processes before any Dismissed/ActionInvoked for that notification can exist - sets the dom0 id
// (SetDom0Id). Lookups for a click are by THAT id (FindDom0): the proxy allocates it, and uses it in
// Dismissed and ActionInvoked alike (notification-proxy-client.rs: next_id / remove_host_id /
// translate_host_id); the bridge's sequence and the Windows notification id are other spaces and never
// looked up by. A dom0 id of 0 is "not yet known" and matches nothing.
class ToastActTable
{
public:
    static constexpr size_t   kMax = 64;
    static constexpr uint64_t kTtlMs = 60ull * 60ull * 1000ull;
    static constexpr uint64_t kDismissGraceMs = 5000;

    size_t Put(ToastActEntry&& e, uint64_t now)
    {
        size_t evicted = Expire(now);
        e.born = now;
#ifndef TOASTACT_DEFECT_UNBOUNDED_TABLE
        while (e_.size() >= kMax) { e_.erase(e_.begin()); evicted++; }
#endif
        e_.push_back(std::move(e));
        return evicted;
    }
    const ToastActEntry* FindDom0(uint32_t dom0Id) const
    {
        if (dom0Id == 0) return nullptr;
#ifdef TOASTACT_DEFECT_KEY_BY_SEQ
        for (auto const& x : e_) if (x.seq == dom0Id) return &x;   // DEFECT: the wrong id space
#else
        for (auto const& x : e_) if (x.dom0Id == dom0Id) return &x;
#endif
        return nullptr;
    }
    bool SetDom0Id(uint64_t seq, uint32_t dom0Id)
    {
        for (auto& x : e_) if (x.seq == seq) { x.dom0Id = dom0Id; return true; }
        return false;
    }
    bool RemoveSeq(uint64_t seq)   // a forward that was not acknowledged: nothing to click on
    {
        for (size_t i = 0; i < e_.size(); i++) if (e_[i].seq == seq) { e_.erase(e_.begin() + (long)i); return true; }
        return false;
    }
    bool Dismiss(uint32_t dom0Id, uint64_t now)
    {
        for (auto& x : e_) if (x.dom0Id == dom0Id && dom0Id != 0) { if (!x.dismissedAt) x.dismissedAt = now; return true; }
        return false;
    }
    size_t Expire(uint64_t now)
    {
        size_t n = 0;
#ifdef TOASTACT_DEFECT_UNBOUNDED_TABLE
        (void)now;
#else
        for (size_t i = 0; i < e_.size(); )
        {
            bool dead = (now - e_[i].born >= kTtlMs) ||
                        (e_[i].dismissedAt != 0 && now - e_[i].dismissedAt >= kDismissGraceMs);
            if (dead) { e_.erase(e_.begin() + (long)i); n++; } else i++;
        }
#endif
        return n;
    }
    void Clear() { e_.clear(); }
    size_t Size() const { return e_.size(); }
private:
    std::vector<ToastActEntry> e_;
};

// ==== the click: ActionInvoked -> the activation ==========================================

// ReplyMessage::ActionInvoked { id: u32, action: String } after its u32 variant tag (4). `p` points at
// the tag, `len` is the frame length. False = malformed (logged by the caller, never acted on).
inline bool ToastActParseInvoked(const unsigned char* p, uint32_t len, uint32_t& id, std::string& key)
{
    auto u32 = [&](const unsigned char* b) { return (uint32_t)b[0] | ((uint32_t)b[1] << 8) | ((uint32_t)b[2] << 16) | ((uint32_t)b[3] << 24); };
    if (!p || len < 16) return false;
    if (u32(p) != 4) return false;
    id = u32(p + 4);
    uint64_t n = (uint64_t)u32(p + 8) | ((uint64_t)u32(p + 12) << 32);
    if (n > 255 || 16 + n != (uint64_t)len) return false;
    key.assign((const char*)p + 16, (size_t)n);
    return ta::KeyValid(key);
}

// The Windows side implements this (notifhost.cpp); the suite drives a recording fake.
struct ToastActivator
{
    virtual bool Protocol(std::wstring const& uri, std::wstring& detail) = 0;
    virtual bool Com(std::wstring const& clsid, std::wstring const& aumid, std::wstring const& args, std::wstring& detail) = 0;
    virtual ~ToastActivator() {}
};

enum class ToastActResult { Done = 0, UnknownKey = 1, Failed = 2 };

inline ToastActResult ToastActDispatch(ToastActEntry const& e, std::string const& key, ToastActivator& act,
                                       const ToastAct** which, std::wstring& detail)
{
    *which = nullptr;
    for (auto const& a : e.plan.actions)
    {
        if (a.key != key) continue;
        *which = &a;
        bool ok = (a.kind == ToastActKind::Protocol) ? act.Protocol(a.arg, detail)
                                                     : act.Com(e.clsid, e.aumid, a.arg, detail);
        return ok ? ToastActResult::Done : ToastActResult::Failed;
    }
    return ToastActResult::UnknownKey;
}

// ==== clicks in flight: admission, the bound, exactly one outcome ============================
// Each admitted click is carried out by a SHORT-LIVED CHILD PROCESS of the bridge (`notifhost --act-exec`,
// same user and session), never by a thread of the bridge (review 2026-10-07, round 2): an activation that
// never answers - a local server that does not come up or does not return from Activate, a ShellExecute
// handler that hangs - then leaves a PROCESS the main loop terminates at the bound, not a thread the bridge
// would carry for ever and could not cancel. The ledger admits at most kToastActInflightMax unresolved
// clicks (a refused click is a failure the user is told about, never silence) and gives each click exactly
// one outcome: the child's exit code when it exits within the bound, the decision-3 failure when the bound
// passes first - and the child is killed in that same step (ToastActChildDecide: Kill, never FailLeave).
constexpr uint64_t kToastActClickBoundMs = 30000;   // a heavy app may take 10-20 s to come up for its activator
constexpr unsigned kToastActInflightMax = 4;        // children at once (human-rate clicks)

class ToastActClickLedger
{
public:
    struct Entry { uint64_t token; uint64_t admittedAt; };

    bool Admit(uint64_t token, uint64_t now, const wchar_t** why)
    {
        if (Inflight() >= kToastActInflightMax) { *why = L"too many clicks in flight (an activation is not answering)"; return false; }
        e_.push_back({ token, now });
        return true;
    }
    // The click's outcome is being taken (the child exited, or the bound passed and the child was killed): true =
    // this call owns it, the first and only time; false = taken already, nothing more may be reported.
    bool Done(uint64_t token)
    {
        for (size_t i = 0; i < e_.size(); i++)
        {
            if (e_[i].token != token) continue;
            e_.erase(e_.begin() + (long)i);
            return true;
        }
#ifdef TOASTACT_DEFECT_DOUBLE_OUTCOME
        return true;   // DEFECT: a second outcome for a click already reported
#else
        return false;
#endif
    }
    size_t Inflight() const { return e_.size(); }
    size_t Size() const { return e_.size(); }
private:
    std::vector<Entry> e_;
};

// What the main loop does with ONE child this pass: reap it (exited: its exit code is the outcome), kill it (the
// bound passed first: the decision-3 failure, exactly once), or keep waiting (the wait array carries its handle,
// the deadline machinery its bound). FailLeave exists only as the defect: reporting the failure while leaving
// the hung child alive - the leak the round-2 review named.
enum class ToastActChildStep { Keep = 0, Reap = 1, Kill = 2, FailLeave = 3 };

inline ToastActChildStep ToastActChildDecide(bool exited, uint64_t now, uint64_t startedAt)
{
    if (exited) return ToastActChildStep::Reap;
#ifdef TOASTACT_DEFECT_NOCLICKBOUND
    (void)now; (void)startedAt;
    return ToastActChildStep::Keep;              // DEFECT: no bound - a hung child is waited for for ever
#else
    if (now - startedAt < kToastActClickBoundMs) return ToastActChildStep::Keep;
#ifdef TOASTACT_DEFECT_NOKILL
    return ToastActChildStep::FailLeave;         // DEFECT: the outcome is reported, the child is left alive
#else
    return ToastActChildStep::Kill;
#endif
#endif
}

// The child's exit code -> the click's outcome. The child's own ACTEXEC line in the bridge log carries the HRESULT.
constexpr unsigned long kToastActExitOk = 0;
constexpr unsigned long kToastActExitFailed = 2;
constexpr unsigned long kToastActExitBadInput = 3;

inline ToastActResult ToastActExitOutcome(unsigned long exitCode, const wchar_t** detail)
{
    switch (exitCode)
    {
    case kToastActExitOk:       *detail = L"carried out"; return ToastActResult::Done;
    case kToastActExitFailed:   *detail = L"the activation failed in the child process (its ACTEXEC line has the HRESULT)"; return ToastActResult::Failed;
    case kToastActExitBadInput: *detail = L"the child process could not read its instructions"; return ToastActResult::Failed;
    case 259:                   *detail = L"the child process reported no exit code (STILL_ACTIVE)"; return ToastActResult::Failed;
    default:                    *detail = L"the child process died (its exit code is logged)"; return ToastActResult::Failed;
    }
}

// ==== the activator lookup, bounded ========================================================
// The lookup (registry, then a Start-menu shortcut scan through IShellLink) runs on a short-lived thread
// of its own with its own apartment, so the thread that asks keeps its apartment and never waits without a
// bound: WaitFor returns false when the bound passes first, and the asker treats the sender as having no
// activator THIS time (window path, logged loudly, not cached); the lookup thread's late result is dropped.
constexpr uint64_t kToastActLookupBoundMs = 5000;

class ToastActLookupHandoff
{
public:
    void Publish(std::wstring const& clsid, const wchar_t* source)
    {
        { std::lock_guard<std::mutex> g(m_); clsid_ = clsid; source_ = source; done_ = true; }
        cv_.notify_all();
    }
    bool WaitFor(uint64_t boundMs, std::wstring& clsid, const wchar_t*& source)
    {
        std::unique_lock<std::mutex> g(m_);
        waited_ = true;
#ifdef TOASTACT_DEFECT_NOLOOKUPBOUND
        (void)boundMs;
        cv_.wait(g, [&] { return done_; });   // DEFECT: no bound
#else
        if (!cv_.wait_for(g, std::chrono::milliseconds(boundMs), [&] { return done_; })) return false;
#endif
        clsid = clsid_; source = source_;
        return true;
    }
    bool Waited() { std::lock_guard<std::mutex> g(m_); return waited_; }
    bool Done() { std::lock_guard<std::mutex> g(m_); return done_; }
private:
    std::mutex m_;
    std::condition_variable cv_;
    bool done_ = false;
    bool waited_ = false;
    std::wstring clsid_;
    const wchar_t* source_ = L"none";
};

// ==== the activator cache, with the lookups in flight ======================================
// Per sender (lower-cased AUMID): the answer - a CLSID, or NONE, negative results cached alike - for
// kTtlMs, bounded; and the hand-off of a lookup in flight, so every asker of the same sender joins the one
// lookup instead of starting another. A result is STORED whether or not anyone waited for it (the 2026-10-07
// regression fix: a cold lookup is started in the background and warms the cache for the sender's next toast;
// an informational toast never waits for it). Not thread-safe by itself: the caller locks.
class ToastActActivatorCache
{
public:
    static constexpr size_t   kMax = 256;
    static constexpr uint64_t kTtlMs = 10ull * 60ull * 1000ull;
    struct Hit { std::wstring clsid; const wchar_t* source; uint64_t tick; };

    ToastActActivator Get(std::wstring const& key, uint64_t now, std::wstring& clsid, const wchar_t*& source) const
    {
        auto it = hits_.find(key);
        if (it == hits_.end() || now - it->second.tick >= kTtlMs) return ToastActActivator::Unknown;
        clsid = it->second.clsid; source = it->second.source;
        return clsid.empty() ? ToastActActivator::None : ToastActActivator::Known;
    }
    // The hand-off of the lookup for `key`: the one in flight, or a new one (*started = true: the caller runs it).
    std::shared_ptr<ToastActLookupHandoff> Pending(std::wstring const& key, bool* started)
    {
        auto it = pending_.find(key);
        if (it != pending_.end()) { *started = false; return it->second; }
        auto h = std::make_shared<ToastActLookupHandoff>();
        pending_[key] = h;
        *started = true;
        return h;
    }
    // The lookup for `key` finished: cached (an empty clsid is the cached NONE), its hand-off published and dropped.
    void Store(std::wstring const& key, std::wstring const& clsid, const wchar_t* source, uint64_t now)
    {
        auto it = pending_.find(key);
        std::shared_ptr<ToastActLookupHandoff> h = (it != pending_.end()) ? it->second : nullptr;
        if (it != pending_.end()) pending_.erase(it);
#ifdef TOASTACT_DEFECT_LATE_RESULT_DROPPED
        if (!h || !h->Waited()) { if (h) h->Publish(clsid, source); return; }   // DEFECT: nobody waited -> not cached
#endif
        if (hits_.size() >= kMax) hits_.clear();   // bound; a refill is one lookup each
        hits_[key] = { clsid, source, now };
        if (h) h->Publish(clsid, source);
    }
    // The lookup for `key` could not run (no thread): its hand-off answers none, nothing is cached (the next toast asks again).
    void Abandon(std::wstring const& key)
    {
        auto it = pending_.find(key);
        if (it == pending_.end()) return;
        it->second->Publish(L"", L"no-thread");
        pending_.erase(it);
    }
    size_t Size() const { return hits_.size(); }
    size_t PendingCount() const { return pending_.size(); }
private:
    std::unordered_map<std::wstring, Hit> hits_;
    std::unordered_map<std::wstring, std::shared_ptr<ToastActLookupHandoff>> pending_;
};

// ==== the listing's route for one toast, allowlisted or not ===================================
// The allowlist is a SHORTCUT for senders whose toasts are informational (ADR-toasts 2, 4) - it was never a
// licence to forward a toast with buttons without them (guest finding 2026-10-07: a row-4 toast from an
// allowlisted sender reached dom0 as text while the hold suppressed its banner; decision 4 forbids exactly
// that). So once the classifier has answered, an allowlisted toast follows its PLAN like any other: bridge
// with the plan's actions, or the window path when the plan refuses (row 4 not fully carriable, rows 0-3). Only
// while the verdict is pending do the two differ: a toast still inside the listing's passes waits for it, and
// one that exhausted them is forwarded WITHOUT a plan if allowlisted (the shortcut's original contract, for a
// classifier that cannot answer - logged loudly: if that toast had buttons they are lost) and takes the window
// path otherwise (ADR-toasts 2, rule 3). An allowlisted informational toast is therefore forwarded on the first
// pass that has its verdict - typically the pass after its listing, tens of milliseconds later - and never
// waits for an activator lookup (its plan does not).
enum class ToastActListingRoute { AwaitVerdict = 0, ForwardWithPlan = 1, Window = 2, ForwardBlind = 3 };

inline ToastActListingRoute ToastActListingDecide(bool allowlisted, bool verdictKnown, bool routeBridge,
                                                  ToastActPlan const& plan, int passes, int maxPasses)
{
#ifdef TOASTACT_DEFECT_ALLOWLIST_BLIND
    if (allowlisted) return ToastActListingRoute::ForwardBlind;   // DEFECT: the shortcut ignores the plan
#endif
    if (verdictKnown) return (routeBridge && plan.ok) ? ToastActListingRoute::ForwardWithPlan : ToastActListingRoute::Window;
    if (passes < maxPasses) return ToastActListingRoute::AwaitVerdict;
    return allowlisted ? ToastActListingRoute::ForwardBlind : ToastActListingRoute::Window;
}

// The assertion the SENT line carries: a row-4 toast (real-choice buttons) sent with no actions is a bug of ours.
inline bool ToastActSentAnomaly(int row, size_t actionsSent)
{
#ifdef TOASTACT_DEFECT_ALLOWLIST_BLIND
    (void)row; (void)actionsSent;
    return false;   // DEFECT: the blind shortcut had no assertion either
#else
    return row == 4 && actionsSent == 0;
#endif
}

// ==== after a failed activation ===========================================================

// How long the bridge waits for the agent's TH_AGENT_SHOWN mark after turning the record `window`. The
// agent acts on the verdict event within one tracking pass (milliseconds); the bound is a FAILURE-STATE
// deadline - no mark by then means no banner was there to reopen - and it is armed only while a failed
// click awaits its outcome.
constexpr uint64_t kToastActShowBoundMs = 2000;
// A notice that could not be sent (dom0 unreachable) is retried on every pass until this long after the
// failure, then given up loudly.
constexpr uint64_t kToastActNoticeGiveUpMs = 60000;

enum class ToastActAfterFail { Wait = 0, BannerShown = 1, Notice = 2, GiveUp = 3 };

// `recordFound`: the hold record was still in the ring when it was turned `window` (false: the banner
// cannot be reopened - straight to the notice); `agentState`: TH_AGENT_* read from that record now.
inline ToastActAfterFail ToastActFailChoice(bool recordFound, long agentState, bool connUp,
                                            uint64_t now, uint64_t flippedAt)
{
    if (recordFound && agentState == 1 /* TH_AGENT_SHOWN */) return ToastActAfterFail::BannerShown;
    const uint64_t due = flippedAt + (recordFound ? kToastActShowBoundMs : 0);
    if (now < due) return ToastActAfterFail::Wait;
#ifdef TOASTACT_DEFECT_NONOTICE
    (void)connUp;
    return ToastActAfterFail::GiveUp;           // DEFECT: the user is never told
#else
    if (connUp) return ToastActAfterFail::Notice;
    if (now - flippedAt >= kToastActNoticeGiveUpMs) return ToastActAfterFail::GiveUp;
    return ToastActAfterFail::Wait;
#endif
}

// The dom0 error notice. Not a notifytexts.h row on purpose: those are once-per-boot agent faults with
// fixed text; this one is sent on EVERY failed click and names the toast (guest text that dom0 renders
// under its usual treatment, like the forwarded toast itself did).
inline void ToastActNoticeText(ToastActEntry const& e, ToastAct const* act, std::wstring const& detail,
                               std::wstring& summary, std::wstring& body)
{
    summary = L"A notification action did not run";
    body = L"'" + (act ? act->label : std::wstring(L"?")) + L"' on '" + e.title + L"'";
    if (!e.app.empty()) body += L" (" + e.app + L")";
    body += L" could not be carried out in the guest";
    if (!detail.empty()) body += L": " + detail;
    body += L". The notification is still in the guest's Notification Center.";
}
