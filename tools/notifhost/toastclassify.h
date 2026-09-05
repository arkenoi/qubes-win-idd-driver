// toastclassify.h - PURE per-toast classifier for the Phase 3 toast bridge (P3b).
//
// Maps ONE toast payload XML (the wpndatabase.db Notification.Payload column - the same
// string an app hands to ToastNotificationManager) to a routing verdict:
//
//   ToastRouteWindow - keep today's override-redirect window path (the safe default);
//   ToastRouteBridge - eligible for forwarding over qubes.Notifications.
//
// It implements the decision table at docs/DESIGN-toast-bridge.md:165-177 EXACTLY,
// evaluated top-down, first match wins:
//
//   row 1  any <input type="text">                                       -> window
//   row 2  any <input type="selection">, or a system action arguments="snooze" -> window
//   row 3  scenario reminder/alarm/incomingCall, afterActivationBehavior=
//          "pendingUpdate", or a <progress> element                      -> window
//   row 4  any foreground/background (non-system) action                 -> window
//          (the owner's split: a real choice stays a real window)
//   row 5  only protocol actions                                         -> bridge
//   row 6  only a system dismiss action, or no actions at all            -> bridge
//
// Documented edge cases (DESIGN-toast-bridge.md:174-177): placement="contextMenu"
// actions are auxiliary (invisible on the banner) and are excluded from rows 4-6, so
// contextMenu-only actions do NOT alone force the window path; buttons + a text box is
// window-path by row 1; an actionless toast with a launch= deep link is still
// informational (the deep link only enriches the default click).
//
// FAIL-OPEN is the load-bearing invariant (DESIGN-toast-bridge.md:581, 596): every
// doubt routes to Window - malformed/unparseable XML, a non-<toast> root, an unknown
// scenario, an unknown activationType or system-arguments, an <input> with a missing or
// unrecognized type, adversarial size/depth, undecodable payload bytes. Window can never
// LOSE a toast (it is today's exact behaviour); Bridge must be EARNED by an exact match.
// That asymmetry is also encoded in string matching: values that force Window match
// case-INSENSITIVELY (liberal - over-triggering Window is safe), values that permit
// Bridge ("protocol", system+"dismiss", the "contextMenu" exemption) match exact-case
// against the schema spelling (strict - a misspelling must not open the bridge).
// Unknown ELEMENTS (image/audio/text/header/...) are ignored: only input/action/
// progress/scenario/afterActivationBehavior are classification-relevant, and e.g. an
// <image> must not push an informational toast off the bridge.
//
// Pure C++17, header-only, no Windows headers, no XML library, no allocation beyond
// std::wstring/vector (matches notifhost's no-new-dependency rule, notifhost.cpp:42 /
// notifhost.vcxproj:3-9). NOT included by notifhost.cpp yet - wiring is P3c (the agent
// verdict channel + deferred map, DESIGN-toast-bridge.md:597-602); P3a's measure-only
// shadow probe includes it to LOG a verdict while routing stays byte-for-byte A0.
// Unit suite: toastclassify_test.cpp over toastclassify_fixtures.h (synthetic corpus).
//
// ==== defect-reintroduction switches (proof the suite can FAIL) =======================
// Define AT MOST ONE to deliberately break a rule; toastclassify_test MUST then fail
// (CI builds once clean = pass required, once with TOASTCLASSIFY_DEFECT_ROW4 = failure
// required). A check never seen to fail is decoration (CLAUDE.md autonomy rule 5).
//   TOASTCLASSIFY_DEFECT_ROW1       - text/unknown <input> no longer forces window
//   TOASTCLASSIFY_DEFECT_ROW4       - foreground/background actions classify bridgeable
//   TOASTCLASSIFY_DEFECT_FAILCLOSED - malformed XML classifies as Bridge (fail-open inverted)
#pragma once
#include <cstdint>
#include <cstddef>
#include <cwchar>     // wcsncmp
#include <string>
#include <vector>

#if (defined(TOASTCLASSIFY_DEFECT_ROW1) + defined(TOASTCLASSIFY_DEFECT_ROW4) + \
     defined(TOASTCLASSIFY_DEFECT_FAILCLOSED)) > 1
#error define at most one TOASTCLASSIFY_DEFECT_* switch
#endif

enum ToastRoute { ToastRouteWindow = 0, ToastRouteBridge = 1 };

