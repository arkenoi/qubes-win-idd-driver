#!/bin/bash
# Reject any staged image that is the full dom0 desktop.
#
# Name-based rules are not enough: xaml-popup-bypass-dom0.png was 5120x1440 and looked like a
# per-window shot from its name. Dimension is the honest test - the guest screen is at most
# 3440 wide here, so anything wider is the host desktop with other qubes on it.
MAXW=3440
fail=0
while IFS= read -r f; do
    case "$f" in *.png)
        w=$(git show ":$f" 2>/dev/null | python3 -c "
import sys,struct
d=sys.stdin.buffer.read(33)
print(struct.unpack('>II', d[16:24])[0] if d[:8]==b'\x89PNG\r\n\x1a\n' else 0)" 2>/dev/null || echo 0)
        if [ "${w:-0}" -gt "$MAXW" ]; then
            echo "BLOCKED: $f is ${w}px wide - that is the dom0 desktop, not a guest window."
            fail=1
        fi ;;
    esac
    case "$f" in *fullshot*|*-full/screen.png)
        echo "BLOCKED: $f matches a full-desktop capture path."; fail=1 ;;
    esac
done < <(git diff --cached --name-only --diff-filter=AM)
[ "$fail" -eq 1 ] && echo "Commit refused. These leak other qubes' windows into a public repo." && exit 1
exit 0
