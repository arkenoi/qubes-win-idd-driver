#!/bin/bash
# Run IN DOM0. Downloads the current consumer Windows ISO inside a netvm-attached qube (dom0 stays
# offline). The ISO stays in that qube; attach it later with:
#   qvm-start win-idd-test --cdrom=<qube>:/home/user/win-iso/<iso-name>
#
# Usage: ./01-fetch-win-iso.sh <download-qube> [10|11]
#        ./01-fetch-win-iso.sh --local [10|11] [--print-link]   # run here (e.g. inside win-idd-mgmt);
#                                                                # --print-link only resolves the URL
#
# Link resolution is the Mido/Fido flow as of 2026-09 (same as tools/get-win-iso.sh): download page
# -> ProductEditionId, vlscppe session permit, ov-df.microsoft.com challenge, connector SKU table
# -> English SKU, connector link -> software.download.prss.microsoft.com URL (valid 24 h).
# quickget is no longer used: upstream lacks the ov-df step, so Microsoft's Sentinel rejects it.
# Needs curl + python3 in the downloading qube. Microsoft bans an IP for ~24 h after a few link
# requests in quick succession - don't loop this.
set -euo pipefail

# Everything below runs in the DOWNLOADING qube (shipped over qvm-run via `declare -f`).
fetch_win_iso() {
    set -euo pipefail
    local winver="${1:-10}"        # 10 = Win10 22H2 (preferred: best seamless behavior). Avoid Win11 25H2.
    local print_link="${2:-}"
    local ua="Mozilla/5.0 (X11; Linux x86_64; rv:100.0) Gecko/20100101 Firefox/100.0"
    local api="https://www.microsoft.com/software-download-connector/api"
    local profile="606624d44113"                            # constant in the page's script (Fido uses the same)
    local instance="560dc9f3-1aa5-4a2f-b63c-9e18f8d0e175"  # ov-df instanceId/CustomerId, likewise constant
    local page="https://www.microsoft.com/en-us/software-download/windows${winver}"
    [ "$winver" = 10 ] && page+="ISO"
    local sid peid ov w rt sku link file

    if [ -z "$print_link" ]; then
        mkdir -p ~/win-iso && cd ~/win-iso
        if ls Win*.iso windows*.iso > /dev/null 2>&1; then
            echo "ISO already present:"; ls -sh Win*.iso windows*.iso 2> /dev/null; return 0
        fi
    fi

    req() { curl -fsS -A "$ua" -H "Accept:" --proto =https --tlsv1.2 --http1.1 --max-filesize 2M "$@"; }
    sid=$(cat /proc/sys/kernel/random/uuid)

    # 1. product edition id of the current release (first <option> of the page's edition <select>)
    peid=$(req -L --max-redirs 3 "$page" | grep -Eo '<option value="[0-9]+">Windows' | head -n1 | tr -cd '0-9')
    [ -n "$peid" ] || { echo "no product edition id found on $page" >&2; return 1; }
    # 2. permit the session id
    req -o /dev/null "https://vlscppe.microsoft.com/tags?org_id=y6jn8c31&session_id=$sid"
    # 3. ov-df challenge: fetch token + server ticks, echo them back with the client time (ms since epoch)
    ov=$(req "https://ov-df.microsoft.com/mdt.js?instanceId=$instance&PageId=si&session_id=$sid")
    w=$(grep -o '[?&]w=[A-Fa-f0-9]*' <<< "$ov" | head -n1 | cut -d= -f2)
    rt=$(grep -o 'rticks="+[0-9]*' <<< "$ov" | head -n1 | tr -cd '0-9')
    [ -n "$w" ] && [ -n "$rt" ] || { echo "ov-df challenge data missing: ${ov:0:200}" >&2; return 1; }
    req -o /dev/null "https://ov-df.microsoft.com/?session_id=$sid&CustomerId=$instance&PageId=si&w=$w&mdt=$(date +%s%3N)&rticks=$rt"
    # 4. English (United States) SKU id
    sku=$(req -e "$page" "$api/getskuinformationbyproductedition?profile=$profile&ProductEditionId=$peid&SKU=undefined&friendlyFileName=undefined&Locale=en-US&sessionID=$sid" \
        | python3 -c '
import json, sys
d = json.load(sys.stdin)
errs = d.get("Errors") or (d.get("ValidationContainer") or {}).get("Errors") or []
if errs:
    sys.exit("SKU request refused: " + "; ".join(e.get("Value", "?") for e in errs))
print(next((s["Id"] for s in d.get("Skus", []) if "English" in (s.get("Language"), s.get("LocalizedLanguage"))), ""))')
    [ -n "$sku" ] || { echo "no English SKU for product edition $peid" >&2; return 1; }
    # 5. x64 download link - the call Sentinel guards
    link=$(req -e "$page" "$api/GetProductDownloadLinksBySku?profile=$profile&productEditionId=undefined&SKU=$sku&friendlyFileName=undefined&Locale=en-US&sessionID=$sid" \
        | python3 -c '
import json, sys
d = json.load(sys.stdin)
errs = d.get("Errors") or (d.get("ValidationContainer") or {}).get("Errors") or []
if errs:
    sys.exit("link request refused: " + "; ".join(e.get("Value", "?") for e in errs))
opts = [o["Uri"] for o in d.get("ProductDownloadOptions") or [] if o.get("DownloadType") == 1 or "x64" in o.get("Uri", "")]
if not opts:
    sys.exit("no x64 link in response: " + json.dumps(d)[:300])
print(opts[0])')

    if [ -n "$print_link" ]; then
        echo "$link"; return 0
    fi
    file=${link%%\?*}; file=${file##*/}
    echo "Downloading $file into ~/win-iso (link valid 24 h; re-run to resume a partial file)"
    curl -fL --progress-bar -C - --proto =https --tlsv1.2 -o "$file.part" "$link"
    mv "$file.part" "$file"
    echo "Downloaded:"; ls -sh "$file"
}

fetch_win_iso_fallback() {
    cat >&2 <<'FALLBACK'
Automated link resolution failed. Fallbacks:
  1. Open the download page in a browser in a networked qube, generate the link, curl it into ~/win-iso/
     Win10: https://www.microsoft.com/en-us/software-download/windows10ISO
     Win11: https://www.microsoft.com/en-us/software-download/windows11
  2. Fido (https://github.com/pbatard/Fido) in any Windows machine/qube -> retail ISO
  3. Windows 10 Enterprise LTSC 2021 Evaluation (90 days, fine for the driver test qube), ungated CDN blob:
     https://software-static.download.prss.microsoft.com/pr/download/19044.1288.211006-0501.21h2_release_svc_refresh_CLIENT_LTSC_EVAL_x64FRE_en-us.iso
Place the ISO in ~/win-iso/ of the downloading qube.
FALLBACK
}

usage() { sed -n '2,8p' "$0" >&2; exit 2; }

case "${1:-}" in
    -h|--help|"") usage ;;
    --local)
        WINVER="${2:-10}"; PRINT_LINK=""
        [ "${3:-}" = "--print-link" ] && PRINT_LINK=1
        case "$WINVER" in 10|11) ;; *) usage ;; esac
        fetch_win_iso "$WINVER" "$PRINT_LINK" || { fetch_win_iso_fallback; exit 1; }
        ;;
    *)
        DLQUBE="$1"; WINVER="${2:-10}"
        case "$WINVER" in 10|11) ;; *) usage ;; esac
        qvm-run --pass-io "$DLQUBE" "bash -s" <<EOF
$(declare -f fetch_win_iso fetch_win_iso_fallback)
fetch_win_iso "$WINVER" || { fetch_win_iso_fallback; exit 1; }
EOF
        echo
        echo "Attach at install time with:"
        echo "  qvm-start win-idd-test --cdrom=${DLQUBE}:/home/user/win-iso/<iso-name>"
        ;;
esac