struct ToastClass
{
    ToastRoute route;
    int row;                // matched decision-table row 1..6 (DESIGN-toast-bridge.md:165-177);
                            // 0 = pre-table fail-open (malformed / undecodable / wrong root)
    const wchar_t* reason;  // static string, safe to embed in a CLASSIFY log line
};

inline const wchar_t* ToastRouteName(ToastRoute r)
{
    return r == ToastRouteBridge ? L"bridge" : L"window";
}

namespace tc {

// Adversarial-input bounds. wpndatabase payloads are a few KB; anything beyond these is
// not a toast the shell produced and fails open to Window.
constexpr size_t kMaxChars = 256 * 1024;   // wchar_t units of XML
constexpr size_t kMaxElems = 512;
constexpr size_t kMaxDepth = 32;
constexpr size_t kMaxAttrs = 64;

inline bool IEq(std::wstring const& a, const wchar_t* b)   // ASCII case-insensitive
{
    size_t i = 0;
    for (; i < a.size() && b[i]; i++)
    {
        wchar_t x = a[i], y = b[i];
        if (x >= L'A' && x <= L'Z') x = (wchar_t)(x + 32);
        if (y >= L'A' && y <= L'Z') y = (wchar_t)(y + 32);
        if (x != y) return false;
    }
    return i == a.size() && b[i] == 0;
}

struct Attr { std::wstring name, value; };
struct Elem { std::wstring name; std::vector<Attr> attrs; };

inline bool IsSpace(wchar_t c) { return c == L' ' || c == L'\t' || c == L'\r' || c == L'\n'; }
inline bool NameStart(wchar_t c)
{ return (c >= L'a' && c <= L'z') || (c >= L'A' && c <= L'Z') || c == L'_' || c == L':'; }
inline bool NameChar(wchar_t c)
{ return NameStart(c) || (c >= L'0' && c <= L'9') || c == L'-' || c == L'.'; }

inline void AppendCp(std::wstring& out, uint32_t cp)
{
    if (cp <= 0xFFFF) { out += (wchar_t)cp; return; }
    if constexpr (sizeof(wchar_t) >= 4) { out += (wchar_t)cp; }
    else
    {
        cp -= 0x10000;
        out += (wchar_t)(0xD800 + (cp >> 10));
        out += (wchar_t)(0xDC00 + (cp & 0x3FF));
    }
}

// s[i] == '&'. Decode a strict XML entity into out and advance i past the ';'.
// Anything else (bare '&', unknown/unterminated entity) is malformed -> caller fails open.
inline bool DecodeEntity(const wchar_t* s, size_t n, size_t& i, std::wstring& out)
{
    size_t j = i + 1, end = 0;
    bool found = false;
    for (size_t k = j; k < n && k < j + 12; k++)
        if (s[k] == L';') { end = k; found = true; break; }
    if (!found || end == j) return false;
    std::wstring ent(s + j, end - j);
    if (ent == L"lt")   { out += L'<';  i = end + 1; return true; }
    if (ent == L"gt")   { out += L'>';  i = end + 1; return true; }
    if (ent == L"amp")  { out += L'&';  i = end + 1; return true; }
    if (ent == L"quot") { out += L'"';  i = end + 1; return true; }
    if (ent == L"apos") { out += L'\''; i = end + 1; return true; }
    if (ent[0] == L'#')
    {
        uint32_t v = 0; size_t k = 1; bool any = false;
        bool hex = ent.size() > 1 && (ent[1] == L'x' || ent[1] == L'X');
        if (hex) k = 2;
        for (; k < ent.size(); k++)
        {
            wchar_t c = ent[k]; uint32_t d;
            if (c >= L'0' && c <= L'9') d = (uint32_t)(c - L'0');
            else if (hex && c >= L'a' && c <= L'f') d = (uint32_t)(c - L'a' + 10);
            else if (hex && c >= L'A' && c <= L'F') d = (uint32_t)(c - L'A' + 10);
            else return false;
            v = v * (hex ? 16u : 10u) + d;
            if (v > 0x10FFFF) return false;
            any = true;
        }
        if (!any || v == 0 || (v >= 0xD800 && v <= 0xDFFF)) return false;
        AppendCp(out, v);
        i = end + 1;
        return true;
    }
    return false;
}

// Minimal strict scan-parser over the closed toast schema: elements + attributes into a
// flat document-order list; text content is skipped (never classification-relevant).
// Returns false on ANY deviation - unbalanced tags, unquoted/duplicate attributes, '<'
// or bare '&' in a value, DOCTYPE, multiple roots, trailing markup, size/depth/count
// bounds - and false always means the caller routes to Window (fail-open).
inline bool Parse(const wchar_t* s, size_t n, std::vector<Elem>& out, std::wstring& rootName)
{
    if (!s || n == 0 || n > kMaxChars) return false;
    size_t i = 0;
    std::vector<std::wstring> stack;
    bool haveRoot = false, rootClosed = false;
    while (i < n)
    {
        wchar_t c = s[i];
        if (c == 0) return false;                    // embedded NUL: not shell-produced XML
        if (c != L'<')
        {
            if (stack.empty() && !IsSpace(c)) return false;  // non-space outside the root
            i++;
            continue;
        }
        if (rootClosed) return false;                // second root / trailing markup
        i++;
        if (i >= n) return false;
        if (s[i] == L'?')                            // <?xml ...?> / processing instruction
        {
            bool done = false;
            for (size_t k = i + 1; k + 1 < n; k++)
                if (s[k] == L'?' && s[k + 1] == L'>') { i = k + 2; done = true; break; }
            if (!done) return false;
            continue;
        }
        if (s[i] == L'!')
        {
            if (n - i >= 3 && s[i + 1] == L'-' && s[i + 2] == L'-')          // comment
            {
                bool done = false;
                for (size_t k = i + 3; k + 2 < n; k++)
                    if (s[k] == L'-' && s[k + 1] == L'-' && s[k + 2] == L'>')
                    { i = k + 3; done = true; break; }
                if (!done) return false;
                continue;
            }
            if (n - i >= 8 && wcsncmp(s + i, L"![CDATA[", 8) == 0)           // CDATA text
            {
                if (stack.empty()) return false;
                bool done = false;
                for (size_t k = i + 8; k + 2 < n; k++)
                    if (s[k] == L']' && s[k + 1] == L']' && s[k + 2] == L'>')
                    { i = k + 3; done = true; break; }
                if (!done) return false;
                continue;
            }
            return false;                            // DOCTYPE etc.: outside the closed schema
        }
        if (s[i] == L'/')                            // closing tag
        {
            i++;
            if (i >= n || !NameStart(s[i])) return false;
            std::wstring nm;
            while (i < n && NameChar(s[i])) nm += s[i++];
            while (i < n && IsSpace(s[i])) i++;
            if (i >= n || s[i] != L'>') return false;
            i++;
            if (stack.empty() || stack.back() != nm) return false;   // mismatched close
            stack.pop_back();
            if (stack.empty()) rootClosed = true;
            continue;
        }
        if (!NameStart(s[i])) return false;          // opening tag
        Elem el;
        while (i < n && NameChar(s[i])) el.name += s[i++];
        bool selfClose = false;
        for (;;)
        {
            while (i < n && IsSpace(s[i])) i++;
            if (i >= n) return false;
            if (s[i] == L'/')
            {
                if (i + 1 >= n || s[i + 1] != L'>') return false;
                i += 2; selfClose = true; break;
            }
            if (s[i] == L'>') { i++; break; }
            if (!NameStart(s[i])) return false;
            Attr a;
            while (i < n && NameChar(s[i])) a.name += s[i++];
            while (i < n && IsSpace(s[i])) i++;
            if (i >= n || s[i] != L'=') return false;
            i++;
            while (i < n && IsSpace(s[i])) i++;
            if (i >= n || (s[i] != L'"' && s[i] != L'\'')) return false;
            wchar_t q = s[i++];
            for (;;)
            {
                if (i >= n) return false;            // unterminated value
                if (s[i] == q) { i++; break; }
                if (s[i] == L'<') return false;
                if (s[i] == L'&') { if (!DecodeEntity(s, n, i, a.value)) return false; }
                else a.value += s[i++];
            }
            for (auto const& prev : el.attrs)
                if (IEq(prev.name, a.name.c_str())) return false;    // duplicate attribute
            if (el.attrs.size() >= kMaxAttrs) return false;
            el.attrs.push_back(std::move(a));
        }
        if (stack.empty())
        {
            if (haveRoot) return false;
            haveRoot = true;
            rootName = el.name;
        }
        if (out.size() >= kMaxElems) return false;
        out.push_back(el);
        if (!selfClose)
        {
            if (stack.size() >= kMaxDepth) return false;
            stack.push_back(out.back().name);
        }
        else if (stack.empty())
            rootClosed = true;
    }
    return haveRoot && rootClosed && stack.empty();
}

inline const Attr* FindAttr(Elem const& e, const wchar_t* name)
{
    for (auto const& a : e.attrs)
        if (IEq(a.name, name)) return &a;
    return nullptr;
}

} // namespace tc

