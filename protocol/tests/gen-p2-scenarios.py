#!/usr/bin/env python3
"""One-shot generator for the p2-network scenarios (green + 5 defect fixtures).

Kept in protocol/tests/ so the fixtures can be regenerated coherently; the REAL incident
outputs are embedded verbatim (the health-check absence line is the measured hc-u10net2
output; the transfer red line is net-transfer-proof.ps1's own red route; the vif-veteran
reg dump mirrors a real XENVIF\\VEN_XP0001&DEV_NET enum).
"""
import json, shutil
from pathlib import Path

SCEN = Path(__file__).resolve().parent.parent / "scenarios"

VARS = {
    "APPVM": "win10-app",
    "CHURN": "win10-c1",
    "ACCEPT_OUT": "/home/user/qwt-accept/AP-20260901-2/p2-network",
}

SHA = "c98dfc40249b111b9afe469a9f8f849a77f0a7793b3cfbe09cdb72eb9e5bb1bb"
BOOT_A = "2026-09-01T08:41:27.5031250+00:00"
BOOT_B = "2026-09-01T09:47:02.1187500+00:00"   # the hidden second boot

def latch_json(boot, tail):
    return ('{"nics":1,"disks":1,"vif_enum_key":true,"task_main":true,"task_rearm":true,'
            f'"payload_sha256":"{SHA}","marker":false,"boot":"{boot}","log_tail":"{tail}"}}')

LATCH_ABSENT_JSON = ('{"nics":null,"disks":null,"vif_enum_key":false,"task_main":false,'
                     '"task_rearm":false,"payload_sha256":null,"marker":false,'
                     f'"boot":"{BOOT_A}","log_tail":null}}')

APPLIER_OFFLINE = '"pvnic_applier":{"pass":true,"evidence":{"offline":true,"failure_marker_present":false}}'
# REAL measured output (hc-u10net2.txt, 2026-08-30) - the M1-latch-absent incident:
APPLIER_ABSENT = ('"pvnic_applier":{"pass":false,"evidence":{"na":"QubesPvNic task not registered'
                  ' - M1 latch deployment absent"},"na":true}')

NET1_GREEN = "MARKJSON\n" + latch_json(
    BOOT_A,
    "08:43:10 --- run start (boot=" + BOOT_A + ") // 08:43:10 latch re-armed NICS=1 // "
    "08:43:11 xenbus_monitor enforced off (start=disabled, AutoReboot=0)") + "\n" + APPLIER_OFFLINE

NET1_ABSENT = "MARKJSON\n" + LATCH_ABSENT_JSON + "\n" + APPLIER_ABSENT

def health_line(ip="10.137.0.72", rx=379307):
    return ('=== HEALTH === {"ok":true,"checks":{'
            '"agent_binary_hash":{"pass":true,"evidence":{"installed":"E5D125CC8A2AA8FA5520609FEE6B0160F692EFA846FF44FBFF30B7E5AB851A0E","manifest":"e5d125cc8a2aa8fa5520609fee6b0160f692efa846ff44fbff30b7e5ab851a0e"}},'
            '"agent_process":{"pass":true,"evidence":{"pid":4188}},'
            '"qubes_services_running":{"pass":true,"evidence":[{"Name":"QdbDaemon","State":"Running","StartMode":"Auto"},{"Name":"QrexecAgent","State":"Running","StartMode":"Auto"},{"Name":"QubesGuiWatchdog","State":"Running","StartMode":"Auto"},{"Name":"QwtngNetSetup","State":"Running","StartMode":"Auto"}]},'
            '"idd_device_bound":{"pass":true,"evidence":{"instance":"ROOT\\\\DISPLAY\\\\0000","status":"OK","cm_error":0}},'
            '"pv_drivers_bound":{"pass":true,"evidence":{"emulated_nics_still_present":[],"started":{"XENNET":true,"XENVIF":true,"XENBUS":true,"XENIFACE":true},"pv_nics":["Xen PV Network Device #0"]}},'
            f'"network_carries_traffic":{{"pass":true,"evidence":{{"dns_resolves":true,"ping_gateway":false,"ip":"{ip}","gateway":"10.138.21.72","tcp_dns_53":true,"dns_server":"10.139.1.1","rx_bytes":{rx},"tx_bytes":197939,"carries_traffic":true}}}},'
            f'"pvnic_applier":{{"pass":true,"evidence":{{"failure_marker_present":false,"pv_adapter_ips":["{ip}"],"default_route_on_pv":true,"apipa_present":[]}}}},'
            '"clipboard_works":{"pass":true,"evidence":{"qubes_services_running":1,"windows_clipboard_roundtrip":true}}},'
            '"resolution":"1280x800","failed":[],"not_applicable":[],"asserted_all":true}')

