# jobpid-lib.sh - A JOB RECORDS ITS OWN PID. A WATCHER NEVER GUESSES ONE.
#
# WHY THIS EXISTS, measured three times in twelve hours on 2026-10-20/21:
#
#   1. Three capture loops launched as `nohup script &` survived every stop, because `$!` after that
#      is the WRAPPER SHELL, not the child. Every "stopped it" killed the wrapper. They ran for
#      hours beside a campaign.
#   2. A watcher built from a /proc scan - `for p in /proc/[0-9]*; case $(cmdline) in *script.sh*)` -
#      returns the WRAPPER TOO, because the wrapper's command line contains the script's name. On
#      2026-10-21 that made a LIVE release-acceptance campaign read as dead: the wrapper exited with
#      the tool call, the waiter fired, and the guest was shut down mid-install by hand.
#   3. pgrep -f matches the matcher's own command line, which is why pkill is prohibited outright.
#
# There were already three written rules saying "use the real pid". Rules did not stop any of the
# three. The mechanism is: the job writes the pid of the process that IS the job - $$ inside itself,
# which cannot be a wrapper - and a watcher reads that file and nothing else.
#
# USE, in the job:
#     source mgmt/harness/jobpid-lib.sh
#     job_claim acceptance            # writes $$ + argv + start time; removes it on exit
#
# USE, in a watcher:
#     job_alive acceptance            # 0 = the recorded pid is alive AND is still that job
#     job_wait  acceptance [poll_s]   # block until it is not
#     job_pid   acceptance            # print the recorded pid
#
# job_alive is deliberately NOT just `kill -0`: a pid is recycled within hours on this qube, and a
# recycled pid answers kill -0 happily. It checks that /proc/<pid> still carries the ARGV the job
# recorded, so a recycled pid reads as dead rather than as the job.
JOBPID_DIR="${JOBPID_DIR:-${TMPDIR:-/tmp}/qwt-jobpid}"

_jp_file(){ printf '%s/%s' "$JOBPID_DIR" "$(printf '%s' "${1:?job name}" | tr -c 'A-Za-z0-9._-' '_')"; }
_jp_say(){ echo "jobpid: $*" >&2; }

# The argv of a pid, NUL-separated, as a single comparable string.
_jp_argv(){ tr '\0' ' ' < "/proc/${1:?}/cmdline" 2>/dev/null; }

job_claim(){ # <name> - record THIS process as the job. Must be called by the job itself.
    local name="${1:?job_claim <name>}" f
    f=$(_jp_file "$name")
    mkdir -p "$JOBPID_DIR" || { _jp_say "[ERROR] cannot create $JOBPID_DIR"; return 1; }
    # $$ IS THE POINT. Inside the job, $$ is the job - it cannot be a wrapper, which is the entire
    # defect this library removes. Never accept a pid as an argument here: a caller that can pass a
    # pid can pass the wrong one, which is how this went wrong three times.
    {
        printf 'pid=%s\n' "$$"
        printf 'argv=%s\n' "$(_jp_argv $$)"
        printf 'started=%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'host=%s\n' "$(hostname)"
    } > "$f" || { _jp_say "[ERROR] cannot write $f"; return 1; }
    _jp_say "claimed $name as pid $$ ($f)"
    # Remove the claim when the job ends, however it ends. A stale claim that reads ALIVE is the
    # failure mode that matters, and the argv check below is the backstop when a trap cannot run.
    trap 'rm -f "'"$f"'" 2>/dev/null' EXIT
}

job_pid(){ # <name> -> the recorded pid, empty if none
    local f; f=$(_jp_file "${1:?job_pid <name>}")
    [ -r "$f" ] || return 1
    sed -n 's/^pid=\([0-9]\{1,\}\).*/\1/p' "$f" | head -1
}

job_alive(){ # <name> - 0 only if the RECORDED pid is alive and still carries the recorded argv
    local name="${1:?job_alive <name>}" f pid want have
    f=$(_jp_file "$name")
    [ -r "$f" ] || return 1
    pid=$(sed -n 's/^pid=\([0-9]\{1,\}\).*/\1/p' "$f" | head -1)
    [ -n "$pid" ] || return 1
    [ -r "/proc/$pid/cmdline" ] || return 1
    # A RECYCLED PID IS NOT THE JOB. Measured convention from never-anchor-freshness-on-a-guest-clock:
    # identity comes from what the process IS, never from the fact that something answers.
    want=$(sed -n 's/^argv=//p' "$f" | head -1)
    have=$(_jp_argv "$pid")
    [ -n "$want" ] || return 0            # an old claim with no argv: fall back to liveness alone
    [ "$want" = "$have" ]
}

job_wait(){ # <name> [poll_s] - block while job_alive; 0 when it has ended, 2 if never claimed
    local name="${1:?job_wait <name>}" poll="${2:-60}"
    job_pid "$name" >/dev/null || { _jp_say "[ERROR] $name was never claimed - refusing to report it ended"; return 2; }
    while job_alive "$name"; do sleep "$poll"; done
    return 0
}
