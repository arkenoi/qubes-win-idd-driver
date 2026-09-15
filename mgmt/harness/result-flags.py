#!/usr/bin/env python3
"""result-flags.py - judge an installer RESULT trailer by its ERROR-CLASS detail flags, not by ok alone.

WHY THIS EXISTS. Install-QwtImproved.ps1 has ~20 warn-and-continue paths that record their failure
ONLY in Result.detail.* (idd_failed, pv_xenvif='failed rc=N', gui_restored='FAILED: ...', ...) and
until 2026-09-16 wrote ok=true regardless - and NO harness read any detail key: quick-upgrade.sh
grepped '"ok":true', matrix.sh graded upgrade_mode / the agent hash / autologon and never looked at
ok at all. A guest with no IDD, no PV NIC driver or no gui-agent therefore graded GREEN
(findings/issues.md, installer P1, audit 2026-09-16: "the systemic one"). The installer's stage-2
terminal now folds ten of those flags into ok=false itself, but (a) gui_restored='FAILED' is written
AFTER that fold, (b) the goldens carry older installers that do not have it, and (c) a harness must
judge the trailer it is handed, not trust the writer. This is the ONE place the flag list lives;
quick-upgrade.sh and matrix.sh both call it at the point where the RESULT is graded.

USAGE
    result-flags.py '=== RESULT === {json}' [...]          one or more trailer lines as arguments
    grep -a '^=== RESULT === {' log | result-flags.py -     one trailer per line on stdin
    result-flags.py --list-keys                             the classification, for the drift test
A bare JSON object is accepted too. EVERY line given is judged, not only the last: on the two-stage
path the last trailer can be stage-1's, and a stage-1 flag would otherwise be invisible.

OUTPUT. One line per trailer, then ONE summary line LAST - that is the line the harnesses quote:
    RESULT ok:true, no error-class flags (1 trailer judged)
    RESULT ok:true but error flags: idd_failed=true, pv_xenvif=failed rc=1
    RESULT ok:false (error: msiexec failed with 1603) with error flags: msiexec_rc=1603
EXIT  0  every trailer ok:true and no error-class flag
      1  some trailer is not ok:true, or carries an error-class flag  (the cell FAILS, flags named)
      2  nothing parseable was given - the caller keeps whatever it does today for a missing or
         unparseable trailer (mandated carve-out; this file changes only the GREEN verdict)
      3  usage
Error wins over unparseable: one bad trailer among several is a FAIL, never masked by a broken one.

CLASSIFICATION, derived by reading every `$script:Result.detail.<key> =` in
packaging/setup/Install-QwtImproved.ps1 (line numbers as of commit 394f86a; the selftest fails if the
installer grows a key this file does not classify). ERROR-CLASS = the site logs ERROR, or logs WARN
about an operation that was ATTEMPTED and did not take (a driver not installed, a task not
registered, a helper that threw / reported failed>0 / returned without its trailer), or a value the
installer itself Fails on. INFORMATIONAL = a switch skipped it, the payload does not carry it
(packaging composition is asserted elsewhere - see matrix.sh's pv-drivers/xenbus check), or it is a
plain record. The 35 healthy trailers on record (2026-09-05..14, all ok:true) carry NONE of the
error forms - run through this file before it shipped; notably etwproxy_account is
'skipped:account-create-refused' on green runs, which is why 'skipped:*' is informational there.

Selftest: tools/tests/result-flags-selftest.sh (RESULTFLAGS_DEFECT=1 blanks the table between the
FLAGS-BEGIN/END markers = the original bug, and must make that test FAIL).
"""
from __future__ import annotations
import json
import re
import sys

RESULT_RE = re.compile(r'^\s*(?:===\s*RESULT\s*===\s*)?(\{.*)$')


# --------------------------------------------------------------------------- predicates
# Each takes the detail VALUE (only keys present in the trailer are evaluated) and returns True when
# the value is the error form. Kept tiny and named so the table below reads as the classification.
def _s(v) -> str:
    return '' if v is None else str(v)


def is_true(v) -> bool:
    return v is True


def is_false(v) -> bool:
    return v is False


def starts(*prefixes):
    return lambda v: isinstance(v, str) and v.startswith(prefixes)


def nonempty(v) -> bool:
    # '', None, [], {}, False are "nothing recorded"; a name list, a pid list, a message are the error.
    return bool(v) and v is not False


