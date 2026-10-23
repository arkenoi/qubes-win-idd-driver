# issues-closed — terse index of retired entries

## CURRENT STATE

Nothing in this file is open. It is a one-line-per-entry index of entries retired from
findings/issues.md: fixed, retracted as wrong, decided by the owner, or declared not-ours.
The narrative is deliberately not kept - owner, 2026-10-21: "ZERO closed issues are allowed in
main file, and most of archeology needs to be purged, especially history of stupid ways we
failed." Status was decided by Jev per entry, not by keyword matching; my own matcher had
classified entries whose head said OPEN as closed. Full text is in git history if ever needed.

## History
- INSTALLKILLSWUSCANANDTELLSTHEUSER [P1; FIXED 2026-10-22 as 9298ce78] The MSI's Restart Manager reaped our running \QubesWindowsUpdateScan (0xC000013A inside a 666 ms session) and the death reporter told the USER "The Windows Update scan task failed" about a scan our own install stopped (dom0_loud_failures=2, max 0). Owner: "it is our installer and our receiver. we may tell it to die politely in any way we please." The installer now ends+disables the three update tasks before msiexec, so the result is 267014/0x41306 which qwt-report-death.ps1:1046 already ignores - ZERO reporter change. /end before /disable (disable cannot stop a running instance). Driven by tools/tests/upd-task-prestop-selftest.sh, 9/0, which also checks the premise still holds in the shipped reporter. An event-log inference probe was written first and fully reverted: the channel it read is enabled and EMPTY on 26300.9457, event 10006 means the opposite of what it used it for, and the 201's EnginePID is not our action process.
- LOGVOLSTICKSCOPE [instrument; FIXED 2026-10-22 as d0bcffec, one gap carried to LOGVOLRESTOREBEFORECOLDBOOTS] Owner ruled the evidence stick is for INSTALL testing only. appvm cells now create/attach/bind nothing, so the pregrade --require-agent-logs proof that FATALed win10-appvm and stopped the matrix at 4 of 8 no longer runs where it cannot pass (the bind writes LogDir into HKLM on a root volume Qubes re-derives every start; all three boots read old='Q:\Qubes Logs' with copied=22/23/24). The saved LogDirPreLogvol/LogSafeFlushPreLogvol are restored on every exit path of an install cell, failures included; the park-time clear stays as a backstop. quick-upgrade unchanged (Jev wedge_coverage_not_lost 0.32). Driven by tools/tests/stick-scope-restore-selftest.sh, 30/0, controls mutating the real matrix.sh.
- PREFLIGHTFIXTURENOTBOUNDTOENTRY [gate; RETRACTED 2026-10-22, same day it was filed] Filed and committed (faa915d7) as a gate defect: preflight validated win10-iqi/win11-iqi while the campaign entered on win10-ours/win11r-ours. The gate was checking the CANONICAL fixtures (docs/ACCEPTANCE-PROTOCOL.md:169); I had swapped the environment under it, reconstructed from the previous campaign's log, and had not run tools/acceptance-plan.py at all. A gate stepped outside of looks like a gate pointed elsewhere. The real defect, that nothing cross-checks the three declarations, is open as ACCEPTANCETARGETSUNCROSSCHECKED.
- ACCEPTCANCELORPHAN - a cancel left the campaign running, three times. ROOT CAUSE: tools/release-acceptance.sh never sourced run-lib.sh and never called job_init, so the leader had NO teardown trap, while its own comment claimed run-lib already tore down its tree. Fixed 2026-10-21: run-lib loaded by a $0-relative path (the block is above the cd to the repo root) with a fatal failure-to-load, job_init installs the traps, and tools/tests/accept-cancel-selftest.sh drives the real teardown over a stand-in child - the pre-fix shape is required to orphan its child.