POSTBOOT_SAME = "MARKJSON\n" + latch_json(
    BOOT_A,
    "08:43:11 xenbus_monitor enforced off // 08:47:21 vif appeared, applier run // "
    "08:47:24 SUCCESS ip=10.137.0.72 gw=10.138.21.72 route-on-pv")

POSTBOOT_2NDBOOT = "MARKJSON\n" + latch_json(
    BOOT_B,
    "09:49:12 --- run start (boot=" + BOOT_B + ") // 09:49:12 latch re-armed NICS=1 // "
    "09:49:40 SUCCESS ip=10.137.0.72 gw=10.138.21.72 route-on-pv")

NETPROOF_GREEN = (
    "settling 90 s before grading (measured inversion at +90 s)\n"
    "=== NETPROOF ===\n"
    '{"pv_nic":["Ethernet [Xen PV Network Device #0] Up"],"loopback_present":false,'
    '"emulated_left":[],"bytes_requested":25000000,"bytes_received":25000000,"seconds":1.3,'
    '"pv_rx_before":9463443,"pv_rx_after":38517706,"pv_rx_delta":29054263,'
    '"transfer_ok":true,"crossed_pv_nic":true,"ok":true,'
    '"reason":"bytes moved, and the PV adapter\'s own counter accounts for them"}')

# net-transfer-proof.ps1's own red route: the transfer completed, DNS worked, but the XENVIF
# adapter's OWN counter barely moved - the bytes came over something else.
NETPROOF_RED = (
    "settling 90 s before grading (measured inversion at +90 s)\n"
    "=== NETPROOF ===\n"
    '{"pv_nic":["Ethernet [Xen PV Network Device #0] Up"],"loopback_present":true,'
    '"emulated_left":[],"bytes_requested":25000000,"bytes_received":25000000,"seconds":41.7,'
    '"pv_rx_before":9463443,"pv_rx_after":9650885,"pv_rx_delta":187442,'
    '"transfer_ok":true,"crossed_pv_nic":false,"ok":false,'
    '"reason":"bytes arrived but NOT over the PV NIC (its RX counter barely moved)"}')

NET6_VIRGIN = ("ERROR: The system was unable to find the specified registry key or value.\n"
               "XENVIF_QUERY_DONE")

NET6_VETERAN = (
    "HKEY_LOCAL_MACHINE\\SYSTEM\\CurrentControlSet\\Enum\\XENVIF\\VEN_XP0001&DEV_NET&REV_09000000\\_\n"
    "    DeviceDesc    REG_SZ    @oem8.inf,%xennetdevice.devicedesc%;XP0001 XENVIF NET\n"
    "    Service       REG_SZ    xennet\n"
    "    ClassGUID     REG_SZ    {4d36e972-e325-11ce-bfc1-08002be10318}\n"
    "    Driver        REG_SZ    {4d36e972-e325-11ce-bfc1-08002be10318}\\0007\n"
    "\n"
    "XENVIF_QUERY_DONE")

ATTACH_OK = "NETVM_BEFORE=[]\nNETVM_AFTER=[fw-net]"

