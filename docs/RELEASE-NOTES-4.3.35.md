# QWT-NG 4.3.35 — the Windows Update agent is installed even during an update check, and the hidden Start menu no longer takes clicks

Everything in 4.3.34 is carried forward. This release fixes two defects reported from the field on a German Windows 11 25H2
template: an upgrade that quietly kept the previous Windows Update agent, and a Windows Start menu that was open but invisible. It
also hardens the GUI agent's connection to dom0 against a dialog that could end a qube's GUI after an upgrade.

## The Windows Update agent is installed even when an update scan is running

A qube that has Windows Tools installed checks Windows Update for available updates two minutes after it boots, and then every
six hours. If the installer was run while such a check was running - the ordinary sequence: start the template, run the
installer - the installer did not install the new Windows Update agent: the qube kept its previous updater, the install said
INSTALL COMPLETE, and the only trace was one warning line in `C:\qwt-improved-install.log`
("Windows Update agent deploy failed: QWTUPDMUTEXHELD"). In dom0 the qube then showed no updates while Windows Update inside it
listed some. This was reproduced on the reporter's environment (a German Windows 11 25H2 template) before it was fixed.

Now the installer waits for a running update check to finish - it watches the check's own lock and continues the moment the
check lets go, for at most the time Windows' Task Scheduler gives the check anyway (20 minutes, plus a few minutes' margin) -
and installs the agent. While it waits it writes a line to its log every 30 seconds. The agent is now installed after the
Qubes RPC agent has started (in 4.3.34 it was installed while that agent was still held back), so dom0 can reach the qube while
the installer waits, and the update check can reach dom0's update proxy and finish. A running update *installation* is not
waited for: it may take up to two hours and ends in a restart, so the installer stops the updater step and says so.

## A failed updater install is reported, not hidden

When the Windows Update agent cannot be installed, for whatever reason:

- The installer logs it as an error, with the cause and what to do, and the last lines it prints before its result say it in
  plain words: "Windows Update agent was NOT installed: ... What to do: ...". The remedy is always the same: let the running
  update pass finish (or end it), then run `install.cmd /updatesonly` from the install medium.
- The install's result is no longer "ok": the result trailer carries `updater_agent_failed` and `ok:false`, so an unattended
  caller reading it sees the failure.
- dom0 receives an error notification ("The Windows Update agent was not installed") at the end of the install, once the Qubes
  RPC agent is running. With `install.cmd /auto /reboot` the qube powers off before that agent starts, so no notification is
  sent in that run; the installer's log and result say so, and carry the failure.
- Every line the updater deploy writes now appears in `C:\qwt-improved-install.log` as it happens. Until now a failed deploy
  left none of its own lines there, only the final error.

## The Windows Start menu no longer stays open invisibly

In seamless mode the Windows Start menu is not shown (on Windows 11 25H2 it cannot be reproduced acceptably as a seamless
window), and the Windows key is blocked by default. With `service.enableWinKey 1` - meant for a third-party start menu such as
Open-Shell - or with Shift+Win, Windows still opened its own Start menu: invisible in dom0, but holding the keyboard and taking
the clicks meant for the windows underneath it ("clicking where it should be starts Paint"). Reproduced on the reporter's
environment with 4.3.34.

Now the agent closes the Windows Start menu the moment it opens in seamless mode, and tells you once per session, with a dom0
notification, why it closed. Open-Shell's menu and Windows Search (Win+S) are not affected. The README's section on the Windows
key said the key was let through by default and that "the Start menu works again"; both were wrong and are corrected.

## The GUI agent sends its protocol version before anything else

After an upgrade or reinstall with the qube's GUI open, dom0 could show "The GUI agent that runs in the VM ... implements outdated
protocol (0:0), and must be updated", and the qube then had no GUI until it was restarted. The "(0:0)" means dom0's GUI daemon read
zeros where the agent's protocol version should have been - the very first thing it reads when it connects. The agent now lets
nothing onto its connection before that version exchange is complete; a part of the agent that tries to send earlier is refused
and logged (`QGAHANDSHAKE` in the gui-agent log). This makes "the version comes first" true by construction. We have not
identified the exact writer of those zeros, so if you still see the dialog, restart the qube and send us the gui-agent log.

## Known and not fixed

- The items under "Known and not fixed" in the 4.3.34 notes stand.
- The updater deploy is not retried at the next boot when it was refused; the remedy is `install.cmd /updatesonly`.
- Whether the dom0 notification arrives on an interactive install depends on the Qubes RPC agent being connected to dom0 when
  the installer sends it, after the updater step; this has not been measured on a guest yet.

## How this release was verified

(placeholder - to be filled from the release acceptance)

- Offline, on this change: the installer and updater-deploy suites (`tools/tests/wu-deploy-loud-selftest.sh`,
  `tools/tests/wu-deploy-prevpass-selftest.sh`, `tools/tests/result-flags-selftest.sh`, `tools/tests/svc-serial-start-selftest.sh`)
  pass, and every new assertion has been seen to fail with its defect re-introduced.
- On a guest: not yet run. The acceptance must include an upgrade started within two minutes of the template's boot (inside the
  previous updater's scan), on the reporter's environment, and must show the agent installed and dom0 reporting the update.
