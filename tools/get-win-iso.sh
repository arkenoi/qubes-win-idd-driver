#!/bin/bash
# Resolve the official Microsoft download link(s) for the current consumer Windows ISO
# (multi-edition, retail/non-eval) headlessly via the software-download-connector API.
#
# Usage: get-win-iso.sh [LANGUAGE] [10|11]          (defaults: English, 10)
#   LANGUAGE matches the connector's "Language" or "LocalizedLanguage" field, e.g. English,
#   "English International", German, "Chinese (Simplified)".
# Prints "<Name><TAB><Uri>" for every architecture Microsoft offers. Links are valid ~24 h.
#
# STATUS (2026-09-05): WORKS headlessly. Notes dated 2026-08-01 and 2026-08-15 in this header
# used to conclude that the final connector call is refused for any non-browser session and
# that fetching an ISO is a human step; both predate finding the missing piece. Since Fido
# commit ea425ffbec (2026-02) a session must also complete the ov-df.microsoft.com challenge
# (mdt.js hands out a token "w" and server ticks "rticks"; both are echoed back with the
# client time). Without that step GetProductDownloadLinksBySku answers
# {"Key":"ErrorSettings.SentinelReject"} - to curl, and to headless Chromium driving the page,
# whose language dropdown never populates so the page's own script never runs it either.
# Same flow as ~/mido.sh (patched ElliotKillick/Mido) and dockur/windows src/mido.sh;
# dom0/01-fetch-win-iso.sh embeds it too. Still true from the 2026-08-15 retest: the old
# contentinclude/html API is retired (404) and the locale-less page URL geo-redirects (302),
# hence the /en-us/ URL and --location on the page fetch below.
# Microsoft bans an IP for ~24 h after a few link requests in quick succession - don't loop it.
set -euo pipefail
LANG_NAME="${1:-English}"
WINVER="${2:-10}"
case "$WINVER" in 10|11) ;; *) echo "usage: $0 [LANGUAGE] [10|11]" >&2; exit 2;; esac

UA="Mozilla/5.0 (X11; Linux x86_64; rv:100.0) Gecko/20100101 Firefox/100.0"
PAGE="https://www.microsoft.com/en-us/software-download/windows${WINVER}"
[ "$WINVER" = 10 ] && PAGE+="ISO"
API="https://www.microsoft.com/software-download-connector/api"
PROFILE="606624d44113"                               # constant in the page's script (Fido uses the same)
INSTANCE="560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175"     # ov-df instanceId/CustomerId, likewise constant
SID=$(cat /proc/sys/kernel/random/uuid)

req() { curl -fsS -A "$UA" -H "Accept:" --proto =https --tlsv1.2 --http1.1 --max-filesize 2M "$@"; }

# 1. product edition id of the current release (first <option> of the page's edition <select>)
PEID=$(req -L --max-redirs 3 "$PAGE" | grep -Eo '<option value="[0-9]+">Windows' | head -n1 | tr -cd '0-9')
[ -n "$PEID" ] || { echo "no product edition id found on $PAGE" >&2; exit 1; }

# 2. permit the session id
req -o /dev/null "https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=$SID"

# 3. ov-df challenge: fetch token + server ticks, echo them back with the client time (ms since epoch)
OV=$(req "https://ov-df.microsoft.com/mdt.js?instanceId=$INSTANCE&PageId=si&session_id=$SID")
W=$(grep -o '[?&]w=[A-Fa-f0-9]*' <<<"$OV" | head -n1 | cut -d= -f2)
RT=$(grep -o 'rticks="+[0-9]*' <<<"$OV" | head -n1 | tr -cd '0-9')
[ -n "$W" ] && [ -n "$RT" ] || { echo "ov-df challenge data missing: ${OV:0:200}" >&2; exit 1; }
req -o /dev/null "https://ov-df.microsoft.com/?session_id=$SID&CustomerId=$INSTANCE&PageId=si&w=$W&mdt=$(date +%s%3N)&rticks=$RT"

# 4. language -> SKU id
SKU=$(req -e "$PAGE" "$API/getskuinformationbyproductedition?profile=$PROFILE&ProductEditionId=$PEID&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=$SID" \
  | python3 -c '
import json, sys
want = sys.argv[1]
d = json.load(sys.stdin)
errs = d.get("Errors") or (d.get("ValidationContainer") or {}).get("Errors") or []
if errs:
    sys.exit("SKU request refused: " + "; ".join(e.get("Value", "?") for e in errs))
print(next((s["Id"] for s in d.get("Skus", []) if want in (s.get("Language"), s.get("LocalizedLanguage"))), ""))' "$LANG_NAME")
[ -n "$SKU" ] || { echo "no SKU for language '$LANG_NAME' (product edition $PEID)" >&2; exit 1; }

# 5. download links - the call Sentinel guards
req -e "$PAGE" "$API/GetProductDownloadLinksBySku?profile=$PROFILE&productEditionId=undefined&SKU=$SKU&friendlyFileName=undefined&Locale=en-US&sessionID=$SID" \
  | python3 -c '
import json, sys
d = json.load(sys.stdin)
errs = d.get("Errors") or (d.get("ValidationContainer") or {}).get("Errors") or []
if errs:
    sys.exit("link request refused: " + "; ".join(e.get("Value", "?") for e in errs))
opts = d.get("ProductDownloadOptions") or []
if not opts:
    sys.exit("no download options in response: " + json.dumps(d)[:300])
for o in opts:
    print(o.get("Name", ""), o.get("Uri", ""), sep="\t")'