// ==== the classifier ==================================================================

inline ToastClass ClassifyToastXml(const wchar_t* xml, size_t len)
{
#if defined(TOASTCLASSIFY_DEFECT_FAILCLOSED)
    // DEFECT (reintroduction proof): fail-open inverted - the suite must catch this.
    const ToastClass malformed{ ToastRouteBridge, 0, L"DEFECT_FAILCLOSED: malformed as bridge" };
#else
    const ToastClass malformed{ ToastRouteWindow, 0, L"malformed/unparseable payload (fail-open)" };
#endif
    std::vector<tc::Elem> els;
    std::wstring root;
    if (!tc::Parse(xml, len, els, root)) return malformed;
    if (!tc::IEq(root, L"toast"))
        return { ToastRouteWindow, 0, L"root element is not <toast> (fail-open)" };

    // Row 1 - any text-class <input>. Table-faithful ordering: this pass runs over ALL
    // inputs before row 2's selection pass, so text-input-anywhere wins even when a
    // selection input appears earlier in the document. Missing/unknown input types are
    // folded in here fail-open: any input the table does not name still needs a real
    // input surface, which cannot cross the bridge.
    for (auto const& e : els)
    {
        if (!tc::IEq(e.name, L"input")) continue;
        const tc::Attr* t = tc::FindAttr(e, L"type");
        if (t && tc::IEq(t->value, L"selection")) continue;   // row 2's business
#if defined(TOASTCLASSIFY_DEFECT_ROW1)
        continue;   // DEFECT: row 1 disabled - text inputs no longer force the window path
#else
        return { ToastRouteWindow, 1, (t && tc::IEq(t->value, L"text"))
                     ? L"text input (reply cannot cross the bridge)"
                     : L"input with missing/unrecognized type (fail-open)" };
#endif
    }

    // Row 2 - selection input, or a system snooze action (shell-internal rescheduling).
    // Snooze scan is liberal (case-insensitive, contextMenu included): over-matching
    // only ever forces Window.
    for (auto const& e : els)
    {
        if (!tc::IEq(e.name, L"input")) continue;
        const tc::Attr* t = tc::FindAttr(e, L"type");
        if (t && tc::IEq(t->value, L"selection"))
            return { ToastRouteWindow, 2, L"selection input (snooze choice is shell-internal)" };
    }
    for (auto const& e : els)
    {
        if (!tc::IEq(e.name, L"action")) continue;
        const tc::Attr* at = tc::FindAttr(e, L"activationType");
        const tc::Attr* ar = tc::FindAttr(e, L"arguments");
        if (at && tc::IEq(at->value, L"system") && ar && tc::IEq(ar->value, L"snooze"))
            return { ToastRouteWindow, 2, L"system snooze action (shell-internal rescheduling)" };
    }

    // Row 3 - time-critical / self-updating surfaces. Unknown scenario values (incl.
    // Win11's "urgent") are not in the table and fail open to Window.
    {
        const tc::Attr* sc = tc::FindAttr(els.front(), L"scenario");
        if (sc && !sc->value.empty() && !tc::IEq(sc->value, L"default"))
        {
            if (tc::IEq(sc->value, L"reminder") || tc::IEq(sc->value, L"alarm") ||
                tc::IEq(sc->value, L"incomingCall"))
                return { ToastRouteWindow, 3, L"time-critical scenario (reminder/alarm/incomingCall)" };
            return { ToastRouteWindow, 3, L"unrecognized scenario (fail-open)" };
        }
    }
    for (auto const& e : els)
    {
        const tc::Attr* b = tc::FindAttr(e, L"afterActivationBehavior");
        if (b && tc::IEq(b->value, L"pendingUpdate"))
            return { ToastRouteWindow, 3, L"afterActivationBehavior=pendingUpdate (self-updating)" };
        if (tc::IEq(e.name, L"progress"))
            return { ToastRouteWindow, 3, L"<progress> element (self-updating)" };
    }

    // Rows 4/5/6 - over BANNER actions only. placement="contextMenu" actions are
    // auxiliary and invisible on the banner (DESIGN-toast-bridge.md:174-175): excluded.
    // The exemption is bridge-permitting, so it matches the exact schema spelling only;
    // an unknown/miscased placement counts as a banner action (conservative).
    bool anyProtocol = false, anyDismiss = false;
    for (auto const& e : els)
    {
        if (!tc::IEq(e.name, L"action")) continue;
        const tc::Attr* pl = tc::FindAttr(e, L"placement");
        if (pl && pl->value == L"contextMenu") continue;
        const tc::Attr* at = tc::FindAttr(e, L"activationType");
        const tc::Attr* ar = tc::FindAttr(e, L"arguments");
        if (!at || tc::IEq(at->value, L"foreground") || tc::IEq(at->value, L"background"))
        {
            // Row 4. An action with no activationType defaults to foreground (schema
            // default), i.e. it is a real choice too.
#if defined(TOASTCLASSIFY_DEFECT_ROW4)
            anyProtocol = true;   // DEFECT: real-choice buttons treated as bridgeable
            continue;
#else
            return { ToastRouteWindow, 4, !at
                         ? L"action defaults to foreground activation (real choice)"
                         : L"foreground/background action (real choice)" };
#endif
        }
        if (at->value == L"protocol") { anyProtocol = true; continue; }       // strict
        if (at->value == L"system" && ar && ar->value == L"dismiss")          // strict
        { anyDismiss = true; continue; }
        return { ToastRouteWindow, 4, L"unrecognized activationType/arguments (fail-open)" };
    }
    if (anyProtocol)
        return { ToastRouteBridge, 5, L"protocol-only actions (URI launch reproducible in-guest)" };
    return { ToastRouteBridge, 6, anyDismiss
                 ? L"dismiss-only actions (informational)"
                 : L"no banner actions (informational)" };
}

