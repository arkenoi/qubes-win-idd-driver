# pwprobe — Gate 0 occlusion premise check

Answers SESSION-PLAN-per-window-capture.md Gate 0: does
`PrintWindow(hwnd, dc, PW_RENDERFULLCONTENT)` return a window's own correct content while
that window is fully occluded?

Three arms, verdict computed in-guest by exact byte comparison against the pattern the
window painted:

| arm | scene | flags | expectation |
|---|---|---|---|
| baseline | A visible | 0 | MATCH — proves the instrument works |
| fullcontent | A covered by B | `PW_RENDERFULLCONTENT` | the question |
| plain | A covered by B | 0 | negative control, expected MISMATCH |

Also asserts B actually occludes A (`WindowFromPoint` at A's center) — a MISMATCH with
`occluded=NO` is a broken scene, not a result.

Outputs (next to the exe): `pwprobe-result.txt` (summary line `PWPROBE: baseline=...
fullcontent=... plain=... occluded=...`), `pw_baseline.bmp`, `pw_full.bmp`, `pw_plain.bmp`.

Run via `tools/viewcheck/pwprobe-run.sh` (push, run, retry-until-demonstrably-ran, print
result). Exit code 0 = instrument sane (baseline MATCH + occluded YES), independent of the
fullcontent verdict.
