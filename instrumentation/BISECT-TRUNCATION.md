# Bisecting the content-truncation regression

Symptom: in a controlled A/B where only the agent binary differs, most of a Notepad's content
never renders in dom0 - lines 4-25 truncated, large stale region - while stock renders all 25.

Discriminator: `tools/notepad-fill.py` counts text pixels in the window's client area from the
full-desktop dom0 capture. Bimodal and repeatable: ~25600-25900 renders fully, ~11900-12400
truncated. Stock measures 25610.

## Results (each build installed live, scene re-run, dom0 captured)

| build | agent | text px | verdict |
|---|---|---|---|
| stock | `3D2E6BCE` | 25610 | renders fully |
| f2 | `42beb784` input-desktop re-attach | 25872 | **PASS** |
| f3 | `3174d67e` framebuffer re-grant | 11906 | **FAIL** |
| rc | `a20fb5b4` only flag a re-grant | 25610, 25872 (x2) | **PASS** |
| pt | `6258a05f` protocol trace | 11906, 11944 (x2) | **FAIL** |

## What this establishes

`3174d67e` introduced it. That commit set `grants_changed` on the **first** grant as well as on
a re-grant, so every startup sent a duplicate `MSG_WINDOW_DUMP` and forced a full repaint.
`a20fb5b4` restricted the flag to genuine re-grants, and the regression goes away - twice.

## What this does NOT establish

`pt` fails repeatably, but the only change from `rc` is +48 lines that are entirely inside
`if (g_ProtoTrace)` guards, and `ProtoTrace` was confirmed `0x0` during those runs. An inert
change cannot cause this, so **the bisect is not trustworthy past `rc`** - there is a confound
I have not identified. Candidates not yet excluded: residual guest state carried between
installs, and dom0 GUI-session degradation (observed separately: after some cycles even stock
delivered 0 windows to dom0 until the VM was restarted).

Do not treat `6258a05f` as the culprit on this evidence.

## Test-environment problems found while doing this

* `qtest pushrun`'s first push intermittently sends 0 bytes; the scene then silently does not
  run and every downstream number is meaningless. Push and run are now issued separately with
  retries, and the harness requires proof the scene ran.
* Running bisect jobs concurrently makes them reboot the VM underneath each other. Serial only.
* The dom0 GUI session can reach a state where no qube window is delivered at all, for stock
  as well as ours. A VM restart clears it. Any "0 windows" result must be re-confirmed against
  stock before being attributed to a build.

---

# RETRACTED — the whole bisect above measured noise

Interleaving the builds inverted every verdict:

```
stock: text_px=11626 => FAIL
pt:    text_px=25872 => PASS      (exactly backwards from the table above)
```

and the same binary, three consecutive runs, gives both answers:

```
stock: 25872 => PASS
stock: 11626 => FAIL
stock: 11906 => FAIL
```

The discriminator is bimodal and repeatable *within a run*, which is what made it look
trustworthy - but it is not a function of the build at all. Every row in the table above is
void, and so is the conclusion that `3174d67e` introduced anything.

**The "ours truncates content while stock renders it" claim is also retracted.** That was a
single sample of each on a metric that swings the full range on one binary.

## Actual cause of the swing

The scene creates the second Notepad at Windows' cascade position - overlapping the first -
and then moves it. Whether the first window has repainted the uncovered area before the
screenshot is a race. Both agents lose it about half the time.

## What this invalidates beyond the bisect

Any single-sample visual comparison in this project. The chrome-fix result survives because it
is a *count* of windows delivered to dom0 (8 -> 4, strips absent from `geometry.txt`), not a
pixel measure, and it reproduced across every capture. The z-order stale-band result survives
because the band appeared and disappeared under a deliberate stacking change, twice.

## Rule

A visual metric must be run **at least three times per build, interleaved with the control**,
before any verdict. A metric that has not been shown to be stable on a single unchanged binary
is not a measurement.