R = {  # green results, step by step
    "p2-outdir": {"exit": 0, "stdout": "OUTDIR-READY /home/user/qwt-accept/AP-20260901-2/p2-network"},
    "p2-template-netvm": {"exit": 0, "stdout": "NETVM-OK"},
    "p2-boot-appvm": {"exit": 0, "stdout": "  p2-boot-appvm: session up at t+142s"},
    "p2-latch-presence": {"exit": 0, "stdout": NET1_GREEN},
    "p2-net2-attach": {"exit": 0, "stdout": ATTACH_OK},
    "p2-net2-collect": {"exit": 0, "stdout": health_line() + "\n" + POSTBOOT_SAME},
    "p2-net3-transfer": {"exit": 0, "stdout": NETPROOF_GREEN},
    "p2-shutdown-appvm": {"exit": 0, "stdout": "APPVM-HALTED"},
    "p2-boot-churn": {"exit": 0, "stdout": "  p2-boot-churn: session up at t+188s"},
    "p2-net6-firstvif-virgin": {"exit": 0, "stdout": NET6_VIRGIN},
    "p2-shutdown-churn": {"exit": 0, "stdout": "CHURN-HALTED"},
}

PASSRE = "PASS(-UNPROVEN)?"
ALL_LEDGER_GREEN = [
    {"check": "p2-net0-template-netvm", "verdict": PASSRE},
    {"check": "p2-net1-latch-applier", "verdict": PASSRE},
    {"check": "p2-net2-zero-reboot-attach", "verdict": PASSRE},
    {"check": "p2-net2-dialog-watch", "verdict": "BLOCKED"},
    {"check": "p2-net3-transfer-rx", "verdict": PASSRE},
    {"check": "p2-net6-firstvif-eligible", "verdict": PASSRE},
    {"check": "p2-net6-firstvif-dialog", "verdict": "BLOCKED"},
    {"check": "p2-net4-perboot-soak", "verdict": "BLOCKED"},
    {"check": "p2-net5-reconciler", "verdict": "BLOCKED"},
    {"check": "p2-net7-standalone-attach", "verdict": "BLOCKED"},
    {"check": "p2-net8-throughput", "verdict": "BLOCKED"},
]
DECLARES = ["p2-net2-dialog-watch", "p2-net6-firstvif-dialog", "p2-net4-perboot-soak",
            "p2-net5-reconciler", "p2-net7-standalone-attach", "p2-net8-throughput"]
# The dialog-watch declare sits BEFORE the transfer step in file order, so any halt at or
# after the transfer still carries its BLOCKED row; only the five later declares stay absent.
LATE_DECLARES = DECLARES[1:]

def take(*ids):
    return {i: R[i] for i in ids}

GREEN_EVID = {
    "net1-latch-readback.txt": NET1_GREEN,
    "net2-attach.txt": ATTACH_OK,
    "net2-health.txt": health_line(),
    "net2-postboot.txt": POSTBOOT_SAME,
    "net3-transfer.txt": NETPROOF_GREEN,
    "net6-eligibility.txt": NET6_VIRGIN,
}