def helper_failed(v) -> bool:
    """The app-tweak helpers report 'changed=N failed=M'; the installer records 'error: ...' when they
    threw and 'ran, no result trailer' when they returned without reporting (missing data fails)."""
    s = _s(v)
    if s.startswith('error:') or s == 'ran, no result trailer':
        return True
    m = re.search(r'\bfailed=(\d+)', s)
    return bool(m and int(m.group(1)) > 0)


def rc_not_in(*ok):
    """A native exit code outside the set the installer itself accepts at that site."""
    def _p(v) -> bool:
        if v is None:
            return False
        try:
            return int(v) not in ok
        except (TypeError, ValueError):
            return True            # not a number at all: the site recorded something other than an rc
    return _p


def any_value(pred):
    """A dict of per-item outcomes (service -> state, feature -> state, product -> rc)."""
    return lambda v: isinstance(v, dict) and any(pred(x) for x in v.values())


# --------------------------------------------------------------------------- the classification
# ---- FLAGS-BEGIN  (tools/tests/result-flags-selftest.sh blanks this block under RESULTFLAGS_DEFECT=1)
ERROR_FLAGS = [
    # (detail key, error-form predicate, installer site - what the flag means when it is in error form)
    # -- display (IddCx activation): the headline capability; failure = guest on the emulated BDA
    ('idd_failed',              is_true,                                  'L2999 ERROR: IDD activation failed, guest boots on the Basic Display Adapter'),
    ('idd_driver',              starts('FAILED'),                         'L2998: narrative of idd_failed'),
    ('idd_vga_disable_pending', is_true,                                  'L2982 ERROR: VGA adapter still enabled in-session after Disable-PnpDevice (code != 22)'),
    ('idd_gui_reappeared',      nonempty,                                 'L2689 WARN: the gui-agent came back during stage 2 - the quiesce is not holding'),
    ('idd_bound',               starts('unreadable'),                     'L2902/L2922 WARN: bound driver version unreadable, the version assertion was skipped'),
    ('gui_quiesce_failed',      nonempty,                                 'L2557 ERROR: quiesce did not hold, the live processes by name'),
    ('gui_restored',            starts('FAILED'),                         'L3862/L3867 ERROR: watchdog started but gui-agent.exe not running / could not be restarted'),
    # -- PV network / console / NIC priming
    ('pv_xenvif',               starts('failed'),                         'L2609 WARN pnputil rc; L3656 ERROR the unplug latch is refused over it'),
    ('pv_xencons',              starts('failed'),                         'L2646 WARN: DEV_CONS stays at code 28, no out-of-band console'),
    ('pvnic_prime_failed',      is_true,                                  'L3612/L3617 ERROR: PV NIC priming failed or threw'),
    ('pvnic_prime',             starts('FAILED', 'error:'),               'L3611/L3616: narrative of pvnic_prime_failed'),
    ('pvnic_latch',             starts('not-armed', 'unconfirmed', 'error:'), 'L3662 ERROR not armed / L3673 WARN NICS did not read back 1 / L3677 WARN threw'),
    ('net_reapply_task',        starts('failed'),                         'L3736 WARN: schtasks /create QubesNetworkReapply failed'),
    # -- pre-msiexec conditions (the installer Fails on most of these; the WARN forms proceed)
    ('pnp_settle',              starts('timeout', 'unavailable'),         'L1422 WARN timeout (a Fail since L1711/L2188) / L1426 WARN the API would not load = no wait at all'),
    ('private_disk_gate',       starts('WARN', 'FAIL'),                   'L1585/L1598 WARN proceeding under -NoMoveUsers / L1588/L1601 Fail'),
    ('inbox_disk_rearm',        starts('incomplete', 'failed'),           'L2150/L2162 WARN (a Fail when C: is on the PV path): boot-start IDE driver not re-armed'),
    ('leftover_sweep',          lambda v: isinstance(v, dict) and bool(v.get('stuck')), 'L747 WARN could not move a leftover aside; refuses msiexec at L2021'),
    ('xenbus_monitor_survivors', nonempty,                                'L425: xenbus_monitor still running after two kill attempts (WARN, or Fail with -FatalIfSurvives)'),
    ('hiberboot',               lambda v: v is not None and _s(v) != '0', 'L1130: Fast Startup still enabled (Fails at L1131)'),
    # -- the MSI and its verification
    ('uninstall_rc',            any_value(rc_not_in(0, 3010, 1605)),      'L917: msiexec /x rc outside 0/3010/1605 (Fails at L911)'),
    ('vc_redist_rc',            rc_not_in(0, 3010, 1638),                 'L2037: vc_redist rc outside 0/3010/1638 (Fails at L2035)'),
    ('msiexec_rc',              rc_not_in(0, 3010),                       'L2231: msiexec /i rc outside 0/3010 (Fails at L2229)'),
    ('same_version_addlocal_retry', rc_not_in(0, 3010),                   'L2302: the ADDLOCAL-only retry rc outside 0/3010 (Fails at L2305)'),
    ('features_installed',      any_value(lambda x: _s(x) != '3'),        'L2278/L2308: a requested feature not LOCAL(3) (Fails at L2316)'),
    ('agent_hash_verified',     is_false,                                 'L2451 WARN: MANIFEST has no reference_binaries - the installed agent could not be verified'),
    ('swept_binaries_lost',     nonempty,                                 'L771: the old gui binaries could not be put back on the Fail path'),
    ('shutdown_rc',             lambda v: v is not None and _s(v) != '0', 'L1369 FATAL: shutdown.exe /s refused, the guest is not powering off'),
    # -- private volume / overlays / helpers
    ('relocate_dir_disarmed',   lambda v: v is True or starts('failed')(v), 'L2394 WARN disarmed because Q: is absent / L2405 WARN could NOT disarm'),
    ('bind_dirs',               starts('installed-no-private-volume', 'error:'), 'L3275 WARN Q: absent at install time / L3279 WARN install threw'),
    ('rpc_overlay_failed',      nonempty,                                 'L3134 WARN: these rpc files stayed STOCK on the guest'),
    ('qrexec_bins',             lambda v: 'FAILED=' in _s(v) or _s(v) == 'target-missing', 'L3205 WARN binaries left STOCK / L3209 WARN bin dir missing'),
    ('appmenu_alias',           starts('service-file-not-found', 'error'), 'L3162/L3166 WARN'),
    ('app_hwaccel',             helper_failed,                            'L3039 failed>0 / L3042 no trailer / L3046 threw'),
    ('session_lock',            helper_failed,                            'L3067 failed>0 / L3068 no trailer / L3071 threw'),
    ('reboot_audit',            helper_failed,                            'L3342 failed>0 / L3343 no trailer / L3346 threw'),
    ('quiet_desktop',           helper_failed,                            'L3428 failed>0 / L3429 no trailer / L3432 threw'),
    ('quiet_desktop_guard',     lambda v: _s(v) != 'rc=0',                'L3472 schtasks rc != 0 / L3475 threw'),
    ('updater_agent',           starts('incomplete', 'error:'),           'L3509 WARN returned without its completion line / L3519 WARN threw'),
    ('etwproxy_account',        starts('error:'),                         "L3323 WARN threw ('skipped:<reason>' at L3317 is the documented fail-open - informational)"),
    ('service_recovery',        any_value(lambda x: _s(x) != 'armed'),    'L538/L542 WARN: stored in detail precisely because a WARN alone let it ship'),
    ('autologon',               lambda v: _s(v) not in ('armed', 'skipped', 'not in payload'),
                                                                          'L1278 not-armed / L1285 error / L3384,L3416 unverified / L3409 no trailer / L3412 verify-error'),
]
# ---- FLAGS-END

