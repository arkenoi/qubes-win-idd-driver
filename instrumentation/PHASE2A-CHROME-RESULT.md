# Goal item (c) VERIFIED: Office synthetic windows, 5 mapped -> 1

Tested with `tools/chromerepro` on win-idd-test (Win10 Enterprise LTSC 2021, seamless mode),
which reproduces the Office 2013+ compound-window layout without Office: a main window plus
four `WS_EX_LAYERED|WS_EX_TRANSPARENT|WS_EX_TOOLWINDOW|WS_EX_NOACTIVATE` owned shadow strips
(exstyle `0x080800A0`, style `0x94000000`, 960x160 and 160x460 - well past the agent's
`SM_CXMIN x SM_CYMIN` size filter, and with no `WS_EX_TOPMOST`, so the pre-existing
banner rule does not catch them).

| agent | `SendWindowMap` for chromerepro windows |
|---|---|
| shipped QWT 4.2.2 (`gui-agent.exe.orig`, 80968 B) | **5** — `0xc017c` main + `0x50062` `0x4012e` `0x7015e` `0x1400f6` |
| with the 2A-chrome fix (87040 B) | **1** — `0x9015e`, which the inventory confirms is `main` |

So all four strips are rejected and the main window is kept: a compound window now appears
in dom0 as one bordered window instead of five fragments.

## Method note: counting screenshots was the WRONG metric

The original acceptance criterion was "count PNGs in `tools/qtest shot`". That is invalid:
`local.WinScreenshot` uses `import -window <id>`, which silently fails on layered/transparent
windows, so the BEFORE case produced **1 PNG while 5 windows were mapped** — it would have
reported a false PASS before the fix was even installed. `SendWindowMap` in the agent log is
the correct metric; it is exactly what the agent presents to dom0. Corrected in
`tools/chromerepro/README.md`.

## Still unverified against real Office

chromerepro's strips are deliberately oversized (>= `SM_CXMIN x SM_CYMIN`, ~136x39) because
`ShouldAcceptWindow` has always dropped anything smaller — a realistic 8 px Office shadow
would be killed by the size filter and prove nothing. It therefore remains **UNVERIFIED**
whether real Office strips clear that threshold, i.e. whether the bug reproduces with real
Office at all and whether this fix is what resolves it. Confirm with a `dump-windows` capture
in the user's real Office qube before claiming coverage of real Office (CLAUDE.md says
real-Office validation happens there, and to ask first).
