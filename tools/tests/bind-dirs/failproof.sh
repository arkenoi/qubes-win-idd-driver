#!/usr/bin/env bash
# Proves the bind-dirs test suite can FAIL: re-introduces one defect at a time into a scratch
# copy of the core and asserts that run.sh's suite goes red for each. A guard that has never
# been seen to fail is not evidence (CLAUDE.md, "No result counts until the instrument is
# validated"). Exit 1 if any mutation is NOT caught.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo="$(cd "$here/../../.." && pwd)"
core="$repo/core-agent/src/bind-dirs"
work="${TMPDIR:-/tmp}/bind-dirs-failproof.$$"
mkdir -p "$work/core"
trap 'rm -rf "$work"' EXIT

cp "$core/bind-dirs.h" "$work/core/"

# name | sed expression applied to bind-dirs.c | what it breaks
mutations=(
  'ancestor-check-removed|s/\*isReparse = 1;/*isReparse = 0;/|the reparse-ancestor refusal (C:\\Users after MoveUsers)'
  'protected-windows-removed|s/L"Windows",/L"WindowsNOPE",/|the C:\\Windows protected-subtree refusal'
  'seed-copy-cleanup-removed|s/fs->DeleteDirectory(fs->context, staging);\n            BdFail(out, L"seed-copy", status);/BdFail(out, L"seed-copy", status);/|removal of the partial staging copy after a failed seed'
  'rollback-removed|s/BD_STATUS rb = fs->Rename(fs->context, orig, ro);/BD_STATUS rb = BD_OK; (void)ro;/|the rename-back rollback after a failed bind'
  'target-match-always-true|s/if (st->reparseTag != BD_IO_REPARSE_TAG_MOUNT_POINT)\n        return 0;/return 1;/|the foreign-reparse-point refusal (any junction accepted as ours)'
  'bare-backslash-allowed|s/p->error = L"bare-backslash-quote-the-path";\n                return -1;/;/|the bare-backslash syntax error'
  'nested-allowed|s/BdFail(r, L"nested", BD_STATUS_FAIL);\n                BdFail(\&results\[j\], L"nested", BD_STATUS_FAIL);/;/|the nested-bind refusal'
  'source-missing-skipped|s/BdFail(out, L"source-missing", BD_STATUS_FAIL);\n            return;/out->result = L"ok"; out->reason = L"skipped"; return;/|the source-missing failure (Linux-style silent skip)'
)

caught=0
missed=0
for m in "${mutations[@]}"; do
    name="${m%%|*}"; rest="${m#*|}"; expr="${rest%%|*}"; what="${rest#*|}"
    # sed -z so multi-line patterns (\n) can be matched.
    sed -z "$expr" "$core/bind-dirs.c" > "$work/core/bind-dirs.c"
    if cmp -s "$core/bind-dirs.c" "$work/core/bind-dirs.c"; then
        echo "BROKEN FIXTURE: mutation '$name' did not change the source (pattern drifted) - fix the failproof, this mutation proves nothing"
        missed=$((missed + 1))
        continue
    fi
    if gcc -std=gnu99 -g -O1 -Wall -Wno-unused-parameter -Wno-unused-variable -I"$work/core" \
           "$work/core/bind-dirs.c" "$here/fake-fs.c" "$here/test-bind-dirs.c" -o "$work/t" 2>"$work/build.log" \
       && "$work/t" >"$work/run.log" 2>&1; then
        echo "MISSED: '$name' ($what) - the suite stayed GREEN with this defect"
        missed=$((missed + 1))
    else
        n=$(grep -c '^  FAIL' "$work/run.log" 2>/dev/null || true)
        echo "caught: '$name' -> $n failing check(s) ($what)"
        caught=$((caught + 1))
    fi
done

echo "--- $caught mutation(s) caught, $missed missed"
[ "$missed" -eq 0 ]
