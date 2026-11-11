#!/bin/bash
# build-tag.sh - THE IDENTITY OF WHAT IS ACCEPTED: an annotated tag `build-<version>.<run number>` on the
# head commit of ONE successful CLEAN release-package run. Created LOCALLY. Never pushed.
#
# Owner, 2026-11-11: «we are not accepting "head", we accept a precise build»; «i asked you to use
# fucking tags, you made tags and now you do not use it!». HEAD is the harness checkout and moves with
# every documentation or harness commit; the package is bytes built from one commit by one run, and
# the tag names exactly that. docs/ADR-acceptance.md section 7 is the contract. 126 such tags were
# written retrospectively on 2026-11-10 (e.g. build-4.3.40.1257 -> 01e6d48a47b3); this tool writes the
# next ones the same way, before any suite runs against the build.
#
#   tools/build-tag.sh create  <release-package-run-id>   verify the run, tag it locally (idempotent), print the tag
#   tools/build-tag.sh resolve <release-package-run-id>   print the EXISTING local tag whose annotation names the run (offline)
#   tools/build-tag.sh run     <build-tag>                print the release-package run id the tag's annotation names (offline)
#   tools/build-tag.sh fi-flag <run-id>                   print the QGA_FAULT_INJECTION value the run's own build log states (0 or 1)
#
# `create` VERIFIES before it tags and REFUSES (exit 1) on any of: not the release-package workflow; not
# completed/success; the run's own build log does not read exactly QGA_FAULT_INJECTION=0 (an injector
# package is never the build under acceptance - and the log is the ONLY proof: a dispatch input arrives
# as a string, the display titles are identical, and the shipped binary greps the same either way);
# the head sha is not in this repo or not an ancestor of origin/main; the agent gitlink at that head has
# no readable `version`. The tag is `build-<that version>.<run number>`. If it already exists it must
# point at that head sha and its annotation must name that run - else refuse: a build tag is never moved.
# `fi-flag` is the one implementation of the injection proof; mgmt/harness/campaign-full.sh reads the
# FI run through it instead of carrying a copy.
#
# NEVER PUSHES. A single-tag push fires pv-xencons.yml / pv-xenvif.yml / winenum; publishing is out of
# scope here and stays a deliberate act.
#
# Exit: 0 ok · 1 refused, or no such tag/run · 2 usage, or gh/git could not be read (no verdict, never a pass).
# No `grep -q` in a pipeline (pipefail turns a match into SIGPIPE): outputs are captured, then tested.
set -uo pipefail
cd "$(git rev-parse --show-toplevel)" || exit 2

die(){ echo "build-tag: $*" >&2; exit 1; }
usage(){
  sed -n 's/^#   \(tools\/build-tag.sh .*\)/  \1/p' "$0" >&2
  exit "${1:-2}"
}

fi_flag(){ # <run-id> -> prints 0 or 1; rc 1 when the log states none or both; rc 2 when gh could not read the log
  local log vals
  log=$(gh run view "$1" --log 2>/dev/null) || return 2
  [ -n "$log" ] || return 2
  vals=$(printf '%s' "$log" | grep -aoE 'QGA_FAULT_INJECTION=[01]' | sort -u)
  case "$vals" in
    QGA_FAULT_INJECTION=0) echo 0 ;;
    QGA_FAULT_INJECTION=1) echo 1 ;;
    *) return 1 ;;
  esac
}

run_row(){ # <run-id> -> one tab-separated row: workflow status conclusion headSha number event createdAt; rc 2 when gh could not read it
  local row
  row=$(gh run view "$1" --json workflowName,status,conclusion,headSha,number,event,createdAt \
          --jq '[.workflowName, .status, (.conclusion // ""), .headSha, (.number|tostring), .event, .createdAt] | join("\t")' 2>/dev/null) || return 2
  [ -n "$row" ] || return 2
  printf '%s\n' "$row"
}

tag_of_run(){ # <run-id> -> the one local build-* tag whose annotation names "release-package run <id> ("; rc 1 when none or several
  local id="$1" t hits=""
  for t in $(git tag -l 'build-*'); do
    case "$(git cat-file -p "refs/tags/$t" 2>/dev/null)" in
      *"release-package run $id ("*) hits="$hits $t" ;;
    esac
  done
  # shellcheck disable=SC2086  # hits is a word list
  set -- $hits
  [ $# -eq 1 ] || { [ $# -eq 0 ] || echo "build-tag: $# tags name run $id:$hits - refusing to pick one" >&2; return 1; }
  echo "$1"
}

run_of_tag(){ # <tag> -> the release-package run id the annotation names; rc 1 when the tag is not a build tag
  local msg id
  msg=$(git cat-file -p "refs/tags/$1" 2>/dev/null) || return 1
  id=$(printf '%s\n' "$msg" | sed -n 's/^release-package run \([0-9][0-9]*\) (.*/\1/p' | head -1)
  [ -n "$id" ] || return 1
  echo "$id"
}