- ACCEPTANCECANNOTPASSWITHUPGRADECELL [gate, tools/log-sweep.py DEFAULT_THRESHOLDS; **STALE - the premise is refuted by measurement**] THE win11-upgrade CELL CANNOT PASS THE LOG SWEEP FOR ANY RELEASE, AND HAS NOT IN [verified 2026-10-18]
- ACCEPTANCEPASSED4336 [release gate; **PASSED 2026-10-18, campaign 20261018-183821, rc=0**] BOTH CLAUSES OF THE STANDING GOAL ARE MET, AND THE NUMBERS ARE THE RUN'S OWN [verified 2026-10-18]
- APPMENUNOUWP [app menu, user-facing; P1, FIXED IN SOURCE 2026-10-11 (core-agent 0258ce2), UNVERIFIED on a guest] The app menu cannot launch any UWP app, which on a stock Windows 11 guest is most of what the OS shi
- APPVMLOGDIRNAMESTHETEMPLATE [P2 instrument, mgmt/harness/matrix.sh appvm cell; **CLOSED 2026-10-20**] THE APPVM SWEPT A DIRECTORY THAT BELONGS TO ITS TEMPLATE [verified 2026-10-19]
- AUTOPLAYTOASTTIMESTHESHELL [measurement + THREE corrections of mine; the LOGVOL_BIND mechanism is REFUTED - by the run-8 pack (LOGVOLBINDNOTMOUNTED, 2026-10-19), NOT by the stick argument below, which is wrong] I [verified 2026-10-19]
- BROKERHOLDREASONUNKNOWN [product, diagnosability; agent/gui-agent/main.c; the DEMOTION IS REVERTED and the reason is now logged] [verified 2026-10-17] **I DEMOTED 589 WARNINGS ON A STORY THE CODE'S OWN INSTRUMENTA
- BROKERLATEREGLOUD [dom0 notifications; P2, FIXED OFFLINE, UNVERIFIED on a guest] My own noise fix was half inert, and the receipt I took said so while I read it as a pass
- BROKERSTARTRACE [capture] RETRACTED: there is no race, and the fix I wrote for it is REVERTED (agent `5ce36ef`) because it was provably inert
- BUILDSCOPINGISNOTONEDIFF [gate, tools/log-sweep.py; **OPEN - MEASURED: scoping two metrics is not enough, the cell still fails on three**] THE ONE-DIFF ANSWER DOES NOT CLEAR THE UPGRADE CELL, and this is measured [verified 2026-10-18]
- CALLERCHECKATENDONLY [acceptance gate; P1, FIXED - the warm checks run per cell; verified in the source 2026-10-15] FIX APPLIED [verified 2026-10-15]
- CAMPAIGNLOGTZSPLIT [evidence; P2, FIXED 2026-10-15, WIDENED 2026-10-19 - the fix missed thirteen emitters and the guest half of its own claim] WIDENED 2026-10-19 - THE FIX WAS NARROWER THAN ITS ENTRY, AND THE ENTR [verified 2026-10-19]
- CAMPAIGNMETERINGARTIFACTS [instrument, tools/log-sweep.py + mgmt/harness/e2e-wait.sh; FIXED 2026-10-17, verified against the campaign's own captures] THE FIRST FULL CAMPAIGN SINCE THE CUT FAILED FOUR CELLS ON THE [verified 2026-10-17]
- CAPTUREDESKSWITCH [harness, acceptance; OURS - mgmt/harness/matrix.sh's accounting; owner CONFIRMED the cause 2026-10-10] A dom0 DESKTOP SWITCH FAILS A CELL, AND THE OWNER CONFIRMED THAT IS WHAT HAPPENED [verified 2026-10-10]
- CAPTURESLOWWARNSFROMTHEFIRSTSECOND [product, log noise; agent/gui-agent/capture.c + qga-lifecycle.h; FIXED 2026-10-17] THE CAPTURE LOOP WARNED FROM THE FIRST SECOND OF A SLOW PASS, ONCE PER SECOND, AGAINST A 15 s [verified 2026-10-17]
- CIELIGIBILITYMEASUREDWRONGPLACE [gate coverage; P2, FIXED] I MEASURED WHICH SUITES CI CAN RUN BY RUNNING THEM ON THE DEV QUBE
- CIREDUNREAD [process/CI; P1, FIXED] `build
- CLAIMSTALELOOP [rig; P1, FIXED] `qvm-start --cdrom` LEAVES A `--required` CLAIM, THE CAMPAIGN RELEASES THE LOOP, AND THE SUBJECT CAN NEVER START AGAIN
- CLASSESWERENEVERBUILDSCOPED [P2 gate, tools/log-sweep.py; **FIXED 2026-10-18, suite 165/1**] The five line-level metrics carried `not _prior(lf, l)` [verified 2026-10-18]
- CLASSIFYERRORSCOULDNOTFINDITSEMITTERS [instrument, tools/classify-errors.sh; FIXED 2026-10-17] 4 [verified 2026-10-17]
- CLOCKBASEVSEFFECTIVEOFFSET [product; P1, FIXED IN SOURCE] THE WITNESS REPORTS THE ZONE'S BASE OFFSET, AND THE DECISION NEEDS THE ONE IN EFFECT
- CLOCKDETECTORVACUOUS [product; P1, FIXED] THE DETECTOR COMPARED THE GUEST'S CLOCK WITH ITSELF
- CLOCKFEATURERETURNS [guest clock; P1, FIXED] THE QUBE'S `timezone` FEATURE COMES BACK AT EVERY INSTALL, AND I ONLY EVER CLEARED IT BEFORE ONE
- CLOCKFEATURESETLATE [product + harness; P1, FIXED AND MEASURED - clock_boot_correction_s = 0] `qubes/ext/windows [verified 2026-10-15]
- CLOCKPREFLIGHTTOOEARLY [product; P1, FIXED IN SOURCE - awaiting a fresh-install measurement] THE INSTALLER SET THE GUEST'S TIMEZONE BEFORE QUBESDB EXISTED, SO IT NEVER SET IT [verified 2026-10-15]
- CLOCKRTCLOCALTIME [guest clock, EVERY cell; P1, FIXED] WE SET A NON-STANDARD RTC OURSELVES, THEN FOUGHT IT WITH A PULLER
- CLOCKSYNCRC2TERMINAL [guest clock, every boot; P1, FIXED] MY OWN REGRESSION: A FEATURE THAT HAD WORKED FOR WEEKS DIED THE DAY I MADE IT LOCALE-INDEPENDENT
- CLOCKWITNESSMISSEDONFIRSTBOOT [product; P1, FIXED] THE DETECTOR REFUSED ON THE FIRST BOOT WHILE A USABLE WITNESS ALREADY EXISTED
- CLOSED (was P3) "exit status 46" on the seamless switch: RETIRED, not open (ow ner 2026-09-24). It is not a service exit status - qrexec-wrapper sends a Win32 error code as the exit code when child s [verified 2026-09-24]
- CONNECTORDER [windows-utils pipe server; P1, FIXED IN SOURCE - unbuilt, unrun on a guest] THE ORDER WAS THE DEFECT, SO THE FUNCTION IS REWRITTEN, NOT GUARDED [verified 2026-10-14]
- COVERAGECELLSINVISIBLE [gate, tools/coverage-receipt.py; P1, FIXED - THIS was the release blocker] EIGHT CELLS RAN, THE RECEIPT SAID NONE OF THEM DID, AND THE CUT WAS REFUSED BY A REGEX [verified 2026-10-16]
- CROPTESTHARDCODESTHELOGPATH [P2 instrument, mgmt/harness/crop-before-map.sh:167; **CLOSED 2026-10-20**] A TEST THAT HARD-CODES Q: CANNOT SEE LOGS THE PRODUCT WAS TOLD TO WRITE ELSEWHERE [verified 2026-10-19]
- DEATHNOTIFIEDTWICE [product, guest/qwt-report-death.ps1; P1, FIXED IN SOURCE AND IN THE TESTED PACKAGE - the condition did not recur, so it is not independently proven] THIS ENTRY SAID "FIX (not yet made)" WHILE T [verified 2026-10-16]
- DEFERPROBEOPENSNOGAP [instrument, mgmt/harness/notify-errors-guest-test.sh; P1, PROBE FIXED - the P1 fix itself is STILL UNPROVEN] I WROTE A PROBE FOR THE SESSION GAP, IT NEVER OPENED THE GAP, AND ONE OF ITS ASSER [verified 2026-10-16]
- DESKSTUCKFIRESBEFOREAUTOLOGON [product, user-facing notification noise; agent/gui-agent QGADESKSTUCK; NOT FIXED, root-caused] DOM0 TELLS THE USER TO GO AND SIGN IN TO A GUEST THAT SIGNS ITSELF IN EIGHT SECONDS LAT [verified 2026-10-17]
- DIRECTSUPPRESSEARLY [dom0 notifications; P1, FIXED] UN-RETRACTED: it IS reachable, it fires a FALSE dom0 popup, and it is now measured end to end
- DOM0LOUDNEVERFIRES [gate, tools/log-sweep.py; P1, FIXED - the check keys on the PATH now, and has been seen to fire] `dom0_loud_failures` IS P1 WITH max 0, AND IT CANNOT COUNT THE THING IT EXISTS FOR [verified 2026-10-15]
- DONE: EMS armed (both templates, AppVM-inherited) and the serial channel prove n end-to-end — SERIALMARK x3 land in guest-<vm>-dm.log. EMS/SAC silence on a healthy client boot is expected (SAC is Ser [verified 2026-09-02]
- EMITTERSFIXEDNOTLEDGERED [gate + product, 6 emitters + tools/sweep-gate.sh; **APPLIED 2026-10-18, awaiting the campaign that proves zero**] THE GATE'S UNACCOUNTED LIST IS FIXED AT THE EMITTERS, NOT IN THE LEDGER - [verified 2026-10-18]
- ENTRYNOQWT [acceptance harness; P1, FIXED] WIN10-upgrade ran with `G10=win10-base`
- ERRFAM2 [errors; 2026-10-09] [verified 2026-10-09] **THE FIRST CLEAN-BOOT CAPTURE FROM A BUILD CARRYING THE FIXES: ELEVEN OF THIRTEEN FAMILIES GONE, 
- ERRORINV [errors; 2026-10-09] THE COMPLETE ERROR-LINE INVENTORY OF THE TWO SWEPT GUESTS, AND WHY "STOCK ERRORS UNFIXED" WAS WRONG
- FIXED 2026-09-30 (9f1d84a, verified on a guest; acceptance check 3d8e394) - wa Measured 2026-09-30 on w11-bench (Win11 24H2 26100 [verified 2026-09-30]
- GATE18NEVERREACHED [release gate, tools/gate-scope.py + mgmt/gate-scope.json; OWNER DECISION TAKEN 2026-10-16: CUT ON `core`; both full-gate routes DEFERRED] [verified 2026-10-16] **EIGHTEEN SUITES ARE REQUIRED, T
- GATEBLINDTOCALLERS [acceptance gate; P1, FIXED] THE GATE COULD NOT SEE THE GOAL'S SECOND CLAUSE
- GATEMETRICSNOTBUILDSCOPED [P1 instrument, tools/log-sweep.py; FIXED 2026-10-19] THE THIRD TIME THIS CLASS WAS FOUND IN compute_metrics, and it failed the 4 [UNVERIFIED]
- GATEVERDICTSAYSOK [harness, mgmt/harness/quick-upgrade.sh:196; P2, FIXED - unrun on a guest] THE VERDICT LINE READ `[ERROR] OK: win11-nfy upgraded 4 [verified 2026-10-16]
- GATEWRONGBIN [gate; OURS - tools/gate-remainder.sh] THE GATE SPENT A WHOLE RUN GRADING A BINARY THAT WAS NEVER THE CANDIDATE, AND REPORTED A FIXED DEFECT AS PRESENT
- GOALVERIFY1014 [qrexec/app-menu, user-facing; THE WHOLE QREXEC CLAUSE OF THE GOAL IS CLOSED - updaters on all three channels, and the UWP start menu warm AND cold] ALL FOUR CLAUSES ARE VERIFIED ON THAT GUEST [verified 2026-10-14]
- GOLDENGATEVACUOUS [guard; P1, FIXED] SIX OF EIGHT BLOCKING CASES IN THE GOLDEN-BOOT SELF-TEST HAD STOPPED TESTING ANYTHING
- GRADEROWSDROPPEDBEFORETHEREPORT [P2 instrument, mgmt/harness/toast-hold-test.sh; FIXED 2026-10-19 7d41676f] THE REPORT DELETED THE ROWS IT TOLD YOU TO READ [UNVERIFIED]
- GUIDNORECONNECT [gui-daemon; NOT OURS - dom0 side; CLOSED BY THE OWNER 2026-10-09] OWNER'S STANDING RULE, 2026-10-10: [verified 2026-10-09]
- GUIRESTOREDBEFOREAPENDINGREBOOT [P2 product, packaging/setup/Install-QwtImproved.ps1; **FIXED 160a47a9 and VERIFIED ON THE RIG - `agent_instances_per_boot` now reads 1**] THE FIX WORKED AND THE PREDICTION HELD [verified 2026-10-18]
- HANDOFFCLAIMSLOSSBEFOREFALLBACK [instrument + log wording, tools/log-sweep.py dom0_lost + tools/notifhost/notifhost.cpp:3417-3475; P1 BREACH THAT IS A FALSE POSITIVE, FIXED in the detector, product wording DEFERRE [verified 2026-10-16]
- HARNESSFORCEDTHECONVENTION [harness; P1, FIXED - this was the root cause] THE HARNESS WROTE THE SETTING THE GATE WAS MEANT TO MEASURE, AFTER EVERY INSTALL
- HARNESSLOGUNSWEPT [harness instrumentation, every suite; P1, FIXED for the short cycle] NOTHING SWEPT THE HARNESSES' OWN LOGS, SO ERROR LINES WERE GRADED BY WHOEVER HAPPENED TO READ THEM [verified 2026-10-14]
- KILLEDMYOWNSHELL3 [working practice; P1, FIXED] I SIGNALLED PROCESSES BY PATTERN AND KILLED MY OWN TOOL SHELLS
- L23CONTINUATIONBLIND [harness lint; P1, FIXED] Rule L23 exists because SIGPIPE + `pipefail` return 141 and grade a live guest dead (measured 86/200 on 2026-10-14)
- L23NEVERFIRED [instrument + harness, tools/lint-harness.py L23 + 30 call sites; FIXED 2026-10-16] THE RULE THAT EXISTS TO PREVENT THIS REPORTED 0 FINDINGS AGAINST 30 LIVE SITES, INCLUDING quick-upgrade [verified 2026-10-16]
- LOGLEVELINDENTBLIND [harness, mgmt/harness/quick-upgrade.sh:97; P2, FIXED - unrun on a guest] `log` DETECTS THE LEVEL TOKEN ONLY AT POSITION ZERO, AND HALF THE HARNESS INDENTS IT [verified 2026-10-16]
- LOGSWEEPOLDEMPTY [log analyzer; P2, FIXED] AN EMPTY ROTATION PLACEHOLDER IS NOT MISSING DATA
- LOGTURNOVERNOTRECOGNISED [instrument, tools/log-sweep.py; FIXED 2026-10-17, found only because the owner pushed back] EVERY QWT LOG IS ONE FILE PER MODULE PER DAY, SO A FILE SPANS BOOTS - AND THE REPORT NAMED ONE [verified 2026-10-17]
- LOGVOLBINDNOTMOUNTED [instrument; P1, default off STANDS - the mechanism this entry named is REFUTED] CORRECTED 2026-10-19: THE HEADLINE BELOW IS REFUTED, AND ITS THREE SUCCESSORS WERE JUDGED ON THE SAME PACK [verified 2026-10-19]
- LOGVOLLETTERMOVES [instrument; P1, FIXED+MEASURED] THE LOG VOLUME'S DRIVE LETTER MOVES WHEN OTHER REMOVABLE VOLUMES ARE REMOVED, AND LogDir IS WRITTEN WITH THE LETTER
- LOGVOLLEVELSDISCARDED [harness instrumentation, 5 call sites; P1, FIXED] A DECLARED SEVERITY SENT TO /dev/null DECIDES NOTHING
- LOGVOLNOTONCLEAN [instrument; P1, FIXED] THE LOG VOLUME WAS NEVER ON THE CLEAN-INSTALL PATH, AND THE GRADING BLAMED THE GUEST FOR ITS ABSENCE
- LOSTLOGSTARTEDSLIDTHEUPTIME [P2 instrument, tools/log-sweep.py; FIXED 2026-10-19] A LOST LOG LINE BREACHED A GATE ON A GUEST WHOSE OWN LOG SAYS EVERY EXIT WAS ORDERLY [UNVERIFIED]
- LOUDNESSUNREADABLE [error gate; P1, FIXED] THE GATE COULD NOT TELL A SILENT LOG LINE FROM ONE THE USER WAS SHOWN
- MATRIXMARKERNORETRY [acceptance harness, every reinstall/upgrade cell; P1, FIXED] THE RUN-MARKER STEP FAILED A CELL ON THE FIRST SILENT ANSWER, AND READ ITS OWN ECHO [verified 2026-10-14]
- MODULEBASEPULLHADNORETRYANDNODIAGNOSIS [P2 harness, mgmt/harness/arm-module-bases.sh; FIXED 2026-10-19] THE ARMING RETRIES; THE PULL THAT PROVES IT DID NOT [UNVERIFIED]
- NETSETUPERRORSONITSOWNCONFIGURATION [product, log noise; core-agent/src/network-setup/qubes-network-setup.c; FIXED 2026-10-17] `SetupNetwork: Failed to get qubes-ip` AT ERROR ON EVERY GUEST THAT IS CONFIGURED NOT [verified 2026-10-17]
- NETSETUPLIVEONUPGRADECELL [product + my own false record; OPEN, mechanism NOT established] A RETIRED BINARY IS RUNNING ON THE UPGRADE CELL, AND THE RECORD THAT WOULD SAY WHY IS TRUNCATED ON THAT SAME CELL [verified 2026-10-17]
- NOTFIXED [gui-daemon, dom0 visibility; the OWNER'S ORIGINAL REPORT] THE DEFECT HE REPORTED IS NOT FIXED, IT STILL REPRODUCES, AND NOTHING I DID TOUCHED IT
- NOTIFBRIDGESYSKILLISTHENORMALORDERING [P2 product, agent/gui-agent/main.c + qga-lifecycle.h; FIXED 2026-10-19] A 51 ms RACE WROTE A DURABLE EVENT LOG RECORD FOR AN ORDINARY SHUTDOWN [UNVERIFIED]
- NOTIFYCLOCK [notifications, gui-agent; OURS; owner found it 2026-10-09] [verified 2026-10-09] **RETRACTED IN PART, SAME DAY: THE 30 s CLOCK IS A REAL DEFECT BUT IT IS NOT WHAT THE OWNER SAW, A
- NOTIFYONCEHANDOFFPATHNOTFOUND [**RETRACTED 2026-10-18 - it is the PREDECESSOR's already-fixed P1, not a defect of this release**] RETRACTION FIRST, because I reported this as a live product defect and it is not on [verified 2026-10-18]
- NULHOLEWASABSORBEDSILENTLY [P2 instrument + an open question about the guest; instrument FIXED 2026-10-19, CAUSE OPEN] LOST DATA READ AS A COMPLETE RECORD [UNVERIFIED]
- Nothing here is open: these entries were moved out of the register on 2026-10- 02 because Jev judged them closed, superseded or retracted (confidence >= 0.5, two passes - the entry's own text, then a [verified 2026-10-02]
- OSCILLATIONJUDGEDBYCOUNTNOTIDENTITY [P2 gate, mgmt/harness/wu-e2e.sh oscillation check; **TOOL BUILT AND TESTED, NOT YET WIRED**] A COUNT CANNOT TELL AN OSCILLATION FROM A PUBLICATION [verified 2026-10-20]
- OVERLOGGEDSETWASALREADYCLOSED [P2 gate ledger, tools/log-sweep.py + findings; **CLOSED 2026-10-18 - nothing to design**] Asked to propose a removal mechanism for each ledger entry scoring overlogged > 0 [verified 2026-10-18]
- P1 -> FIXED IN 4.3.34 (register updated 2026-10-04: rz39-prep a10ff0db install SHIPPED CODE KILLS AND ADOPTS PROCESSES BY NAME [verified 2026-10-03]
- P1 -> FIXED [supervision, user-facing; OURS - packaging/setup/Install-QwtImpro Found by the rz39 (4 [verified 2026-10-04]
- P1 -> FIXED [updates, installer, user-facing; OURS - guest/install-updater-agent.ps1 DEPLOY-PREVPASS] AN INSTALL OVER A QUBE WHOSE LAST UPDATE PASS WAS CUT OFF DID NOT DEPLOY THE UPDATER AT ALL - AND 4 [verified 2026-10-04]
- P1 PACKAGING GAP: `wgcbroker.exe` + `notifhost.exe` + `wgcprobe.exe` are BUILT in CI (gui-agent-package artifact) but NEVER staged into the installable package — `qwt-full`/stage-qwt-repo `agent-bins [verified 2026-09-04]
- P1 [CORRECTED 2026-09-22 BY A 1:1 READ OF THE TWO RUNS] THE STALL DOES NOT HAPPEN DURING THE INSTALL - IT HAPPENS BEFORE THE INSTALLER PRODUCES ANYTHING
- P1 [CORRECTED BY THE OWNER 2026-09-21 - I DIAGNOSED A GUEST TWICE AND WAS WRONG BOTH TIMES; THE PATTERN IS THE FINDING] `win11-acc`, left over from a failed prime-run, was started by a diagnostic probe, showed a b [verified 2026-09-21]
- P1 [MEASURED 2026-09-10 - the post-install-reboot stall is a MULTI-vCPU DEADLOCK IN THE GUEST, not a shutdown problem] RECURRED 2026-09-25 DURING RELEASE ACCEPTANCE [verified 2026-09-25]
- P1 [MEASURED 2026-09-17, release 4.3.29.538 run 35171496552 - THE STALL RECURRED, AND THE HARNESS ATE THE SPECIMEN] WIN11-clean on win11-acc: install COMPLETE (installer rc=10, qrexec answering at t+498 s), then t [verified 2026-09-18]
- P1 [MEASURED 2026-09-21 - THE HUNG SHUTDOWN RECURRED AND THE SPECIMEN IS PRESERVED, UNKILLED] RECLASSIFICATION WITHDRAWN, MEASURED 2026-09-21 [verified 2026-09-21]
- P1 [MEASURED 2026-09-27 - FIX F1 (f31dba8) SERVES THE TOAST; ITS ACCEPTANCE (win11de-v6) DID NOT PASS: run 1 all PASS, run 2 failed two pixel checks on a stale broker SIGNATURE (throttle, fixed 5cd0187), run 3 was [verified 2026-09-27]
- P1 [MEASURED 2026-09-27 - THE STALL, AFTER A CLEAN INSTALL, ON A COLD BOOT; IT BLOCKED THE ROUTE-FIX ACCEPTANCE] `win11de-v4` (build `f28d892`, serial stop + qrexec pin included) installed 10/10, then wedged ~5 mi [verified 2026-09-27]
- P1 [MECHANISM REMOVED FROM THE PRODUCT AND PROVEN ON BOTH INSTALL PATHS 2026-09-16 - the wrapper creates Q: by serial before msiexec, the stock action is dropped from the MSI at build time; the ORIGINAL TRIGGER wa [verified 2026-09-16]
- P1 [NOT THE STALL - owner 2026-10-02: "gwecks update path is apparently fully  8/8 asserted facts [verified 2026-09-16]
- P1 [SUPERSEDED 2026-10-01 by the first entry; kept as the measured history; capture, product-relevant; OURS - agent, broker, notification bridge] AT REST OUR STACK WAKES ~40 TIMES A SECOND; THE NOTIFICATION BRIDGE [verified 2026-10-01]
- P1 [SUPERSEDED 2026-10-01 by the first entry; kept as the measured history; capture, product-relevant; OURS - notification bridge] AT REST THE BROKER NOW WAKES ~0 TIMES A MINUTE; THE NOTIFICATION BRIDGE STILL WAKE [verified 2026-10-01]
- P1 [UNPARKED BY THE OWNER 2026-09-17 - IN SCOPE OF GWECK'S UPDATE PATH: "the upgrade should work end to end. if it does not, it is the same bug in a different shape and it was NOT fixed and the fix is worth nothin [verified 2026-09-11]
- P1 [capture, product-relevant, BLOCKS the de-slice goal] AFTER A COLD BOOT THE RELAY DOES NOT DELIVER A SOURCE CHANGE; WARM IT DELIVERS RELIABLY
- P1 [capture, product-relevant] DWM BURNS 118% OF A CORE ON AN ORDINARY EIGHT-WINDOW DESKTOP WHILE OUR AGENT IS CAPTURING
- P1 [capture, rest-zero M7; OURS - agent liveness pokes; the M7 phases cell was blind to it] Retracts the "M7 pass on rz25" reported earlier on 2026-10-02 [verified 2026-10-02]
- P1 [capture, user-facing; OURS - the broker's control path; FIXED 2026-10-07, NOT YET DEMONSTRATED] Diagnosed entirely from logs already on the dev qube - no rig time (Jev: root_cause control-behind-work 0 [verified 2026-10-07]
- P1 [guest-stability, product-relevant, blocks a clean full acceptance] Pre-registered A/Bs on the SOAK reproducer (6 serial qubes
- P1 [harness, acceptance; OURS - guest/health-check.ps1] Measured on win11-acc over one boot (14 samples): the live log is PER-DAY and APPENDED (`gui-agent-20261009
- P1 [superseded detail] ROOT CAUSE, from a CLEAN FRESH-BOOT measurement (this RETIRES the handshake verdict below; Jev `prior_verdict_retired`
- P1 [superseded detail] SETTLED 2026-09-25 BY COUNTERS ON A PURPOSE-BUILT BUILD: WGC STOPS DELIVERING FRAMES FOR THE ApplicationFrameWindow
- P1 [updates, user-facing; OURS - guest/qubes-windows-update.ps1; NOT FIXED] Measured on TemplateVM clones of the sealed German 25H2 golden (env-assert gweck OK): the published 4
- P1 [user-facing, non-seamless; OURS - regression of 255e7aa, shipped in 4.3.33 and 4.3.34] [verified 2026-10-06] **THE NON-SEAMLESS DESKTOP COVERED THE SCREEN ON THE FIRST SWITCH AFTER THE AGENT STARTED (owner: 
- P1 [user-facing, rendering; OURS - agent gui-agent/main.c ShouldAcceptWindow's THE WINDOWS START MENU OPENS INVISIBLY IN SEAMLESS MODE AND TAKES THE USER'S CLICKS [verified 2026-10-04]
- P2 BOOT-TO-QREXEC VARIES 15-38 s AND THE CAUSE IS UNKNOWN. **RETRACTED 2026-09 It was n=2 vs n=4 from a single campaign [verified 2026-09-09]
- P2 TOAST OVERCROP — ROOT CAUSE = the slide-in ANIMATION RACE (owner-reported " CROP FIXES (1,2,3 + the geometry half of 4) are GOOD [verified 2026-09-06]
- P2 [FIXED 2026-09-09, fail-proofed] THE RESCUE GATE WAS DEFEATED BY MISSING DATA - prime-run's cpu reader printed the sentinel `9999` ("very busy") whenever [verified 2026-09-09]
- P2 [FIXED 2026-09-13, RIG-UNVALIDATED] THE BLACK BLINK WAS A BUFFER REBUILD, NOT A MAP. Owner: "btw right now i see black toast" ... "self-fixed after a while" [UNVERIFIED]
- P2 [FIXED AND PROVEN 2026-09-09] THE STAGE-1 REBOOT WAS A COIN FLIP; IT IS NOW A DEFINED PATH. A pristine guest has no PV drivers bound, so stage 1's reb [verified 2026-09-09]
- P2 [FOLLOW-UPS FROM THE 45ed344 ACCEPTANCE, 2026-09-27, none done] (1) The agent calls a registration that has never received a frame "feed LOST" when the slot still holds the PREVIOUS oc [verified 2026-09-27]
- P2 [FOUND AND HALF-FIXED 2026-09-13] TWO PRIME-RUN DEFECTS TURNED A HEALTHY GUEST INTO A REPORTED "STALL", AND THE UNPARK PATH STILL GIVES UP WHERE ITS SIBLI [verified 2026-09-13]
- P2 [MEASURED 2026-09-21 - A CLONE OF A PARKED CHECKPOINT BOOTS WINDOWS WITH 400 MB, AND I BLAMED THE WRONG THING FIRST] `win11de-ctlc` went deaf during its install and I recorded, in this file, that I had probably [verified 2026-09-21]
- P2 [PROFILED 2026-09-16 - VERDICT: NO SLEEP WORTH CHASING; THE LEVER IS RUNTIME C# COMPILES] INSTALL SPEED. Owner: "after we finish, chase sleeps". Profiled from the two fresh stage-2 logs (gaps between consecutiv [verified 2026-09-16]
- P2 [acceptance, unexplained] A WIN10-upgrade CELL SAW ZERO MAPPED WINDOWS DURING 4
- P2 [capture, rest-zero deaf ladder; OURS - the broker's relay rung] [verified 2026-10-02] **WHILE THE RELAY RUNG SERVES A DEAF WGC SESSION, ITS INVISIBLE DESTINATION WINDOW CAN GET A NEIGH
- P2 [guest-stability, user-facing; OURS - supervision ordering; FIXED AND MEASURED 2026-10-07, awaiting a release] What it was, measured on win11r-gz (4 [verified 2026-10-07]
- P2 [harness, log-sweep; OURS - tools/log-sweep.py] Measured on the win11-acc capture: every one of the 35 error lines is stamped `045801`
- P2 [harness, log-sweep; OURS - tools/log-sweep.py] boot 1 and boot 4 are the SAME BOOT
- P2 [harness; OURS - tools/qtest] qtest (FIXED 04597066) HONOURED EVERY `QTEST_INCOMING` EVER SET
- P2 [installer; OURS - MSI service serialization; FIXED 2026-10-07 (fix/broker-control), the actor named from evidence] [verified 2026-10-07] **INSTALL STAGE 2 WAS RECORDING THE ERROR-CLASS FLAG `svc_msi_started` (
- P2 [netsetup, errors; OURS - guest/pvnic-selfprime.ps1's qwtng-netsetup] FIXED fc4c5654: NETSETUP DISCOVERED QUBESDB'S READINESS BY FAILING, AT TWELVE ERROR LINES A GO
- P2 [reprioritized 2026-10-02: was P1; Jev P2 0.43] THE IDLE BURN IS CUT ~4x BY AN ECHO GUARD IN THE AGENT'S PrintWindow ENGINE; NOT YET RETIRED
- P2 [reprioritized 2026-10-02: was P1; Jev P2 0.45] ONLY ONE EPISODE WAS A RULE THAT NOBODY HAD MECHANIZED
- P2 [superseded] WINDOWS DEFENDER BLOCKS THE PV DRIVER INSTALL ON A REAL IMAGE - MEASURED 2026-09-25, AND IT IS NOT A WEDGE
- P2 [typing latency; OURS - rest-zero vs the pre-rest-zero candidate echo2; DEFERRED BY THE OWNER 2026-10-03: "write it off as P2 defect, will return to it later" - not blocking the rest-zero acceptance or a releas [verified 2026-10-03]
- P2 [user-facing, latency; OURS until shown otherwise - broker WGC session] The owner played with Calculator from dom0 on w11-ds (26100
- P2 [user-facing, notifications; OURS - the death reporter's trigger; FIXED 2026-10-07, not yet demonstrated] A COMPONENT THAT DIED DURING A SHUTDOWN LOST ITS DOM0 NOTIFICATION [verified 2026-10-07]
- P2 [user-facing, notifications; OURS - the helper tasks' instance policy; FIXED IN rc2 (agent bfdadba), NOT YET DEMONSTRATED] AFTER AN AGENT RESTART THE GUEST RAN WITH NO TOAST BRIDGE AT ALL, SILENTLY FOR THE REST [verified 2026-10-07]
- P2 toast-bridge (docs/DESIGN-toast-bridge.md): A0 per-app forward-bridge DONE  GATE NOW DEFAULTS ON (2026-09-13, agent 2862c13, rig-unvalidated) [UNVERIFIED]
- P2 win11-24H2 resolution-change capture FREEZE (0x887a0026 keyed-mutex-abandoned) [verified 2026-10-16] **MY 2026-10-16 LINKAGE TO THE FAILPROOF SUITES IS RETRACTED - see FAILPROOFGATESP53BLOCKED: those suites sto
- P3 Win10 ESU: real 2025-11 CU resolves and is installable; the gate is CBS ESU entitlement — owner MAK/licensing decision. [verified 2026-08-20]
- P3 Windows PV TCP connect tail ~5x vs Linux qube (p99 65 vs 49 ms) + ~8 ms DNS overhead; IPv6 hypothesis disproven. [verified 2026-08-24]
- P3 [ASSOCIATION OVER 4 OBSERVATIONS, NOT A MECHANISM] THE FIRST WU SCAN AFTER A SERVICING APPLY IS VERY SLOW on the German 25H2 template: ordinary-boot scans took ~70 s and ~ [verified 2026-09-17]
- P3 [CLOSED 2026-09-10 - THE DEFECT NEVER EXISTED; a fix was shipped for it anyway] "SHUTTING A GUEST DOWN WITH WRITES IN FLIGHT PRODUCES AN UNCLEAN SHUTDOWN" IS REFUTED. ORIGINAL CLAIM: idle shutdowns cl [verified 2026-09-10]
- P3 [FIXED AND DEMONSTRATED ON A GUEST 2026-09-20/21; WHAT REMAINS IS A CURIOSITY, NOT A DEFECT OF OURS - RE-GRADED FROM P1 2026-09-21 after the owner asked why a fixed item was still listed as open] `KB5007651` (W [verified 2026-09-21]
- P3 [FIXED AND VERIFIED ON A GUEST 2026-09-21 - re-graded from P2, and the product gained the control that made it testable] RESOLVED AND INSTALLED ON win11de-fb9 [verified 2026-09-21]
- P3 [RESEARCH DELIVERED 2026-09-16] docs/RESEARCH-kvm-guest-display-vs-qubes.md - promptable implementation research note (owner: analyse the Proxmox/KVM gu [verified 2026-09-16]
- P3 [SHIPPED AND VERIFIED IN 4.3.26] THE ERROR-NOTIFY ROUTE HAD NEVER DELIVERED A NOTIFICATION IN ANY RELEASE, while its suite reported 10/10. `Send-QwtError [verified 2026-09-10]
- P3 [SHIPPED IN 4.3.22, the 7043 risk measured] WATCHDOG LIFETIME FIXES. Merged from `watchdog-lifetime-4322` (agent 550e1da) into 4.3.22: token handle leaks in `StartT [verified 2026-09-09]
- P3 [VERIFIED ON A GUEST 2026-09-21, AFTER THE VERIFICATION FOUND A SECOND DEFECT IN IT - not a clean green, and recorded as such: Jev graded the blanket claim "these fixes are verified on a guest" at 0.30 precisel [verified 2026-09-21]
- P3 [errors, qrexec; OURS - shipped upstream paths] The lines, attributed by each writing instance's own `Module version` (4
- P3 [installer; OURS - the PV NIC re-arm task] THE SHUTDOWN RE-ARM WAS TERMINATED (267014) AND NOTHING COULD TELL WHETHER ITS TWO REGISTRY WRITES HAD LANDED
- P3 [reprioritized 2026-10-02: was P1; Jev P3 0.54] Measured 2026-10-01 on w11-ds (26100
- P3 [reprioritized 2026-10-02: was P1; Jev not-open 0.22 - likely resolved by a newer entry or the current build; verify, then move to issues-closed.md] Source-verified end to end 2026-09-26, and it explains a meas [verified 2026-09-26]
- P3 [reprioritized 2026-10-02: was P1; Jev not-open 0.25 - likely resolved by a WHY WGC STOPS - MEASURED 2026-09-25, and it is not a UWP quirk but a whole CLASS [verified 2026-09-25]
- P3 [reprioritized 2026-10-02: was P1; Jev not-open 0.27 - likely resolved by a newer entry or the current build; verify, then move to issues-closed.md] AT REST THE WHOLE STACK WAKES 8-29 TIMES A MINUTE AND ITS CPU [verified 2026-10-01]
- P3 [reprioritized 2026-10-02: was P1; Jev not-open 0.33 - likely resolved by a newer entry or the current build; verify, then move to issues-closed.md] THE BROKER NEVER PUMPED ITS WINDOW MESSAGES, SO WINDOWS GHOST [verified 2026-09-27]
- P3 [reprioritized 2026-10-02: was P1; Jev not-open 0.34 - likely resolved by a newer entry or the current build; verify, then move to issues-closed.md] THE RELAY WORKS AND IS THROWN AWAY: THE QUIET RULE DEMOTES HE [verified 2026-09-26]
- P3 [reprioritized 2026-10-02: was P1; Jev not-open 0.37 - likely resolved by a newer entry or the current build; verify, then move to issues-closed.md] THE UWP FIX, FIRST RIG RESULT (w11-ds, 26100 [verified 2026-09-30]
- P3 [split 2026-10-06 from the closed TOAST OVERCROP entry (issues-closed.md);  TWO RESIDUALS OF THE TOAST OVERCROP FIX [verified 2026-09-06]
- P3 [updates, installer; OURS - the dom0 RPM] THE dom0 RPM SHIPPED THREE SCRIPTS AND ITS `%post` RAN TWO OF THEM IN dom0
- P3 [user-facing, geometry + capture; OURS - the agent's dom0-drive path (ADR-gui 2); FIXED agent 001b525 (build rz23), owner-verified 2026-10-02 01:03 "all perfect"] [verified 2026-10-02] **A DOM0 EDGE-RESIZE REPL
- P3 goldens/checkpoint restores may carry another lineage's stale `Q:\qwtng-net cfg.txt` L3 cache — never measured. UNVERIFIED
- P3 legacy lint findings (40) are BASELINED in tools/lint-baseline.txt — not op en work; editing a legacy harness re-exposes its findings (line-anchored), so touched code gets fixed and NEW findings s [verified 2026-09-01]
- P3 scroll/typing damage-cost attribution vs b299011 baseline recorded closed b ut closing evidence lost — re-derive from tools/bench-stock-vs-ours.sh before any regression claim. UNVERIFIED
- P3 the %~f0/shift elevation fix has no regression check that can fail here (al l rigs run EnableLUA=0, the relaunch path is structurally unreachable). [verified 2026-08-16]
- P3 verdict-grading defect FIXED + p3a-live-validated (2026-09-06, commit d22ec 3c): the p3a/a0 wraps summed `grep -cE 'FAIL|INSTRUMENT'`, folding ungraded probes and un-stageable drills (a drill that [verified 2026-09-06]
- P3 win11-24h2 qrexec-agent death while the guest lived — n=1, plausible wedge- class, unproven. [verified 2026-08-29] RETRACTED 2026-09-13, same day it was raised: I briefly recorded this as n=2 from
- PAYLOADREADONLY [harness; P2, FIXED] A PAYLOAD COPIED OFF AN ISO IS READ-ONLY, AND prime-run REPORTED THE WRONG FAILURE TWICE
- PINNEDLETTERISNOTEXCLUSIVE [P1 instrument, the ROOT CAUSE of SWEEPBLINDWHENLOGDIRISNOTLIVE; mgmt/harness/logvol-bind.ps1 Pin-LogVol + every LogDir consumer; **HARNESS SIDE CLOSED; cause REPRODUCED ON DEMAND**] ANO [verified 2026-10-20]
- PIPEFAILGREPQFILEREAD [harness; P2, FIXED - all 6 sites] A FILE READ PIPED INTO `grep -q` RETURNS 141 UNDER pipefail, NOT grep's STATUS
- PROBESIGPIPE [harness liveness, every suite; P1, FIXED] A GUEST THAT ANSWERED WAS GRADED DEAD, INTERMITTENTLY, BY EVERY LIVENESS PROBE IN THE RIG
- PWFUSE42 [rig images, blocks acceptance; P1, FIXED] EVERY WINDOWS IMAGE CARRIED A 42-DAY PASSWORD FUSE, AND THE WIN10 ONE WENT OFF TODAY
- QDBREADERNAMEWRONG [product; P1, FIXED IN SOURCE] THE INSTALLER CALLED A FUNCTION THAT DOES NOT EXIST, AND BLAMED DOM0 FOR THE RESULT
- QGANOTIFPIDCALLEDAREUSEDPIDAFORGERY [P2 product, agent/gui-agent/main.c; FIXED 2026-10-19] THE AGENT ACCUSED THE GUEST OF TAMPERING 1 [UNVERIFIED]
- QGAVCHANFAIL [errors, qrexec-wrapper; owner 2026-10-09] A FAILED VCHAN CONNECT IS ONE HUMAN-READABLE ERROR LINE
- QGAWGCRECREATEBLAMEDAKEYPRESS [P2 product, agent/gui-agent/main.c; FIXED 2026-10-19] "a key or click got no frame" ON A CELL THAT SENDS NEITHER [UNVERIFIED]
- QREXECAGENTAV [qrexec agent, Win10 clean+reinstall cells; P1, FIXED IN SOURCE - unbuilt, unrun on a guest] qrexec-agent [verified 2026-10-14]
- QREXECOUTPUTLOSTWHENTHECALLERHANGSUP [P2, and the gate condition that failed two cells; guest/qrexec-wrapper + mgmt/harness callers; **HALF CLOSED**] win10-upgrade breached with 2 and win10-reinstall with 1 [verified 2026-10-19]
- REAPEDTASKFRAMEMISMATCH [product, guest/qwt-report-death.ps1; P1, FIXED - a reaped task was reported to the user as a failure] THE SHUTDOWN PROBE COMPARED A LOCAL INSTANT WITH A UTC ONE, SO NO SHUTDOWN COULD EVER [verified 2026-10-15]
- RELAYBOUNDTHEPIDNOTTHEPORT [P1 product, guest/qubes-updates-relay.cs + guest/install-updater-agent.ps1; FIXED 2026-10-19] An orphaned relay (pid 9648, no parent watchdog, so it outlived its pass) has been squattin [UNVERIFIED]
- RELAYREADINESSNEVERWAITED [P1 product, guest/qubes-windows-update.ps1; FIXED 2026-10-19] THE CHECK THAT FAILED template-update ALL THREE ROUNDS SAMPLED ONCE AND CALLED IT A 3 s WAIT [UNVERIFIED]
- REPORTCLOCKS [errors, notifications; OURS] [verified 2026-10-09] **RE-MEASURED AFTER FOUR DEFECTS IN THE REVIEWER ITSELF: THE REAL CANDIDATE SET IS 14, NOT 18, AND
- RESMODESETNOTLIVEONRELOAD [P2 product, OUR QubesIDD driver + agent/gui-agent/resolution.c; **DRIVER SIDE OPEN**, agent workaround shipped 4.3.37] OUR OWN RELOAD IOCTL RETURNS BEFORE THE MODE SET IS LIVE [UNVERIFIED]
- RESWAITSTALLONSECUREDESKTOP [P2 product, agent/gui-agent/resolution.c; **FIXED 2026-10-18 - the pre-flight is skipped on the secure desktop; campaign 20261018-183821 rc=0**] Campaign 20261018-123812, one occurrenc [verified 2026-10-18]
- RTCCALLUNRESOLVED [guest clock; P1, FIXED] THE RTC FIX'S SUBJECT-SIDE ARM WAS NEVER CALLABLE, AND A GREEN SUITE SAID IT WAS
- RTIUFORCEDINIMAGES [harness/images; P1, FIXED] THE VALUE THE GATE WAS MEANT TO MEASURE WAS BAKED INTO THE IMAGES AND THE GOLDENS
- RTIUWRONGDEFAULT [product; P1, FIXED IN SOURCE - awaiting a fresh-install measurement from a REBUILT golden] WE DECLARE THE HARDWARE CLOCK HOLDS UTC, AND ON A QUBES WINDOWS QUBE IT DOES NOT [verified 2026-10-15]
- SELFTESTSUNRUNINCI [gate coverage; P2, FIXED] PRODUCER ADDED:
- SHADOWWARNOUTLIVEDITSOWNCONDITION [product, log noise; agent/gui-agent/main.c ApplyGuestShadows; FIXED 2026-10-17] A COMMENT KEPT A WARNING ALIVE ON THE AUTHORITY OF A SENTENCE THAT HAD STOPPED BEING TRUE [verified 2026-10-17]
- SHUTDOWNDEATHTOAST [notifications, watchdog/notifhost; OURS; owner named it 2026-10-10] EVERY SHUTDOWN TELLS dom0 A QWT COMPONENT DIED OF A MAJOR ERROR, AND IT IS JUST WINDOWS ENDING THE SESSION [verified 2026-10-10]
- SPECIMENHANDBOOT [working practice; P2, FIXED] I STARTED A PRESERVED SPECIMEN BY HAND TO READ LOGS THAT NEEDED NO GUEST
- STALEWORKTREEHIDSUITES [instrument; P2, FIXED] TWO SUITES THAT GUARD SHIPPED PATCHES COULD NOT RUN, AND READ AS PRODUCT REGRESSIONS
- STARTAPPCOLDSILENT [app menu, user-facing; P1, FIXED and receipted on a guest] rc=46 after 70 s, stderr EMPTY [verified 2026-10-11]
- STARTDISMISSNOMECHANISMWORKS [P1 user-facing, agent/gui-agent/main.c; **STILL OPEN - TWO MECHANISMS NOW REFUTED ON THE GUEST, AND A CONFIGURATION DECISION IS OWED**; GWeck #172] THE AGENT CANNOT CLOSE THE HIDDEN S [verified 2026-10-17]
- SWEEPBILLSOLDBUILD [instrument, tools/log-sweep.py; FIXED 2026-10-16] On win11-nfy the OLD build (gui-agent 4
- SWEEPBLINDWHENLOGDIRISNOTLIVE [P1 instrument, mgmt/harness/matrix.sh + the guest-side log collector; **CLOSED 2026-10-20**] FOUR OF EIGHT CELLS WERE GRADED BLIND WHILE THEIR LOGS SAT ON THE VOLUME [verified 2026-10-19]
- SWEEPFILECAPSILENTLYUNDERREAD [P2 instrument, mgmt/harness/matrix.sh MATRIX_SWEEP_FILE_CAP; **CLOSED 2026-10-20**] THE CAMPAIGN PRODUCED 610 LOG FILES AND THE SWEEP READ 600 [verified 2026-10-19]
- SWEEPGATEADVISORY [gate, tools/sweep-gate.sh + mgmt/harness/quick-upgrade.sh; P1, FIXED - it gates, and its first verdict was against ME] NOW GATES, AND THE RECEIPT IS THAT IT BLOCKED A RUN I WANTED TO PASS [verified 2026-10-16]
- SWEEPGATEBLINDONITSOWNEMITTERS [instrument, tools/sweep-gate.sh + three harness loggers; FIXED 2026-10-17] THE CAMPAIGN-WIDE ERROR GATE REFUSED TO JUDGE RUN 38994277148 AT ALL, AND IT WAS RIGHT TO [verified 2026-10-17]
- SWEEPGATESNOPRODUCER [gate, tools/log-sweep.py; P1, CLOSED - all 14 gates now fire and breach] UPDATE 2026-10-15, same day: ten of the fourteen now FIRE AND BREACH [verified 2026-10-15]
- SWEEPGATEUNINVESTIGATED [gate, mgmt/harness/error-ledger.txt; 9 DISPOSITIONED, 7 UNSETTLED, 3 EXTERNAL as of 2026-10-17] NINE qualify and now have rows carrying their distributions: QioWriteBuffer x6 (0 [verified 2026-10-17]
- SWEEPGRADEDDOUBLE [acceptance harness tally; P2, FIXED] ONE FAILURE, TWO TALLY ENTRIES, AND THE WRONG CLASS ON THE SECOND
- SWEEPSAYSNOTATTACHEDWHENITWAS [P2 instrument, mgmt/harness/matrix.sh:325; **CLOSED 2026-10-20**] A FALSE REASON ON A REAL FAILURE [verified 2026-10-19]
- SWEEPSUITEBLINDONTWOP1METRICS [P1 instrument, tools/tests/log-sweep-selftest.sh; FIXED 2026-10-19] TWO P1 METRICS HAD NO OFFLINE COVERAGE AT ALL, which is how the defect above survived [UNVERIFIED]
- SWEEPUTF16BLIND [error gate; P2, FIXED] A UTF-16 LOG IS INVISIBLE TO EVERY REGEX, AND WINDOWS WRITES IT BY DEFAULT
- SWEEPWARNUNLEDGERABLE [gate, tools/sweep-gate.sh + mgmt/harness/quick-upgrade.sh; P1, FIXED - the gate half has a suite, the emitter half awaits the next guest run] THREE INDEPENDENT REASONS IT CAN NEVER BE LEDGER [verified 2026-10-16]
- TOASTHOLDPARSERBLIND [instrument, mgmt/harness/toast-hold-grade.py; P1, FIXED - and MY FIRST DIAGNOSIS WAS WRONG] THE SLICE WAS NOT THE CAUSE [verified 2026-10-16]
- TRIGGERPIPEOWNTOKEN [qrexec, security posture; UPSTREAM DESIGN, NOT OURS - reported, not changed] [verified 2026-10-10] **A LOCAL CLIENT CAN ASK THE AGENT FOR A CHILD ON THE SERVICE'S OWN TOKEN BY SPELLING THE USE
- UPDATESAVAILABLEOSCILLATES [instrument, mgmt/harness/wu-e2e.sh oscillation leg; P1, FIXED - NOT a product defect; the CHECK was wrong and now judges AGREEMENT] SETTLED ON THE PRESERVED SPECIMEN: THE SCAN FOUND A R [verified 2026-10-16]
- UPDCLEANFAIL [updates, installer; OURS; owner drove the RCA 2026-10-09] [verified 2026-10-09] **VALIDATED ON THE FAILING PATH, 2026-10-09 20:31Z: `"updater_agent":"deployed"`, `"stage":"stage2
- UPGRADECELLBREACHES [P2 product, win11-upgrade; **STALE - four of the five are gone**] [verified 2026-10-18] **WITH THE BASELINE REFRESHED, THE ACCEPTANCE FAILURE STOPPED BEING BOOKKEEPING AND BECAME FIVE NA
- UPGRADECELLUSESCLEANBOOTTHRESHOLDS [gate, tools/log-sweep.py DEFAULT_THRESHOLDS; **STALE - same premise as ACCEPTANCECANNOTPASSWITHUPGRADECELL**] [verified 2026-10-18] **AN UPGRADE CELL REPLACES THE AGENT MID-BOOT
- UPSTREAMBASELINEISCAMPAIGNSHAPED [P1 instrument, tools/sweep-gate.sh + mgmt/harness/upstream-counts.txt; FIXED 2026-10-19] AN ABSOLUTE COUNT CANNOT SCOPE A WORKLOAD, and this alone would have blocked the 4 [UNVERIFIED]
- VMEXECNOSTDOUT [qrexec transport, ALL dom0 tooling; P1, FIXED ON A GUEST 2026-10-14 - see GOALVERIFY1014 below; the release-wide receipt is the acceptance run] `qubes [verified 2026-10-14]
- WUE2EDECLARESNOLEVEL [gate, mgmt/harness/wu-e2e.sh:52; P1, FIXED IN SOURCE - unrun on a guest] THE UPDATER SUITE MEASURED THE PRODUCT CLEANLY AND STILL FAILED THE RELEASE, BECAUSE ITS OWN LINES DECLARE NO LEVEL [verified 2026-10-16]
- WUFIRSTCONTACTSILENT [updater, dom0-facing; P1, FIXED ON A GUEST 2026-10-14 with its root cause VMEXECNOSTDOUT - see GOALVERIFY1014 below] ON FIRST CONTACT THE UPDATER DIAGNOSES ITS OWN FAILURE PERFECTLY AND TELLS [verified 2026-10-14]
- WUJUDGECOULDNOTSEESILENCE [P2, instrument; tools/wu-pass-judge.py; FIXED 2026-10-17 a293aa11] THE "DID IT DIE SILENTLY" JUDGE COULD NOT SEE A PASS THAT DIED SILENTLY [verified 2026-10-17]
- WUJUDGEPASSEDADEADUPDATER [P1, release gate blind; tools/wu-pass-judge.py; FIXED 2026-10-17 a293aa11] Release 4 [verified 2026-10-17]
- P2 [platform, idle cost; NOT OURS - Windows 11 on Qubes' Xen HVM configuration; remedy dom0-side, owner decision] [verified 2026-10-02] **AN IDLE WINDOWS 11 GUEST BURNS ~45% OF ONE CORE, AND A PRISTINE GUEST WITHOUT QWT BURNS TH
- DOM0LOUDCOUNTSTHETEST [gate, tools/log-sweep.py dom0_loud_failures; FIXED - tools/gate-remainder.sh:335 declares the four notifications the acceptance suites fire on purpose, and MEASURED 2026-10-21 no sweep in the campaign path covers win11-nfy at all: release-acceptance.sh invokes log-sweep nowhere and the eight cell subjects do not include it] [verified 2026-10-21]
- APPVMSWEEPSWRONGQUBE [acceptance gate, mgmt/harness/matrix.sh; FIXED - matrix.sh resolves the subject in _matrix_sweep_subject() with the appvm arms BEFORE the prefix arms, which is the fix the entry asks for, and tools/tests/matrix-logsweep-grade-selftest.sh:169 exercises it without a guest] [verified 2026-10-21]
- APPVMCELLNEVERSWEPT [acceptance gate, mgmt/harness/matrix.sh; FIXED - MEASURED 2026-10-21 on run 39476792836: both appvm cells pulled 21 files each, so the evidence stick is attached and pulled on the appvm path (the entry recorded ONE zero-byte file on run 38787325142)] [verified 2026-10-21]
- LOGVOLBINDSENTZERO [harness, mgmt/harness/logvol-lib.sh; FIXED - MEASURED 2026-10-21 on run 39476792836: 26 LOGVOL-PROOF ok and zero failures, and no "binder never arrived" or "sent 0/" line anywhere in the campaign; logvol_prove_roundtrip now writes a nonce from the guest and reads it back off the image] [verified 2026-10-21]
- CLOCKFEATURECLEARHIDESIT [instrument; FIXED - clock_feature_reset no longer exists; matrix.sh:879 is clock_feature_report, which REPORTS the qube clock convention and never changes it ("THIS USED TO UNSET THE FEATURE, AND THAT HID A P1 FROM THE GATE")] [verified 2026-10-21]
- QREXECCALLSTARTSAQUBE [instrument; FIXED 2026-10-21 in BOTH halves - tools/hooks/serial-rig-gate.sh treats any qrexec call to a non-dom0 target as mutating (it had named three services; the measured waker qubes.GetAppmenus was not one), and tools/qtest refuses run/ps/push/pushrun/synctime/incoming when the target is HALTED, which is what stops a job that outlived its run - the hook gates tool calls and cannot see an already-running script. dom0 services stay exempt so monitoring is never blocked. Verified live against a halted win11-nfy: rc=3 and the guest stayed halted. tools/tests/qtest-halted-guard-selftest.sh 12/12, no override knob] [verified 2026-10-21]
- OSCILLATIONSCANTIMEDOUTUNDIAGNOSABLE [P2 instrument, mgmt/harness/wu-e2e.sh oscillation check; FIXED - verified against the code 2026-10-21, Jev 0.55: mgmt/harness/wu-e2e.sh:353-355 + :392-394 (commit e6252f85, ancestor of HEAD)] [verified 2026-10-21]
- CLAUSE2MEASURED [acceptance gate; FIXED - verified against the code 2026-10-21, Jev 0.70: /home/user/qwt-accept/rel-39476792836/campaign/runner.log:78 and :309; .../matrix/win10-clean-coldcallers.out:2-11] [verified 2026-10-21]
- LOGVOLBINDUPGRADE [log recovery, upgrade cells; FIXED - verified against the code 2026-10-21, Jev 0.82: /home/user/qwt-accept/rel-39476792836/campaign/matrix/WIN10-upgrade-logvol-bind.out:1 and WIN11-upgrade-logvol-bind.out:1; fix in mgmt/harness/logvol-] [verified 2026-10-21]
- P3 [harness; FIXED - verified against the code 2026-10-21, Jev 0.68: tools/log-sweep.py:472 + :2428 (agent_instances_per_boot) and :465 + :2398 (agent_relaunches_at_shutdown)] [verified 2026-10-21]
- P1 [user-facing, rendering; FIXED - verified against the code 2026-10-21, Jev 0.77: agent/gui-agent/main.c:346 (`g_WgcArenaBytes = 1024u * 1024u * 1024u`) and :2868 (`CreateFileMapping(..., PAGE_READWRITE | SEC_RESERVE, ...)`)] [verified 2026-10-21]
- P2 [reprioritized 2026-10-02: was P1; FIXED - verified against the code 2026-10-21, Jev 0.51: mgmt/harness/quick-upgrade.sh:371, mgmt/harness/matrix.sh:1024 and :2296, mgmt/harness/prime-run.sh:211 (`qvm-features <vm> timezone localtime` at cre] [verified 2026-10-21]
- P2 vchansendbuffer-unbounded [; FIXED - verified against the code 2026-10-21, Jev 0.77: agent/gui-agent/vchan.h:55 (`VCHAN_SEND_DEADLINE_MS 10000`) and :62 (`VCHAN_SEND_COMMITTED_DEADLINE_MS`), with VchanReserveLocked at agent/gui-agent/v] [verified 2026-10-21]
- P1 [updates/install, user-facing; FIXED - verified against the code 2026-10-21, Jev 0.81: core-agent/src/qubes-rpc-services/set-time.ps1:88 `Set-Date -Date $utc.ToLocalTime() -ErrorAction Stop`] [verified 2026-10-21]
- P2 guest-title-bar-hiding [; FIXED - verified against the code 2026-10-21, Jev 0.76: docs/QVM-FEATURES.md:22 (`service.hideGuestTitleBar` default **on** since 4.3.21) and agent/gui-agent/main.c:7784-7787] [verified 2026-10-21]
- UPGRADECELLGRADESOLDBINARY [gate, tools/log-sweep.py; FIXED - verified against the code 2026-10-21, Jev 0.82: tools/log-sweep.py:2549 (errors_during_requested_stop now filtered through _prior) and :2550 (_count("stale_error_lines", ... and not _prior(lf, l))),] [verified 2026-10-21]
- RTCOFFSETWRITEBACK [product/environment; FIXED - verified against the code 2026-10-21, Jev 0.57: /home/user/qwt-accept/rel-39476792836/campaign/matrix/*-logsweep.out: clock_boot_correction_s=0 on 8 of 8 cells (2026-10-20), pre-sync skew -1..-5 s; ] [verified 2026-10-21]
- DOM0SENDSPARKHANG [harness instrumentation; FIXED - verified against the code 2026-10-21, Jev 0.77: /home/user/qwt-accept/rel-39476792836/campaign/full.out: four dom0-sends parks on 2026-10-20 (19:56:35, 20:04:24, 20:42:08, 20:55:06), each completing] [verified 2026-10-21]
- RELAYLOGONSYSTEM [notifications, qrexec-wrapper/notifhost; FIXED - verified against the code 2026-10-21, Jev 0.81: core-agent/src/qrexec-agent/qrexec-agent.c:721-735 (NormalizeUserName maps SYSTEM/root, case-insensitively, to NULL = the service's own token) applied] [verified 2026-10-21]
- P2 [reprioritized 2026-10-02: was P1; FIXED - verified against the code 2026-10-21, Jev 0.77: docs/ADR-capture.md:965-1016 - §32 "Liveness from input and Windows' own events only; the damage-comparison detector goes", ACCEPTED (owner) 2026-10-0] [verified 2026-10-21]
- P3 [reprioritized 2026-10-02: was P1; FIXED - verified against the code 2026-10-21, Jev 0.67: tools/wgcbroker/wgcbroker.cpp:830-847 (RepublishRetained), called from the main loop at :2077 after Reconcile - the exact dead-end the entry diagnoses] [verified 2026-10-21]
- P3 U3 - dom0-driven install drain has never run on a TemplateVM proper [; FIXED - verified against the code 2026-10-21, Jev 0.74: /home/user/qwt-accept/template-update-test-rz38d2.log (2026-10-03): "VERDICT PASS: the update completed on a TemplateVM in gweck's environment (1 reme] [verified 2026-10-21]
- P1 [notifications, shutdown; FIXED - verified against the code 2026-10-21, Jev 0.83: Fix in code: guest/qwt-report-death.ps1:632-663 - Test-QwtTaskEndedByShutdown now returns 'shutdown' on ERROR_SHUTDOWN_IN_PROGRESS alone (:647-648) an] [verified 2026-10-21]
- STARTMENUDTESTNOEVIDENCE [instrument; FIXED - verified against the code 2026-10-21, Jev 0.52: tools/start-dismiss-grade.py:35-45 (CURRENT_STEMS anchor check + three emitter generations) and its docstring :11-15 naming this exact defect; tools/t] [verified 2026-10-21]
- GATEBLINDTOSTARTMENU [acceptance gate; FIXED - verified against the code 2026-10-21, Jev 0.55: mgmt/harness/matrix.sh:1160 calls dom0-callers-check.sh per cell and matrix.sh:2742 calls it --cold, each with `no "..."` on failure (matrix.sh:332: `] [verified 2026-10-21]
- NOTIFYLOSTINSESSIONGAP [product, tools/notifhost; FIXED - verified against the code 2026-10-21, Jev 0.58: tools/notifhost/notifhost.cpp:3589 `if (NotifyDeferWrite(summary, body)) return 5;` ahead of the LOST line at :3590; NotifyDeferWrite :3515, NotifyDef] [verified 2026-10-21]
- PROBEECHOMATCH [harness liveness; FIXED - verified against the code 2026-10-21, Jev 0.51: mgmt/harness/e2e-wait.sh:123 `command grep -qa '^QREADY'` and :148 the same for w_alive_poll; 16 anchored '^QREADY' sites across mgmt/ and tools/, zer] [verified 2026-10-21]
- BRIDGESTOPTEARDOWN [notifications, gui-agent; FIXED - verified against the code 2026-10-21, Jev 0.71: agent/gui-agent/main.c:4885 (bridge, 3 s) and :4032 (broker, 2 s) both grade the bounded wait through QgaHelperStopOutcome(LifecycleSessionEnding(), w] [verified 2026-10-21]
- P2 [guest-stability, debug-introspection; FIXED - verified against the code 2026-10-21, Jev 0.84: core-agent/src/qrexec-wrapper/qrexec-wrapper.c:1664 arms the connect-aware hold, :1673 releases it at DEBUG on success, :1691 XifHoldReleaseCollapsed ] [verified 2026-10-21]
- P3 [reprioritized 2026-10-02 BY THE OWNER: "agent restart is not part of normal operation. on linux it kills the entirety of gui windows and its ok. so it never was p1."; FIXED - verified against the code 2026-10-21, Jev 0.62: agent/gui-agent/main.c:9566 `if (!windowData->PwBrokerSourced)` -> BrokerRegister retry + BROKERLATEREG at :9595/:9599, reached for every tracked wind] [verified 2026-10-21]
- REINSTALLCLOCKPHASE [acceptance gate + product; FIXED - verified against the code 2026-10-21, Jev 0.72: tools/log-sweep.py:1632 - detect_clock_offset now sequences per WRITER (channel for an event line, file otherwise), commit 6683d24a 2026-10-16; re-mea] [verified 2026-10-21]
- APPMAPWRONGHIVE [app menu, user-facing; FIXED - verified against the code 2026-10-21, Jev 0.71: core-agent/src/qubes-rpc-services/get-appmenus.ps1:70 + Set-AppMap at :275-284 now mirror every AppMap entry into HKLM (the ROOT volume an appvm inher] [verified 2026-10-21]
- DESKLOCKFALSE [notifications, gui-agent; FIXED - verified against the code 2026-10-21, Jev 0.79: agent/include/qga-lifecycle.h:379-405 - QgaLockVerdict's QGA_LOCK_PRE_SHELL arm (LOCK read, no shell window seen by this instance and no shell process] [verified 2026-10-21]
- SHUTDOWNTASKS [notifications, shutdown; FIXED - verified against the code 2026-10-21, Jev 0.71: guest/qwt-report-death.ps1:632-663 - Test-QwtTaskEndedByShutdown suppresses only on TWO positive detections (result code names the shutdown or event 1] [verified 2026-10-21]
- P2 [testing methodology; FIXED - verified against the code 2026-10-21, Jev 0.74: no answer file pins UTC any more: mgmt/autounattend.xml:106, mgmt/autounattend-win11.xml:114 and mgmt/autounattend-win11-static.xml:140 all set <TimeZ] [verified 2026-10-21]
- P3 [reprioritized 2026-10-02: was P1; FIXED - verified against the code 2026-10-21, Jev 0.83: the mechanism itself no longer exists: agent/gui-agent/wgcbroker_ipc.h:130-134 - "RETIRED at ABI 19 (rest-zero S4): neither side writes or reads a hea] [verified 2026-10-21]
- P2 [user-facing; FIXED - verified against the code 2026-10-21, Jev 0.74: the remedy was built the same day the entry said nothing had been: agent commit e0082d6 (2026-10-08) "A UAC prompt Windows did not raise is found by i] [verified 2026-10-21]
- PRIMERUNNOSHOTS [procedure; FIXED - verified against the code 2026-10-21, Jev 0.75: mgmt/harness/prime-run.sh:334 screen_probe() calling `tools/qtest shot`, invoked at :583 every ~60 s inside the install/boot wait loop (:432), plus a ] [verified 2026-10-21]
- AGENTVCHANDEATHUNEXPLAINED [gui-agent lifecycle; FIXED - verified against the code 2026-10-21, Jev 0.56: upstream/ro/qubes-windows-utils/src/log.c:462 PREFIX_FORMAT and :471 - the number between timestamp and level is GetCurrentThreadId(); the cited captu] [verified 2026-10-21]
- register-cleanup-2026-10-02 [; FIXED - verified against the code 2026-10-21, Jev 0.55: findings/issues-closed.md:5-11 is now a terse one-line index ("The narrative is deliberately not kept - owner, 2026-10-21 ... Full text is in git hist] [verified 2026-10-21]
- P1 [updates, user-facing; FIXED - verified against the code 2026-10-21, Jev 0.63: packaging/setup/Install-QwtImproved.ps1:5159 sets detail.updater_agent_failed=$true on the deploy catch (GUARD:deployflag), :5178 folds it into $errFl] [verified 2026-10-21]
- P2 [reprioritized 2026-10-02: was P1; FIXED - verified against the code 2026-10-21, Jev 0.66: all three causes closed: CAUSE 1 - mgmt/harness/prime-run.sh:268 PRIME_ASSIGN_MODE defaults to `required` again (findings/rig.md:36 retracts the plain] [verified 2026-10-21]
- u1-update-availability-to-dom0-unmeasured [; FIXED - verified against the code 2026-10-21, Jev 0.66: /home/user/qwt-accept/template-update-test-rz38d2.d/wu-e2e.out - round 2: dom0 updates-available BEFORE='<empty>' AFTER='1', JUDGE PASS; round 3: BEFO] [verified 2026-10-21]
- UPGRADECELLTWOBUILDS [instruments, tools/log-sweep.py; FIXED - verified against the code 2026-10-21, Jev 0.89: Both named metrics are now build-scoped: tools/log-sweep.py:2549 (errors_during_requested_stop, filtered by `_prior`) and :2550 (stale_error_lines, `a] [verified 2026-10-21]
- P3 [harness, log-sweep; FIXED - verified against the code 2026-10-21, Jev 0.85: The capability the entry says is missing now exists: tools/log-sweep.py:745 line_version() (per-line version from the line's own pid/init) and :832 bu] [verified 2026-10-21]
- P3 [latent; FIXED - verified against the code 2026-10-21, Jev 0.86: The root cause named in the entry ("the agent starts wgcbroker and notifhost through their 8.3 paths") was removed by agent commit 33d15de (2026-10-07] [verified 2026-10-21]
- VERSIONLESSSOURCESCANNOTBEBUILDSCOPED [gate, tools/log-sweep.py; FIXED - verified against the code 2026-10-21, Jev 0.84: tools/log-sweep.py:705-742 (install_anchor, added by 0040cfd8) + :861-864 prior() = is_prior_build(...) or (pre_install(l) and not line_version(lf,l))] [verified 2026-10-21]
- DESLICEDOWNFALSE [dom0 notifications; FIXED - verified against the code 2026-10-21, Jev 0.53: agent/include/qga-lifecycle.h:461-471 QgaDesliceWarnDue returns FALSE when downSince==0 || nextWarn==0 ('a zeroed clock means NOT ARMED, never due now] [verified 2026-10-21]
- REQUESTEDSTOPSENTINEL [instruments, tools/log-sweep.py; FIXED - verified against the code 2026-10-21, Jev 0.86: tools/log-sweep.py:655 QGA_EXPECTED_EXITS = ("0x0","0x20514701","0x20514702","0x20514703","0x20514704") - mirroring QgaExitIsExpected() - and the metr] [verified 2026-10-21]
- P3 [reprioritized 2026-10-02: was P1; FIXED - verified against the code 2026-10-21, Jev 0.73: The entry's own last revision withdraws it: 'THIS P1 IS WITHDRAWN. THE RELAY WAS BEHAVING CORRECTLY AND THE FAULT WAS IN MY OWN INSTRUMENT (Jev p1_wit] [verified 2026-10-21]
- P2 [test-framework, release gate; FIXED - verified against the code 2026-10-21, Jev 0.82: mgmt/harness/crop-before-map.sh:129-153 now enforces its own precondition instead of documenting it: read_loglevel, and if either key is < 4 it writes] [verified 2026-10-21]
- CPUTWOREADERS [instrument; FIXED 2026-10-21 - the defect was not two scales but one BAD reader: e2e-wait.sh did `tr -d \0` + `grep -aoE cpu_usage_raw[0-9]+` and summed, the exact parse mgmt/reprovision-usb.sh:179 documents as wrong twice over (measured 2026-08-30: 149 and 6225 where the truth was 3). Four siblings already read it correctly; e2e-wait.sh now does too, and the log line names the unit. tools/tests/cpu-raw-reader-selftest.sh 6/6, control returns 6 for a true 3, plus a sweep so the pattern cannot return] [verified 2026-10-21]
- DEGOLDENHALTSLOW [harness, mgmt/harness/shutdown-lib.sh; FIXED 2026-10-21 - qwt_shutdown re-issues the ACPI request every 120 s while it polls, instead of asking once and waiting out the whole deadline. The entry measured a second ask being answered in seconds after a 909 s wait, twice, costing two seals. A re-ask is the same idempotent request, never a kill. tools/tests/shutdown-reask-selftest.sh 5/5: 5 asks across a 600 s deadline, exactly ONE when the guest halts promptly, the deadline still bounds the wait, nothing kills, and the control rebuilt from the pre-fix loop asks once] [verified 2026-10-21]
- EVLOCKNOTONTHEDESTRUCTIVEPATH [harness, mgmt/harness/prime-run.sh; FIXED 2026-10-21 - the pre-clean that kills and qvm-removes the churn subject now refuses when the guest carries a specimen marker, printing the recorded reason and naming specimen_clear as the deliberate release. It uses specimen-lib, the LIVE mechanism (matrix.sh and e2e-wait.sh write it, golden-boot-gate.sh reads it); MEASURED 2026-10-21 that all five evidence-lock.sh functions have ZERO live consumers and nothing sources that file, so it is dead code and its fate is the OWNER'S CALL rather than a second source of truth wired here. The entry's 2026-09-09 field case - cell 4 re-priming win11-acc and destroying the guest that had just failed win11-clean - is exactly what the guard now refuses. tools/tests/specimen-not-a-leftover-selftest.sh 6/6] [verified 2026-10-21]
- SWEEPGATEVERDICTUNSTABLE [gate, tools/log-sweep.py + mgmt/harness/log-sweep-baseline.json; FIXED 2026-10-21 - IT WAS NEVER AN OWNER DECISION. Root cause: signature keys are family|LEVEL|text (log-sweep.py:891), fc94490 (2026-10-10) deliberately lowered the A6LEAK by-design line to Info with Jev over that site at defect 0.03, and the baseline was generated 2026-10-07 - so the declaration was ORPHANED by the level change and a predecessor build's copy of the line, still at W in the swept directory (the bind copies the old log dir across), arrived as a NEW signature and was re-judged per campaign: 0.51, one hundredth over JEV_DEFECT_FLOOR, failing all three cells of 20261018-010748. The 'judge disagrees with itself 0.40 vs 0.91' reading was wrong: those were two different baseline entries with two different message texts, one of which exists nowhere in the source. FIX: the two stale signature entries are replaced by ONE level-agnostic pattern (issue a6leak-by-design), so a line whose level is a recorded decision cannot orphan its own declaration; and compare() now DETECTS an orphan by name - a line arriving as new while a declaration exists for the same family and text at a different level is reported as a STALE DECLARATION in the report and in the summary, before the new-signature list. Driven: log-sweep-selftest T59, 182/0, with the detector's loop emptied as the control.]

## CLOSED 2026-10-22 — THE RELAY WAS NEVER REBUILT: A BARE `{ }` MADE THE COMPILE DEAD CODE

Owner, every day for weeks, and finally: *"fix the relay properly this time. i am fucking surprised
it was NOT fixed despite me asking EVERY FUCKING DAY"*, then *"YOU WERE SUPPOSED TO INCLUDE THIS FIX
IN YESTERDAYS BUILD AND TOLD ME IT IS FUCKING READY"*, then the question that found it:
*"why didnt you VERIFY IT RUNS"*.

**THE CAUSE.** `guest/install-updater-agent.ps1` had a bare `{ ... }` around its relay compile and
move. In PowerShell a bare brace pair is a **ScriptBlock literal**: constructed, its value emitted to
the output stream, and the statements inside it never executed. So the deploy logged `updater agent
deployed` and the installer RESULT carried `"updater_agent":"deployed"` while nothing was built.

**DATED, AND OUR OWN CHANGE DID IT.** The braces came from **`fa5b416a`, 2026-10-19 09:32 +0300**,
which deleted `if ($skipRelayCompile) { ... } else {` and left its braces behind. That commit is
titled *"updater: the relay bound the updater's PID instead of 8082, and the deploy called it a
success"* — **the fix for the pid-port defect is what made the compile dead**, three days before the
owner's question. Removing the dead skip branch was right; leaving its braces turned a conditional
skip into an unconditional one.

**TWO MECHANISMS IN SEQUENCE — DO NOT CONFLATE THEM.** This was first written up as though the
braces explained everything, and they do not. win11de-tup's relay was written **2026-09-16**, a
MONTH before the braces existed, and `win11r-qwt`'s own install log carries
`2026-10-15 22:38:03 compiled relay ->` — so the block was still executing then. The September
staleness came from the OLDER skip branch (`kept the previous relay exe`), which preserved a stale
exe whenever something appeared to hold 8082 — self-perpetuating, because the stale relay held both
the port and the file. From 2026-10-19 the braces made the compile dead outright, so even after
`87e3a746` removed the refusal nothing was ever built. The stale binary predates `--parent-pid`, so
the launcher's `--parent-pid <PID>` had its VALUE taken as the listen port; WinHTTP pointed at 8082,
nothing served it, and the passes measured on win11de-tup that day ended silent - 10:19:37 and
10:26:20, each dying on "still not accepting connections on 127.0.0.1:8082 after respawn" with
nothing reported to dom0. How many passes across the estate were affected is NOT measured and is
not claimed: the install logs available here are the harness's deduped per-run tails.

**EVERY THEORY I REPORTED BEFORE THIS WAS WRONG**, and each was reported as the fix: a squatter
holding 8082 (nothing held 8082 — the orphans were on pid-ports); a self-perpetuating
`GUARD:vouchexe` refusal; a stale staged `$SetupRoot` copy; `87e3a746`, which stopped a squatter
only when a pid HELD 8082 and so could never fire. All were consistent with the symptom; none was
the cause. A corpus count of install logs was also offered here as corroboration and has been
REMOVED: those files are the harness's deduped per-run tails, the numbers did not behave as the
model predicted (1 of 144 carried the skip branch's own line), and a figure I cannot explain is not
evidence.

**WHY NOTHING CAUGHT IT.** The source text was entirely correct. Greps, offline suites and Jev all
read text, and no amount of reading text can see that a syntactically perfect block is never
entered. `87e3a746` was reported READY on offline legs and Jev scores alone, with no receipt that
the new relay had ever run. One line proves the semantics: `{ $ran = $true }` leaves `$ran` False.

**THE A/B THAT ESTABLISHED IT**, win11de-tup, 2026-10-22, both arms pushed the SAME fresh
`$SetupRoot` from the repo minutes apart, so the ONLY difference was the brace pair:

| | timestamped `compiled relay ->` | block's SOURCE echoed as a value | exe write time | reported |
|---|---|---|---|---|
| arm A — HEAD, braces present | **0** | **1** | unchanged `2026-09-16T16:33:26Z` | `updater agent deployed` |
| arm B — braces removed | **1** (`10:27:04`) | 0 | `2026-10-22T07:27:04Z` | deployed |

The exe went 48128 → 56320 bytes and its UTF-16 `parent=` marker False → True. The next pass logged
`10:29:08.084 listen 127.0.0.1:8082 target=@default user=SYSTEM self=...qubes-updates-relay.exe
parent=936` plus `parent watchdog armed: pid 936`, with 8082 in Listen held by our exe
(`listen_owner_is_our_exe=True`) and accepting a connection — against the five pid-ports the same
cumulative log carries from before the fix (8228, 6688, 8892, 2540, 5956), none with a `parent=`
field. Receipts: `scratchpad/relay-receipt/`.

**WHAT SHIPPED WITH THE FIX.** Removing the braces is the fix; the rest exists so this class cannot
return silently:
- `RELAYSOURCEVOUCH` — the source being compiled must carry three markers, each **code and never a
  human-facing message** (the flag name the launcher passes, the positional-port rule itself, the
  log field). A vouch keyed on an error string's wording refuses a good deploy the day someone
  rewords it, and that failure would land on a guest.
- `RELAYEXEVOUCH` — the PLACED exe must contain the UTF-16 bytes of `parent=`; ASCII does not
  satisfy it. The read is retried four times and an unreadable file throws `QWTRELAYUNREADABLE`, a
  DIFFERENT error from `QWTRELAYSTALEEXE`, because a vouch that cannot tell "wrong binary" from
  "could not read it yet" fails good installs (Defender holds a freshly written exe).
- `RELAYBYIMAGE` — stale relays are found by **image path**, whatever port they hold, and ended by
  PID, never by name. A relay on a different image is LOGGED rather than silently skipped, and a
  failed process query reports that it could not confirm instead of "0 left" (UNKNOWN IS NOT ZERO —
  the same shape of lie as the deploy that reported success over work it never did).
- `tools/tests/discarded-scriptblock-selftest.sh` — an **AST** check over 303 shipped `.ps1` files.
  Its control is the real shipped shape, because the first draft tested for a standalone
  `ScriptBlockExpressionAst`, reported every file clean, and could not detect the shape that had
  just been removed (a bare block is a `PipelineAst` wrapping a `CommandExpressionAst`) — the same
  error one level up.

Jev on the final state: `receipt_proves_execution` 0.96, `serves_the_intended_port` 0.95,
`dead_block_was_the_cause` 0.79 (0.39 before the A/B existed).

## RETIRED 2026-10-23 - the shipped-log-level measurement was taken

- CLOSED 2026-10-23: **the birth line IS present at the shipped log level.** The measurement this
  entry demanded was taken on acceptance run 39880114972. `patches/windows-utils-single-birth-line.patch`
  emits one `LogInfo` line per process start and is wired into `.github/workflows/build.yml` and
  `qwt-full.yml`, so the LogDebug demotion in `loginit-banner-debug.patch` no longer costs the
  declaration. MEASURED in that run's captures, at level `I` with the product shipping LogLevel 3:
      [20261023.095817.602-7108:7112-I] LogInit: QWTBIRTH module=gui-agent ver=4.3.37.1062 pid=7108 session=1 uptime=97.765
  `tools/sweep-gate.sh` counted `birth_lines=896` across 618 sources (it was 207 before the patch),
  from gui-agent, gui-watchdog, qrexec-agent, qubesdb-daemon, file-receiver, get-image-rgba and
  qrexec-wrapper. log-sweep.py's clock-free boot anchor therefore has its input: boot epochs in that
  campaign were derived from each module's own `uptime=` and agreed with the cell log to the second
  (win10-clean boot 3 derived 10:40:51 against the cell's `07:40:51` UTC + the guest's UTC+3).
  The entry also recorded that a single-INFO-birth-line patch had been "written and WITHDRAWN" on
  Jev 0.15/0.06/0.47 - that withdrawal was reversed when the campaign-wide attribution blindness was
  measured directly (four CLEAN cells reporting boots=0 agent_instances=0 over gui-agent logs holding
  148 lines), which is the evidence those Jev readings did not have.
  THE ORIGINAL ENTRY, verbatim:
  - P3 [gate, sweep; MEASUREMENT OWED] [verified 2026-10-21] **WHETHER A MODULE DECLARES ITSELF AT THE SHIPPED LOG LEVEL IS UNMEASURED, AND A PRODUCT PATCH WAS WRITTEN ON THE ASSUMPTION THAT IT DOES NOT.** `patches/windows-utils-loginit-banner-debug.patch` moves the four birth lines from LogInfo to LogDebug; the product ships LogLevel 3 (log.h:64-67, INFO=3 DEBUG=4) and matrix.sh never raises it. If that demotion reaches the binaries, then at the shipped level nothing declares that a module ran and log-sweep.py loses its clock-free boot anchor (ts - System uptime), on which boot and instance attribution rest. NO CAPTURE SETTLES IT: rel-39537916697 holds four harness-side logs and ZERO guest logs (it never reached a sweep); rel-39476792836 shows the banner at INFO with zero Debug lines across 60 guest logs, but its modules report `Module version: 4.3.35.795` on 103 lines and `4.2.2.0` on 6 - builds older than the ea61ba28 package under test, which is the `_is_prior_build` case. A single-INFO-birth-line patch was written and WITHDRAWN on this: Jev product_patch_was_needed_for_the_measured_defects 0.15, patch_premise_is_established 0.06, keep_it_anyway 0.47. THE MEASUREMENT: one guest running a package built after ea61ba28, then `grep -oE 'LogInit: (Log started|System uptime)' | grep -oE '\-[IWEDV]\]'` over its own logs. Until it is taken, do not patch the shared logging library for this.
- SWEEPGRADESTHEDEFAULTDIRNOTTHEBOUNDVOLUME [P1 instrument; it is what failed BOTH upgrade cells; the product is FINE; **OPEN until a campaign measures an upgrade cell grading the candidate's own lines**] [verified 2026-10-23] **THE HARNESS UNBOUND THE LOG VOLUME 18 SECONDS BEFORE THE SWEEP COLLECTED, SO THE SWEEP GRADED THE DIRECTORY THE PRODUCT WAS NOT USING.** From the cell's own log (instrumented re-run, /home/user/qwt-matrix/20261023-050323): `05:17:36 log path still PROVEN` / `05:17:36 log volume pulled` / `05:17:43 LogDir restored to 'Q:\Qubes Logs'` / `05:18:01 the sweep's collector runs` (`LSW LOGDIR pathb64=UTpcUXViZXMgTG9ncw==` = Q:) / `05:18:18 FAIL`. The collector is GUEST-SIDE and its `Get-LswLogDir` resolved the registry LogDir AT COLLECTION TIME, which `logvol_restore_now` had just reverted. **THE EVIDENCE WAS COLLECTED AND NOT GRADED**: the 05:17:36 pull holds gui-agent-20261023.log at 31163 bytes whose first line is a 4.3.37.1062 QWTBIRTH, 27 birth lines in all, in `logvol-<cell>/` - a directory the sweep does not read. **THE PRODUCT IS FINE.** It logged every module to the bound volume throughout. Clean cells pass because their agent also ran while unbound, so Q: holds candidate logs too; an upgrade cell's candidate only ever ran bound.
  **FIXED 2026-10-23 (1d057059) AND PROVEN IN PRODUCTION**: the collector sweeps the UNION of every directory a module could have resolved (`Get-LswLogDirCandidates`: root LogDir, `LogDirPreLogvol`, every per-module key, log.c's `<system drive>\Qubes Logs`, `Q:\Qubes Logs`, `C:\Program Files\Qubes Tools\log`), deduplicated, each non-primary dir reported as `LSW LOGDIREXTRA`; the primary `LSW LOGDIR` receipt is unchanged because the analyzer and three selftests parse it. A union needs no caller change and ordering cannot defeat it. On a live 4.3.37 guest it reported `LOGDIR Z:\qwt-logs\win11r-ttfw exists=1` plus `LOGDIREXTRA Q:\Qubes Logs exists=1 files=4` - four files the previous collector would never have read - and `C:\Qubes Logs exists=0`. Jev: land 0.83.
  THREE MECHANISMS OF MINE DIED ON THE WAY HERE, recorded so none is re-derived: "the agent serves pixels and writes no log" (it writes, to the right place); "the post-install REBOOT is the discriminator" (a probe holding golden, package and reboot constant logged normally); "logvol_pull races Windows' lazy writer" (true but irrelevant - the sweep never reads the image).
  **CLOSED 2026-10-23: the condition in the head is MET, and what it exposed is fixed.** The head said OPEN until a campaign measures an upgrade cell grading the candidate's own lines. The supervision gate's L1 upgrades the golden (4.3.35.0 -> 4.3.37) and its sweep did exactly that on a guest (/home/user/qwt-sup/1023-1733): `LOGSWEEP-RESULT rc=0 status=CLEAN`, zero breaches, `prior_build_mix` carrying BOTH builds, `candidate_build_absent=0`, `error_lines_prior_build=5` (the golden's, correctly excluded), `signatures_unclassified=0`. **AND THE UNION FIX WAS INCOMPLETE IN A WAY NOTHING HAD CHECKED**: a file present in TWO candidate directories was pulled TWICE and every line counted twice - 21 of 88 files on the first gate run, so one process start opened two instance records and `agent_instances_per_boot` read 2 against max 1, failing cell L2 on a healthy guest. Fixed in 5dccc6aa (decode drops a copy only when it is a strict byte prefix of another; divergent copies are kept and reported; `files_deduped` is published) with tools/tests/decode-dedup-selftest.sh 13/13, two mutations seen to fail.