# Present-and-harmless, or a plain record. Listed so the drift test can prove every installer key is
# classified one way or the other - a new detail key that lands in neither list fails the selftest.
INFORMATIONAL = (
    'xenbus_monitor',            # L438 'disabled'
    'swept_binaries_restored',   # L770 what the Fail path put back
    'next',                      # L1149/L1942 what the next boot does
    'bin_dir', 'leftovers_targeted', 'existing_qwt', 'upgrade_mode',      # L1741/L1742/L1754-1757/L1853 records
    'pv_boot_disk',              # L1747 probe result; the installer gates on it itself (UNKNOWN = at risk)
    'pvdisk_driver_installed', 'pvdisk_driver_package',                    # L1828/L1829 versions
    'emulated_storage_rearmed',  # L1970 marker
    'addlocal', 'msiexec_1618_retries',                                    # L2232 what was asked / L2217 bounded retry count
    'installed_gui_agent_sha256', 'expected_gui_agent_sha256', 'gui_quiesced_for_stage2',   # L2423/L2425/L2559
    'start_menu_shortcut',       # L2570 by design
    'idd_vga_instance_id', 'idd_recovery',                                 # L2985/L2986 recovery recipe
    'rpc_overlay', 'appmenu_scripts',                                      # L3136/L3141 counts (failure is rpc_overlay_failed)
    'xenbus_autoreboot_final', 'xenbus_monitor_final',                     # L3758/L3759 readback (matrix.sh asserts the service state itself)
    'uac_prompt_on_secure_desktop',                                        # L3778 readback
    'certs_installed', 'precondition', 'payload_files_verified', 'package_version',   # L3921/L4115/L4193/L4205
)