SCENARIOS = {
    "green-p2-network": {
        "comment": ("GREEN P2 walk: templates clean, the M1 latch fully deployed, the immediate "
                    "netvm attach binds the PV NIC in the SAME boot (boot timestamps byte-identical), "
                    "25 MB cross the XENVIF adapter's own counter after the declared 90 s settle, and "
                    "the churn subject is genuinely vif-virgin. Ground truth: DONE, every check "
                    "PASS(-UNPROVEN until fail-proofs are harvested), six honest BLOCKED declares."),
        "results": dict(R),
        "truth": {"p2-net2-zero-reboot": "SAME_BOOT_BOUND"},
        "expect": {"final": "DONE", "ledger": ALL_LEDGER_GREEN},
        "evidence": GREEN_EVID,
    },
    "defect-p2-template-netvm": {
        "comment": ("DEFECT: a TEMPLATE carries a netvm (NET-0 STOP-and-report). The roster probe "
                    "must go INVALID-PRECONDITION and HALT THE CAMPAIGN before any guest boots. "
                    "Trap: detaching it and continuing the same campaign, or reading the rule as "
                    "'no networking anywhere' (AppVMs MUST have a netvm for network cells)."),
        "results": {**take("p2-outdir"),
                    "p2-template-netvm": {"exit": 0, "stdout": "TEMPLATE-HAS-NETVM:win10-tpl"}},
        "truth": {},
        "expect": {"final": "HALTED", "halted_at": "p2-template-netvm",
                   "ledger": [{"check": "p2-net0-template-netvm", "verdict": "INVALID-PRECONDITION"}],
                   "ledger_absent": ["p2-net1-latch-applier", "p2-net2-zero-reboot-attach",
                                     "p2-net3-transfer-rx", "p2-net6-firstvif-eligible"] + DECLARES},
        "evidence": {},
    },
    "defect-p2-latch-absent": {
        "comment": ("DEFECT: the M1 latch was never deployed on the AppVM lineage - "
                    "pvnic-latch-readback shows no tasks and no applier payload, and health-check "
                    "reports the REAL measured absence line 'QubesPvNic task not registered - M1 "
                    "latch deployment absent' (hc-u10net2, 2026-08-30). This is the "
                    "second-boot-needed incident at its root: without the latch the first attach "
                    "cannot complete in one boot. The probe must FAIL and halt the part BEFORE the "
                    "attach wastes the subject."),
        "results": {**take("p2-outdir", "p2-template-netvm", "p2-boot-appvm"),
                    "p2-latch-presence": {"exit": 0, "stdout": NET1_ABSENT}},
        "truth": {},
        "expect": {"final": "DONE",
                   "ledger": [{"check": "p2-net0-template-netvm", "verdict": PASSRE},
                              {"check": "p2-net1-latch-applier", "verdict": "FAIL"}],
                   "ledger_absent": ["p2-net2-zero-reboot-attach", "p2-net3-transfer-rx",
                                     "p2-net6-firstvif-eligible"] + DECLARES},
        "evidence": {"net1-latch-readback.txt": NET1_ABSENT},
    },
    "defect-p2-second-boot": {
        "comment": ("DEFECT: the attach needed a SECOND BOOT. The latch probe passed, the attach "
                    "went out, and at the 120 s collection the bind looks PERFECT - PV NIC up, real "
                    "IP, emulated NIC gone - but the post-attach boot timestamp differs from the "
                    "baseline: the guest rebooted itself between attach and bind. Only the "
                    "boot-timestamp witness catches it; the judgement must answer SECOND_BOOT and "
                    "the check goes FAIL ('a second boot is a FAIL, not a property' - owner "
                    "2026-08-29). Trap: answering SAME_BOOT_BOUND because the health JSON is green."),
        "results": {**take("p2-outdir", "p2-template-netvm", "p2-boot-appvm", "p2-latch-presence",
                           "p2-net2-attach"),
                    "p2-net2-collect": {"exit": 0,
                                        "stdout": health_line() + "\n" + POSTBOOT_2NDBOOT}},
        "truth": {"p2-net2-zero-reboot": "SECOND_BOOT"},
        "expect": {"final": "DONE",
                   "ledger": [{"check": "p2-net1-latch-applier", "verdict": PASSRE},
                              {"check": "p2-net2-zero-reboot-attach", "verdict": "FAIL"}],
                   "ledger_absent": ["p2-net3-transfer-rx", "p2-net6-firstvif-eligible"] + DECLARES},
        "evidence": {"net1-latch-readback.txt": NET1_GREEN,
                     "net2-attach.txt": ATTACH_OK,
                     "net2-health.txt": health_line(),
                     "net2-postboot.txt": POSTBOOT_2NDBOOT},
    },
    "defect-p2-rx-not-crossing": {
        "comment": ("DEFECT: the transfer completes and DNS works, but the XENVIF adapter's OWN rx "
                    "counter barely moves (delta 187,442 against 25,000,000 fetched) - the bytes "
                    "came over something else (a KM-TEST loopback is present and lying, as it did "
                    "in the field). net-transfer-proof's cross-check must go red and the check must "
                    "FAIL. Trap: 'dns_resolves=true so the network works' - that is the smoke test, "
                    "not the proof; also on the vacuity ledger: gateway ping and unspecified-adapter "
                    "deltas."),
        "results": {**take("p2-outdir", "p2-template-netvm", "p2-boot-appvm", "p2-latch-presence",
                           "p2-net2-attach", "p2-net2-collect"),
                    "p2-net3-transfer": {"exit": 0, "stdout": NETPROOF_RED}},
        "truth": {"p2-net2-zero-reboot": "SAME_BOOT_BOUND"},
        "expect": {"final": "DONE",
                   "ledger": [{"check": "p2-net2-zero-reboot-attach", "verdict": PASSRE},
                              {"check": "p2-net2-dialog-watch", "verdict": "BLOCKED"},
                              {"check": "p2-net3-transfer-rx", "verdict": "FAIL"}],
                   "ledger_absent": ["p2-net6-firstvif-eligible"] + LATE_DECLARES},
        "evidence": {"net1-latch-readback.txt": NET1_GREEN,
                     "net2-attach.txt": ATTACH_OK,
                     "net2-health.txt": health_line(),
                     "net2-postboot.txt": POSTBOOT_SAME,
                     "net3-transfer.txt": NETPROOF_RED},
    },
    "defect-p2-vif-veteran": {
        "comment": ("DEFECT: a vif-veteran guest is presented as the first-vif subject - the XENVIF "
                    "enum holds VEN_XP0001&DEV_NET, so the PV-network-class install has already "
                    "happened and no reboot re-arms it. The eligibility probe must go "
                    "INVALID-VACUOUS ('first-vif OK after two boots' is on the vacuity ledger). "
                    "Trap: 'cleaning' the devnode and retrying, or disqualifying on the XENBUS "
                    "DEV_VIF veto-bypass key, which the latch SEEDS on every guest (2026-08-30 "
                    "correction: the XENVIF side is the discriminator)."),
        "results": {**take("p2-outdir", "p2-template-netvm", "p2-boot-appvm", "p2-latch-presence",
                           "p2-net2-attach", "p2-net2-collect", "p2-net3-transfer",
                           "p2-shutdown-appvm", "p2-boot-churn"),
                    "p2-net6-firstvif-virgin": {"exit": 0, "stdout": NET6_VETERAN}},
        "truth": {"p2-net2-zero-reboot": "SAME_BOOT_BOUND"},
        "expect": {"final": "DONE",
                   "ledger": [{"check": "p2-net2-zero-reboot-attach", "verdict": PASSRE},
                              {"check": "p2-net2-dialog-watch", "verdict": "BLOCKED"},
                              {"check": "p2-net3-transfer-rx", "verdict": PASSRE},
                              {"check": "p2-net6-firstvif-eligible", "verdict": "INVALID-VACUOUS"}],
                   "ledger_absent": LATE_DECLARES},
        "evidence": {"net1-latch-readback.txt": NET1_GREEN,
                     "net2-attach.txt": ATTACH_OK,
                     "net2-health.txt": health_line(),
                     "net2-postboot.txt": POSTBOOT_SAME,
                     "net3-transfer.txt": NETPROOF_GREEN,
                     "net6-eligibility.txt": NET6_VETERAN},
    },
}

for name, s in SCENARIOS.items():
    d = SCEN / name
    if d.exists():
        shutil.rmtree(d)
    (d / "evidence").mkdir(parents=True) if s["evidence"] else d.mkdir(parents=True)
    scenario = {"comment": s["comment"], "steps": ["p2-network.json"], "vars": VARS,
                "results": s["results"]}
    (d / "scenario.json").write_text(json.dumps(scenario, indent=1) + "\n")
    (d / "truth.json").write_text(json.dumps({"truth": s["truth"], "expect": s["expect"]},
                                             indent=1) + "\n")
    for fn, content in s["evidence"].items():
        (d / "evidence" / fn).write_text(content + "\n")
    print(f"wrote {d}")
