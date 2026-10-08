#!/usr/bin/env python3
"""log-sweep.py - the PROACTIVE LOG SWEEP: find the abnormality in our guest logs BEFORE it causes the crash.

WHY THIS EXISTS (owner, 2026-10-07: "could you look for such abnormalities in logs IN ADVANCE, not waiting
for crashes they cause?" and "use jev proactively"). For days the GUI watchdog logged, at ERROR, on every
guest shutdown: "Process 'gui-agent.exe' (PID N) exited with code 0x40010004 without this service asking it
to - the agent DIED", then relaunched the agent into a session that was ending - three agent instances per
shutdown, each a vchan setup with dom0 - and nobody read it until a dom0 dialog forced a hunt. In the same
logs a REQUESTED stop ended with "WinMain: WatchForEvents failed with error 0xb7" at ERROR: a stale error
code on a clean exit. Both were visible in the logs after every run. This tool reads them after every run.

THE DIVISION OF LABOUR (CLAUDE.md; .claude/skills/jev/SKILL.md): everything deterministic is CODE here -
parsing, normalizing lines to SIGNATURES, counting per signature per log family per boot, joining watchdog
launches and deaths to the shutdown markers, the metric thresholds. Every SEMANTIC judgment - "is this NEW
signature a defect, expected behaviour or noise?", "does this count rise / metric breach indicate a
defect?" - goes to Jev (tools/jev.py), batched as ONE call per run with one question per item (chunked only
past --jev-max questions). jev.py exit 2 = the judge did not run = the sweep is INCOMPLETE, never a pass.

    tools/log-sweep.py decode   <pull.txt> --out <logsdir>
        verifies the collector's stream (mgmt/harness/log-sweep-collect.ps1: base64 blocks + sha256 + line
        counts, the proven transfer shape) and writes <logsdir>/files/*, events.txt, meta.json. A count or
        hash mismatch, a truncated block or a missing END line FAILS (rc 1) - trust counts, not streams.
    tools/log-sweep.py analyze  <logsdir> --baseline <baseline.json> --out <report.json>
                                [--summary <txt>] [--since <utc iso>] [--label <s>] [--workdir <dir>]
                                [--jev-cmd <cmd>] [--jev-max N] [--no-jev]
        <logsdir> is a decode output (meta.json present) or any directory of collected logs (corpus mode:
        families from file names / content). Exit codes: 0 CLEAN, 1 FINDINGS (a metric breach or a
        Jev-classified defect), 3 DATA (a missing, empty, partial or unparseable log), 4 INCOMPLETE (the
        judge did not run, or items were left unjudged). 3 and 4 are never a pass.
    tools/log-sweep.py baseline-init --out <baseline.json> [--known-defect 'REGEX=ISSUE=REASON']... <report.json>...
        builds / refreshes the tracked baseline from analyze reports: Jev's folded verdicts become the
        statuses (defect -> known-defect, expected -> expected, noise -> benign, low confidence -> unsettled),
        the per-boot maxima become the rise ceilings. The baseline holds normalized PATTERNS and a reason
        each - never captured log content (the repo is public).

LOG FORMATS (designed from the code that writes them):
  agent / watchdog / qrexec / qubesdb / misc windows-utils   [YYYYMMDD.HHMMSS.mmm-TID-L] Function: message
  bridge.log, etw-proxy.log (tools/notifhost/qtb_shared.h BLog)   HH:MM:SS message  (local time, no date)
  installer (packaging/setup/Install-QwtImproved.ps1 Write-Log)   yyyy-MM-dd HH:mm:ss [LEVEL] message
                                                                  + '=== RESULT === {json}' trailers
  msi (msiexec /l*v)                                              MSI (s) (NN:NN) [HH:MM:SS:mmm]: message
  events (the collector's lines)   EV yyyy-MM-dd HH:mm:ss.fff [LogName] id=N level=N Provider: message
  guid / qrexec-dom0 / console (dom0-side, when present in the dir)   plain lines / bracketed timestamps

Stdlib only. Python 3.8+.
"""
from __future__ import annotations

import argparse
import base64
import datetime as dt
import hashlib
import json
import os
import re
import subprocess
import sys
import time
from collections import Counter, defaultdict

VERSION = 1
MARK = "LSW "

# ----------------------------------------------------------------------------------------------- constants
# Which of our executables / services / tasks an event-log record must name to count as OURS.
OUR_EXES_RE = re.compile(
    r"(?i)\b(gui-agent|gui-watchdog|wgcbroker|notifhost|etwproxy|qrexec-agent|qrexec-wrapper|qrexec-client-vm|"
    r"qubesdb-daemon|qwtng-netsetup|network-setup|relocate-dir|set-gui-mode|file-receiver|qubes-updates-relay|"
    r"disable-autosleep|toastfire|winid|bind-dirs)(\.exe)?\b")
OUR_SERVICES_RE = re.compile(r"(?i)(QdbDaemon|QrexecAgent|QubesGuiWatchdog|QgaWatchdog|QwtngNetSetup|Qubes [A-Za-z ]*(DB|qrexec|GUI|PV NIC)|Qubes Windows Tools)")
OUR_TASKS_RE = re.compile(r"(?i)\\?(Qwt[A-Za-z]+|Qubes[A-Za-z]+)")

# INFO lines that are always worth a signature (the task's always-suspicious list, plus the words the agent
# and watchdog use for the same events).
SUSPICIOUS_RE = re.compile(
    r"(?i)\b(died|death|dies|relaunch\w*|restart\w*|crash\w*|fallback|falls back|falling back|timed out|timeout|"
    r"refus\w+|stuck|hung|hang\b|LOST|ANOMALY|A6LEAK|QGAHANDSHAKE|awaiting for a vchan client|vchan client has connected|"
    r"disconnect\w*|not running|going down|exited with code|is gone|asked '.*' to exit|preshutdown|terminat\w+|"
    r"backing off|deaf|withheld|not shown|unmapped unpainted|reaping|reap\b|wedge|exiting)\b")
# Levelless logs (bridge / etw-proxy / plain): E and W by vocabulary; a routine line that merely CONTAINS one of
# these words is still shown to Jev, which is the point.
BLOG_E_RE = re.compile(r"\b(FAIL|CRASH|ERROR|error|failed|Failed|SCHEMA MISMATCH|refusing)\b")
BLOG_W_RE = re.compile(r"(?i)\b(WARN|down|absent|disconnected|mismatch|fallback|refused|unavailable|lost|retry|"
                       r"not opened|not mapped|ignored|squatter|dropped|invalid|timeout|timed out|burst|sampling)\b")
# A COUNTER AT ZERO IS NOT A FAILURE. bind-dirs writes a key=value RESULT RECORD whose own first
# line is "result=ok", and the line "failed=0" in it was graded an ERROR because BLOG_E_RE matches
# the bare word "failed" - one of the eight undeclared error lines a clean cycle produced on
# win11r-logvol, 2026-10-08. Exactly the shape of the MSI rollback-plan defect: a token-based
# classifier calling a success a failure. A NON-zero counter is still an error, which is the point.
BLOG_ZERO_COUNTER_RE = re.compile(r"(?i)^\s*(failed|failures?|errors?|warnings?|faults?|drops?|dropped|lost|"
                                  r"refused|crashes?)\s*[=:]\s*(0+|0x0+|none|no)\s*$")
# ...AND A COUNTER THAT IS NOT ZERO *IS* A FAILURE, which the vocabulary missed: BLOG_E_RE has no
# plural, so "errors=12" matched nothing (\berror\b does not match inside "errors") and a result
# record reporting twelve failures was graded INFO. Found by the check written for the zero case.
BLOG_NONZERO_COUNTER_RE = re.compile(r"(?i)^\s*(failed|failures?|errors?|faults?|crashes?)\s*[=:]\s*"
                                     r"(?!0+\s*$)(?!0x0+\s*$)(\d+|0x[0-9a-f]+)\s*$")
STALE_ERR_RE = re.compile(r"failed with error 0x0\b")
MSI_SUSPECT_RE = re.compile(r"(Return value 3|Installation (failed|success or error status: [1-9])|Note: 1:|\bError \d+|-- Error|Failed to|rolled back|Rollback)")

# Lines that are not log lines and not a defect either: the cmd.exe banner a `type` pull carries, blanks,
# the previous instruments' prefixes, an installer JSON trailer (parsed separately).
IGNORE_LINE_RE = re.compile(r"^(\ufeff?\s*$|Microsoft Windows \[Version|\(c\) Microsoft Corporation|[A-Za-z]:\\.*>|THC |DR |E2EMARK-|=== PRECONDITION ===)")

# The event records the sweep keeps (the collector pre-filters the same way; a corpus pull may carry more).
EV_MARKER_IDS = {1074, 1076, 13, 6005, 6006, 6008, 6009, 6013}
EV_SERVICE_IDS = {7000, 7009, 7011, 7023, 7024, 7031, 7034, 7036, 7040, 7043, 7045}


def event_wanted(log, eid, provider, msg):
    if provider == "Qubes Windows Tools":
        return True
    if log == "System":
        if eid in EV_MARKER_IDS:
            return True
        if eid == 12 and provider == "Microsoft-Windows-Kernel-General":
            return True
        if eid == 1001 and "BugCheck" in provider:
            return True
        if eid == 41 and "Kernel-Power" in provider:
            return True
        if eid == 109 and "Kernel-Power" in provider:
            return True
        if eid in EV_SERVICE_IDS and OUR_SERVICES_RE.search(msg):
            return True
        return False
    if log == "Application":
        return eid in (1000, 1001, 1026) and bool(OUR_EXES_RE.search(msg))
    if "LocalSessionManager" in log:
        return eid in (21, 22, 23, 24, 25, 54)
    if "TaskScheduler" in log:
        return eid in (201, 203) and bool(OUR_TASKS_RE.search(msg))
    return False

# Two prefix shapes, both accepted: since 2026-10-07 the numbers are PID:TID (one log file per
# module, so a line has to say which process wrote it), and before that there was one number and
# it was the TID. Guests still hold logs in the old shape, so dropping it would blind the gate.
WINUTILS_RE = re.compile(r"^\ufeff?\[(\d{8})\.(\d{6})\.(\d{3})-(\d+)(?::(\d+))?-([IWEDV])\] (?:([A-Za-z0-9_]+): )?(.*)$")
BLOG_RE = re.compile(r"^\ufeff?(\d\d):(\d\d):(\d\d) (.*)$")
INSTALLER_RE = re.compile(r"^\ufeff?(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d) \[(INFO|WARN|ERROR|FATAL|DEBUG)\] (.*)$")
RESULT_RE = re.compile(r"^\ufeff?=== RESULT === (\{.*\})\s*$")
# How far the guest's clock may be from this host's UTC before a --since window is untrustworthy.
# The analyze runs within a minute or two of the collection, so this is generous and still catches
# the three-hour skew measured on win11r-logvol.
CLOCK_SKEW_TOLERANCE_S = 300

MSI_RE = re.compile(r"^\ufeff?MSI \([sc]\) \([0-9A-Fa-f:!]+\) \[(\d\d):(\d\d):(\d\d):(\d{3})\]: ?(.*)$")
EV_RE = re.compile(r"^EV (\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d{3}) \[([^\]]+)\] id=(\d+) level=(\d+) ([^:]*): ?(.*)$")
EV_NONE_RE = re.compile(r"^EV NONE \[([^\]]+)\]")
EV_ERR_RE = re.compile(r"^EV ERR \[([^\]]+)\] ?(.*)$")
CONSOLE_RE = re.compile(r"^\[(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\] ?(.*)$")
QREXEC_DOM0_RE = re.compile(r"^(\d{4})-(\d\d)-(\d\d) (\d\d):(\d\d):(\d\d)\.(\d+) qrexec-daemon\[\d+\]: (.*)$")

FAMILY_BY_NAME = [
    (re.compile(r"(?i)^gui-agent-\d{8}-\d{6}-\d+\.log$|^agent\d*\.log$|gui-agent.*\.log$"), "agent"),
    (re.compile(r"(?i)^gui-watchdog-.*\.log$|watchdog.*\.log$"), "watchdog"),
    (re.compile(r"(?i)^qrexec-(agent|wrapper|client-vm)-.*\.log$"), "qrexec"),
    (re.compile(r"(?i)^qubesdb-daemon-.*\.log$|^qubesdb.*\.log$"), "qubesdb"),
    (re.compile(r"(?i)^etw-proxy\.log(\.old)?$"), "etwproxy"),
    (re.compile(r"(?i)^bridge\.log(\.old)?$"), "bridge"),
    (re.compile(r"(?i)^qwt-(un)?install\.log$|msi-verbose\.log$|qwt-msi.*\.log$"), "msi"),
    (re.compile(r"(?i)qwt-improved-install\.log$|-final\.log$|-install\.log$"), "installer"),
    (re.compile(r"(?i)^guid\..*\.log$"), "guid"),
    (re.compile(r"(?i)^qrexec\..*\.log$"), "qrexec-dom0"),
    (re.compile(r"(?i)^guest-.*\.log$"), "console"),
    (re.compile(r"(?i)^events\.txt$"), "events"),
    (re.compile(r"(?i)^(network-setup|relocate-dir|set-gui-mode|file-receiver|qwtng-netsetup|disable-autosleep|qubes-updates-relay)-.*\.log$"), "winutils"),
    (re.compile(r"(?i)^bind-dirs.*\.(log|txt)$"), "binddirs"),
    # The PowerShell qrexec services log through core-agent/src/qubes-rpc-services/log.ps1, one
    # file per script per day: "<script>.ps1-YYYYMMDD.log". Their prefix now carries a pid, so
    # WINUTILS_RE matches and the content sniffer would reach the same answer - but by NAME is
    # deterministic, where sniffing depends on the first five lines of whichever file is read.
    (re.compile(r"(?i)^[A-Za-z0-9._-]+\.ps1-\d{8}\.log$"), "winutils"),
    (re.compile(r"(?i)^qwt-fi-.*\.txt$"), "marker"),
]
WINUTILS_FAMILIES = {"agent", "watchdog", "qrexec", "qubesdb", "winutils"}
BLOG_FAMILIES = {"bridge", "etwproxy", "blog"}
STRUCTURED_FAMILIES = WINUTILS_FAMILIES | BLOG_FAMILIES | {"installer", "events", "msi"}

# Structural thresholds: the owner's rules, as numbers, each with the severity its breach is reported at. A baseline
# may override any of them. P1 = a death of ours or a regression of a closed defect (owner policy 2026-10-07: "deslice
# broker deaths are P1"); P2 = everything else that must not happen.
DEFAULT_THRESHOLDS = {
    "agent_unrequested_deaths": {"max": 0, "severity": "P1", "why": "ADR-supervision 1: an unrequested death of ours is a major error"},
    "agent_deaths_at_shutdown": {"max": 0, "severity": "P1", "why": "a shutdown must stop the agent through the watchdog, never kill it"},
    "agent_relaunches_at_shutdown": {"max": 0, "severity": "P2", "why": "a relaunch into an ending session is the 2026-10-07 defect"},
    "error_lines_undeclared": {"max": 0, "severity": "P2", "why": "owner 2026-10-07: a clean error log is THE gate condition - any error line our own code wrote, and that this run did not declare it caused, is a defect to fix at its cause (never to hide)"},
    "declared_errors_unmatched": {"max": 0, "severity": "P2", "why": "a declared error that never appeared: the stimulus the run claims to have applied did not happen, so the run proved less than it says"},
    "agent_instances_per_shutdown": {"max": 1, "severity": "P2", "why": "one agent per shutdown; three = three vchan setups with dom0"},
    "agent_instances_per_boot": {"max": 1, "severity": "P2", "why": "the agent is started once per boot; a second instance is a death or a restart"},
    "agent_ends_unrecorded": {"max": 0, "severity": "P2", "why": "an agent log that stops with no requested stop and no death record"},
    "vchan_setups_per_shutdown": {"max": 0, "severity": "P2", "why": "no new vchan announcement while the guest is going down"},
    "vchan_announce_without_connect": {"max": 0, "severity": "P2", "why": "an announced vchan that dom0 never connected to"},
    "vchan_reconnects": {"max": 0, "severity": "P2", "why": "a second announcement in one instance is a reconnect"},
    "handshake_refusals": {"max": 0, "severity": "P2", "why": "QGAHANDSHAKE: messages refused before the version exchange"},
    "broker_deaths": {"max": 0, "severity": "P1", "why": "QGABROKERDIED outside a fault-injection context - owner policy 2026-10-07: a spontaneous de-slice broker death is P1 (findings/issues.md P1 'A SPONTANEOUS DE-SLICE BROKER DEATH OR HANG IS P1')"},
    "broker_hangs": {"max": 0, "severity": "P1", "why": "QGABROKERHUNG outside a fault-injection context (same policy)"},
    "fi_detection_missing": {"max": 0, "severity": "P1", "why": "an M8 injection record whose detection is absent (QGABROKERHUNG within 2 s of the next registration, then reap + relaunch): the test failing silently is the other half of M8"},
    "fi_context_unproven": {"max": 0, "severity": "P1", "why": "the run was declared fault-injection, but no log carries QGAFAULT-INIT and no injection record is in the capture: the test build / injection was not running (the rz24 lesson); nothing is excused"},
    "closed_defect_recurrence": {"max": 0, "severity": "P1", "why": "a signature whose issue the baseline records as CLOSED recurred: a regression"},
    "helper_deaths": {"max": 0, "severity": "P1", "why": "QGANOTIFBRIDGEEXIT / ETWPROXYSUP exited: the notification bridge or etwproxy died (the broker has its own metric)"},
    "helper_relaunches": {"max": 0, "severity": "P2", "why": "a helper launched more than once in one agent instance (broker relaunches after an injected hang excluded)"},
    "requested_stop_nonzero_exit": {"max": 0, "severity": "P2", "why": "a requested stop must exit 0 (the 0xb7 case)"},
    "errors_during_requested_stop": {"max": 0, "severity": "P2", "why": "no ERROR line between the watchdog's 'asked to exit' and 'is gone'"},
    "stale_error_lines": {"max": 0, "severity": "P2", "why": "'failed with error 0x0: The operation completed successfully' is a stale error code"},
    "watchdog_fast_death_backoffs": {"max": 0, "severity": "P2", "why": "the agent died within 10 s of launch, or a launch failed"},
    "service_failures": {"max": 0, "severity": "P1", "why": "System 7023/7024/7031/7034/7043 for one of our services"},
    "wer_crashes": {"max": 0, "severity": "P1", "why": "Application 1000/1001/1026 for one of our executables"},
    "death_events": {"max": 0, "severity": "P1", "why": "Application 4001-4004 under 'Qubes Windows Tools': a supervisor recorded a death"},
    "death_record_mismatch": {"max": 0, "severity": "P2", "why": "a watchdog death line without its 4001 record, or a 4001 without the line (ADR-supervision 2)"},
    "unexpected_shutdowns": {"max": 0, "severity": "P1", "why": "System 6008 / Kernel-Power 41: the previous shutdown was not clean"},
    "bugchecks": {"max": 0, "severity": "P1", "why": "System 1001 BugCheck"},
    "task_failures": {"max": 0, "severity": "P2", "why": "TaskScheduler 201/203 for one of our tasks"},
    "fallbacks_fired": {"max": 0, "severity": "P2", "why": "project rule: a fallback firing is an anomaly, logged loudly and diagnosed"},
    "rise_factor": 2.0,
    "rise_min_delta": 3,
}
INFORMATIONAL_METRICS = ["error_lines", "warning_lines", "agent_instances", "boots", "shutdowns", "agent_going_down_exits",
                         "deaths_by_exit_code", "broker_events_excused", "fi_records"]