create(){ # <run-id> -> verifies the run, creates build-<version>.<number> at its head (idempotent), prints the tag
  local id="$1" row wf st con sha num ev created flag frc gitlink ver tag have tmp err
  [[ "$id" =~ ^[0-9]+$ ]] || { echo "build-tag: the run id must be numeric, got '$id'" >&2; exit 2; }
  row=$(run_row "$id") || { echo "build-tag: gh could not read run $id - no verdict" >&2; exit 2; }
  IFS=$'\t' read -r wf st con sha num ev created <<< "$row"
  [ "$wf" = release-package ] || die "run $id is workflow '$wf', not release-package - only that workflow builds the package a build tag names"
  { [ "$st" = completed ] && [ "$con" = success ]; } || die "run $id is $st/${con:-no conclusion} - a build tag names a SUCCESSFUL run only"
  flag=$(fi_flag "$id"); frc=$?
  case "$frc:${flag:-}" in
    0:0) ;;
    0:1) die "run $id is a FAULT-INJECTION build (its log reads QGA_FAULT_INJECTION=1) - an injector package is never the build under acceptance; name the ordinary run" ;;
    2:*) echo "build-tag: gh could not read run $id's log - the injection flag is unproven, no verdict" >&2; exit 2 ;;
    *)   die "run $id's log does not state exactly one QGA_FAULT_INJECTION value - refusing to tag a build whose kind is unproven" ;;
  esac
  git cat-file -e "${sha}^{commit}" 2>/dev/null || die "the run's head $sha is not in this repo - git fetch origin, then retry"
  git merge-base --is-ancestor "$sha" origin/main 2>/dev/null \
    || die "the run's head ${sha:0:12} is not an ancestor of origin/main - a build tag names a commit on main (git fetch origin first if origin/main is stale)"
  gitlink=$(git ls-tree "$sha" agent 2>/dev/null | awk '$2=="commit"{print $3}')
  [ -n "$gitlink" ] || die "no agent gitlink at ${sha:0:12} - the version cannot be read"
  ver=$(git -C agent show "${gitlink}:version" 2>/dev/null | tr -d ' \t\r\n')
  [[ "$ver" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || die "the agent gitlink ${gitlink:0:12} at ${sha:0:12} has no readable MAJOR.MINOR.PATCH version (got '${ver:-nothing}') - fetch the agent submodule, then retry"
  tag="build-${ver}.${num}"
  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null 2>&1; then
    have=$(git rev-parse "refs/tags/${tag}^{commit}" 2>/dev/null)
    [ "$have" = "$sha" ] || die "tag $tag already exists and points at ${have:0:12}, not at the run's head ${sha:0:12} - refusing: a build tag is never moved"
    case "$(git cat-file -p "refs/tags/$tag" 2>/dev/null)" in
      *"release-package run $id ("*) echo "$tag"; return 0 ;;
      *) die "tag $tag already exists at ${sha:0:12} but its annotation does not name run $id - refusing" ;;
    esac
  fi
  tmp=$(mktemp "${TMPDIR:-/tmp}/build-tag-XXXXXX") || exit 2
  printf 'build %s.%s\n\nrelease-package run %s (run number %s, event %s)\n\nbuilt %s from %s\n\nagent %s, version %s\n\ntagged %s by tools/build-tag.sh (QGA_FAULT_INJECTION=0 read from the run'"'"'s log)\n' \
    "$ver" "$num" "$id" "$num" "$ev" "$created" "$sha" "$gitlink" "$ver" "$(date -u +%Y-%m-%dT%H:%M:%SZ)" > "$tmp"
  if err=$(git tag -a "$tag" -F "$tmp" "$sha" 2>&1); then
    rm -f "$tmp"; echo "$tag"
  else
    rm -f "$tmp"; die "git tag -a $tag $sha failed: $err"
  fi
}

case "${1:-}" in
  create)  [ $# -eq 2 ] || usage; create "$2" ;;
  resolve) [ $# -eq 2 ] || usage
           tag_of_run "$2" || die "no local build tag names release-package run $2 - the acceptance creates it first: tools/build-tag.sh create $2" ;;
  run)     [ $# -eq 2 ] || usage
           run_of_tag "$2" || die "'$2' is not a build tag whose annotation names a release-package run" ;;
  fi-flag) [ $# -eq 2 ] || usage
           v=$(fi_flag "$2"); rc=$?
           case "$rc" in
             0) echo "$v" ;;
             1) die "run $2's log does not state exactly one QGA_FAULT_INJECTION value" ;;
             *) echo "build-tag: gh could not read run $2's log - no verdict" >&2; exit 2 ;;
           esac ;;
  -h|--help) usage 0 ;;
  *) usage ;;
esac
