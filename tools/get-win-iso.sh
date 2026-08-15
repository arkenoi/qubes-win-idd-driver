#!/bin/bash
# Fetch the official Windows 10 22H2 (multi-edition, retail/non-eval) ISO link from
# Microsoft's software-download connector API.
#
# STATUS (measured 2026-08-01, on a residential exit): steps 1-3 work headlessly - the
# SKU catalogue comes back fine (English = SKU 16067). The final link call is refused
# with {"Key":"ErrorSettings.SentinelReject"}: Microsoft's Sentinel rejects the SESSION,
# not the IP, because a headless client never executes the vlscppe fingerprint
# JavaScript. quickget and Fido fail the same way for the same reason.
#
# RETESTED 2026-08-15 for Windows 11 25H2, and the "use a real browser engine" idea above
# was TRIED and does not work either:
#   * the contentinclude/html controls API that mido.sh and Fido use now returns 404 - it is
#     retired, so those tools are broken for this page regardless of session handling;
#   * https://www.microsoft.com/software-download/windows11 GEO-REDIRECTS (302) to the exit
#     IP's locale, and mido does not follow redirects, so it never finds a product edition id;
#   * the JSON connector's getskuinformationbyproductedition WORKS headlessly and reports the
#     current media as "Windows 11 25H2__V2" (product edition id 3321);
#   * GetProductDownloadLinksBySku answers SentinelReject even from headless Chromium driving
#     the real page, and even after registering that same session id with vlscppe from inside
#     the page. Driving the page's own UI gets as far as clicking "Download Now"; the language
#     dropdown never populates headless, so the flow dead-ends before any link.
# CONCLUSION: getting an ISO link is a human step (open the page, copy the link, valid ~24h).
# The alternatives that need no link at all are UUP dump (builds official media from Microsoft
# packages) and, for 25H2 specifically, the ENABLEMENT PACKAGE over an existing 24H2 guest -
# 25H2 is 26200 on top of 24H2's 26100, and this project already drives Windows Update.
set -uo pipefail
LANG_NAME="${1:-English}"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"
PAGE="https://www.microsoft.com/en-us/software-download/windows10ISO"
SID=$(cat /proc/sys/kernel/random/uuid)
JAR=$(mktemp)
curl -s -c "$JAR" -A "$UA" -o /dev/null "$PAGE"
curl -s -b "$JAR" -A "$UA" -o /dev/null "https://vlscppe.microsoft.com/fp/tags?org_id=y6jn8c31&session_id=$SID"
API="https://www.microsoft.com/software-download-connector/api"
sleep 2; SKUS=$(curl -s -b "$JAR" -A "$UA" -H "Referer: $PAGE" \
  "$API/getskuinformationbyproductedition?profile=606624d44113&ProductEditionId=2618&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=$SID")
SKU=$(printf '%s' "$SKUS" | python3 -c "
import json,sys
want=sys.argv[1]
d=json.load(sys.stdin)
print(next((s['Id'] for s in d['Skus'] if want in (s['Language'], s.get('LocalizedLanguage'))), ''))" "$LANG_NAME")
[ -n "$SKU" ] || { echo 'no SKU for that language' >&2; exit 1; }
curl -s -b "$JAR" -A "$UA" -H "Referer: $PAGE" \
  "$API/GetProductDownloadLinksBySku?profile=606624d44113&productEditionId=undefined&SKU=$SKU&friendlyFileName=undefined&Locale=en-US&sessionID=$SID" \
  | python3 -c "
import json,sys
raw=sys.stdin.read()
try: d=json.loads(raw)
except Exception: print('unexpected response:', raw[:300], file=sys.stderr); sys.exit(1)
errs=(d.get('ValidationContainer') or {}).get('Errors') or []
if errs: print('API errors:', errs, file=sys.stderr)
for o in d.get('ProductDownloadOptions') or []:
    print(o.get('Name'), o.get('Uri'))"
rm -f "$JAR"
