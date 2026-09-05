// toastclassify_fixtures.h - SYNTHETIC toast-XML corpus for toastclassify_test (P3b).
//
// Every string here is HAND-WRITTEN against the public toast schema, shaped after the
// documented real-world classes (Phone Link quick reply, Outlook snooze, Windows Update
// restart, Snipping Tool "screenshot saved", the guest/fire-demo-toast.ps1 fixture
// shapes at its lines 29/32/35). NONE of it is a rig capture: no wpndatabase dump, no
// per-run evidence, nothing from a guest (CLAUDE.md public-repo rule). Expected verdicts
// cite the decision-table rows at docs/DESIGN-toast-bridge.md:165-177; row 0 = pre-table
// fail-open. Shared so the P3a shadow probe / P3c wiring can replay the same corpus.
#pragma once
#include "toastclassify.h"

struct ToastFixture
{
    const wchar_t* name;   // stable test id, greppable in CI logs
    const wchar_t* xml;    // synthetic payload
    int route;             // expected ToastRoute (0 window / 1 bridge)
    int row;               // expected ToastClass.row
};

static const ToastFixture kToastFixtures[] = {

// ---- row 1: text input -> window (reply cannot cross the bridge) ---------------------
{ L"row1-textbox-plus-send-button",   // buttons AND a text box: window by row 1 (doc:175-176)
  L"<toast><visual><binding template=\"ToastGeneric\"><text>msg</text></binding></visual>"
  L"<actions><input id=\"tb\" type=\"text\" placeHolderContent=\"reply\"/>"
  L"<action content=\"Send\" activationType=\"background\" arguments=\"reply\" hint-inputId=\"tb\"/>"
  L"</actions></toast>", 0, 1 },
{ L"row1-textbox-alone",
  L"<toast><visual><binding template=\"ToastGeneric\"><text>t</text></binding></visual>"
  L"<actions><input id=\"tb\" type=\"text\"/></actions></toast>", 0, 1 },
{ L"row1-input-missing-type-failopen",
  L"<toast><actions><input id=\"x\"/></actions></toast>", 0, 1 },
{ L"row1-input-unknown-type-failopen",
  L"<toast><actions><input id=\"x\" type=\"quickreply\"/></actions></toast>", 0, 1 },
{ L"row1-type-TEXT-uppercase-liberal",  // window-forcing matches are case-insensitive
  L"<toast><actions><input id=\"x\" type=\"TEXT\"/></actions></toast>", 0, 1 },
{ L"row1-phonelink-quickreply-shape",
  L"<toast launch=\"action=open\"><visual><binding template=\"ToastGeneric\">"
  L"<text>Alice</text><text>hi there</text></binding></visual><actions>"
  L"<input id=\"reply\" type=\"text\" placeHolderContent=\"Type a reply\"/>"
  L"<action content=\"Send\" activationType=\"background\" arguments=\"send\"/>"
  L"<action content=\"Call\" activationType=\"foreground\" arguments=\"call\"/>"
  L"</actions></toast>", 0, 1 },
{ L"row1-wins-over-earlier-selection",  // table order: text anywhere beats selection anywhere
  L"<toast><actions><input id=\"s\" type=\"selection\"><selection id=\"5\" content=\"5 min\"/></input>"
  L"<input id=\"tb\" type=\"text\"/></actions></toast>", 0, 1 },

// ---- row 2: selection input / system snooze -> window --------------------------------
{ L"row2-selection-snooze-interval",   // Outlook-style snooze picker
  L"<toast scenario=\"default\"><actions>"
  L"<input id=\"snoozeTime\" type=\"selection\" defaultInput=\"15\">"
  L"<selection id=\"15\" content=\"15 minutes\"/><selection id=\"60\" content=\"1 hour\"/></input>"
  L"<action content=\"Snooze\" activationType=\"system\" arguments=\"snooze\" hint-inputId=\"snoozeTime\"/>"
  L"<action content=\"Dismiss\" activationType=\"system\" arguments=\"dismiss\"/>"
  L"</actions></toast>", 0, 2 },
{ L"row2-system-snooze-button",
  L"<toast><actions><action content=\"Snooze\" activationType=\"system\" arguments=\"snooze\"/>"
  L"<action content=\"Dismiss\" activationType=\"system\" arguments=\"dismiss\"/></actions></toast>", 0, 2 },
{ L"row2-snooze-case-variant-liberal",
  L"<toast><actions><action content=\"Snooze\" activationType=\"System\" arguments=\"Snooze\"/>"
  L"</actions></toast>", 0, 2 },

// ---- row 3: time-critical scenario / pendingUpdate / progress -> window --------------
{ L"row3-reminder-two-buttons",        // guest/fire-demo-toast.ps1:29 -RealChoice shape
  L"<toast scenario=\"reminder\"><visual><binding template=\"ToastGeneric\">"
  L"<text>demo toast</text><text>demo body</text></binding></visual>"
  L"<actions><action content=\"OK\" arguments=\"ok\"/><action content=\"Later\" arguments=\"later\"/>"
  L"</actions></toast>", 0, 3 },
{ L"row3-persistent-informational",    // fire-demo-toast.ps1:32 -Persistent shape; its :17-19
                                       // note predicts exactly this: window path under Phase 3
  L"<toast scenario=\"reminder\"><visual><binding template=\"ToastGeneric\">"
  L"<text>demo toast</text><text>demo body</text></binding></visual>"
  L"<actions><action content=\"OK\" arguments=\"ok\"/></actions></toast>", 0, 3 },
{ L"row3-alarm",
  L"<toast scenario=\"alarm\"><visual><binding template=\"ToastGeneric\"><text>wake</text>"
  L"</binding></visual></toast>", 0, 3 },
{ L"row3-incomingCall",
  L"<toast scenario=\"incomingCall\"><visual><binding template=\"ToastGeneric\"><text>ring</text>"
  L"</binding></visual></toast>", 0, 3 },
{ L"row3-scenario-urgent-unknown-failopen",   // Win11 value, not in the table -> window
  L"<toast scenario=\"urgent\"><visual><binding template=\"ToastGeneric\"><text>x</text>"
  L"</binding></visual></toast>", 0, 3 },
{ L"row3-scenario-gibberish-failopen",
  L"<toast scenario=\"bananas\"><visual><binding template=\"ToastGeneric\"><text>x</text>"
  L"</binding></visual></toast>", 0, 3 },
{ L"row3-pendingUpdate-action",
  L"<toast><actions><action content=\"Done\" activationType=\"background\" arguments=\"d\""
  L" afterActivationBehavior=\"pendingUpdate\"/></actions></toast>", 0, 3 },
{ L"row3-progress-element",
  L"<toast><visual><binding template=\"ToastGeneric\"><text>copying</text>"
  L"<progress value=\"0.4\" status=\"working\"/></binding></visual></toast>", 0, 3 },

// ---- row 4: foreground/background (real choice) -> window ----------------------------
{ L"row4-one-foreground-button",
  L"<toast><visual><binding template=\"ToastGeneric\"><text>t</text></binding></visual>"
  L"<actions><action content=\"Open\" activationType=\"foreground\" arguments=\"open\"/>"
  L"</actions></toast>", 0, 4 },
{ L"row4-one-background-button",
  L"<toast><actions><action content=\"Archive\" activationType=\"background\" arguments=\"a\"/>"
  L"</actions></toast>", 0, 4 },
{ L"row4-no-activationType-defaults-foreground",   // schema default = foreground
  L"<toast><actions><action content=\"OK\" arguments=\"ok\"/></actions></toast>", 0, 4 },
{ L"row4-windowsupdate-restart-shape",             // the DELIBERATELY EXCLUDED class,
                                                   // notifhost.cpp:268-273
  L"<toast><visual><binding template=\"ToastGeneric\"><text>Restart required</text>"
  L"</binding></visual><actions>"
  L"<action content=\"Restart now\" activationType=\"foreground\" arguments=\"restart\"/>"
  L"<action content=\"Pick a time\" activationType=\"foreground\" arguments=\"pick\"/>"
  L"</actions></toast>", 0, 4 },
{ L"row4-unknown-activationType-failopen",
  L"<toast><actions><action content=\"X\" activationType=\"com\" arguments=\"x\"/>"
  L"</actions></toast>", 0, 4 },
{ L"row4-FOREGROUND-uppercase-liberal",
  L"<toast><actions><action content=\"X\" activationType=\"FOREGROUND\" arguments=\"x\"/>"
  L"</actions></toast>", 0, 4 },
{ L"row4-Protocol-wrong-case-strict",   // bridge-permitting values match exact-case only
  L"<toast><actions><action content=\"Open\" activationType=\"Protocol\" arguments=\"https://e/\"/>"
  L"</actions></toast>", 0, 4 },
{ L"row4-protocol-plus-foreground-mix",
  L"<toast><actions><action content=\"Open\" activationType=\"protocol\" arguments=\"https://e/\"/>"
  L"<action content=\"Reply\" activationType=\"foreground\" arguments=\"r\"/></actions></toast>", 0, 4 },
{ L"row4-placement-ContextMenu-wrong-case",   // exemption is strict: this stays a banner action
  L"<toast><actions><action content=\"X\" placement=\"ContextMenu\" activationType=\"foreground\""
  L" arguments=\"x\"/></actions></toast>", 0, 4 },
{ L"row4-system-unknown-arguments-failopen",
  L"<toast><actions><action content=\"X\" activationType=\"system\" arguments=\"reboot\"/>"
  L"</actions></toast>", 0, 4 },

// ---- row 5: protocol-only actions -> bridge ------------------------------------------
{ L"row5-single-protocol",
  L"<toast><visual><binding template=\"ToastGeneric\"><text>saved</text></binding></visual>"
  L"<actions><action content=\"Open folder\" activationType=\"protocol\""
  L" arguments=\"file:///C:/shots\"/></actions></toast>", 1, 5 },
{ L"row5-two-protocols",
  L"<toast><actions>"
  L"<action content=\"Open\" activationType=\"protocol\" arguments=\"https://example.com/a\"/>"
  L"<action content=\"Docs\" activationType=\"protocol\" arguments=\"https://example.com/b\"/>"
  L"</actions></toast>", 1, 5 },
{ L"row5-protocol-plus-system-dismiss",
  L"<toast><actions>"
  L"<action content=\"Open\" activationType=\"protocol\" arguments=\"ms-settings:windowsupdate\"/>"
  L"<action content=\"Dismiss\" activationType=\"system\" arguments=\"dismiss\"/>"
  L"</actions></toast>", 1, 5 },
{ L"row5-contextMenu-foreground-ignored",   // auxiliary contextMenu action must not force window
  L"<toast><actions>"
  L"<action content=\"Open\" activationType=\"protocol\" arguments=\"https://example.com/\"/>"
  L"<action content=\"Settings\" placement=\"contextMenu\" activationType=\"foreground\""
  L" arguments=\"cfg\"/></actions></toast>", 1, 5 },

// ---- row 6: dismiss-only / actionless -> bridge (informational) ----------------------
{ L"row6-no-actions",                  // guest/fire-demo-toast.ps1:35 informational shape
  L"<toast><visual><binding template=\"ToastGeneric\"><text>demo toast</text>"
  L"<text>demo body</text></binding></visual></toast>", 1, 6 },
{ L"row6-empty-actions-element",
  L"<toast><visual><binding template=\"ToastGeneric\"><text>t</text></binding></visual>"
  L"<actions/></toast>", 1, 6 },
{ L"row6-system-dismiss-only",
  L"<toast><actions><action content=\"Dismiss\" activationType=\"system\" arguments=\"dismiss\"/>"
  L"</actions></toast>", 1, 6 },
{ L"row6-launch-deep-link-actionless",  // deep link only enriches the default click (doc:176-177)
  L"<toast launch=\"snippingtool://open?id=42\" activationType=\"protocol\">"
  L"<visual><binding template=\"ToastGeneric\"><text>Screenshot saved</text></binding></visual>"
  L"</toast>", 1, 6 },
{ L"row6-contextMenu-only-actions",     // contextMenu presence alone must NOT force window (doc:174)
  L"<toast><visual><binding template=\"ToastGeneric\"><text>t</text></binding></visual>"
  L"<actions><action content=\"Settings\" placement=\"contextMenu\" activationType=\"foreground\""
  L" arguments=\"cfg\"/></actions></toast>", 1, 6 },
{ L"row6-image-audio-extras-ignored",   // unknown-but-harmless elements never force window
  L"<toast displayTimestamp=\"2026-01-01T00:00:00Z\"><visual>"
  L"<binding template=\"ToastGeneric\"><text>photo imported</text>"
  L"<image src=\"file:///C:/img.png\" placement=\"appLogoOverride\"/></binding></visual>"
  L"<audio silent=\"true\"/></toast>", 1, 6 },
{ L"row6-xmldecl-and-comment-prolog",
  L"<?xml version=\"1.0\" encoding=\"utf-8\"?><!-- generated --><toast><visual>"
  L"<binding template=\"ToastGeneric\"><text>t</text></binding></visual></toast>", 1, 6 },
{ L"row6-cdata-text-content",
  L"<toast><visual><binding template=\"ToastGeneric\"><text><![CDATA[5 < 6 & more]]></text>"
  L"</binding></visual></toast>", 1, 6 },
{ L"row6-entity-in-attribute",
  L"<toast launch=\"a&amp;b=&quot;c&quot;\"><visual><binding template=\"ToastGeneric\">"
  L"<text>t</text></binding></visual></toast>", 1, 6 },
{ L"row6-numeric-entities",
  L"<toast launch=\"x&#65;&#x42;\"><visual><binding template=\"ToastGeneric\"><text>t</text>"
  L"</binding></visual></toast>", 1, 6 },
{ L"row6-selfclosed-root",
  L"<toast/>", 1, 6 },
{ L"row6-scenario-default-explicit",    // scenario=default is not a row-3 trigger
  L"<toast scenario=\"default\"><visual><binding template=\"ToastGeneric\"><text>t</text>"
  L"</binding></visual></toast>", 1, 6 },

// ---- row 0: malformed / unclassifiable -> window (the mandatory fail rows) -----------
{ L"fail-empty-string",            L"",                                            0, 0 },
{ L"fail-whitespace-only",         L"   \r\n\t ",                                  0, 0 },
{ L"fail-truncated",               L"<toast><visual><binding template=\"ToastGen", 0, 0 },
{ L"fail-mismatched-close",        L"<toast><visual></toast></visual>",            0, 0 },
{ L"fail-unclosed-root",           L"<toast><visual/>",                            0, 0 },
{ L"fail-wrong-root-tile",         L"<tile><visual/></tile>",                      0, 0 },
{ L"fail-not-xml-at-all",          L"definitely not xml { \"json\": true }",       0, 0 },
{ L"fail-unquoted-attribute",      L"<toast scenario=reminder></toast>",           0, 0 },
{ L"fail-bare-ampersand-in-value", L"<toast launch=\"a&b\"></toast>",              0, 0 },
{ L"fail-lt-in-attribute-value",   L"<toast launch=\"a<b\"></toast>",              0, 0 },
{ L"fail-doctype",                 L"<!DOCTYPE toast><toast/>",                    0, 0 },
{ L"fail-two-roots",               L"<toast/><toast/>",                            0, 0 },
{ L"fail-duplicate-attribute",     L"<toast scenario=\"reminder\" scenario=\"default\"/>", 0, 0 },
{ L"fail-unterminated-comment",    L"<!-- open forever <toast/>",                  0, 0 },
{ L"fail-attr-without-value",      L"<toast scenario></toast>",                    0, 0 },
};

static const size_t kToastFixtureCount = sizeof(kToastFixtures) / sizeof(kToastFixtures[0]);
static_assert(sizeof(kToastFixtures) / sizeof(kToastFixtures[0]) >= 45,
              "fixture corpus shrank - the suite would be checking less than it claims");
