# Locale testing: what is proven, what needs a real foreign-language guest

Our only test guest is **English**. A real user (GWeck) runs a **German** edition. That gap already
hid one serious bug — on a German guest, every progress line the updater sent to dom0 was
unparseable — so this file records exactly what has been proven on the English guest, and what can
only be surfaced by someone running Windows in another language.

Read the first section before reporting anything: several plausible-sounding problems have been
measured NOT to exist, and re-reporting them costs everyone time.

## Already proven SAFE — do not re-litigate

Measured on 2026-08-14 by forcing `CurrentCulture` in-process across en-US, de-DE, th-TH (Buddhist
era), ar-SA (UmAlQura/Hijri), ja-JP, zh-CN, tr-TR (dotless i) and he-IL
(`guest/wu-locale-primitives.ps1`, `guest/wu-sortable-check.ps1`):

| Thing | Verdict |
|---|---|
| `ToString('s')` / `ToString('o')` | Calendar-invariant. Identical in all 8 cultures. |
| Status-file timestamp round trip | Safe in all 9 write-culture x read-culture combinations, which matters because the agent writes it as SYSTEM and the handler reads it as the user. |
| `[datetime]::TryParse(<ISO>)` | Parses correctly even under Hijri/Buddhist defaults. |
| `-match` / `-like` / `-eq`, case-insensitive | **Invariant-culture, NOT ordinal.** The Turkish dotless-i trap does not reach them - `'i' -eq 'I'` and `'XENIFACE' -match 'xeniface'` hold in tr-TR exactly as in en-US - because invariant casing is used rather than the thread culture. Being linguistic rather than ordinal has one consequence: zero-width marks carry no weight, so `'Update' -eq "Update$LRM"` is True while an ordinal comparison is False. |
| `.ToLower()` / `.ToUpper()` | **Culture-sensitive - do NOT use to normalise identifiers.** `'XENIFACE'.ToLower()` returns a dotless U+0131 under tr-TR. Use `ToLowerInvariant()`. This broke the Xen PV driver check in `health-check.ps1`. |
| `[double]"75.5"`, `[int]"42"` | Invariant. PowerShell casts do not use the culture. |
| `ConvertTo-Json` numbers | Emits `75.5`, never `75,5`. |
| Catalog package selection | Resolves to the **identical .msu** under en-US/de-DE/fr-FR/ja-JP, including when the catalog answers in German. Decided on the filename, not the title. |
| Start Menu / Programs paths | Not localized since Vista. |
| CBS `~xx-XX~` package tags | Identifiers, not prose. |

Also measured: the Update Catalog's response language is **arbitrary and non-deterministic** - the
same request has returned German, English and Italian at different times, and `fr-FR` once returned
Italian. If you see a foreign-language title in the log, that is expected and harmless; what
matters is the file that was chosen.

## What needs a real foreign-language guest

These are the classes an English guest cannot honestly settle. If you run Windows in another
language, these are worth ten minutes each.

### 1. Any locale — the update GUI progress bar

The highest-value check, because this is the class that already broke.

* Run an update from the Qube Manager and **watch the progress bar**, not just the outcome.
* PASS = the bar advances 0 -> 100 and update messages appear alongside it.
* FAIL = the update completes correctly but the bar never moves, and/or progress values show up as
  text messages instead.

That failure means a number reached dom0 in a locale format (`75,0`). Capture
`C:\ProgramData\Qubes\update-status.json` and the dom0-side output.

### 2. CJK guests (ja-JP, zh-CN, zh-TW, ko-KR) — encodings and code pages

The console OEM code page is 932/936/949/950 rather than 437/1252.

* Does the update run at all, or does it fail early? Native tool output (`reg`, `schtasks`, `DISM`)
  is parsed in places.
* Is `C:\ProgramData\Qubes\wu\agent.log` readable, or full of replacement characters?
* Does a user profile path or computer name containing non-ASCII characters break the workdir
  (`C:\ProgramData\Qubes\wu`) or the qrexec transport?

Known rule from our own scar: files under `guest/` must stay ASCII - a CJK literal was mangled to
`?a??a?` in transit and broke the parse. Non-ASCII arriving as *data* (an update title, a path) is
the untested part.

### 3. RTL guests (ar-SA, he-IL) — bidi marks and the Hijri calendar

* Update **titles** in Arabic/Hebrew carry invisible bidi marks (U+200E/U+200F). Those titles are
  sent to dom0 as messages and used as hash keys for de-duplication. Watch for duplicated or
  garbled messages in the update output.
* ar-SA defaults to the **Hijri** calendar. The shipped path only formats dates as `'s'`, `'o'` or
  `'HH:mm:ss'`, all proven invariant - but the dev harnesses (`drag-measure.ps1`,
  `wu-recon-extra.ps1`, `wu-relay-tail.ps1`) use custom `yyyy` patterns and WILL print Hijri years.
  That is cosmetic in a diagnostic, but do not be alarmed by a log dated 1448.

### 4. Thai (th-TH) — Buddhist era

Same as above: `ToString('yyyy-MM-dd')` yields **2569**-08-14. Shipped path is clean; diagnostics
are not. Report it only if a Buddhist year appears somewhere that a *program* reads.

### 5. Turkish (tr-TR) — decimal comma and dotless i

Turkish is the one locale that hits BOTH classes at once: it uses a decimal comma (so it exercises
the progress-bar bug class) and the dotless-i casing rule.

The comparison OPERATORS are invariant-culture and were measured unaffected. The casing METHODS are
not: `.ToLower()` on an identifier yields a dotless U+0131, which already broke the Xen PV driver
check in `health-check.ps1` (fixed). If you run Turkish, the useful check is `health-check.ps1` -
it should report the XENBUS/XENIFACE/XENVIF/XENNET drivers present, not missing. Beware that the
console renders the dotted and dotless i identically; compare code points, not glyphs.

## How to capture evidence

Everything below is read-only and safe to run on a live qube.

```powershell
# The locale hazard map, from YOUR guest - this is the single most useful artifact
powershell -ExecutionPolicy Bypass -File guest\wu-locale-primitives.ps1

# Catalog resolution: does your guest pick the same package we do?
powershell -ExecutionPolicy Bypass -File guest\wu-locale-invariant.ps1 -Kb <KB of an offered update>
```

Then attach:

* `C:\ProgramData\Qubes\wu\agent.log` — what the agent decided, with its `catalog pick:` line
* `C:\ProgramData\Qubes\update-status.json` — the phase/progress the handler was reading
* the dom0-side output of the update (the progress bar behaviour is the point)

## Reporting

State the **UI language**, the **system locale** (they can differ), and `Get-Culture` /
`Get-WinSystemLocale`. A finding is only actionable with the value that was produced - "it looked
wrong" cannot be acted on, `'75,0'` can.