inline ToastClass ClassifyToastXml(std::wstring const& xml)
{
    return ClassifyToastXml(xml.c_str(), xml.size());
}

// Byte-payload entry (the wpndatabase Payload column is stored as bytes): UTF-8 with or
// without BOM, or UTF-16LE when it carries the FF FE BOM. Strict validation - any
// undecodable byte sequence fails open to Window.
inline ToastClass ClassifyToastXmlBytes(const void* data, size_t bytes)
{
    const ToastClass bad{ ToastRouteWindow, 0, L"payload bytes undecodable (fail-open)" };
    if (!data || bytes == 0 || bytes > tc::kMaxChars * 3) return bad;
    const unsigned char* p = (const unsigned char*)data;
    std::wstring w;
    if (bytes >= 2 && p[0] == 0xFF && p[1] == 0xFE)          // UTF-16LE BOM
    {
        if (bytes % 2) return bad;
        w.reserve((bytes - 2) / 2);
        for (size_t i = 2; i + 1 < bytes; i += 2)
            w += (wchar_t)((uint32_t)p[i] | ((uint32_t)p[i + 1] << 8));
        return ClassifyToastXml(w.c_str(), w.size());
    }
    size_t i = (bytes >= 3 && p[0] == 0xEF && p[1] == 0xBB && p[2] == 0xBF) ? 3 : 0;
    w.reserve(bytes - i);
    while (i < bytes)
    {
        unsigned char b = p[i];
        uint32_t cp; int len;
        if (b < 0x80) { cp = b; len = 1; }
        else if ((b & 0xE0) == 0xC0) { cp = b & 0x1F; len = 2; }
        else if ((b & 0xF0) == 0xE0) { cp = b & 0x0F; len = 3; }
        else if ((b & 0xF8) == 0xF0) { cp = b & 0x07; len = 4; }
        else return bad;
        if (i + (size_t)len > bytes) return bad;
        for (int k = 1; k < len; k++)
        {
            if ((p[i + k] & 0xC0) != 0x80) return bad;
            cp = (cp << 6) | (uint32_t)(p[i + k] & 0x3F);
        }
        static const uint32_t minv[5] = { 0, 0, 0x80, 0x800, 0x10000 };
        if (cp < minv[len] || cp > 0x10FFFF || (cp >= 0xD800 && cp <= 0xDFFF) || cp == 0)
            return bad;                                       // overlong/surrogate/NUL
        tc::AppendCp(w, cp);
        i += (size_t)len;
    }
    return ClassifyToastXml(w.c_str(), w.size());
}