SEVERITY_ORDER = {"P1": 0, "P2": 1, "P3": 2}

# FAULT-INJECTION CONTEXT - decided from EVIDENCE in the capture, never from a file name (coordinator, 2026-10-07):
#   * the QGAFAULT-INIT banner (faultinject.c FiInit: "loud unconditionally" on a fault-capable agent build) -> that
#     agent INSTANCE is a test build; every line of it is in FI context;
#   * an M8 injection record the harness captured (scratchpad/design-wf/m8-suspend.ps1 prints
#     "M8|name=<proc>|pid=<n>|suspend=<rc>|t=HH:mm:ss.fff" and "...|resume=<rc>|t=...|alive=<bool>"): the broker hang /
#     death / reap / recovery that falls inside that suspension, for that pid, is the injected one;
#   * the explicit flag the rig wrapper passes (log-sweep.sh --fault-injection -> context.json): DECLARES the context,
#     so the M8 rule set applies, but it excuses nothing by itself - a declared run with neither banner nor record is a
#     breach (fi_context_unproven), because that is a test that did not run its test build.
# Unknown is NOT fault injection: a broker death with no evidence of an injection is a real death, P1.
FI_BANNER_RE = re.compile(r"QGAFAULT-INIT build=")
FI_ARMED_RE = re.compile(r"QGAFAULT-INIT FAULTS ARE ARMED")
M8_RE = re.compile(r"^M8\|name=([A-Za-z0-9_.-]+)\|pid=(\d+)\|(suspend|resume)=(-?\d+)\|t=(\d\d):(\d\d):(\d\d)(?:\.(\d{1,3}))?(?:\|alive=(\w+))?")
BROKER_HUNG_RE = re.compile(r"^QGABROKERHUNG ")
BROKER_DIED_RE = re.compile(r"^QGABROKERDIED .*?pid was (\d+)")
BROKER_REAP_RE = re.compile(r"^QGABROKERREAP terminating hung de-slice broker pid (\d+)")
BROKER_BACK_RE = re.compile(r"^QGABROKERBACK ")
BROKER_REG_RE = re.compile(r"^QGABROKERREG hwnd=0x[0-9a-fA-F]+ slot=(\d+)")
M8_DETECT_S = 2.5      # docs/DESIGN-rest-zero-capture.md M8: QGABROKERHUNG within 2 s of the next registration (+0.5 s slack)
M8_RECOVER_S = 10.0    # then the reap and the relaunch (QGABROKERREAP, QGABROKERBACK) within 10 s
M8_RECORD_SLACK_S = 5.0

# The issue references the tracked baseline MUST carry (the audit: `log-sweep.py baseline-audit`). Each row: a regex
# over signature keys, the status the matching entries must have (None = any), and either an issue substring or the
# context the entries must declare. A baseline that lost one of these is refused.
REQUIRED_REFS = [
    (r"QGABROKERDIED de-slice broker STOPPED HEARTBEATING", "known-defect", {"issue": "broker-heartbeat-reap (CLOSED 2026-09-27"}),
    (r"QGABROKERHUNG de-slice broker process is still RUNNING", "expected", {"context": "fault-injection"}),
    (r"QGABROKERDIED de-slice broker STOPPED SERVING", "expected", {"context": "fault-injection"}),
    (r"QGABROKERREAP terminating hung de-slice broker", "expected", {"context": "fault-injection"}),
    (r"QGABROKERBACK de-slice broker RECOVERED", "expected", {"context": "fault-injection"}),
    (r"AcquireNextFrame\(\) failed with error 0xH: The keyed mutex was abandoned", None, {"issue": "0x887a0026"}),
    (r"QGAWGCRECREATE", None, {"issue": "M7"}),
]

OWNER_PREMISES = """PREMISES (the owner's standing rules; judge against them, not against general log-reading habits):
1. Anything of ours that dies unexpectedly is a MAJOR ERROR and must be loud (docs/ADR-supervision.md 1). A relaunch is never a quiet recovery.
2. A REQUESTED stop (the watchdog asked the agent to exit via Global\\QGA_SHUTDOWN) must be clean: exit code 0, no ERROR lines. An ERROR logged on a requested stop that carries a stale error code (0x0 "The operation completed successfully", or a leftover code such as 0xb7) is a defect of the exit path, not noise.
3. At shutdown exactly one agent instance should exist and the watchdog should stop it. The agent dying with 0x40010004 when the session ends and being relaunched into the ending session (three instances per shutdown, each a vchan setup with dom0) is a KNOWN DEFECT being fixed now.
4. Fallbacks are anomalies: a fallback FIRING is logged loudly and diagnosed, never routine. A fallback REFUSED (e.g. "composite fallback refused") is the designed behaviour.
5. Capabilities are decided at START (CLAUDE.md): a component that was working and stops is a FAILURE of an eligible system, never a capability change.
6. Definitions: DEFECT = evidence of misbehaviour in our components or their supervision, or a log line that misstates what happened. EXPECTED = designed behaviour that is correct in this context (a correct ERROR record of a real death is EXPECTED behaviour of the recorder - the death itself is judged under its own item). NOISE = a line carrying no information about health. INSUFFICIENT-EVIDENCE = the excerpt cannot settle it; say so rather than guess.
7. Judge only from the facts under each item. A line is not a defect merely because it is logged at ERROR, nor expected merely because it recurs.
"""


