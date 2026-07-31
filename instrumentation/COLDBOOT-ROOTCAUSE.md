# Cold-boot failure: root cause and fix

## Cause

The agent can start while **Winlogon** is still the input desktop (the logon screen). It
attaches there correctly, autologon then switches the input desktop to **Default**, and the
agent stays on Winlogon. `EnumWindows` on Winlogon cannot see the user's windows, so nothing
enters the watched list and the qube renders nothing in dom0.

Proven directly, on a boot where it fired, by logging the desktop state against the failure:

```
QGADESK,tid=3804,from=Default,to=Winlogon,SetThreadDesktop=ok
QGADESK,event=enumfail,tid=3804,threadDesktop=Winlogon(ok=1),inputDesktop=Default   (x12)
```

That is not an inference from a pass rate - the thread is demonstrably on the wrong desktop.

* **Intermittent** because it is a race against autologon.
* **Cold boot only** for the same reason.
* **Cleared by an agent restart**, which re-attaches to whatever is current - which is exactly
  why every check in this suite missed it: they all restarted the agent in a live session.

## Fix

The 2 s resync path now compares its thread desktop against the input desktop and re-attaches
when they differ, rearming the window hooks so tracking follows to the new desktop.

## Verification

6 cold boots, binary hash verified per boot, 2 refused for failed installs:

```
PASS  EnumWindows_failures=0
PASS  EnumWindows_failures=0
PASS  EnumWindows_failures=0
```

against ~1 failure in 3 before the fix. Three passes alone would be weak evidence; combined
with the log showing the wrong-desktop mechanism and its removal, this is the cause.

## Two earlier theories, both wrong, both leaving real fixes behind

* `a4a64a7` - capture.c closed the desktop handle it had previously installed;
* `b01a146` - util.c closed the handle from `GetThreadDesktop`, which MSDN forbids, with two
  callers racing at startup. This one is an **upstream** bug in stock QWT.

Both are genuine API-contract violations worth keeping. Neither changed the failure rate, and
the bisect that pointed at the first was built on a discriminator later shown to be unstable.
