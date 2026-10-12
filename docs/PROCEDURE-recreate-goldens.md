# PROCEDURE — recreate goldens (when none exist)

Load this only when `win10-base`, `win11-base`, `win10-qwt` and `win11-qwt` are all missing or their seals fail `mgmt/golden.sh verify`.

This is the committed sequence. Do not invent steps. Do not substitute other harnesses.

## Preconditions
- No Windows guests running.
- Vendor install media available to the existing reprovision path (`mgmt/reprovision-usb.sh` or the documented equivalent that produces a Halted pristine base).
- An N-1 release setup tree (install.cmd + MANIFEST.json at root) available on disk. If missing, obtain it from CI artifacts of the previous release; do not build a new one for this purpose.

## Sequence (execute in order, serially)

1. Recreate the pristine bases.
   Use the existing reprovision path to produce Halted `win10-base` and `win11-base`.
   Confirm each is Halted and tagged `win-idd-testbed`.
   Do not boot them after creation except as the reprovision script itself requires.

2. Seal the bases if the reprovision path did not already do so.
   ```
   mgmt/golden.sh seal win10-base "pristine base recreated <date>"
   mgmt/golden.sh seal win11-base "pristine base recreated <date>"
   mgmt/golden.sh verify win10-base
   mgmt/golden.sh verify win11-base
   ```
   Both verifies must exit 0.

3. Build and seal the QWT goldens from those bases.
   ```
   mgmt/harness/seal-qwt-golden.sh win10 <path-to-N-1-setup-tree>
   mgmt/harness/seal-qwt-golden.sh win11 <path-to-N-1-setup-tree>
   ```
   Each script calls prime-run from the base, cleans the install stick, and seals.

4. Verify the QWT goldens.
   ```
   mgmt/golden.sh verify win10-qwt
   mgmt/golden.sh verify win11-qwt
   ```
   Both must exit 0.

5. Only after step 4 succeeds may short-cycle work (`quick-upgrade.sh`) resume.

## Gate exception
When no golden exists, there is no short-cycle alternative. A Jev call whose state contains the marker `recreate_goldens` and quotes the commands above (or the path to this file) satisfies `tools/hooks/committed-procedure-gate.sh` for the heavy steps in this sequence (`reprovision-usb.sh`, `prime-run.sh`, `seal-qwt-golden`).

Any other heavy command still requires the normal "exact command + rejected short-cycle" justification.

## After success
Record the N-1 version that was sealed (already written by seal-qwt-golden.sh into `mgmt/fixtures/<os>-qwt.json`). Do not start the goldens. Clone only.