# ----------------------------------------------------------------------------------------------- helpers
def utcnow_iso():
    return dt.datetime.now(dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse_iso(s):
    """Accept 2026-10-07T08:00:00Z, 2026-10-07T08:00:00.123Z, '2026-10-07 08:00:00[.fff]'; returns a naive datetime."""
    if not s:
        return None
    s = s.strip().replace("T", " ").rstrip("Z")
    for fmt in ("%Y-%m-%d %H:%M:%S.%f", "%Y-%m-%d %H:%M:%S"):
        try:
            return dt.datetime.strptime(s, fmt)
        except ValueError:
            pass
    raise ValueError("unparseable time: %r" % s)


def fmt_ts(t):
    return t.strftime("%Y-%m-%d %H:%M:%S.%f")[:-3] if t else "-"


def kv_parse(s):
    out = {}
    for tok in s.split():
        if "=" in tok:
            k, v = tok.split("=", 1)
            out[k] = v
    return out


def b64dec_path(v):
    try:
        return base64.b64decode(v).decode("utf-8", errors="replace")
    except Exception:
        return v


# ----------------------------------------------------------------------------------------------- normalize
_NORM_RULES = [
    (re.compile(r"S-1-5-21(-\d+)+"), "SID"),
    (re.compile(r"S-1-5-\d+"), "SID"),
    (re.compile(r"\{?[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\}?"), "GUID"),
    (re.compile(r"\?\d{4}\?-\?\d\d\?-\?\d\dT[\d:.]+Z?"), "TS"),
    (re.compile(r"\d{4}-\d\d-\d\d[T ]\d\d:\d\d:\d\d(\.\d+)?(Z|[+-]\d\d:?\d\d)?"), "TS"),
    (re.compile(r"\d{8}\.\d{6}\.\d{3}"), "TS"),
    (re.compile(r"\b\d{1,2}:\d\d:\d\d(\.\d+)?\b"), "TS"),
    (re.compile(r"(?i)[A-Z]:\\Users\\[^\\\s]+"), lambda m: "C:\\Users\\USER"),
    (re.compile(r"\b(WIN1[01][A-Z0-9]*-[A-Z0-9-]+|WIN-[A-Z0-9]{6,})\b"), "HOST"),
    (re.compile(r"(Fullscreen desktop name: )\S+"), r"\1VM"),
    (re.compile(r"(?i)(QubesIncoming\\)[^\\\s]+"), r"\1SRC"),
    # a ZERO exit / error code is a different fact from a non-zero one (a requested stop that exits 0 is the designed
    # path; 0xb7 is the defect) - keep that distinction before every other hex is folded into 0xH
    (re.compile(r"\b(exit(?:ed with)? code) 0x0\b"), r"\1 ZERO"),
    (re.compile(r"\b0x[0-9A-Fa-f]+"), "0xH"),
    (re.compile(r"\b\d+x\d+\b"), "NxN"),                        # window / screen sizes
    (re.compile(r"\b[0-9A-Fa-f]*[A-Fa-f][0-9A-Fa-f]*\b(?<=[0-9A-Fa-f]{8})"), "H"),   # 8+ hex chars with a letter
    (re.compile(r"\b\d{8,}\b"), "H"),
    (re.compile(r"-?\b\d+(\.\d+)?\b"), "N"),
    (re.compile(r"\s+"), " "),
]


def normalize(msg):
    s = msg
    for rx, rep in _NORM_RULES:
        s = rx.sub(rep, s)
    s = s.strip()
    return s[:220]


# ----------------------------------------------------------------------------------------------- the model
class Line:
    __slots__ = ("family", "file", "idx", "ts", "level", "func", "msg", "raw", "boot", "extra", "fi")

    def __init__(self, family, file, idx, ts, level, func, msg, raw, extra=None):
        self.family, self.file, self.idx, self.ts, self.level, self.func, self.msg, self.raw = family, file, idx, ts, level, func, msg, raw
        self.boot = None
        self.extra = extra or {}
        self.fi = False          # in a fault-injection context (set by build_structure from evidence)

    def key(self):
        if self.family == "events":
            e = self.extra
            return "event|%s|%s|%s|%s|%s" % (self.level, e.get("log"), e.get("id"), e.get("provider"), normalize(self.msg))
        if self.func:
            return "%s|%s|%s: %s" % (self.family, self.level, self.func, normalize(self.msg))
        return "%s|%s|%s" % (self.family, self.level, normalize(self.msg))


class LogFile:
    def __init__(self, path, name, family):
        self.path, self.name, self.family = path, name, family
        self.lines = []          # Line objects (every parsed line, all levels)
        self.scanned = 0         # raw lines read
        self.ignored = 0         # banner / blank / known non-log lines
        self.unparsed = 0        # lines the family parser did not understand
        self.skipped = 0         # structured lines deliberately not kept (msi routine, console routine)
        self.partial = False
        self.total_lines = None
        self.written = None      # the collector's LastWriteTime (local), for dating BLog lines
        self.problems = []
        # windows-utils instance facts. ONE FILE CAN HOLD SEVERAL PROCESSES since 2026-10-07 (one
        # file per module per day), so the single-value fields below are the LAST init's and are a
        # hint only; `inits` is the real record and `pid` on each LINE is what identifies a process.
        self.inits = []          # [{"ts","pid","uptime_s","boot_time","session","version"}] in order
        self.pid = None
        self.session = None
        self.version = None
        self.uptime_s = None
        self.boot_time = None
        self.boot = None


def family_of(name, hint=None, first_lines=None):
    if hint and hint != "auto":
        return hint
    for rx, fam in FAMILY_BY_NAME:
        if rx.search(name):
            return fam
    for ln in first_lines or []:
        if WINUTILS_RE.match(ln):
            return "winutils"
        if INSTALLER_RE.match(ln):
            return "installer"
        if BLOG_RE.match(ln):
            return "blog"
        if ln.startswith("EV "):
            return "events"
        if MSI_RE.match(ln):
            return "msi"
    return "plain"


def read_lines(path):
    with open(path, "rb") as f:
        data = f.read()
    for enc in ("utf-8-sig", "utf-16"):
        try:
            text = data.decode(enc)
            if enc == "utf-16" and not (data[:2] in (b"\xff\xfe", b"\xfe\xff")):
                continue
            break
        except UnicodeDecodeError:
            continue
    else:
        text = data.decode("utf-8", errors="replace")
    return text.replace("\r\n", "\n").replace("\r", "\n").split("\n")


# ----------------------------------------------------------------------------------------------- parsers
def parse_winutils(lf, raw_lines):
    prev = None
    for i, raw in enumerate(raw_lines):
        lf.scanned += 1
        m = WINUTILS_RE.match(raw)
        if not m:
            if IGNORE_LINE_RE.match(raw) or raw.strip() == "":
                lf.ignored += 1
            elif prev is not None and (raw.startswith(" ") or raw.startswith("\t")):
                prev.msg += " " + raw.strip()      # continuation of a multi-line message
            else:
                lf.unparsed += 1
            continue
        d, t, ms, n1, n2, lvl, func, msg = m.groups()
        pid, tid = (n1, n2) if n2 else ("", n1)   # one number means the old shape: it is the tid
        try:
            ts = dt.datetime(int(d[0:4]), int(d[4:6]), int(d[6:8]), int(t[0:2]), int(t[2:4]), int(t[4:6]), int(ms) * 1000)
        except ValueError:
            lf.unparsed += 1
            continue
        ln = Line(lf.family, lf.name, i, ts, lvl, func or "", msg, raw, {"tid": tid, "pid": pid})
        lf.lines.append(ln)
        prev = ln
        if func == "LogInit":
            mm = re.match(r"Running as user: .*, process ID: (\d+)", msg)
            if mm:
                lf.pid = int(mm.group(1))
                # A NEW init record is a NEW PROCESS in this file, not an update to the old one.
                lf.inits.append({"ts": ts, "pid": lf.pid, "uptime_s": None, "boot_time": None,
                                 "session": None, "version": None})
            mm = re.match(r"System uptime: ([\d.]+) seconds", msg)
            if mm:
                lf.uptime_s = float(mm.group(1))
                lf.boot_time = ts - dt.timedelta(seconds=lf.uptime_s)
                if lf.inits:
                    lf.inits[-1]["uptime_s"] = lf.uptime_s
                    lf.inits[-1]["boot_time"] = lf.boot_time
            mm = re.match(r"Session: (\d+)", msg)
            if mm:
                lf.session = int(mm.group(1))
                if lf.inits:
                    lf.inits[-1]["session"] = lf.session
            mm = re.match(r"Module version: (\S+)", msg)
            if mm:
                lf.version = mm.group(1)
                if lf.inits:
                    lf.inits[-1]["version"] = lf.version
    if lf.pid is None:
        # ONLY the old per-process name shape carries a pid: "<module>-<yyyymmdd>-<hhmmss>-<pid>.log".
        # The current shape is "<module>-<yyyymmdd>.log", and `-(\d+)\.log$` read that DATE as a
        # process id - 20261007 - which then keyed every per-instance death and stop join.
        mm = re.search(r"-\d{8}-\d{6}-(\d+)\.log$", lf.name)
        if mm:
            lf.pid = int(mm.group(1))


def blog_level(msg):
    # the zero-counter check comes FIRST: "failed=0" is a success record's own accounting
    if BLOG_ZERO_COUNTER_RE.match(msg):
        return "I"
    if BLOG_NONZERO_COUNTER_RE.match(msg):
        return "E"
    if BLOG_E_RE.search(msg):
        return "E"
    if BLOG_W_RE.search(msg):
        return "W"
    return "I"


def parse_blog(lf, raw_lines, anchor):
    """HH:MM:SS lines. Dated backwards from `anchor` (the file's LastWriteTime, or the capture time): the last
    line's time of day is <= the anchor's (else it was the day before); every earlier line whose time of day is
    later than its successor's is a day earlier again. Without an anchor the lines stay undated."""
    items = []
    for i, raw in enumerate(raw_lines):
        lf.scanned += 1
        m = BLOG_RE.match(raw)
        if not m:
            if IGNORE_LINE_RE.match(raw) or raw.strip() == "":
                lf.ignored += 1
            else:
                lf.unparsed += 1
            continue
        hh, mi, ss, msg = m.groups()
        items.append((i, int(hh), int(mi), int(ss), msg, raw))
    date = anchor.date() if anchor else None
    nxt_tod = anchor.time() if anchor else None
    dated = [None] * len(items)
    for j in range(len(items) - 1, -1, -1):
        i, hh, mi, ss, msg, raw = items[j]
        tod = dt.time(hh, mi, ss)
        if date is not None:
            if nxt_tod is not None and tod > nxt_tod:
                date = date - dt.timedelta(days=1)
            dated[j] = dt.datetime.combine(date, tod)
            nxt_tod = tod
    for j, (i, hh, mi, ss, msg, raw) in enumerate(items):
        lf.lines.append(Line(lf.family, lf.name, i, dated[j], blog_level(msg), "", msg, raw))


def parse_installer(lf, raw_lines):
    run = 0
    for i, raw in enumerate(raw_lines):
        lf.scanned += 1
        m = INSTALLER_RE.match(raw)
        if m:
            y, mo, d, hh, mi, ss, lvl, msg = m.groups()
            ts = dt.datetime(int(y), int(mo), int(d), int(hh), int(mi), int(ss))
            level = {"INFO": "I", "WARN": "W", "ERROR": "E", "FATAL": "E", "DEBUG": "D"}[lvl]
            if msg.startswith("run id:"):
                run += 1
            lf.lines.append(Line(lf.family, lf.name, i, ts, level, "", msg, raw, {"run": run, "fatal": lvl == "FATAL"}))
            continue
        m = RESULT_RE.match(raw)
        if m:
            try:
                r = json.loads(m.group(1))
            except ValueError:
                lf.unparsed += 1
                continue
            ok = r.get("ok")
            stage = r.get("stage", "?")
            err = r.get("error") or ""
            ts = lf.lines[-1].ts if lf.lines else None
            if ok is True:
                lf.lines.append(Line(lf.family, lf.name, i, ts, "I", "RESULT", "stage=%s ok=true" % stage, raw[:300], {"run": run}))
            else:
                detail = r.get("detail") or {}
                flags = sorted(k for k, v in detail.items() if isinstance(v, str) and re.search(r"(?i)fail|error|refused|missing|not ", v))
                lf.lines.append(Line(lf.family, lf.name, i, ts, "E", "RESULT",
                                     "stage=%s ok=false error=%s flags=%s" % (stage, err, ",".join(flags) or "-"), raw[:300], {"run": run}))
            continue
        if IGNORE_LINE_RE.match(raw) or raw.strip() == "":
            lf.ignored += 1
        elif lf.lines and (raw.startswith(" ") or raw.startswith("\t")):
            lf.lines[-1].msg += " " + raw.strip()
        else:
            lf.unparsed += 1


def parse_msi(lf, raw_lines, anchor_date):
    """Only the few lines that can carry a failure; everything else in a verbose MSI log is routine."""
    for i, raw in enumerate(raw_lines):
        lf.scanned += 1
        m = MSI_RE.match(raw)
        if not m:
            if raw.strip() == "" or IGNORE_LINE_RE.match(raw) or raw.startswith(" ") or raw.startswith("=== ") or raw.startswith("Property(") or raw.startswith("MSI (") or raw.startswith("Action "):
                lf.ignored += 1
            else:
                lf.skipped += 1
            continue
        hh, mi, ss, ms, msg = m.groups()
        ts = dt.datetime.combine(anchor_date, dt.time(int(hh), int(mi), int(ss), int(ms) * 1000)) if anchor_date else None
        if MSI_SUSPECT_RE.search(msg):
            # "Rollback" ALONE matched the rollback actions EVERY MSI install schedules up front in
            # case something fails - ActionStart(Name=MsiRollbackInstall),
            # CustomActionSchedule(Action=...Rollback...), RollbackInfo(...), the property adds, the
            # MSI_LUA privilege notices. Measured 2026-10-08 on a VERIFIED-SUCCESSFUL 4.3.36 upgrade
            # (installed hash == the package reference, one product, right version): 168 of the run's
            # 171 error lines were those, drowning the three that were real. A rollback that actually
            # RAN says "rolled back"; an action that failed says "Return value 3"; the engine says
            # "MainEngineThread is returning <nonzero>".
            level = "E" if re.search(r"Return value 3|Installation failed|error status: [1-9]|rolled back"
                                     r"|MainEngineThread is returning [1-9]", msg) else "W"
            lf.lines.append(Line(lf.family, lf.name, i, ts, level, "", msg, raw))
        else:
            lf.skipped += 1


def parse_events(lf, raw_lines):
    for i, raw in enumerate(raw_lines):
        lf.scanned += 1
        m = EV_RE.match(raw)
        if m:
            y, mo, d, hh, mi, ss, ms, log, eid, lvl, prov, msg = m.groups()
            ts = dt.datetime(int(y), int(mo), int(d), int(hh), int(mi), int(ss), int(ms) * 1000)
            lvl = int(lvl)
            level = "E" if lvl in (1, 2) else ("W" if lvl == 3 else "I")
            if not event_wanted(log, int(eid), prov.strip(), msg):
                lf.skipped += 1
                continue
            lf.lines.append(Line(lf.family, lf.name, i, ts, level, "", msg, raw, {"log": log, "id": int(eid), "provider": prov.strip(), "evlevel": lvl}))
            continue
        m = EV_NONE_RE.match(raw)
        if m:
            lf.ignored += 1
            lf.problems.append(("events-none", m.group(1)))
            continue
        m = EV_ERR_RE.match(raw)
        if m:
            lf.ignored += 1
            lf.problems.append(("events-err", "%s: %s" % (m.group(1), m.group(2))))
            continue
        if raw.strip() == "" or IGNORE_LINE_RE.match(raw):
            lf.ignored += 1
        else:
            lf.unparsed += 1


def parse_plain(lf, raw_lines, family):
    for i, raw in enumerate(raw_lines):
        lf.scanned += 1
        if raw.strip() == "" or IGNORE_LINE_RE.match(raw):
            lf.ignored += 1
            continue
        ts, msg = None, raw
        if family == "console":
            m = CONSOLE_RE.match(raw)
            if m:
                y, mo, d, hh, mi, ss, msg = m.groups()
                ts = dt.datetime(int(y), int(mo), int(d), int(hh), int(mi), int(ss))
                if not msg.strip() or re.match(r"^(\[ATTACHED\]|\[DETACHED\]|Logfile Opened|\S+ login: ?)$", msg.strip()):
                    lf.skipped += 1
                    continue
        elif family == "qrexec-dom0":
            m = QREXEC_DOM0_RE.match(raw)
            if m:
                y, mo, d, hh, mi, ss, frac, msg = m.groups()
                ts = dt.datetime(int(y), int(mo), int(d), int(hh), int(mi), int(ss), int((frac + "000000")[:6]))
                if "client sent MSG_DATA_STDOUT" in msg:
                    lf.skipped += 1
                    continue
            elif re.match(r"^(Next ID is \d+, mapping to host ID \d+|Entering loop|Server capabilities:|Unknown capability )", raw):
                lf.skipped += 1
                continue
        elif family == "guid":
            pass
        level = blog_level(msg)
        if family in ("console", "qrexec-dom0") and level == "I" and not SUSPICIOUS_RE.search(msg):
            lf.skipped += 1
            continue
        if family == "guid":
            if re.search(r"Failed|dead|failed", msg):
                level = "E"
            elif re.search(r"EOF|eof", msg):
                level = "W"
        lf.lines.append(Line(family, lf.name, i, ts, level, "", msg.strip(), raw))


def parse_marker(lf, raw_lines):
    """A harness-captured marker file: the M8 injection records it carries (other lines are ignored, not unparsed)."""
    for i, raw in enumerate(raw_lines):
        lf.scanned += 1
        m = M8_RE.match(raw.strip())
        if not m:
            lf.ignored += 1
            continue
        name, pid, kind, rc, hh, mi, ss, ms, alive = m.groups()
        tod = dt.time(int(hh), int(mi), int(ss), int((ms or "0").ljust(3, "0")) * 1000)
        lf.lines.append(Line("marker", lf.name, i, None, "I", "M8", raw.strip(), raw,
                             {"name": name, "pid": int(pid), "kind": kind, "rc": int(rc), "tod": tod, "alive": alive}))


def has_m8_records(raw_lines):
    return any(M8_RE.match(l.strip()) for l in raw_lines[:2000])


def parse_file(lf, raw_lines, anchor):
    fam = lf.family
    if fam == "marker":
        parse_marker(lf, raw_lines)
    elif fam in WINUTILS_FAMILIES:
        parse_winutils(lf, raw_lines)
    elif fam in BLOG_FAMILIES:
        parse_blog(lf, raw_lines, anchor)
    elif fam == "installer":
        parse_installer(lf, raw_lines)
    elif fam == "msi":
        parse_msi(lf, raw_lines, anchor.date() if anchor else None)
    elif fam == "events":
        parse_events(lf, raw_lines)
    else:
        parse_plain(lf, raw_lines, fam)


# ----------------------------------------------------------------------------------------------- loading
def load_context(logsdir):
    """context.json (written by the rig wrapper for --fault-injection) - a DECLARATION, not evidence."""
    p = os.path.join(logsdir, "context.json")
    if not os.path.exists(p):
        return {"declared": False, "source": None, "declared_errors": []}
    try:
        with open(p, encoding="utf-8") as f:
            c = json.load(f)
        # declared_errors: [{"pattern": "<regex>", "why": "<the stimulus that caused it>"}]. A DECLARATION
        # BELONGS TO THE RUN THAT CAUSED THE ERROR, never to a global list of errors we have decided to live
        # with - that is the difference between a stimulus and hiding (owner 2026-10-07: "you should not HIDE
        # it, you should find out why it is there and how to get rid of its cause properly"; Jev: a baseline
        # exemption for the gate IS hiding, 0.64).
        de = c.get("declared_errors") or []
        if not isinstance(de, list):
            de = []
        return {"declared": bool(c.get("fault_injection_declared") or c.get("fault_injection")),
                "source": c.get("source"), "declared_errors": de}
    except (OSError, ValueError) as e:
        return {"declared": False, "source": "context.json unreadable: %s" % e, "declared_errors": []}


def load_logs(logsdir):
    """Returns (meta, [LogFile], problems). meta is the decode's meta.json or None (corpus mode)."""
    problems = []
    meta = None
    mp = os.path.join(logsdir, "meta.json")
    if os.path.exists(mp):
        with open(mp, encoding="utf-8") as f:
            meta = json.load(f)
    files = []
    now = None
    # harness-captured markers (log-sweep.sh --marker FILE copies them here; a corpus directory may hold them anywhere)
    mdir = os.path.join(logsdir, "markers")
    if os.path.isdir(mdir):
        for n in sorted(os.listdir(mdir)):
            p = os.path.join(mdir, n)
            if os.path.isfile(p):
                files.append(LogFile(p, n, "marker"))
    if meta:
        now = parse_iso((meta.get("begin") or {}).get("now", "").replace("T", " ")) if (meta.get("begin") or {}).get("now") else None
        for fe in meta.get("files", []):
            local = fe.get("local")
            path = os.path.join(logsdir, local) if local else None
            name = os.path.basename(b64dec_path(fe.get("pathb64", "")) or local or "?")
            lf = LogFile(path, name, family_of(name, fe.get("family")))
            lf.partial = str(fe.get("partial", "0")) == "1"
            lf.total_lines = int(fe.get("total_lines", fe.get("lines", 0)) or 0)
            lf.written = parse_iso(fe["written"]) if fe.get("written") else None
            if not path or not os.path.exists(path):
                problems.append(("missing", name, "listed by the collector but absent from the decode output"))   # GUARD:missing DEFECT: pass
                continue
            if int(fe.get("lines", 0) or 0) == 0 and os.path.getsize(path) == 0:
                problems.append(("empty", name, "the collector found this log empty (0 lines)"))   # GUARD:empty DEFECT: pass
            if lf.partial:
                problems.append(("partial", name, "over the collector's size cap: head + W/E/suspicious lines + tail only (%s lines in the file)" % lf.total_lines))
            files.append(lf)
        for fe in meta.get("fileerrs", []):
            problems.append(("fileerr", b64dec_path(fe.get("pathb64", "?")), fe.get("error", "?")))
        if meta.get("skipped") and int(meta["skipped"].get("n", 0)) > 0:
            # THE NAMES, NOT JUST THE COUNT (2026-10-07). "skipped n=5" could not say whether an agent or watchdog log
            # had been dropped, so a verdict of "zero deaths" rested on cross-referencing pids by hand. The collector
            # now sends the names; a dropped log from a family that DECIDES a verdict is a far worse problem than a
            # dropped qrexec-wrapper, and it is called out as such.
            names = []
            b64 = meta["skipped"].get("namesb64") or ""
            for part in [x for x in b64.split(",") if x]:
                try:
                    names.append(base64.b64decode(part).decode("utf-8", "replace"))
                except Exception:
                    names.append("(undecodable)")
            verdict = [n for n in names if n.startswith(("gui-agent-", "gui-watchdog-")) or "install" in n.lower()]
            shown = ", ".join(names[:8]) + (" ..." if len(names) > 8 else "")
            if verdict:
                problems.append(("skipped-verdict", "%d file(s) INCLUDING %d that decide a verdict" % (len(names), len(verdict)),
                                 "the collector hit its file cap and dropped: " + ", ".join(verdict[:6]) +
                                 " - a metric computed without these is not evidence"))
            else:
                problems.append(("skipped", "%s files" % meta["skipped"].get("n"),
                                 "the collector hit its file cap; no agent, watchdog or installer log was dropped" +
                                 (" (dropped: %s)" % shown if shown else "")))
        ev = meta.get("events") or {}
        if ev.get("required_missing") and ev.get("required_missing") != "-":
            problems.append(("events-required", ev["required_missing"], "a required event channel could not be read"))
        evp = os.path.join(logsdir, "events.txt")
        if os.path.exists(evp):
            lf = LogFile(evp, "events.txt", "events")
            files.append(lf)
        elif meta.get("events") is not None:
            problems.append(("missing", "events.txt", "the collector announced an event block but none was decoded"))
        if not meta.get("end"):
            problems.append(("truncated", "stream", "the collector's END line is missing - the pull was cut short"))
    else:
        for root, _dirs, names in os.walk(logsdir):
            if os.path.basename(root) == "markers":
                continue
            for n in sorted(names):
                if n in ("meta.json", "pull.txt", "report.json", "summary.txt", "decode.txt", "context.json") or n.endswith((".json", ".png", ".tar")):
                    continue
                p = os.path.join(root, n)
                if os.path.getsize(p) == 0:
                    problems.append(("empty", n, "0 bytes"))   # (corpus mode: the same gate, no collector table to compare against)
                files.append(LogFile(p, n, family_of(n)))
    for lf in files:
        if not lf.path or not os.path.exists(lf.path):
            continue
        raw = read_lines(lf.path)
        if raw and raw[-1] == "":
            raw = raw[:-1]
        if lf.family == "plain":
            lf.family = family_of(lf.name, None, raw[:5])
        if lf.family in ("plain", "console", "binddirs") and has_m8_records(raw):
            lf.family = "marker"      # evidence is the RECORD in the file, whatever the file is called
        anchor = lf.written or now
        if anchor is None and lf.family in BLOG_FAMILIES | {"msi"}:
            # corpus mode: date BLog lines from the newest windows-utils line in the same directory, if any
            anchor = None
        parse_file(lf, raw, anchor)
        structured = lf.family in STRUCTURED_FAMILIES
        kept = len(lf.lines) + lf.skipped
        if structured and kept == 0 and (lf.scanned - lf.ignored) > 0:
            problems.append(("unparseable", lf.name, "%d lines, none in the %s format" % (lf.scanned, lf.family)))
        elif structured and lf.unparsed > max(5, 0.1 * max(1, lf.scanned)):
            problems.append(("unparseable", lf.name, "%d of %d lines not in the %s format" % (lf.unparsed, lf.scanned, lf.family)))
        if lf.family == "events":
            for kind, what in lf.problems:
                if kind == "events-err":
                    problems.append(("events-err", what.split(":")[0], what))
    # corpus mode: give undated BLog files an anchor from the directory's newest dated line
    newest = max((l.ts for lf in files for l in lf.lines if l.ts), default=None)
    for lf in files:
        if lf.family in BLOG_FAMILIES and lf.lines and all(l.ts is None for l in lf.lines) and newest:
            raw = read_lines(lf.path)
            if raw and raw[-1] == "":
                raw = raw[:-1]
            lf.lines = []
            lf.scanned = lf.ignored = lf.unparsed = 0
            parse_blog(lf, raw, newest)
    return meta, files, problems


# ----------------------------------------------------------------------------------------------- structure
def cluster_boots(files):
    """Boot times from every windows-utils log (first ts - uptime) and from System 6013/6005; clustered at 150 s."""
    # TOLERANCE. Measured 2026-10-07: this was 150 s, and a test guest boots in ~55 s and is shut down ~30 s after
    # its session comes up - so consecutive boots are 90-110 s apart and TWO REAL BOOTS MERGED INTO ONE. The retest
    # then read as "3 agent instances in one boot" when the logs plainly showed one instance per boot, five boots in
    # a row: a grader artefact that would have been filed against the product. An estimate from a log's own
    # "System uptime" (or System 6013, which states the uptime) is accurate to about a second, so same-boot
    # estimates differ only by clock jitch; 45 s is far beyond that and far below a cycle here.
    #
    # PRECISION MATTERS TOO: the 6005 estimate (the Event Log service started) is a guess at boot - 45 s, which can
    # be tens of seconds out, so it may only JOIN a cluster an exact estimate opened. Letting it open one split a
    # single boot in two, which is the same defect in the other direction.
    BOOT_TOL_S = 45
    est = []
    for lf in files:
        if lf.boot_time:
            est.append((lf.boot_time, lf, True))
        if lf.family == "events":
            for l in lf.lines:
                if l.extra.get("log") == "System" and l.extra.get("id") == 6013:
                    m = re.search(r"uptime is (\d+) seconds", l.msg)
                    if m:
                        est.append((l.ts - dt.timedelta(seconds=int(m.group(1))), None, True))
                elif l.extra.get("log") == "System" and l.extra.get("id") == 6005:
                    est.append((l.ts - dt.timedelta(seconds=45), None, False))
    est.sort(key=lambda e: e[0])
    boots = []
    for t, lf, exact in est:
        if boots and abs((t - boots[-1]["times"][-1]).total_seconds()) <= BOOT_TOL_S:   # GUARD:boottol DEFECT: if boots and abs((t - boots[-1]["times"][-1]).total_seconds()) <= 150:
            boots[-1]["times"].append(t)
        elif exact:
            boots.append({"times": [t]})
        elif boots:
            near = min(boots, key=lambda b: min(abs((x - t).total_seconds()) for x in b["times"]))
            near["times"].append(t)          # imprecise: joins, never opens
        else:
            boots.append({"times": [t]})
    for i, b in enumerate(boots):
        b["id"] = i + 1
        b["time"] = b["times"][len(b["times"]) // 2]
        b["label"] = "B%d@%s" % (b["id"], fmt_ts(b["time"]))
        del b["times"]
    for lf in files:
        if lf.boot_time:
            lf.boot = min(boots, key=lambda b: abs((b["time"] - lf.boot_time).total_seconds()))["id"]
    def boot_for(ts):
        if ts is None:
            return boots[-1]["id"] if boots else 0
        cur = 0
        for b in boots:
            if b["time"] <= ts + dt.timedelta(seconds=150):
                cur = b["id"]
        return cur
    for lf in files:
        # A FILE'S BOOT IS ONLY THE FILE'S WHEN THE FILE IS ONE PROCESS. With one file per module per
        # day a file spans boots, and stamping every line with the LAST init's boot put a whole day's
        # lines in one bucket - so a real per-boot rise could hide under a quiet neighbour.
        one_process = len(lf.inits) <= 1
        for l in lf.lines:
            l.boot = lf.boot if (lf.boot and one_process) else boot_for(l.ts)
    return boots


LAUNCH_RE = re.compile(r"^Running process '(.*gui-agent\.exe)' in session (\d+)")
DEATH_RE = re.compile(r"^Process 'gui-agent\.exe' \(PID (\d+)\) exited with code (0x[0-9a-fA-F]+) without this service asking it to")
GOINGDOWN_RE = re.compile(r"^Process 'gui-agent\.exe' \(PID (\d+)\) exited with code (0x[0-9a-fA-F]+) while the system is going down")
ASKED_RE = re.compile(r"^service stopping: asked 'gui-agent\.exe' \(PID (\d+)\) to exit")
GONE_RE = re.compile(r"^service stopping: 'gui-agent\.exe' \(PID (\d+)\) is gone, exit code (0x[0-9a-fA-F]+)")
FASTDEATH_RE = re.compile(r"^(Process 'gui-agent\.exe' died within \d+ ms of starting|Starting process '.*' failed)")
EV4001_RE = re.compile(r"\((gui-agent\.exe|wgcbroker\.exe|notifhost\.exe|etwproxy\.exe), PID (\d+)\) exited without being asked to - exit code (0x[0-9a-fA-F]+)")
HELPER_LAUNCH_RE = re.compile(r"(WGCBROKER launched|NOTIFHOST launched|ETWPROXYSUP launched)")
HELPER_DEATH_RE = re.compile(r"(QGANOTIFBRIDGEEXIT|ETWPROXYSUP proxy exited)")     # the broker has its own, context-aware metrics


def m8_records(files, agents):
    """The M8 injection records in the capture, dated from the agent logs (the record carries a time of day only)."""
    dates = sorted({l.ts.date() for lf in agents for l in lf.lines if l.ts})
    recs = []
    pending = {}
    for lf in files:
        if lf.family != "marker":
            continue
        for l in lf.lines:
            e = l.extra
            key = (e["name"], e["pid"])
            if e["kind"] == "suspend":
                if key in pending:
                    recs.append(pending.pop(key))
                pending[key] = {"name": e["name"], "pid": e["pid"], "t_suspend_tod": e["tod"], "t_resume_tod": None, "alive": None,
                                "file": lf.name, "line": l.raw.strip()[:120], "joined": [], "checks": []}
            else:
                r = pending.pop(key, None)
                if r is None:
                    r = {"name": e["name"], "pid": e["pid"], "t_suspend_tod": None, "t_resume_tod": None, "alive": None, "file": lf.name,
                         "line": l.raw.strip()[:120], "joined": [], "checks": []}
                r["t_resume_tod"] = e["tod"]
                r["alive"] = e["alive"]
                recs.append(r)
    recs.extend(pending.values())
    # date each record: the agent-line date nearest to its suspend time (a capture spans a day at most)
    for r in recs:
        tod = r["t_suspend_tod"] or r["t_resume_tod"]
        best = None
        for d in dates:
            cand = dt.datetime.combine(d, tod)
            dist = min((abs((cand - l.ts).total_seconds()) for lf in agents for l in lf.lines if l.ts), default=None)
            if dist is not None and (best is None or dist < best[0]):
                best = (dist, d)
        d = best[1] if best else (dates[-1] if dates else None)
        if d is None:
            r["t_suspend"] = r["t_resume"] = None
            continue
        r["t_suspend"] = dt.datetime.combine(d, r["t_suspend_tod"]) if r["t_suspend_tod"] else None
        r["t_resume"] = dt.datetime.combine(d, r["t_resume_tod"]) if r["t_resume_tod"] else None
        if r["t_suspend"] and r["t_resume"] and r["t_resume"] < r["t_suspend"]:
            r["t_resume"] += dt.timedelta(days=1)
        if r["t_suspend"] is None and r["t_resume"]:
            r["t_suspend"] = r["t_resume"] - dt.timedelta(seconds=60)
        r["t_end"] = (r["t_resume"] or (r["t_suspend"] + dt.timedelta(seconds=60))) + dt.timedelta(seconds=M8_RECORD_SLACK_S)
        r["t_begin"] = r["t_suspend"] - dt.timedelta(seconds=1)
    return [r for r in recs if r.get("t_suspend")]


def broker_events(src):
    """The broker supervision events of one agent instance, in order.

    Takes the INSTANCE's own lines (or a LogFile, for callers that still have one): with one file per
    module per day a file holds every process of the day, so a file's events are not an instance's.
    """
    out = []
    for l in getattr(src, "lines", src):
        if l.func not in ("BrokerSupervise", "BrokerRegister", "WgcLaunch"):
            continue
        m = BROKER_DIED_RE.match(l.msg)
        if m:
            out.append({"kind": "DIED", "ts": l.ts, "pid": int(m.group(1)), "line": l, "heartbeat": "STOPPED HEARTBEATING" in l.msg}); continue
        m = BROKER_REAP_RE.match(l.msg)
        if m:
            out.append({"kind": "REAP", "ts": l.ts, "pid": int(m.group(1)), "line": l}); continue
        if BROKER_HUNG_RE.match(l.msg):
            out.append({"kind": "HUNG", "ts": l.ts, "pid": None, "line": l}); continue
        if BROKER_BACK_RE.match(l.msg):
            out.append({"kind": "BACK", "ts": l.ts, "pid": None, "line": l}); continue
        m = BROKER_REG_RE.match(l.msg)
        if m:
            out.append({"kind": "REG", "ts": l.ts, "pid": None, "slot": int(m.group(1)), "line": l}); continue
        if "WGCBROKER launched" in l.msg:
            out.append({"kind": "LAUNCH", "ts": l.ts, "pid": None, "line": l})
    # a HUNG carries no pid; the DIED / REAP that follow within 2 s do
    for i, e in enumerate(out):
        if e["kind"] in ("HUNG", "BACK") and e["pid"] is None:
            for f in out[i + 1:i + 4]:
                if f["kind"] in ("DIED", "REAP") and f["pid"] and (f["ts"] - e["ts"]).total_seconds() <= 2:
                    e["pid"] = f["pid"]; break
            if e["pid"] is None:
                for f in reversed(out[max(0, i - 3):i]):
                    if f["kind"] in ("DIED", "REAP") and f["pid"] and (e["ts"] - f["ts"]).total_seconds() <= 10:
                        e["pid"] = f["pid"]; break
    return out


def join_fi(files, instances, agents, declared):
    """Mark every line / broker event that is in a fault-injection context, from evidence; run the M8 detection checks."""
    recs = m8_records(files, agents)
    sources = []
    for i in instances:
        # THE INSTANCE'S OWN LINES, not its file's. A file now holds every process of the day, so
        # reading the banner file-wide put ONE fault-injection build's context on every other
        # process of that day - and a line marked fi excuses a P1 broker death outright.
        ilines = i.get("_lines") or []
        i["fi_build"] = any(FI_BANNER_RE.search(l.msg) for l in ilines)   # GUARD:ficontext DEFECT: i["fi_build"] = ("fi" in i["file"].lower())
        i["fi_armed"] = any(FI_ARMED_RE.search(l.msg) for l in ilines)
        i["broker_events"] = broker_events(ilines)
        if i["fi_build"]:
            sources.append("QGAFAULT-INIT banner in %s (pid %s)%s" % (i["file"], i["pid"], " - FAULTS ARE ARMED" if i["fi_armed"] else ""))
            for l in ilines:
                l.fi = True
        for e in i["broker_events"]:
            e["fi"] = bool(i["fi_build"])   # GUARD:fideclared DEFECT: e["fi"] = bool(i["fi_build"]) or bool(declared["declared"])
            e["record"] = None
            if e["kind"] in ("HUNG", "DIED", "REAP", "BACK", "LAUNCH") and not e["fi"]:
                for r in recs:
                    if r["name"].lower().startswith("wgcbro") and r["t_begin"] <= e["ts"] <= r["t_end"] and (e["pid"] is None or e["pid"] == r["pid"]):
                        e["fi"] = True
                        e["record"] = r
                        r["joined"].append("%s %s" % (e["kind"], fmt_ts(e["ts"])))
                        e["line"].fi = True
                        break
    for r in recs:
        if r["name"].lower().startswith("wgcbro"):
            sources.append("M8 record %s: pid %s suspended %s..%s (%s)" % (r["file"], r["pid"], fmt_ts(r["t_suspend"]), fmt_ts(r["t_resume"]),
                                                                            ", ".join(r["joined"]) if r["joined"] else "no broker event joined"))
        else:
            sources.append("M8 record %s: %s pid %s suspended %s..%s (the detection for an agent suspension is on the broker side - not verifiable from the agent log)" % (
                r["file"], r["name"], r["pid"], fmt_ts(r["t_suspend"]), fmt_ts(r["t_resume"])))
    # THE OTHER HALF OF M8: an injected hang the agent did NOT detect is a silent test failure (DESIGN-rest-zero-capture M8)
    missing = 0
    for r in recs:
        if not r["name"].lower().startswith("wgcbro"):
            continue
        lo, hi = r["t_suspend"], (r["t_resume"] or r["t_suspend"] + dt.timedelta(seconds=60))
        evs = [e for i in instances for e in i["broker_events"]]
        regs = [e for e in evs if e["kind"] == "REG" and lo <= e["ts"] <= hi]
        if not regs:
            r["checks"].append("no registration during the suspension: nothing to detect (a control)")
            continue
        reg = regs[0]
        hung = next((e for e in evs if e["kind"] == "HUNG" and reg["ts"] <= e["ts"] <= reg["ts"] + dt.timedelta(seconds=M8_DETECT_S)), None)
        if hung is None:
            missing += 1
            r["checks"].append("MISSING: registration %s during the suspension, no QGABROKERHUNG within %.1f s" % (fmt_ts(reg["ts"]), M8_DETECT_S))
            continue
        reap = next((e for e in evs if e["kind"] == "REAP" and hung["ts"] <= e["ts"] <= hung["ts"] + dt.timedelta(seconds=M8_RECOVER_S)), None)
        back = next((e for e in evs if e["kind"] == "BACK" and hung["ts"] <= e["ts"] <= hung["ts"] + dt.timedelta(seconds=M8_RECOVER_S)), None)
        if reap is None or back is None:
            missing += 1
            r["checks"].append("MISSING: QGABROKERHUNG %s detected (%.0f ms after the registration) but %s within %.0f s" % (
                fmt_ts(hung["ts"]), (hung["ts"] - reg["ts"]).total_seconds() * 1000, "no QGABROKERREAP" if reap is None else "no QGABROKERBACK", M8_RECOVER_S))
        else:
            r["checks"].append("OK: QGABROKERHUNG %.0f ms after the registration, reaped and back within %.0f ms" % (
                (hung["ts"] - reg["ts"]).total_seconds() * 1000, (back["ts"] - hung["ts"]).total_seconds() * 1000))
    evidenced = any(i["fi_build"] for i in instances) or bool(recs)
    ctx = {"fault_injection": bool(evidenced), "declared": bool(declared["declared"]), "declared_source": declared["source"],
           "declared_errors": declared.get("declared_errors", []),
           "sources": sources, "records": recs, "detection_missing": missing,
           "unproven": bool(declared["declared"] and not evidenced)}
    return ctx
FALLBACK_FIRED_RE = re.compile(r"(?i)(falling back to|falling to [a-z ]*fallback|falls back to|fallback (fired|active|engaged|path taken)|DB fallback|signal fallback|tier down)")


def build_structure(files, boots, declared=None):
    agents = [lf for lf in files if lf.family == "agent" and lf.pid is not None]
    watchdogs = [lf for lf in files if lf.family == "watchdog"]
    events = [l for lf in files if lf.family == "events" for l in lf.lines]

    launches, deaths, goingdown, asked, gone, fastdeath, preshutdown = [], [], [], {}, {}, [], []
    for wd in watchdogs:
        for l in wd.lines:
            if l.func == "StartTargetProcess" and LAUNCH_RE.match(l.msg):
                launches.append(l)
            elif l.func == "WatchdogThread":
                m = DEATH_RE.match(l.msg)
                if m:
                    deaths.append({"pid": int(m.group(1)), "code": m.group(2).lower(), "ts": l.ts, "line": l, "kind": "unrequested"})
                    continue
                m = GOINGDOWN_RE.match(l.msg)
                if m:
                    goingdown.append({"pid": int(m.group(1)), "code": m.group(2).lower(), "ts": l.ts, "line": l, "kind": "going-down"})
                    continue
                if FASTDEATH_RE.match(l.msg):
                    fastdeath.append(l)
            elif l.func == "StopOwnAgent":
                m = ASKED_RE.match(l.msg)
                if m:
                    asked[int(m.group(1))] = l
                    continue
                m = GONE_RE.match(l.msg)
                if m:
                    gone[int(m.group(1))] = (l, m.group(2).lower())
            elif l.func == "ControlHandlerEx" and l.msg.startswith("preshutdown"):
                preshutdown.append(l)

    # shutdown windows from the event markers (System 1074 / LSM 54 -> System 13 / 6006 / Kernel-Power 109)
    starts = sorted([l for l in events if (l.extra.get("log") == "System" and l.extra.get("id") in (1074, 1076)) or
                     (l.extra.get("id") == 54 and "LocalSessionManager" in str(l.extra.get("log")))], key=lambda l: l.ts)
    ends = sorted([l for l in events if l.extra.get("log") == "System" and l.extra.get("id") in (13, 6006, 109)], key=lambda l: l.ts)
    windows = []
    for s in starts:
        if windows and (s.ts - windows[-1]["start"]).total_seconds() <= 5:
            windows[-1]["markers"].append(s.raw[:200])
            continue
        end = next((e.ts for e in ends if e.ts >= s.ts and (e.ts - s.ts).total_seconds() <= 600), None)
        windows.append({"start": s.ts, "end": end or (s.ts + dt.timedelta(seconds=120)), "approx_end": end is None,
                        "approx": False, "markers": [s.raw[:200]]})
    for p in preshutdown:   # a preshutdown the event markers do not cover: approximate window around it
        if not any(w["start"] - dt.timedelta(seconds=90) <= p.ts <= w["end"] + dt.timedelta(seconds=30) for w in windows):
            windows.append({"start": p.ts - dt.timedelta(seconds=90), "end": p.ts + dt.timedelta(seconds=30), "approx_end": True,
                            "approx": True, "markers": ["(no 1074/54 event in the capture) " + p.raw[:160]]})
    windows.sort(key=lambda w: w["start"])
    # A SHUTDOWN WINDOW ENDS WHEN THE GUEST IS DOWN, NEVER INSIDE THE NEXT BOOT (2026-10-07). An end the capture does
    # not state is approximated as start + 120 s, and a test guest is restarted ~13 s after it halts - so the window
    # swallowed the next boot's agent and every per-window count read one too many: "2 agent instances per shutdown"
    # on a capture whose logs show one launch and one orderly exit per boot. The next boot's own time is the hard
    # bound, and it is known (detect_boots ran before this). (# GUARD:winclamp)
    for w in windows:
        nxt = min([b["time"] for b in boots if b["time"] > w["start"]], default=None)
        if nxt is not None and nxt < w["end"]:   # GUARD:winclamp DEFECT: if False:
            w["end"] = nxt
            w["clamped_at_next_boot"] = True
    for i, w in enumerate(windows):
        w["id"] = i + 1

    # AGENT INSTANCES ARE PER PROCESS, NOT PER FILE. Until 2026-10-07 one agent log file WAS one
    # agent process, so a file could stand in for an instance. The log is now one file per module per
    # day, and reading a file as an instance collapsed every process that ran that day into one
    # instance spanning the whole day - which silently zeroed the metric that exists for the
    # three-instances-per-shutdown defect (agent_instances_per_shutdown), turned
    # agent_relaunches_at_shutdown into 0, and with --since dropped the day-spanning instance
    # altogether so agent_instances_per_boot read 0 and "nothing was running" looked like a clean run.
    #
    # The split is by the PID the patched logger now puts in every line's prefix, GROUPED rather than
    # taken in consecutive runs, because concurrent processes interleave their lines in one file. A
    # log with no pid in its prefix is an OLD one - written when the file really was per-process - so
    # it stays a single instance keyed on the file's own init pid.
    def _instance_groups(lf):
        groups, order = {}, []
        for l in lf.lines:
            pid = (l.extra or {}).get("pid") or ""
            key = int(pid) if pid else lf.pid   # GUARD:perfileinst DEFECT: key = lf.name
            if key not in groups:
                groups[key] = []
                order.append(key)
            groups[key].append(l)
        return [(k, groups[k]) for k in order]

    instances = []
    _segments = []
    for lf in sorted(agents, key=lambda f: (f.lines[0].ts if f.lines else dt.datetime.min)):
        if not lf.lines:
            continue
        for _pid, _lines in _instance_groups(lf):
            _segments.append((lf, _pid, _lines))
    for lf, _pid, _lines in sorted(_segments, key=lambda t: (t[2][0].ts or dt.datetime.min)):
        # the init record this process wrote, when it is in this file (it names the session/version)
        _init = next((i for i in lf.inits if i["pid"] == _pid), None)
        inst = {"pid": _pid, "file": lf.name,
                "boot": (_lines[0].boot if len(lf.inits) > 1 else lf.boot),
                "session": (_init or {}).get("session", lf.session) if _init else lf.session,
                "version": (_init or {}).get("version", lf.version) if _init else lf.version,
                "start": _lines[0].ts, "end": _lines[-1].ts, "lines": len(_lines),
                "announces": sum(1 for l in _lines if l.func == "WatchForEvents" and l.msg.startswith("Awaiting for a vchan client")),
                "connects": sum(1 for l in _lines if l.func == "WatchForEvents" and l.msg.startswith("A vchan client has connected")),
                "handshake_refusals": sum(1 for l in _lines if "QGAHANDSHAKE" in l.msg),
                "helper_launches": Counter(HELPER_LAUNCH_RE.search(l.msg).group(1) for l in _lines if HELPER_LAUNCH_RE.search(l.msg)),
                "helper_deaths": sum(1 for l in _lines if HELPER_DEATH_RE.search(l.msg)),
                "exit_logged": any(l.func == "WatchForEvents" and l.msg == "exiting" for l in _lines),
                "end_kind": "unknown", "exit_code": None, "death": None, "stop": None, "errors_during_stop": [], "exit_errors": [], "_lines": _lines}
        # PIDs are recycled across boots: a watchdog record belongs to this instance only if it falls in its lifetime
        lo, hi = inst["start"] - dt.timedelta(seconds=2), inst["end"] + dt.timedelta(seconds=120)
        in_life = lambda ts: ts is not None and lo <= ts <= hi
        d = next((x for x in deaths + goingdown if x["pid"] == _pid and in_life(x["ts"])), None)
        if d:
            inst["end_kind"] = "died" if d["kind"] == "unrequested" else "going-down"
            inst["exit_code"] = d["code"]
            inst["death"] = {"ts": d["ts"], "code": d["code"], "kind": d["kind"], "line": d["line"].raw}
        if _pid in asked and in_life(asked[_pid].ts):
            a = asked[_pid]
            g = gone.get(_pid)
            if g and not in_life(g[0].ts):
                g = None
            inst["end_kind"] = "requested-stop"
            inst["stop"] = {"asked": a.ts, "gone": g[0].ts if g else None, "code": g[1] if g else None, "asked_line": a.raw, "gone_line": g[0].raw if g else None}
            inst["exit_code"] = g[1] if g else None
            hi = (g[0].ts if g else a.ts + dt.timedelta(seconds=10)) + dt.timedelta(milliseconds=500)
            inst["errors_during_stop"] = [l for l in _lines if l.level == "E" and l.ts and a.ts <= l.ts <= hi]   # GUARD:stoperr DEFECT: inst["errors_during_stop"] = []
        inst["exit_errors"] = [l for l in _lines if l.level == "E" and l.ts and (inst["end"] - l.ts).total_seconds() <= 2.0]
        inst["stale_errors"] = [l for l in _lines if l.level == "E" and STALE_ERR_RE.search(l.msg)]
        instances.append(inst)

    # join instances / launches / deaths / announcements to the shutdown windows
    for w in windows:
        lo = w["start"] - dt.timedelta(seconds=2)
        w["instances"] = [i for i in instances if i["start"] <= w["end"] and (i["end"] >= lo)]
        w["launches"] = [l for l in launches if l.ts and lo <= l.ts <= w["end"]]
        w["deaths"] = [d for d in deaths if d["ts"] and lo <= d["ts"] <= w["end"]]
        w["goingdown"] = [d for d in goingdown if d["ts"] and lo <= d["ts"] <= w["end"]]
        # A LAUNCH IS NOT YET A RELAUNCH. The 2 s pre-roll above exists for marker jitter, and with it a launch
        # that happened BEFORE the shutdown marker counted as one INTO it - which is how a BOOT followed five
        # seconds later by a shutdown (the install's own reboot chain) was reported on 2026-10-07 as the very
        # defect that build had just fixed: a P2 breach, Jev 0.73, against a correct binary. The defect is the
        # watchdog starting a NEW agent after one of ours ENDED in that window; a launch with nothing of ours
        # ended before it is the boot's own launch, and a boot that is followed by a shutdown is not it.
        _ends = [i["end"] for i in w["instances"] if i.get("end")] + [d["ts"] for d in w["deaths"] if d.get("ts")]
        w["relaunches"] = [l for l in w["launches"] if any(e <= l.ts for e in _ends)]   # GUARD:relaunchneedsend DEFECT: w["relaunches"] = w["launches"]
        w["announces"] = [l for i in w["instances"] for l in i["_lines"] if l.func == "WatchForEvents" and l.msg.startswith("Awaiting for a vchan client") and lo <= l.ts <= w["end"]]
        w["stops"] = [i for i in w["instances"] if i["stop"] and i["stop"]["asked"] and lo <= i["stop"]["asked"] <= w["end"] + dt.timedelta(seconds=60)]
        w["label"] = "S%d %s..%s%s" % (w["id"], fmt_ts(w["start"]), fmt_ts(w["end"]), " (approximate window)" if w["approx"] or w["approx_end"] else "")

    # death records from the event log (4001-4004)
    ev_deaths = []
    for l in events:
        if l.extra.get("provider") == "Qubes Windows Tools" and l.extra.get("id") in (4001, 4002, 4003, 4004):
            m = EV4001_RE.search(l.msg)
            ev_deaths.append({"exe": m.group(1) if m else "?", "pid": int(m.group(2)) if m else None, "code": m.group(3).lower() if m else None, "ts": l.ts, "line": l})

    ctx = join_fi(files, instances, agents, declared or {"declared": False, "source": None, "declared_errors": []})
    return {"launches": launches, "deaths": deaths, "goingdown": goingdown, "asked": asked, "gone": gone, "fastdeath": fastdeath,
            "preshutdown": preshutdown, "windows": windows, "instances": instances, "ev_deaths": ev_deaths, "events": events,
            "agents": agents, "watchdogs": watchdogs, "context": ctx}


def compute_metrics(files, boots, st, since, now=None):
    """now = the capture time (the collector's clock) - without it the two 'still running?' metrics are not evaluable."""
    m = {}
    inst = st["instances"]
    windows = st["windows"]
    events = st["events"]
    sel = lambda ts: (ts is not None) and (since is None or ts >= since)
    m["boots"] = len(boots)
    m["shutdowns"] = len(windows)
    m["agent_instances"] = len(inst)
    m["agent_unrequested_deaths"] = len([d for d in st["deaths"] if sel(d["ts"])])
    m["agent_going_down_exits"] = len([d for d in st["goingdown"] if sel(d["ts"])])
    # --since APPLIES HERE TOO (2026-10-07). These four counted every window in the capture whatever the window
    # asked for, so a re-grade over just the post-install cycles returned the install's own numbers - the installer
    # deliberately stops and starts the agent several times, and that read as shutdown churn. A metric that ignores
    # the window cannot answer the question the window was chosen to ask.
    # The window's own field is "start" (windows.append above). Filtering on a key that does not exist silently
    # zeroed three metrics in the first version of this fix - 0 because nothing was considered, which reads exactly
    # like 0 because nothing happened. A window with no start is KEPT, never dropped: missing data must not shrink a
    # count. (# GUARD:winsince)
    win = [w for w in windows if w.get("start") is None or sel(w["start"])] if since is not None else windows   # GUARD:winsince DEFECT: win = windows
    insts = [i for i in inst if i.get("start") is None or sel(i["start"])] if since is not None else inst   # GUARD:winkey DEFECT: insts = [i for i in inst if sel(i.get("ts"))] if since is not None else inst
    m["shutdowns_in_window"] = len(win)
    m["agent_deaths_at_shutdown"] = sum(len(w["deaths"]) for w in win)
    m["agent_relaunches_at_shutdown"] = sum(len(w["relaunches"]) for w in win)
    m["agent_instances_per_shutdown"] = max([len(w["instances"]) for w in win], default=0)   # GUARD:instances DEFECT: m["agent_instances_per_shutdown"] = 0
    per_boot = Counter(i["boot"] for i in insts)
    m["agent_instances_per_boot"] = max(per_boot.values(), default=0)
    m["vchan_setups_per_shutdown"] = max([len(w["announces"]) for w in win], default=0)
    if now is not None:
        # an instance that announced within the last 30 s of the capture may simply not have been connected yet
        m["vchan_announce_without_connect"] = len([i for i in inst if i["announces"] >= 1 and i["connects"] == 0 and (now - i["end"]).total_seconds() > 30])
    else:
        m["vchan_announce_without_connect"] = None
    m["vchan_reconnects"] = sum(max(0, i["announces"] - 1) for i in inst)
    m["handshake_refusals"] = sum(i["handshake_refusals"] for i in inst)
    m["helper_deaths"] = sum(i["helper_deaths"] for i in inst)
    # the broker: a hang / death counts unless EVIDENCE puts it in a fault-injection context (join_fi)
    bev = [e for i in inst for e in i.get("broker_events", [])]
    gate_on = True   # GUARD:brokersev DEFECT: gate_on = False
    m["broker_hangs"] = len([e for e in bev if e["kind"] == "HUNG" and not e["fi"] and sel(e["ts"])]) if gate_on else 0
    m["broker_deaths"] = len([e for e in bev if e["kind"] == "DIED" and not e["fi"] and sel(e["ts"])]) if gate_on else 0
    m["broker_events_excused"] = len([e for e in bev if e["kind"] in ("HUNG", "DIED") and e["fi"]])
    ctx = st["context"]
    m["fi_records"] = len(ctx["records"])
    m["fi_detection_missing"] = ctx["detection_missing"]   # GUARD:fidetect DEFECT: m["fi_detection_missing"] = 0
    m["fi_context_unproven"] = 1 if ctx["unproven"] else 0
    rel = 0
    for i in inst:
        for h, n in i["helper_launches"].items():
            if h == "WGCBROKER launched":
                excused = len([e for e in i.get("broker_events", []) if e["kind"] == "DIED" and e["fi"]])
                rel += max(0, n - 1 - excused)
            else:
                rel += max(0, n - 1)
    m["helper_relaunches"] = rel
    m["requested_stop_nonzero_exit"] = len([i for i in inst if i["stop"] and i["stop"]["code"] not in (None, "0x0")])
    m["errors_during_requested_stop"] = sum(len(i["errors_during_stop"]) for i in inst)
    m["stale_error_lines"] = len([l for lf in files for l in lf.lines if l.level == "E" and STALE_ERR_RE.search(l.msg) and sel(l.ts)])
    m["watchdog_fast_death_backoffs"] = len([l for l in st["fastdeath"] if sel(l.ts)])
    if now is not None:
        m["agent_ends_unrecorded"] = len([i for i in inst if i["end_kind"] == "unknown" and (now - i["end"]).total_seconds() > 120 and not i["exit_logged"]])
    else:
        m["agent_ends_unrecorded"] = None   # not evaluable without the capture time (corpus mode)
    m["service_failures"] = len([l for l in events if l.extra.get("log") == "System" and l.extra.get("id") in (7023, 7024, 7031, 7034, 7043) and OUR_SERVICES_RE.search(l.msg) and sel(l.ts)])
    m["wer_crashes"] = len([l for l in events if l.extra.get("log") == "Application" and l.extra.get("id") in (1000, 1001, 1026) and OUR_EXES_RE.search(l.msg) and sel(l.ts)])
    m["death_events"] = len([d for d in st["ev_deaths"] if sel(d["ts"])])
    have_wd = bool(st["watchdogs"]) and bool([lf for lf in files if lf.family == "events"])
    mismatch = 0
    if have_wd:
        for d in st["deaths"]:
            if not any(e["pid"] == d["pid"] and e["ts"] and d["ts"] and abs((e["ts"] - d["ts"]).total_seconds()) <= 5 for e in st["ev_deaths"]):
                mismatch += 1
        for e in st["ev_deaths"]:
            if e["exe"] == "gui-agent.exe" and not any(d["pid"] == e["pid"] and e["ts"] and d["ts"] and abs((e["ts"] - d["ts"]).total_seconds()) <= 5 for d in st["deaths"]):
                mismatch += 1
        m["death_record_mismatch"] = mismatch
    else:
        m["death_record_mismatch"] = None   # not evaluable: needs both the watchdog log and the event block
    m["unexpected_shutdowns"] = len([l for l in events if l.extra.get("log") == "System" and l.extra.get("id") in (6008, 41) and sel(l.ts)])
    m["bugchecks"] = len([l for l in events if l.extra.get("log") == "System" and l.extra.get("id") == 1001 and "BugCheck" in (l.extra.get("provider") or "") and sel(l.ts)])
    m["task_failures"] = len([l for l in events if "TaskScheduler" in str(l.extra.get("log")) and l.extra.get("id") in (201, 203) and OUR_TASKS_RE.search(l.msg) and sel(l.ts)])
    m["fallbacks_fired"] = len([l for lf in files for l in lf.lines if FALLBACK_FIRED_RE.search(l.msg) and "fallback refused" not in l.msg and sel(l.ts)])
    errs = [l for lf in files for l in lf.lines if l.level == "E" and sel(l.ts)]
    m["error_lines"] = len(errs)
    # THE OWNER'S GATE CONDITION, 2026-10-07: "Make clean error log the gate condition. Any error is fuckup!"
    # Every error line in our own logs counts, EXCEPT one this run declared it caused (a fault injection, or a
    # cell that ends a helper on purpose). Jev: zero-except-declared-injection 1.00; an exemption from the
    # BASELINE would be hiding (0.64), so the baseline does not excuse anything here - it only says new vs known.
    _decl, _bad = [], 0
    for d in (st.get("context") or {}).get("declared_errors", []):
        pat = d.get("pattern") if isinstance(d, dict) else None
        if not pat:
            _bad += 1
            continue
        try:
            _decl.append(re.compile(pat))
        except re.error:
            _bad += 1   # a malformed declaration can match nothing, so it counts as one that never appeared
    def _is_declared(line):
        return any(rx.search(line.raw) for rx in _decl)
    m["error_lines_undeclared"] = len([l for l in errs if not _is_declared(l)])
    # a declaration that matches nothing is itself a finding: the stimulus it names did not happen, so the
    # run proved less than it claims (the same rule as a check that has never been seen to fail)
    m["declared_errors_unmatched"] = _bad + len([1 for rx in _decl if not any(rx.search(l.raw) for l in errs)])
    m["warning_lines"] = len([l for lf in files for l in lf.lines if l.level == "W" and sel(l.ts)])
    codes = Counter(d["code"] for d in st["deaths"] + st["goingdown"])
    for e in st["ev_deaths"]:
        if e["code"] and not any(d["pid"] == e["pid"] for d in st["deaths"] + st["goingdown"]):
            codes[e["code"]] += 1
    m["deaths_by_exit_code"] = dict(codes)
    return m


# ----------------------------------------------------------------------------------------------- signatures
def collect_signatures(files, since):
    sigs = {}
    for lf in files:
        for l in lf.lines:
            if since is not None and l.ts is not None and l.ts < since:
                continue
            if l.level in ("D", "V") and not SUSPICIOUS_RE.search(l.msg):
                continue
            if l.level == "I" and lf.family not in ("events", "guid") and not SUSPICIOUS_RE.search(l.msg) and l.func != "RESULT":
                continue
            k = l.key()
            s = sigs.get(k)
            if s is None:
                s = sigs[k] = {"key": k, "family": lf.family, "level": l.level, "count": 0, "per_boot": Counter(), "files": set(),
                               "examples": [], "first_ts": l.ts, "last_ts": l.ts, "ctx": None, "line": l, "count_fi": 0, "count_nonfi": 0, "nonfi_line": None}
            s["count"] += 1
            if l.fi:
                s["count_fi"] += 1
            else:
                s["count_nonfi"] += 1
                if s["nonfi_line"] is None:
                    s["nonfi_line"] = l
            # per boot; with no boot cluster at all (an installer-only or dom0-only directory) per file+run
            s["per_boot"][l.boot or "%s#%s" % (lf.name, l.extra.get("run", 0))] += 1
            s["files"].add(lf.name)
            if len(s["examples"]) < 3:
                s["examples"].append(l.raw[:300])
            if s["ctx"] is None:
                lo, hi = max(0, l.idx - 2), l.idx + 3
                s["ctx"] = [x.raw[:200] for x in lf.lines if lo <= x.idx < hi and x is not l]
            if l.ts and (s["last_ts"] is None or l.ts > s["last_ts"]):
                s["last_ts"] = l.ts
    return sigs


def lookup_baseline(baseline, key):
    entry = (baseline.get("signatures") or {}).get(key)   # GUARD:lookup DEFECT: entry = None
    if entry is not None:
        return entry, "exact"
    for p in baseline.get("patterns") or []:
        try:
            if re.search(p["regex"], key):
                return p, "pattern"
        except re.error:
            continue
    return None, None


def compare(sigs, baseline, metrics):
    thr = dict(DEFAULT_THRESHOLDS)
    thr.update(baseline.get("thresholds") or {})
    new, rose, known, unsettled, expected, out_of_context = [], [], [], [], [], []
    closed_recurrence = 0
    for k, s in sorted(sigs.items()):
        entry, how = lookup_baseline(baseline, k)
        s["baseline"] = entry
        s["match"] = how
        maxb = max(s["per_boot"].values()) if s["per_boot"] else s["count"]
        s["max_per_boot"] = maxb
        if entry is None:
            is_new = True   # GUARD:new DEFECT: is_new = False
            if is_new:
                new.append(s)
            continue
        status = entry.get("status", "expected")
        if status == "known-defect":
            known.append(s)
            if "CLOSED" in str(entry.get("issue", "")):
                closed_recurrence += s["count"]   # GUARD:closedrec DEFECT: pass
        elif status == "unsettled":
            unsettled.append(s)
        else:
            expected.append(s)
        # expected ONLY under fault injection: seen outside it, it is as good as new - and it feeds the P1 broker metrics
        if entry.get("context") == "fault-injection" and s["count_nonfi"] > 0:
            out_of_context.append(s)
        ceiling = entry.get("max_per_boot")
        if ceiling is not None and status != "known-defect":
            limit = max(int(ceiling * float(thr.get("rise_factor", 2.0)) + 0.999), int(ceiling) + int(thr.get("rise_min_delta", 3)))
            is_rose = maxb > limit   # GUARD:rise DEFECT: is_rose = False
            if is_rose:
                s["rise_limit"] = limit
                rose.append(s)
    metrics["closed_defect_recurrence"] = closed_recurrence
    breaches = []
    for name, t in thr.items():
        if not isinstance(t, dict) or "max" not in t:
            continue
        v = metrics.get(name)
        if v is None:
            continue
        if v > t["max"]:
            breaches.append({"metric": name, "value": v, "max": t["max"], "severity": t.get("severity", "P2"), "why": t.get("why", "")})
    breaches.sort(key=lambda b: (SEVERITY_ORDER.get(b["severity"], 9), b["metric"]))
    return {"new": new, "rose": rose, "known": known, "unsettled": unsettled, "expected": expected, "out_of_context": out_of_context,
            "breaches": breaches, "thresholds": thr}


# ----------------------------------------------------------------------------------------------- Jev
def breach_evidence(b, st, metrics):
    name = b["metric"]
    out = []
    if name in ("agent_instances_per_shutdown", "agent_relaunches_at_shutdown", "agent_deaths_at_shutdown", "vchan_setups_per_shutdown"):
        for w in st["windows"]:
            out.append("shutdown %s: markers=%s" % (w["label"], " | ".join(w["markers"])[:300]))
            out.append("  instances alive: %s" % ", ".join("pid %s [%s..%s end=%s code=%s]" % (i["pid"], fmt_ts(i["start"]), fmt_ts(i["end"]), i["end_kind"], i["exit_code"]) for i in w["instances"]))
            for l in w["launches"]:
                out.append("  launch%s: %s" % (" (RELAUNCH - something of ours had already ended in this window)"
                                               if l in w["relaunches"] else " (the boot's own - nothing of ours had ended yet)", l.raw[:200]))
            for d in w["deaths"]:
                out.append("  death: " + d["line"].raw[:220])
            for l in w["announces"]:
                out.append("  vchan announce: " + l.raw[:160])
    elif name in ("errors_during_requested_stop", "requested_stop_nonzero_exit"):
        for i in st["instances"]:
            if i["stop"]:
                out.append("pid %s requested stop: %s -> %s" % (i["pid"], (i["stop"]["asked_line"] or "")[:200], (i["stop"]["gone_line"] or "no 'is gone' line")[:200]))
                for l in i["errors_during_stop"]:
                    out.append("  ERROR during the stop: " + l.raw[:220])
    elif name in ("agent_unrequested_deaths", "watchdog_fast_death_backoffs", "death_events", "death_record_mismatch"):
        for d in st["deaths"]:
            out.append("death: " + d["line"].raw[:220])
        for l in st["fastdeath"]:
            out.append("backoff: " + l.raw[:220])
        for e in st["ev_deaths"]:
            out.append("event: " + e["line"].raw[:220])
    elif name in ("vchan_announce_without_connect", "vchan_reconnects", "handshake_refusals", "helper_deaths", "helper_relaunches", "agent_ends_unrecorded", "agent_instances_per_boot"):
        for i in st["instances"]:
            out.append("pid %s boot=%s [%s..%s] announces=%s connects=%s helpers=%s helper_deaths=%s end=%s code=%s fi_build=%s" % (
                i["pid"], i["boot"], fmt_ts(i["start"]), fmt_ts(i["end"]), i["announces"], i["connects"], dict(i["helper_launches"]), i["helper_deaths"], i["end_kind"], i["exit_code"], i.get("fi_build")))
    elif name in ("broker_deaths", "broker_hangs", "fi_detection_missing", "fi_context_unproven", "closed_defect_recurrence"):
        c = st["context"]
        out.append("context: fault_injection=%s declared=%s (%s) unproven=%s" % (c["fault_injection"], c["declared"], c["declared_source"], c["unproven"]))
        for s_ in c["sources"]:
            out.append("  evidence: " + s_)
        for r in c["records"]:
            for ch in r["checks"]:
                out.append("  M8 record pid %s suspended %s..%s: %s" % (r["pid"], fmt_ts(r["t_suspend"]), fmt_ts(r["t_resume"]), ch))
        for i in st["instances"]:
            for e in i.get("broker_events", []):
                if e["kind"] in ("HUNG", "DIED", "REAP", "BACK"):
                    out.append("  pid %s %s %s fi=%s%s: %s" % (i["pid"], e["kind"], fmt_ts(e["ts"]), e["fi"], (" (joined to M8 record pid %s)" % e["record"]["pid"]) if e.get("record") else "", e["line"].raw[:160]))
    if "lines" in b:
        out.extend(b["lines"])
    return out[:40]


def build_jev_items(cmp, st, metrics, files, since):
    items = []
    n = 0
    for b in cmp["breaches"]:
        n += 1
        items.append({"id": "b%02d_%s" % (n, re.sub(r"[^a-z0-9_]", "_", b["metric"])), "kind": "breach", "metric": b["metric"], "value": b["value"], "max": b["max"],
                      "why": b["why"], "evidence": breach_evidence(b, st, metrics)})
    order = {"E": 0, "W": 1, "I": 2, "D": 3, "V": 3}
    for s in sorted(cmp["new"], key=lambda s: (order.get(s["level"], 9), -s["count"], s["key"])):
        n += 1
        items.append({"id": "n%02d" % n, "kind": "new", "sig": s})
    for s in sorted(cmp["rose"], key=lambda s: (order.get(s["level"], 9), -s["count"], s["key"])):
        n += 1
        items.append({"id": "r%02d" % n, "kind": "rose", "sig": s})
    for s in sorted(cmp["out_of_context"], key=lambda s: (order.get(s["level"], 9), -s["count_nonfi"], s["key"])):
        n += 1
        items.append({"id": "c%02d" % n, "kind": "context", "sig": s})
    return items


def sig_facts(s, st):
    l = s["line"]
    facts = []
    for w in st["windows"]:
        if l.ts and w["start"] - dt.timedelta(seconds=2) <= l.ts <= w["end"]:
            facts.append("first occurrence falls INSIDE shutdown window %s" % w["label"])
    for i in st["instances"]:
        if i["stop"] and l.ts and l.file == i["file"] and i["stop"]["asked"] <= l.ts <= (i["stop"]["gone"] or i["stop"]["asked"]) + dt.timedelta(milliseconds=500):
            facts.append("logged by pid %s DURING ITS REQUESTED STOP (watchdog asked %s, gone %s, exit code %s)" % (i["pid"], fmt_ts(i["stop"]["asked"]), fmt_ts(i["stop"]["gone"]), i["stop"]["code"]))
        if i["death"] and l.file == i["file"] and l.ts and (i["death"]["ts"] - l.ts).total_seconds() <= 3:
            facts.append("pid %s DIED %s (code %s) within 3 s after this line" % (i["pid"], fmt_ts(i["death"]["ts"]), i["death"]["code"]))
    if l.family in ("agent", "watchdog", "qrexec", "qubesdb", "winutils") and l.level == "E" and STALE_ERR_RE.search(l.msg):
        facts.append("the error code is 0x0 (ERROR_SUCCESS) on an ERROR line: a stale GetLastError")
    c = st["context"]
    if s.get("count_fi") or s.get("count_nonfi"):
        facts.append("fault-injection context: %d of %d occurrences carry evidence of an injection (QGAFAULT-INIT banner in the instance, or an M8 record joined by pid+time); capture context fault_injection=%s declared=%s" % (
            s["count_fi"], s["count"], c["fault_injection"], c["declared"]))
    return facts


def jev_state_text(items, meta, boots, st, metrics, label, since):
    out = [OWNER_PREMISES, "CAPTURE: label=%s since=%s files=%d boots=%d shutdown_windows=%d agent_instances=%d" % (
        label, fmt_ts(since) if since else "all", len(st["agents"]) + len(st["watchdogs"]), len(boots), len(st["windows"]), len(st["instances"]))]
    for w in st["windows"]:
        out.append("  shutdown %s: instances=%s relaunches=%d deaths=%d vchan_announces=%d requested_stops=%s" % (
            w["label"], [i["pid"] for i in w["instances"]], len(w["relaunches"]), len(w["deaths"]), len(w["announces"]),
            ["pid %s exit %s" % (i["pid"], i["stop"]["code"]) for i in w["stops"]]))
    out.append("METRICS: " + json.dumps({k: v for k, v in metrics.items() if k != "deaths_by_exit_code"}, sort_keys=True) + " deaths_by_exit_code=" + json.dumps(metrics.get("deaths_by_exit_code")))
    out.append("")
    for it in items:
        out.append("=== ITEM %s (%s) ===" % (it["id"], it["kind"]))
        if it["kind"] == "breach":
            out.append("metric %s = %s, threshold max %s. Rule: %s" % (it["metric"], it["value"], it["max"], it["why"]))
            out.append("Question: does this breach indicate a DEFECT in our components or their supervision, or is it EXPECTED in this capture (e.g. a harness-driven agent restart), NOISE, or undecidable?")
            out.extend("  " + e for e in it["evidence"])
        else:
            s = it["sig"]
            out.append("family=%s level=%s signature=%s" % (s["family"], s["level"], s["key"]))
            out.append("count=%d per_boot=%s files=%d first=%s last=%s" % (s["count"], dict(s["per_boot"]), len(s["files"]), fmt_ts(s["first_ts"]), fmt_ts(s["last_ts"])))
            if it["kind"] == "rose":
                out.append("ROSE: baseline max_per_boot=%s (rise limit %s), observed max per boot=%s; baseline status=%s reason=%s" % (
                    (s["baseline"] or {}).get("max_per_boot"), s.get("rise_limit"), s["max_per_boot"], (s["baseline"] or {}).get("status"), (s["baseline"] or {}).get("reason", "")[:160]))
                out.append("Question: does this RISE in count indicate a defect, or is the higher count expected / noise here?")
            elif it["kind"] == "context":
                out.append("OUT OF CONTEXT: the baseline expects this signature ONLY under fault injection (%s); %d of its %d occurrences have NO evidence of an injection - no QGAFAULT-INIT banner in that agent instance, no M8 suspend record joining them by pid and time. Under the premises an unexcused broker hang/death is a real one." % (
                    (s["baseline"] or {}).get("reason", "")[:160], s["count_nonfi"], s["count"]))
                if s.get("nonfi_line") is not None:
                    out.append("  first unexcused occurrence: " + s["nonfi_line"].raw[:300])
                out.append("Question: is this a DEFECT (a real hang/death outside any injection), EXPECTED, NOISE, or undecidable?")
            else:
                out.append("Question: is this NEW signature (never in the baseline) a DEFECT, EXPECTED behaviour, NOISE, or undecidable from this evidence?")
            for f in sig_facts(s, st):
                out.append("  fact: " + f)
            for e in s["examples"]:
                out.append("  example: " + e)
            for c in (s["ctx"] or [])[:4]:
                out.append("  context: " + c)
        out.append("")
    return "\n".join(out)


def jev_rubric(items):
    q = {}
    for it in items:
        if it["kind"] == "breach":
            judge = "Item %s: metric %s breached its threshold (%s > %s). From the state under 'ITEM %s' only: does this indicate a defect, or is it expected, noise, or undecidable?" % (it["id"], it["metric"], it["value"], it["max"], it["id"])
        elif it["kind"] == "rose":
            judge = "Item %s: a known signature's per-boot count ROSE above its baseline ceiling. From the state under 'ITEM %s' only: does the rise indicate a defect, or is it expected, noise, or undecidable?" % (it["id"], it["id"])
        elif it["kind"] == "context":
            judge = "Item %s: a signature the baseline expects ONLY under fault injection was seen OUTSIDE any evidenced injection. From the state under 'ITEM %s' only, and against the PREMISES: a defect, expected, noise, or undecidable?" % (it["id"], it["id"])
        else:
            judge = "Item %s: a NEW log signature not in the baseline. From the state under 'ITEM %s' only, and against the PREMISES: is it a defect, expected behaviour, noise, or undecidable?" % (it["id"], it["id"])
        q[it["id"]] = {"type": "choice", "instructions": {"judge": judge},
                       "criteria": {"defect": "evidence of misbehaviour in our components or their supervision, or a log line that misstates what happened (e.g. an ERROR with a stale error code on a requested stop)",
                                    "expected": "designed, correct behaviour in this context; a correct record of something that happened",
                                    "noise": "carries no information about the guest's health",
                                    "insufficient-evidence": "the facts given cannot settle it"}}
    return {"questions": q}


def run_jev(items, state_fn, workdir, jev_cmd, chunk, wire_log):
    """One call per run when the items fit; past `chunk` questions the items are split, and each call carries ONLY its
    own items' state (the premises and the capture summary are repeated). A call the instrument refuses for size
    (HTTP 400 max_tokens_exceeded) is split in two and retried - deterministic, bounded, and still the judge's own
    answer; any other instrument failure ends the run INCOMPLETE. Returns (answers, calls, rc, incomplete_reason)."""
    os.makedirs(workdir, exist_ok=True)
    answers = {}
    calls = []
    queue = [items[i:i + chunk] for i in range(0, len(items), chunk)]
    while queue:
        part = queue.pop(0)
        n = len(calls) + 1
        rubric = jev_rubric(part)
        rp = os.path.join(workdir, "jev-rubric-%d.json" % n)
        sp = os.path.join(workdir, "jev-state-%d.txt" % n)
        ap = os.path.join(workdir, "jev-answers-%d.json" % n)
        with open(rp, "w", encoding="utf-8") as f:
            json.dump(rubric, f, indent=1)
        with open(sp, "w", encoding="utf-8") as f:
            f.write(state_fn(part))
        cmd = jev_cmd + [rp, sp, "--out", ap]
        env = dict(os.environ)
        if wire_log:
            env["JEV_WIRE_LOG"] = wire_log
        t0 = time.time()
        try:
            p = subprocess.run(cmd, capture_output=True, text=True, timeout=900, env=env)
            rc, out = p.returncode, (p.stdout + p.stderr)[-4000:]
        except Exception as e:   # the instrument did not run
            rc, out = 2, "%s: %s" % (type(e).__name__, e)
        calls.append({"rubric": rp, "state": sp, "answers": ap, "questions": len(part), "rc": rc, "seconds": round(time.time() - t0, 1), "tail": out[-1500:]})
        if rc != 0:
            if "max_tokens_exceeded" in out and len(part) > 1:
                half = len(part) // 2
                queue[0:0] = [part[:half], part[half:]]
                calls[-1]["split"] = True
                continue
            return answers, calls, rc, "jev.py exited %s on call %d (%d questions): %s" % (rc, len(calls), len(part), out.strip().splitlines()[-1] if out.strip() else "no output")
        try:
            with open(ap, encoding="utf-8") as f:
                a = json.load(f).get("answers", {})
        except (OSError, ValueError) as e:
            return answers, calls, 2, "jev answers unreadable: %s" % e
        for it in part:
            if it["id"] not in a:
                return answers, calls, 2, "no answer for %s" % it["id"]
            answers[it["id"]] = a[it["id"]]
    return answers, calls, 0, None


# ----------------------------------------------------------------------------------------------- report
def sig_json(s, with_examples=True):
    d = {"key": s["key"], "family": s["family"], "level": s["level"], "count": s["count"], "max_per_boot": s.get("max_per_boot"),
         # SORT BY THE STRING, because a boot key can be an int (a clustered boot) or a str ('?' for a line whose boot
         # could not be attributed) and Python will not order those against each other: measured 2026-10-07, the
         # analyzer CRASHED on a real capture ("'<' not supported between instances of 'int' and 'str'") after the
         # boot-attribution change, and the rig wrapper then reported FINDINGS for a run that had produced no report
         # at all. (# GUARD:bootkeysort)
         "per_boot": {str(k): v for k, v in sorted(s["per_boot"].items(), key=lambda kv: str(kv[0]))}, "files": sorted(s["files"]),
         "first": fmt_ts(s["first_ts"]), "last": fmt_ts(s["last_ts"]), "baseline": s.get("baseline"), "match": s.get("match"),
         "count_fi": s.get("count_fi", 0), "count_nonfi": s.get("count_nonfi", 0)}
    if "rise_limit" in s:
        d["rise_limit"] = s["rise_limit"]
    if with_examples:
        d["examples"] = s["examples"]
        d["context"] = s.get("ctx")
    if "jev" in s:
        d["jev"] = s["jev"]
    return d


def write_summary(rep, path):
    L = []
    h = rep["header"]
    L.append("LOG SWEEP %s  status=%s rc=%d  since=%s  files=%d lines=%d boots=%d shutdowns=%d agent_instances=%d  (report %s)" % (
        h["label"], rep["status"], rep["rc"], h["since"] or "all", h["files"], h["lines"], h["boots"], h["shutdowns"], h["agent_instances"], h["generated"]))
    # THE LOG DIRECTORY AS IT ACTUALLY IS, independent of what the collector pulled. This is the
    # volume measurement that nothing reported, so "386 files, 368 of them one module's" had to be
    # counted by hand once and was then unavailable to every later run.
    inv = rep["header"].get("inventory")
    if inv:
        try:
            nf, nl, nb = int(inv.get("files", 0)), int(inv.get("lines", 0)), int(inv.get("bytes", 0))
            other = inv.get("otherfiles")
            L.append("LOGDIR INVENTORY: %d files, %d lines, %.1f MiB across %s module(s)%s%s" % (
                nf, nl, nb / 1048576.0, inv.get("modules", "?"),
                ("   + %s non-.log file(s)" % other) if other not in (None, "0") else "",
                "" if inv.get("direxists") == "1" else "   -- THE LOG DIRECTORY DOES NOT EXIST"))
            # RANKED BY LINES, not by file count: one file per module per day flattens the counts to
            # about one each, so ranking by files would show nothing and hide whichever module is
            # actually producing the volume.
            worst = sorted(rep["header"].get("invmodules") or [], key=lambda m: -int(m.get("lines", 0)))[:5]
            for m in worst:
                nm = b64dec_path(m.get("nameb64", "")) or "?"
                unread = int(m.get("unreadable", 0))
                L.append("  %-24s %4s file(s) %9s line(s)%s" % (
                    nm[:24], m.get("files", "?"), m.get("lines", "?"),
                    "   %d UNREADABLE - counted as missing, never as empty" % unread if unread else ""))
        except (TypeError, ValueError):
            L.append("LOGDIR INVENTORY: present but unparseable - %r" % (inv,))
    else:
        L.append("LOGDIR INVENTORY: absent - this stream predates the inventory, so the file and line "
                 "volume for this run is NOT KNOWN (missing data, not zero)")
    c = rep["context"]
    L.append("CONTEXT: fault_injection=%s declared=%s%s records=%d%s" % (
        str(c["fault_injection"]).lower(), str(c["declared"]).lower(), (" (%s)" % c["declared_source"]) if c["declared"] else "", len(c["records"]),
        "  UNPROVEN: declared but no banner and no record - nothing excused" if c["unproven"] else ""))
    for s_ in c["sources"]:
        L.append("  evidence: " + s_[:200])
    for r in c["records"]:
        for ch in r["checks"]:
            L.append("  M8 pid %s %s..%s: %s" % (r["pid"], r["t_suspend"], r["t_resume"], ch))
    if rep["data_problems"]:
        L.append("DATA (%d) - the sweep is not complete; missing data FAILS:" % len(rep["data_problems"]))
        for p in rep["data_problems"]:
            L.append("  %-10s %s: %s" % p)
    br = rep["breaches"]
    L.append("BREACHES (%d; P1 %d):" % (len(br), len([b for b in br if b.get("severity") == "P1"])))
    for b in br:
        j = b.get("jev")
        L.append("  [%s] %s = %s (max %s)  %s  Jev: %s" % (b.get("severity", "P2"), b["metric"], b["value"], b["max"], b["why"], "%s %.2f" % (j["choice"], j["confidence"]) if j else "not judged"))
    ooc = rep["out_of_context"]
    if ooc:
        L.append("OUT OF CONTEXT (%d) - expected only under fault injection, seen without evidence of one:" % len(ooc))
        for s in ooc:
            j = s.get("jev")
            L.append("  %s %-10s x%-4d (unexcused %d) %s  Jev: %s" % (s["level"], s["family"], s["count"], s["count_nonfi"], s["key"][:120], "%s %.2f" % (j["choice"], j["confidence"]) if j else "not judged"))
    new = rep["new"]
    jc = Counter((s.get("jev") or {}).get("choice", "unjudged") for s in new)
    L.append("NEW SIGNATURES (%d; Jev: %s):" % (len(new), ", ".join("%s %d" % kv for kv in sorted(jc.items())) or "-"))
    for s in new:
        j = s.get("jev")
        L.append("  %s %-10s x%-4d %s  Jev: %s" % (s["level"], s["family"], s["count"], s["key"][:150], "%s %.2f" % (j["choice"], j["confidence"]) if j else "not judged"))
    L.append("ROSE (%d):" % len(rep["rose"]))
    for s in rep["rose"]:
        j = s.get("jev")
        L.append("  %s %-10s max/boot %s (baseline %s, limit %s) %s  Jev: %s" % (s["level"], s["family"], s["max_per_boot"], (s["baseline"] or {}).get("max_per_boot"), s.get("rise_limit"), s["key"][:120], "%s %.2f" % (j["choice"], j["confidence"]) if j else "not judged"))
    L.append("KNOWN-DEFECT PRESENT (%d):" % len(rep["known_defects_present"]))
    for s in rep["known_defects_present"]:
        L.append("  %s %-10s x%-4d %s  [%s]" % (s["level"], s["family"], s["count"], s["key"][:130], (s["baseline"] or {}).get("issue", "?")))
    if rep["unsettled_present"]:
        L.append("UNSETTLED IN BASELINE, PRESENT (%d) - a human decision is owed:" % len(rep["unsettled_present"]))
        for s in rep["unsettled_present"]:
            L.append("  %s %-10s x%-4d %s" % (s["level"], s["family"], s["count"], s["key"][:140]))
    m = rep["metrics"]
    L.append("METRICS: " + " ".join("%s=%s" % (k, v) for k, v in sorted(m.items()) if k != "deaths_by_exit_code") + " deaths_by_exit_code=%s" % json.dumps(m.get("deaths_by_exit_code")))
    j = rep["jev"]
    L.append("JEV: calls=%d (%d split for size) questions=%d rc=%s %s wire=%s" % (len(j["calls"]), len([c for c in j["calls"] if c.get("split")]), j["questions"], j["rc"],
                                                                                ("- " + j["incomplete_reason"]) if j.get("incomplete_reason") else "", j["wire_log"]))
    text = "\n".join(L) + "\n"
    if path:
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)
    return text


# ----------------------------------------------------------------------------------------------- analyze
def cmd_analyze(a):
    since = parse_iso(a.since) if a.since else None
    baseline = {"signatures": {}, "patterns": [], "thresholds": {}}
    if a.baseline and a.baseline != "none":
        with open(a.baseline, encoding="utf-8") as f:
            baseline = json.load(f)
    meta, files, problems = load_logs(a.logsdir)
    # --since is UTC (the wrapper's contract); the guest's logs and event records are in GUEST LOCAL time. The collector
    # reports the offset (tz=+hh:mm); a guest not pinned to UTC (the German images) is shifted here, never assumed.
    if since is not None and meta and (meta.get("begin") or {}).get("tz"):
        m = re.match(r"^([+-])(\d\d):(\d\d)$", meta["begin"]["tz"])
        if m:
            off = dt.timedelta(hours=int(m.group(2)), minutes=int(m.group(3)))
            since = since + off if m.group(1) == "+" else since - off
    # A --since WINDOW IS ONLY AS GOOD AS THE GUEST'S CLOCK. The window arrives in UTC and the logs
    # are in guest-local time, converted above with the offset the collector reports - but if the
    # guest's clock itself is wrong, no conversion saves it. MEASURED 2026-10-08 on win11r-logvol:
    # the collector reported tz=+00:00 with now=nowutc=09:50:36 while the host's UTC was 06:50, so
    # the guest believed UTC was three hours later than it was, every line looked three hours newer
    # than the window, and a quiet boot's sweep silently admitted the two shutdown errors from the
    # previous run and the one before it. That is a DATA problem - the sweep is not complete - and
    # never something to absorb, because the direction of the error makes a clean run look dirty and
    # a declared fault-injection window cover lines it never caused.
    # TWO CLOCKS, RECORDED AT THE SAME MOMENT. "now at analyze time" is not the second clock: a
    # corpus analysed hours or days later would read as a huge skew, which is exactly what happened
    # to this suite's own fixtures on the first attempt. The wrapper records the HOST's UTC when it
    # runs the collector and passes it here; with no --host-utc there is no second clock and nothing
    # is claimed either way.
    if a.host_utc and meta and (meta.get("begin") or {}).get("nowutc"):
        guest_now = parse_iso((meta["begin"]["nowutc"] or "").rstrip("Z"))
        host_now = parse_iso(a.host_utc.rstrip("Z"))
        if guest_now is not None and host_now is not None:
            skew = (guest_now - host_now).total_seconds()
            if abs(skew) > CLOCK_SKEW_TOLERANCE_S:
                problems.append(("clockskew", a.logsdir,
                    "the guest's clock is %+.0f s from the host's at collection time (guest said %s, tz %s; "
                    "host said %s) - no --since window can be trusted, so every count may include lines from "
                    "outside it" % (skew, meta["begin"]["nowutc"], (meta["begin"] or {}).get("tz"), a.host_utc)))
    if not files:
        problems.append(("missing", a.logsdir, "no log files at all"))
    boots = cluster_boots(files)
    st = build_structure(files, boots, load_context(a.logsdir))
    now = parse_iso((meta.get("begin") or {}).get("now")) if meta and (meta.get("begin") or {}).get("now") else None
    metrics = compute_metrics(files, boots, st, since, now)
    sigs = collect_signatures(files, since)
    cmp = compare(sigs, baseline, metrics)
    items = build_jev_items(cmp, st, metrics, files, since)

    repo = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    workdir = a.workdir or os.path.join(repo, "scratchpad", "log-sweep", time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + re.sub(r"[^A-Za-z0-9_-]", "_", a.label or "run"))
    wire_log = os.environ.get("JEV_WIRE_LOG") or os.path.join(repo, "scratchpad", "jev-wire.jsonl")
    jev_cmd = a.jev_cmd.split() if a.jev_cmd else [sys.executable, os.path.join(repo, "tools", "jev.py")]
    answers, calls, jrc, jreason = {}, [], 0, None
    if items:
        if a.no_jev:
            jrc, jreason = 2, "--no-jev: %d item(s) left unjudged" % len(items)
        else:
            answers, calls, jrc, jreason = run_jev(items, lambda part: jev_state_text(part, meta, boots, st, metrics, a.label, since),
                                                   workdir, jev_cmd, a.jev_max, wire_log)
    judged_defects = []
    for it in items:
        ans = answers.get(it["id"])
        if ans:
            j = {"choice": ans.get("choice"), "confidence": ans.get("confidence"), "probabilities": ans.get("probabilities")}
            if it["kind"] == "breach":
                for b in cmp["breaches"]:
                    if b["metric"] == it["metric"]:
                        b["jev"] = j
            else:
                it["sig"]["jev"] = j
            is_defect = (j["choice"] == "defect")   # GUARD:defect DEFECT: is_defect = False
            if is_defect:
                judged_defects.append(it["id"])

    incomplete = (jrc != 0)   # GUARD:jev2 DEFECT: incomplete = False
    if problems:
        status, rc = "DATA", 3
    elif incomplete:
        status, rc = "INCOMPLETE", 4
    elif cmp["breaches"] or judged_defects:
        status, rc = "FINDINGS", 1
    else:
        status, rc = "CLEAN", 0
    # a data problem never hides findings: the report still carries them
    c = st["context"]
    rep = {
        "version": VERSION, "status": status, "rc": rc,
        "context": {"fault_injection": c["fault_injection"], "declared": c["declared"], "declared_source": c["declared_source"], "unproven": c["unproven"],
                    "sources": c["sources"], "detection_missing": c["detection_missing"],
                    "records": [{"file": r["file"], "name": r["name"], "pid": r["pid"], "t_suspend": fmt_ts(r["t_suspend"]), "t_resume": fmt_ts(r["t_resume"]),
                                 "alive_after": r["alive"], "joined": r["joined"], "checks": r["checks"]} for r in c["records"]]},
        "out_of_context": [sig_json(s) for s in cmp["out_of_context"]],
        "header": {"label": a.label, "since": fmt_ts(since) if since else None, "generated": utcnow_iso(), "logsdir": os.path.abspath(a.logsdir),
                   "baseline": a.baseline, "files": len(files), "lines": sum(lf.scanned for lf in files), "boots": len(boots), "shutdowns": len(st["windows"]),
                   # CORPUS MODE HAS NO META (load_logs returns None for a plain directory of
                   # collected logs), so this must not reach into it - reading it unguarded crashed
                   # `analyze <dir>` outright, and no test covered that mode.
                   "inventory": (meta or {}).get("inventory"), "invmodules": (meta or {}).get("invmodules") or [],
                   "agent_instances": len(st["instances"]), "collector": meta.get("begin") if meta else None},
        "data_problems": problems,
        "files": [{"name": lf.name, "family": lf.family, "scanned": lf.scanned, "parsed": len(lf.lines), "ignored": lf.ignored, "unparsed": lf.unparsed, "skipped": lf.skipped,
                   "partial": lf.partial, "pid": lf.pid, "boot": lf.boot, "version": lf.version} for lf in files],
        "boots": [{"id": b["id"], "time": fmt_ts(b["time"])} for b in boots],
        "shutdowns": [{"id": w["id"], "start": fmt_ts(w["start"]), "end": fmt_ts(w["end"]), "approximate": w["approx"] or w["approx_end"], "markers": w["markers"],
                       "instances": [i["pid"] for i in w["instances"]], "launches": len(w["launches"]), "deaths": [(d["pid"], d["code"]) for d in w["deaths"]],
                       "going_down": [(d["pid"], d["code"]) for d in w["goingdown"]], "vchan_announces": len(w["announces"]),
                       "requested_stops": [{"pid": i["pid"], "exit_code": i["stop"]["code"], "errors_during_stop": len(i["errors_during_stop"])} for i in w["stops"]]} for w in st["windows"]],
        "instances": [{"pid": i["pid"], "file": i["file"], "boot": i["boot"], "session": i["session"], "version": i["version"], "start": fmt_ts(i["start"]), "end": fmt_ts(i["end"]),
                       "fi_build": i.get("fi_build"), "fi_armed": i.get("fi_armed"),
                       "broker_events": [{"kind": e["kind"], "ts": fmt_ts(e["ts"]), "pid": e["pid"], "fi": e.get("fi"), "record_pid": e["record"]["pid"] if e.get("record") else None} for e in i.get("broker_events", []) if e["kind"] != "REG"],
                       "lines": i["lines"], "announces": i["announces"], "connects": i["connects"], "handshake_refusals": i["handshake_refusals"],
                       "helper_launches": dict(i["helper_launches"]), "helper_deaths": i["helper_deaths"], "end_kind": i["end_kind"], "exit_code": i["exit_code"],
                       "stop": ({"asked": fmt_ts(i["stop"]["asked"]), "gone": fmt_ts(i["stop"]["gone"]), "code": i["stop"]["code"]} if i["stop"] else None),
                       "errors_during_stop": [l.raw[:300] for l in i["errors_during_stop"]], "exit_errors": [l.raw[:300] for l in i["exit_errors"]],
                       "stale_errors": [l.raw[:300] for l in i["stale_errors"]]} for i in st["instances"]],
        "metrics": metrics, "thresholds": {k: v for k, v in cmp["thresholds"].items() if isinstance(v, dict)},
        "breaches": cmp["breaches"], "judged_defects": judged_defects,
        "new": [sig_json(s) for s in cmp["new"]], "rose": [sig_json(s) for s in cmp["rose"]],
        "known_defects_present": [sig_json(s, False) for s in cmp["known"]], "unsettled_present": [sig_json(s, False) for s in cmp["unsettled"]],
        "expected_present": len(cmp["expected"]),
        "signatures": {k: sig_json(s, False) for k, s in sorted(sigs.items())},
        "jev": {"calls": calls, "questions": len(items), "rc": jrc, "incomplete_reason": jreason, "wire_log": wire_log, "workdir": workdir},
    }
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(rep, f, indent=1, default=str)
    text = write_summary(rep, a.summary)
    sys.stdout.write(text)
    return rc


# ----------------------------------------------------------------------------------------------- decode
PULL_RE = re.compile(r"^PULL name=(\S+) lines=(\d+) bytes=(\d+) sha256=([0-9a-f]{64}) b64lines=(\d+)$")
PULLEND_RE = re.compile(r"^PULLEND name=(\S+) b64lines=(\d+)$")


def cmd_decode(a):
    with open(a.pullfile, encoding="utf-8", errors="replace") as f:
        lines = [ln.rstrip("\r\n").replace("\0", "") for ln in f]
    meta = {"begin": None, "logdir": None, "files": [], "fileerrs": [], "skipped": None, "events": None, "end": None, "decode": [], "pullfile": os.path.abspath(a.pullfile)}
    blocks, cur = {}, None
    for ln in lines:
        if not ln.startswith(MARK):
            continue
        body = ln[len(MARK):]
        if body.startswith("BEGIN "):
            meta["begin"] = kv_parse(body[6:])
        elif body.startswith("LOGDIR "):
            meta["logdir"] = kv_parse(body[7:])
        elif body.startswith("FILE "):
            meta["files"].append(kv_parse(body[5:]))
        elif body.startswith("FILEERR "):
            meta["fileerrs"].append(kv_parse(body[8:]))
        elif body.startswith("FILESKIPPED "):
            meta["skipped"] = kv_parse(body[12:])
        elif body.startswith("INVENTORY "):
            # What the guest's log directory actually holds, independent of the collection cap.
            meta["inventory"] = kv_parse(body[10:])
        elif body.startswith("INVMODULE "):
            meta.setdefault("invmodules", []).append(kv_parse(body[10:]))
        elif body.startswith("EVENTS "):
            meta["events"] = kv_parse(body[7:])
        elif body.startswith("PULL "):
            m = PULL_RE.match(body)
            if m:
                cur = m.group(1)
                blocks[cur] = {"lines": int(m.group(2)), "bytes": int(m.group(3)), "sha": m.group(4), "b64n": int(m.group(5)), "b64": [], "end_n": None}
        elif body.startswith("B|"):
            if cur:
                blocks[cur]["b64"].append(body[2:])
        elif body.startswith("PULLEND "):
            m = PULLEND_RE.match(body)
            if m and cur == m.group(1):
                blocks[cur]["end_n"] = int(m.group(2))
            cur = None
        elif body.startswith("END "):
            meta["end"] = kv_parse(body[4:])
    os.makedirs(os.path.join(a.out, "files"), exist_ok=True)
    rc = 0
    # THE INTEGRITY GATE: announced base64 line count, byte count, sha256 and line count must all agree, and the
    # stream must carry its END line. Trust counts, not streams (the toast-hold pull lesson).
    strict = True   # GUARD:truncated DEFECT: strict = False
    if meta["begin"] is None:
        print("DECODE: no BEGIN line - this is not a collector stream"); rc = 1
    if meta["end"] is None and strict:
        print("DECODE: no END line - the stream was CUT SHORT"); rc = 1

    def verify(name, b):
        if b is None:
            return None, "MISSING block"
        if strict and (len(b["b64"]) != b["b64n"] or b["end_n"] != b["b64n"]):
            return None, "base64 line count %d != announced %d / end %s - TRUNCATED transfer" % (len(b["b64"]), b["b64n"], b["end_n"])
        try:
            data = base64.b64decode("".join(b["b64"]), validate=True)
        except (ValueError, base64.binascii.Error) as e:
            return None, "base64 invalid (%s)" % e
        if strict and (len(data) != b["bytes"] or hashlib.sha256(data).hexdigest() != b["sha"]):
            return None, "bytes/sha mismatch (%d vs %d)" % (len(data), b["bytes"])
        text = data.decode("utf-8", errors="replace")
        n = len(text.split("\n")) if text else 0
        if strict and n != b["lines"] and not (b["lines"] == 0 and text == ""):
            return None, "%d lines decoded, %d announced" % (n, b["lines"])
        return text, None

    used = set()
    for fe in meta["files"]:
        name = fe.get("id")
        path = b64dec_path(fe.get("pathb64", ""))
        base = os.path.basename(path.replace("\\", "/")) or name
        local = base if base not in used else "%s.%s" % (base, name)
        used.add(local)
        text, err = verify(name, blocks.get(name))
        if err:
            print("DECODE %s (%s): %s" % (name, base, err)); rc = 1
            meta["decode"].append({"id": name, "path": path, "ok": False, "error": err})
            continue
        with open(os.path.join(a.out, "files", local), "w", encoding="utf-8") as f:
            f.write(text + ("\n" if text and not text.endswith("\n") else ""))
        fe["local"] = os.path.join("files", local)
        meta["decode"].append({"id": name, "path": path, "ok": True, "lines": blocks[name]["lines"], "bytes": blocks[name]["bytes"]})
        print("DECODE %s (%s): OK lines=%s bytes=%s sha256=%s partial=%s" % (name, base, blocks[name]["lines"], blocks[name]["bytes"], blocks[name]["sha"][:12], fe.get("partial", "0")))
    if meta["events"] is not None:
        text, err = verify("events", blocks.get("events"))
        if err:
            print("DECODE events: %s" % err); rc = 1
        else:
            with open(os.path.join(a.out, "events.txt"), "w", encoding="utf-8") as f:
                f.write(text + ("\n" if text and not text.endswith("\n") else ""))
            print("DECODE events: OK lines=%s bytes=%s" % (blocks["events"]["lines"], blocks["events"]["bytes"]))
    for fe in meta["fileerrs"]:
        print("DECODE FILEERR %s: %s" % (b64dec_path(fe.get("pathb64", "?")), fe.get("error", "?")))
    with open(os.path.join(a.out, "meta.json"), "w", encoding="utf-8") as f:
        json.dump(meta, f, indent=1)
    print("DECODE %s: files=%d ok=%d errors=%d" % ("OK" if rc == 0 else "FAILED", len(meta["files"]), sum(1 for d in meta["decode"] if d["ok"]), sum(1 for d in meta["decode"] if not d["ok"])))
    return rc


# ----------------------------------------------------------------------------------------------- baseline-init
def cmd_baseline_init(a):
    sigs = {}
    seen_reports = []
    for rp in a.reports:
        with open(rp, encoding="utf-8") as f:
            rep = json.load(f)
        seen_reports.append(os.path.basename(rp))
        jev_by_key = {s["key"]: s.get("jev") for s in rep.get("new", []) + rep.get("rose", []) if s.get("jev")}
        for k, s in rep.get("signatures", {}).items():
            e = sigs.setdefault(k, {"family": s["family"], "level": s["level"], "max_per_boot": 0, "seen": 0, "jev": None, "prior": s.get("baseline")})
            e["max_per_boot"] = max(e["max_per_boot"], int(s.get("max_per_boot") or 0))
            e["seen"] += int(s.get("count") or 0)
            j = jev_by_key.get(k)
            if j and (e["jev"] is None or (j.get("confidence") or 0) > (e["jev"].get("confidence") or 0)):
                e["jev"] = j
    rules, fi_rules, ref_rules = [], [], []
    for kd in a.known_defect or []:
        parts = kd.split("=", 2)
        if len(parts) != 3:
            print("bad --known-defect (want REGEX=ISSUE=REASON): %r" % kd); return 2
        rules.append((re.compile(parts[0]), parts[1], parts[2]))
    for kd in a.expected_in_fi or []:
        parts = kd.split("=", 2)
        if len(parts) != 3:
            print("bad --expected-in-fi (want REGEX=ISSUE=REASON): %r" % kd); return 2
        fi_rules.append((re.compile(parts[0]), parts[1], parts[2]))
    for kd in a.issue_ref or []:
        parts = kd.split("=", 1)
        if len(parts) != 2:
            print("bad --issue-ref (want REGEX=ISSUE): %r" % kd); return 2
        ref_rules.append((re.compile(parts[0]), parts[1]))
    out = {"version": VERSION, "generated": utcnow_iso(), "source_reports": seen_reports,
           "note": "normalized SIGNATURE patterns + a reason each; never captured log content. status: expected | benign | known-defect | unsettled. "
                   "max_per_boot is the rise ceiling (rise = > max(ceiling*rise_factor, ceiling+rise_min_delta)).",
           "thresholds": {k: v for k, v in DEFAULT_THRESHOLDS.items()}, "patterns": [], "signatures": {}}
    counts = Counter()
    for k in sorted(sigs):
        e = sigs[k]
        j = e["jev"]
        status, reason, issue, context = None, "", None, None
        for rx, iss, rsn in rules:
            if rx.search(k):
                status, issue, reason = "known-defect", iss, rsn
                break
        if status is None:
            for rx, iss, rsn in fi_rules:
                if rx.search(k):
                    status, issue, reason, context = "expected", iss, rsn, "fault-injection"
                    break
        if status is None and e.get("prior") and e["prior"].get("status") in ("expected", "benign", "known-defect", "unsettled"):
            status, reason, issue, context = e["prior"]["status"], e["prior"].get("reason", ""), e["prior"].get("issue"), e["prior"].get("context")
        if status is None:
            if j is None:
                status, reason = "unsettled", "never judged (no Jev answer in the source reports)"
            elif j.get("choice") == "defect" and (j.get("confidence") or 0) >= 0.5:
                status, reason, issue = "known-defect", "Jev: defect %.2f on the corpus - unfiled; confirm and file or downgrade" % j["confidence"], "unfiled"
            elif j.get("choice") == "expected" and (j.get("confidence") or 0) >= 0.5:
                status, reason = "expected", "Jev: expected %.2f on the corpus" % j["confidence"]
            elif j.get("choice") == "noise" and (j.get("confidence") or 0) >= 0.5:
                status, reason = "benign", "Jev: noise %.2f on the corpus" % j["confidence"]
            else:
                status, reason = "unsettled", "Jev: %s %.2f on the corpus (below 0.5) - a human decision is owed" % (j.get("choice"), j.get("confidence") or 0)
        for rx, iss in ref_rules:
            if rx.search(k):
                issue = iss
        ent = {"status": status, "reason": reason, "max_per_boot": e["max_per_boot"], "family": e["family"], "level": e["level"]}
        if issue:
            ent["issue"] = issue
        if context:
            ent["context"] = context
        if j:
            ent["jev"] = {"choice": j.get("choice"), "confidence": j.get("confidence")}
        out["signatures"][k] = ent
        counts[status] += 1
    for rx, iss, rsn in rules:
        out["patterns"].append({"regex": rx.pattern, "status": "known-defect", "issue": iss, "reason": rsn})
    for rx, iss, rsn in fi_rules:
        out["patterns"].append({"regex": rx.pattern, "status": "expected", "context": "fault-injection", "issue": iss, "reason": rsn})
    with open(a.out, "w", encoding="utf-8") as f:
        json.dump(out, f, indent=1, sort_keys=False)
    print("BASELINE %s: %d signatures (%s), %d patterns, from %d report(s)" % (a.out, len(out["signatures"]), ", ".join("%s %d" % kv for kv in sorted(counts.items())), len(out["patterns"]), len(seen_reports)))
    return 0


# ----------------------------------------------------------------------------------------------- baseline-audit
def cmd_baseline_audit(a):
    """The tracked baseline must carry the issue references REQUIRED_REFS names; a baseline that lost one is refused."""
    with open(a.baseline, encoding="utf-8") as f:
        b = json.load(f)
    entries = [(k, v) for k, v in (b.get("signatures") or {}).items()] + [(p.get("regex", ""), p) for p in (b.get("patterns") or [])]
    failures = []
    audit_on = True   # GUARD:issuerefs DEFECT: audit_on = False
    for rx_s, status, need in REQUIRED_REFS:
        rx = re.compile(rx_s)
        hits = [(k, v) for k, v in entries if rx.search(k) or (rx_s in k)]
        if not hits:
            failures.append("no baseline entry or pattern matches /%s/" % rx_s)
            continue
        for k, v in hits:
            if status and v.get("status") != status:
                failures.append("%s: status %s, want %s" % (k[:90], v.get("status"), status))
            if "issue" in need and need["issue"] not in str(v.get("issue", "")):
                failures.append("%s: issue %r lacks %r" % (k[:90], v.get("issue"), need["issue"]))
            if "context" in need and v.get("context") != need["context"]:
                failures.append("%s: context %r, want %r" % (k[:90], v.get("context"), need["context"]))
    if not audit_on:
        failures = []
    if failures:
        print("BASELINE-AUDIT FAIL %s: %d required reference(s) missing" % (a.baseline, len(failures)))
        for f in failures:
            print("  " + f)
        return 1
    print("BASELINE-AUDIT OK %s: %d required reference rows present" % (a.baseline, len(REQUIRED_REFS)))
    return 0


# ----------------------------------------------------------------------------------------------- main
def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    d = sub.add_parser("decode"); d.add_argument("pullfile"); d.add_argument("--out", required=True)
    an = sub.add_parser("analyze"); an.add_argument("logsdir"); an.add_argument("--baseline", required=True); an.add_argument("--out", required=True)
    an.add_argument("--summary"); an.add_argument("--since")
    an.add_argument("--host-utc", help="this host's UTC at the moment the collector ran, so the guest's "
                                       "clock can be checked against a second clock rather than against now"); an.add_argument("--label", default="run"); an.add_argument("--workdir")
    an.add_argument("--jev-cmd", help="override the judge command (tests use a stub)")
    an.add_argument("--jev-max", type=int, default=25, help="questions per call; more items = more calls, each with its own items' state")
    an.add_argument("--no-jev", action="store_true", help="do not call the judge: any item to judge makes the run INCOMPLETE")
    bi = sub.add_parser("baseline-init"); bi.add_argument("reports", nargs="+"); bi.add_argument("--out", required=True)
    bi.add_argument("--known-defect", action="append", help="REGEX=ISSUE=REASON: force known-defect on matching signature keys (repeatable)")
    bi.add_argument("--expected-in-fi", action="append", help="REGEX=ISSUE=REASON: expected ONLY in a fault-injection context (repeatable)")
    bi.add_argument("--issue-ref", action="append", help="REGEX=ISSUE: set the issue reference on matching keys, status unchanged (repeatable)")
    ba = sub.add_parser("baseline-audit"); ba.add_argument("baseline")
    a = ap.parse_args(argv)
    if a.cmd == "decode":
        return cmd_decode(a)
    if a.cmd == "analyze":
        return cmd_analyze(a)
    if a.cmd == "baseline-audit":
        return cmd_baseline_audit(a)
    return cmd_baseline_init(a)


if __name__ == "__main__":
    sys.exit(main())