# --------------------------------------------------------------------------- judging
def _short(v) -> str:
    s = v if isinstance(v, str) else json.dumps(v, separators=(',', ':'))
    return s if len(s) <= 100 else s[:97] + '...'


def judge(obj: dict) -> tuple[bool, list[tuple[str, str]]]:
    """-> (ok_is_true, [(key, value-as-text) for every error-class flag present])."""
    detail = obj.get('detail')
    if not isinstance(detail, dict):
        detail = {}
    hits = []
    for key, pred, _why in ERROR_FLAGS:
        if key not in detail:
            continue
        try:
            bad = bool(pred(detail[key]))
        except Exception:             # a predicate that cannot read the value: that IS an anomaly
            bad = True
        if bad:
            hits.append((key, _short(detail[key])))
    return obj.get('ok') is True, hits


def parse_line(line: str):
    m = RESULT_RE.match(line.rstrip('\r\n'))
    if not m:
        return None
    try:
        obj = json.loads(m.group(1))
    except ValueError:
        return None
    return obj if isinstance(obj, dict) else None


def main(argv: list[str]) -> int:
    if len(argv) == 2 and argv[1] == '--list-keys':
        for key, _p, why in ERROR_FLAGS:
            print(f'error\t{key}\t{why}')
        for key in INFORMATIONAL:
            print(f'info\t{key}')
        return 0
    if len(argv) < 2:
        print(__doc__.split('USAGE', 1)[1].split('OUTPUT', 1)[0].strip(), file=sys.stderr)
        return 3
    lines = [ln for ln in sys.stdin.read().splitlines()] if argv[1:] == ['-'] else argv[1:]
    lines = [ln for ln in lines if ln.strip()]

    judged = 0
    unparseable = 0
    not_ok: list[tuple[str, str]] = []          # (stage, error text)
    flags: list[str] = []                       # 'key=value' or 'stage:key=value' when >1 trailer
    per: list[tuple[str, bool, list[tuple[str, str]]]] = []
    for ln in lines:
        obj = parse_line(ln)
        if obj is None:
            unparseable += 1
            print(f'UNPARSEABLE: {ln[:120]}')
            continue
        judged += 1
        ok, hits = judge(obj)
        stage = _s(obj.get('stage')) or '?'
        per.append((stage, ok, hits))
        if not ok:
            not_ok.append((stage, _s(obj.get('error')) or 'no error text'))
    multi = judged > 1
    for stage, ok, hits in per:
        tag = f'{stage}:' if multi else ''
        for k, v in hits:
            flags.append(f'{tag}{k}={v}')
        print(f'[{stage}] ok={json.dumps(ok)}  {len(hits)} error-class flag(s)'
              + (': ' + '; '.join(f'{k}={v}' for k, v in hits) if hits else ''))

    if judged == 0:
        print(f'RESULT: nothing parseable in {len(lines)} line(s) - ok and flags NOT judged')
        return 2
    okpart = 'ok:true' if not not_ok else 'ok:false (' + '; '.join(
        (f'{st}: ' if multi else '') + f'error: {err}' for st, err in not_ok) + ')'
    if flags:
        print(f'RESULT {okpart} {"but" if not not_ok else "with"} error flags: ' + ', '.join(flags))
        return 1
    if not_ok:
        print(f'RESULT {okpart}, no error-class detail flags')
        return 1
    if unparseable:
        print(f'RESULT {okpart} on {judged} trailer(s) but {unparseable} line(s) UNPARSEABLE - not judged')
        return 2
    print(f'RESULT {okpart}, no error-class flags ({judged} trailer{"s" if multi else ""} judged)')
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv))
