#!/usr/bin/env python3
"""The acceptance-protocol RUNNER. The protocol is data (protocol/steps/*.json); this file is
the only authority on scheduling, verdicts, and guest custody. The operator never chooses a
step, never composes a command, never interprets a rule: the runner prints exactly one next
action, and everything else it does itself.

WHY THIS EXISTS. docs/ACCEPTANCE-PROTOCOL.md is 1877 lines of prose rules, measured (2026-09-01)
at ~60% adherence by its own author, and judged by the owner unexecutable by a weaker model.
Prose asks the reader to remember; this asks the reader to obey a prompt. Every meta-rule that
could be moved into code is enforced here, in one place, so no step file and no operator can
express a violation:

  V1  PASS needs a fail-proof registry entry for that check -> else PASS-UNPROVEN (emit_verdict).
  V2  INVALID-* is never folded into FAIL (they are distinct verdict paths end to end).
  V3  Missing data is INVALID-INSTRUMENT, never FAIL, never a default (run_step; dry fixtures too).
  V4  A check that cannot fail does not load: every verdict-emitting step must name the defect it
      detects and the scenario in which it is SEEN to fail (load_steps refuses otherwise; selftest
      executes those scenarios and records the observed failure into the registry).
  G-0/G-0b  A FAIL or INVALID on a guest marks it OUT_OF_SERVICE; the runner then refuses every
      step touching that guest until a step declaring `restores` for it completes. Contamination
      is a state transition, not a judgement call.
  G-1  The campaign verdict is arithmetic: `verdicts` delegates to tools/campaign-verdict.sh.
  H3.6 One guest at a time: steps run strictly serially, and live mode takes the same
      per-guest lock file as mgmt/harness/vmlock.sh, so it excludes the existing harnesses too.
  H5   The ledger grammar is the five-column TSV campaign-verdict.sh already parses.

DRY-RUN. `--mode dry --scenario <dir>` never executes a step command. It prints
`INTEND[dry]: <command>` and takes the result from the scenario's fixtures, so a whole campaign
can be walked with zero guest contact. Judgement evidence comes from fixture files. A scenario
that lacks a result for a reached step is missing data -> INVALID-INSTRUMENT (V3), by design.

Owner constraint (2026-09-01): every test must be decisive and falsifiable against a probable or
known defect. Mechanised at load time: `defect` and `falsified_by` are mandatory on any step that
emits a verdict or gates the campaign, and protocol/selftest.sh proves each such step actually
goes red in its named scenario. A step whose failure has never been observed cannot plain-PASS.
"""
from __future__ import annotations
import argparse, fcntl, json, os, re, shlex, subprocess, sys, time
from pathlib import Path

PROTO = Path(__file__).resolve().parent
ROOT = PROTO.parent
SCEN_ROOT = PROTO / "scenarios"
FAILPROOFS = PROTO / "failproofs.json"

MECH_KINDS = {"gate", "probe", "action", "wait"}
KINDS = MECH_KINDS | {"judgement"}
FAIL_ACTIONS = {"HALT_CAMPAIGN", "HALT_PART", "CONTINUE", "RETRY"}
# Steps that gate or grade must be falsifiable; plain actions (mkdir, tar) need not be.
FALSIFIABLE_KINDS = {"gate", "probe", "judgement", "wait"}
GREEN, RED = "GREEN", "RED"
LEDGER_HEADER = "cell\tcheck\tverdict\tdetail\tevidence"


def die(msg: str, code: int = 2) -> "NoReturn":
    print(f"RUNNER-ERROR: {msg}", file=sys.stderr)
    sys.exit(code)


# --------------------------------------------------------------------------- loading
def load_steps(paths: list[Path], check_scenarios: bool = True) -> list[dict]:
    """Load and VALIDATE step files. Any violation refuses the whole load and lists every
    offender - a protocol that can be half-loaded can be half-followed."""
    steps: list[dict] = []
    errors: list[str] = []
    seen: set[str] = set()
    for p in paths:
        try:
            doc = json.loads(p.read_text())
        except Exception as e:
            errors.append(f"{p}: unparseable JSON ({e})")
            continue
        part = doc.get("part") or p.stem
        for s in doc.get("steps", []):
            sid = s.get("id", "<missing id>")
            where = f"{p.name}:{sid}"
            s["part"] = s.get("part", part)
            if sid in seen:
                errors.append(f"{where}: duplicate id")
            seen.add(sid)
            kind = s.get("kind")
            if kind not in KINDS:
                errors.append(f"{where}: kind must be one of {sorted(KINDS)}, got {kind!r}")
                continue
            if kind in MECH_KINDS:
                if not s.get("command"):
                    errors.append(f"{where}: mechanical step needs a command")
                exp = s.get("expect") or {}
                if kind != "action" and not (("exit" in exp) or exp.get("stdout_re")):
                    errors.append(f"{where}: {kind} needs expect.exit and/or expect.stdout_re")
            else:  # judgement
                j = s.get("judgement") or {}
                answers = j.get("answers") or {}
                jmap = j.get("map") or {}
                if len(answers) < 2:
                    errors.append(f"{where}: judgement needs >=2 closed answers")
                missing = [a for a in answers if a not in jmap and "*" not in jmap]
                if missing:
                    errors.append(f"{where}: judgement.map does not cover {missing}")
                bad = [v for v in jmap.values() if v not in (GREEN, RED, "INVALID")]
                if bad:
                    errors.append(f"{where}: judgement.map values must be GREEN/RED/INVALID, got {bad}")
                if not j.get("evidence"):
                    errors.append(f"{where}: judgement needs evidence file(s) to read")
            of = s.get("on_fail") or {}
            act = of.get("action", "HALT_PART")
            if act not in FAIL_ACTIONS:
                errors.append(f"{where}: on_fail.action must be one of {sorted(FAIL_ACTIONS)}")
            # THE FALSIFIABILITY GATE (owner, 2026-09-01). Decisive over probable: a step that can
            # judge the product must name the defect it detects and the scenario where it is seen
            # to detect it. No declared failure route -> the step does not load.
            if kind in FALSIFIABLE_KINDS or s.get("check"):
                if not (s.get("defect") or "").strip():
                    errors.append(f"{where}: no `defect` - a check must name the defect it exists to catch")
                fb = (s.get("falsified_by") or "").strip()
                if not fb:
                    errors.append(f"{where}: no `falsified_by` - a check never seen to fail is not evidence")
                elif check_scenarios and not (SCEN_ROOT / fb).is_dir():
                    errors.append(f"{where}: falsified_by names missing scenario {fb!r}")
            for r in s.get("requires", []):
                if r not in seen:
                    errors.append(f"{where}: requires {r!r} which is not defined earlier (order is execution order)")
            steps.append(s)
    if errors:
        print("LOAD REFUSED - the protocol data violates its own contract:", file=sys.stderr)
        for e in errors:
            print(f"  {e}", file=sys.stderr)
        sys.exit(2)
    if not steps:
        die("no steps loaded")
    return steps


def load_failproofs() -> dict:
    if FAILPROOFS.exists():
        return json.loads(FAILPROOFS.read_text())
    return {}


# --------------------------------------------------------------------------- state
class Campaign:
    def __init__(self, cid: str):
        self.cid = cid
        self.dir = PROTO / "state" / cid
        self.state_p = self.dir / "state.json"
        self.trace_p = self.dir / "trace.jsonl"
        self.ledger_p = self.dir / "verdicts.tsv"
        self.st: dict = {}

    def create(self, steps_files: list[str], mode: str, scenario: str | None, vars: dict):
        if self.state_p.exists():
            die(f"campaign {self.cid} already exists at {self.dir}; choose a new --campaign id "
                f"(state is evidence and is never overwritten)")
        self.dir.mkdir(parents=True)
        self.st = {"campaign": self.cid, "mode": mode, "scenario": scenario,
                   "steps_files": steps_files, "vars": vars, "steps": {},
                   "guests": {}, "halted": None, "created_utc": utc()}
        self.ledger_p.write_text(LEDGER_HEADER + "\n")
        self.save()

    def load(self):
        if not self.state_p.exists():
            die(f"no campaign {self.cid!r} under protocol/state/ - `start` it first")
        self.st = json.loads(self.state_p.read_text())

    def save(self):
        tmp = self.state_p.with_suffix(".tmp")
        tmp.write_text(json.dumps(self.st, indent=1, sort_keys=True))
        tmp.replace(self.state_p)

    def trace(self, event: str, **kw):
        rec = {"t": utc(), "event": event, **kw}
        with self.trace_p.open("a") as f:
            f.write(json.dumps(rec) + "\n")

    def ledger(self, cell: str, check: str, verdict: str, detail: str, evidence: str):
        with self.ledger_p.open("a") as f:
            f.write("\t".join(x.replace("\t", " ").replace("\n", " ")
                              for x in (cell, check, verdict, detail, evidence)) + "\n")


def utc() -> str:
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


# --------------------------------------------------------------------------- verdicts
def emit_verdict(c: Campaign, step: dict, verdict: str, detail: str, evidence: str,
                 failproofs: dict):
    check = step.get("check") or step["id"]
    if verdict == "PASS":
        fp = failproofs.get(check)
        live_ok = fp and fp.get("grade") == "live"
        dry_ok = fp and c.st["mode"] == "dry"          # a dry proof upgrades only dry runs
        if not (live_ok or dry_ok):
            # V1: the writer refuses plain PASS - it is not a convention.
            verdict = "PASS-UNPROVEN"
            detail = (detail + " | no fail-proof on record for this check "
                      "(protocol/failproofs.json)").strip(" |")
    c.ledger(step["part"], check, verdict, detail, evidence)
    c.trace("verdict", step=step["id"], check=check, verdict=verdict, detail=detail)


# --------------------------------------------------------------------------- execution
def subst(template: str, vars: dict) -> str:
    def rep(m):
        k = m.group(1)
        if k not in vars:
            raise KeyError(k)
        return str(vars[k])
    return re.sub(r"\{([A-Z0-9_]+)\}", rep, template)


def guest_of(step: dict, vars: dict) -> str | None:
    g = step.get("guest")
    if not g:
        return None
    return str(vars.get(g, g))     # `guest` is a var name if bound, else a literal qube name


def run_command(c: Campaign, step: dict, cmd: str) -> tuple[int | None, str]:
    """Returns (exit, stdout). In dry mode the command is NEVER executed."""
    if c.st["mode"] == "dry":
        print(f"  INTEND[dry]: {cmd}")
        scen = Path(c.st["scenario"])
        fixtures = json.loads((scen / "scenario.json").read_text())
        res = (fixtures.get("results") or {}).get(step["id"])
        if res is None:
            return None, ""        # missing data - the caller turns this into INVALID-INSTRUMENT
        return int(res.get("exit", 0)), res.get("stdout", "")
    timeout = int(step.get("timeout_s", 300))
    try:
        p = subprocess.run(["bash", "-c", cmd], cwd=ROOT, capture_output=True,
                           text=True, timeout=timeout)
        return p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired:
        return None, f"TIMEOUT after {timeout}s"


def expect_ok(step: dict, exit_code: int, out: str) -> tuple[bool, str]:
    exp = step.get("expect") or {}
    if "exit" in exp and exit_code != exp["exit"]:
        return False, f"exit {exit_code} != expected {exp['exit']}"
    if exp.get("stdout_re") and not re.search(exp["stdout_re"], out, re.M):
        return False, f"output did not match /{exp['stdout_re']}/"
    if exp.get("stdout_absent_re") and re.search(exp["stdout_absent_re"], out, re.M):
        return False, f"output matched forbidden /{exp['stdout_absent_re']}/"
    return True, "expected output present"


def capture_vars(c: Campaign, step: dict, out: str):
    for name, rx in (step.get("vars_out") or {}).items():
        m = re.search(rx, out, re.M)
        if m:
            c.st["vars"][name] = m.group(1)
            c.trace("var", name=name, value=m.group(1), step=step["id"])


def step_status(c: Campaign, sid: str) -> str:
    return (c.st["steps"].get(sid) or {}).get("status", "PENDING")


def mark(c: Campaign, step: dict, status: str, **kw):
    c.st["steps"][step["id"]] = {"status": status, "t": utc(), **kw}
    c.trace("step", step=step["id"], status=status, **kw)


def handle_red(c: Campaign, step: dict, why: str, out: str, failproofs: dict) -> str:
    """Apply on_fail + guest custody. Returns 'stop' | 'continue' | 'retry'."""
    of = step.get("on_fail") or {}
    kind = step["kind"]
    is_probe_silent = kind == "probe" and not out.strip()
    if is_probe_silent:
        # V3 / RIG-CONSTRAINTS 1.1: an empty probe answer is a broken instrument, NEVER a verdict
        # about the product, in either direction.
        verdict = "INVALID-INSTRUMENT"
        why = f"probe returned NOTHING - instrument invalid, not a product result ({why})"
    else:
        verdict = of.get("verdict") or ("FAIL" if step.get("check") else "INVALID-PRECONDITION")
    if step.get("check") or verdict.startswith(("FAIL", "INVALID")):
        emit_verdict(c, step, verdict, why, evidence=step.get("evidence", ""), failproofs=failproofs)
    g = guest_of(step, c.st["vars"])
    if g and verdict.startswith(("FAIL", "INVALID")):
        # G-0/G-0b, mechanised: the subject is now evidence. Everything on it is refused until a
        # step that declares `restores` for it completes. No plausibility argument can lift this.
        c.st["guests"][g] = {"status": "OUT_OF_SERVICE", "since": step["id"], "why": verdict}
        c.trace("guest_out_of_service", guest=g, step=step["id"])
    mark(c, step, RED, verdict=verdict, why=why)
    act = of.get("action", "HALT_PART")
    if act == "RETRY":
        tries = (c.st["steps"][step["id"]].get("tries") or 0)
        if tries < int(of.get("retries", 2)):
            c.st["steps"][step["id"]] = {"status": "PENDING", "tries": tries + 1}
            return "retry"
        act = of.get("exhausted", "HALT_PART")
    if act == "HALT_CAMPAIGN":
        c.st["halted"] = {"at": step["id"], "why": why, "verdict": verdict,
                          "msg": of.get("msg", "")}
        return "stop"
    if act == "HALT_PART":
        c.st.setdefault("halted_parts", []).append(step["part"])
        return "continue"
    return "continue"


def runnable(c: Campaign, step: dict) -> tuple[bool, str]:
    if step_status(c, step["id"]) != "PENDING":
        return False, "done"
    if c.st.get("halted"):
        return False, "campaign halted"
    if step["part"] in c.st.get("halted_parts", []):
        return False, f"part {step['part']} halted"
    for r in step.get("requires", []):
        if step_status(c, r) != GREEN:
            return False, f"requires {r} (status {step_status(c, r)})"
    g = guest_of(step, c.st["vars"])
    if g and c.st["guests"].get(g, {}).get("status") == "OUT_OF_SERVICE" and not step.get("restores"):
        return False, (f"guest {g} is OUT_OF_SERVICE since {c.st['guests'][g]['since']} "
                       f"({c.st['guests'][g]['why']}) - G-0b: rebuild before any further step")
    for v in step.get("vars_in", []):
        if v not in c.st["vars"]:
            return False, f"var {v} unbound"
    return True, ""


def advance(c: Campaign, steps: list[dict], failproofs: dict, auto_truth: bool = False) -> dict | None:
    """Run mechanical steps in order until a judgement needs an operator, nothing is runnable,
    or the campaign halts. Returns the waiting judgement step or None."""
    live_locks: dict[str, int] = {}
    progressed = True
    while progressed and not c.st.get("halted"):
        progressed = False
        for step in steps:
            ok, why = runnable(c, step)
            if not ok:
                if step_status(c, step["id"]) == "PENDING" and why.startswith("guest"):
                    if not (c.st["steps"].get(step["id"]) or {}).get("blocked_noted"):
                        c.ledger(step["part"], step.get("check") or step["id"],
                                 "BLOCKED", why, "")
                        c.st["steps"][step["id"]] = {"status": "BLOCKED", "why": why,
                                                     "blocked_noted": True}
                        c.trace("blocked", step=step["id"], why=why)
                        progressed = True
                continue
            if step["kind"] == "judgement":
                ans = (c.st["steps"].get(step["id"]) or {}).get("answer")
                if ans is None:
                    if auto_truth and c.st["mode"] == "dry" and os.environ.get("PROTOCOL_SELFTEST") == "1":
                        truth = json.loads((Path(c.st["scenario"]) / "truth.json").read_text()) \
                            .get("truth", {}).get(step["id"])
                        if truth is None:
                            mark(c, step, RED, verdict="INVALID-INSTRUMENT",
                                 why="selftest: no truth recorded for judgement")
                            continue
                        print(f"  [selftest auto-answer] {step['id']} := {truth}")
                        apply_answer(c, step, truth, failproofs)
                        progressed = True
                        continue
                    c.save()
                    return step
                continue    # answered judgements were applied in apply_answer
            # mechanical step
            g = guest_of(step, c.st["vars"])
            if g and c.st["mode"] == "live" and g not in live_locks:
                lf = os.path.join(os.environ.get("TMPDIR", "/tmp"), f"qwt-vmlock-{g}")
                fd = os.open(lf, os.O_WRONLY | os.O_CREAT | os.O_APPEND)
                try:
                    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
                except OSError:
                    die(f"REFUSING TO START on {g}: another harness holds the vm lock ({lf}). "
                        f"Two jobs on one guest fabricate verdicts. Wait, or kill the holder BY PID.")
                os.write(fd, f"pid={os.getpid()} cmd=protocol/run.py started={utc()}\n".encode())
                live_locks[g] = fd
            try:
                cmd = subst(step["command"], c.st["vars"])
            except KeyError as e:
                mark(c, step, RED, verdict="INVALID-PRECONDITION", why=f"unbound var {e}")
                progressed = True
                continue
            print(f"[{step['id']}] {step['title']}")
            code, out = run_command(c, step, cmd)
            (c.dir / "output").mkdir(exist_ok=True)
            (c.dir / "output" / f"{step['id']}.txt").write_text(
                f"$ {cmd}\nexit={code}\n{out}")
            if code is None and c.st["mode"] == "dry":
                # V3: the scenario recorded no result for a step that was reached. Missing data
                # FAILS - it is never approximated and never defaulted.
                r = handle_red(c, step, "scenario has no fixture for this step - missing data",
                               "", failproofs)
                progressed = True
                if r == "stop":
                    break
                continue
            ok2, why2 = expect_ok(step, code if code is not None else -1, out)
            if ok2:
                capture_vars(c, step, out)
                if step.get("check"):
                    emit_verdict(c, step, "PASS", why2, step.get("evidence", ""), failproofs)
                if step.get("restores"):
                    rg = str(c.st["vars"].get(step["restores"], step["restores"]))
                    if rg in c.st["guests"]:
                        c.st["guests"][rg] = {"status": "IN_SERVICE", "since": step["id"]}
                        c.trace("guest_restored", guest=rg, step=step["id"])
                mark(c, step, GREEN)
            else:
                r = handle_red(c, step, why2, out, failproofs)
                if r == "stop":
                    progressed = True
                    break
            progressed = True
            c.save()
    c.save()
    return None


def apply_answer(c: Campaign, step: dict, value: str, failproofs: dict):
    j = step["judgement"]
    key = value.split(":", 1)[0]
    outcome = j["map"].get(key, j["map"].get("*"))
    c.st["steps"][step["id"]] = {"status": GREEN if outcome == GREEN else RED,
                                 "answer": value, "t": utc()}
    c.trace("answer", step=step["id"], value=value, outcome=outcome)
    if outcome == GREEN:
        if step.get("check"):
            emit_verdict(c, step, "PASS", f"operator answered {value}",
                         step.get("evidence", ""), failproofs)
    else:
        verdict = ("INVALID-INSTRUMENT" if outcome == "INVALID"
                   else (step.get("on_fail", {}).get("verdict") or "FAIL"))
        c.st["steps"][step["id"]]["verdict"] = verdict
        emit_verdict(c, step, verdict, f"operator answered {value}",
                     step.get("evidence", ""), failproofs)
        g = guest_of(step, c.st["vars"])
        if g:
            c.st["guests"][g] = {"status": "OUT_OF_SERVICE", "since": step["id"], "why": verdict}
        act = step.get("on_fail", {}).get("action", "HALT_PART")
        if act == "HALT_CAMPAIGN":
            c.st["halted"] = {"at": step["id"], "why": f"answer {value}", "verdict": verdict,
                              "msg": step.get("on_fail", {}).get("msg", "")}
        elif act == "HALT_PART":
            c.st.setdefault("halted_parts", []).append(step["part"])
    c.save()


# --------------------------------------------------------------------------- operator UI
def banner(c: Campaign, state: str):
    tag = "DRY-RUN" if c.st["mode"] == "dry" else "LIVE"
    print(f"\n==== PROTOCOL RUNNER ==== campaign={c.cid} mode={tag} state={state}")
    if c.st["mode"] == "dry":
        print("(dry run: no command was or will be executed; results come from scenario fixtures)")


def print_wait_block(c: Campaign, step: dict):
    j = step["judgement"]
    banner(c, "WAITING_ANSWER")
    print(f"step: {step['id']}  ({step['title']})")
    print("=== OPERATOR ACTION REQUIRED - do these steps and NOTHING else ===")
    ev = []
    for e in j["evidence"]:
        try:
            p = subst(e, c.st["vars"])
        except KeyError as exc:
            die(f"evidence path {e!r} references unbound var {exc}")
        if c.st["mode"] == "dry":
            # fixtures stand in for live evidence: same basename, scenario-owned
            p = str(Path(c.st["scenario"]) / "evidence" / Path(p).name)
        ev.append(p)
    for i, e in enumerate(ev, 1):
        print(f"{i}. Read this file completely: {e}")
    print(f"{len(ev)+1}. {j['question']}")
    print(f"{len(ev)+2}. Answer with EXACTLY ONE of these tokens:")
    for k, desc in j["answers"].items():
        print(f"     {k:<24} {desc}")
    print(f"{len(ev)+3}. The ONLY valid next command is:")
    print(f"     python3 protocol/run.py answer --campaign {c.cid} --step {step['id']} --value <TOKEN>")
    print("Do not run any other command. Do not open other files. Do not re-run earlier steps.")


def print_terminal(c: Campaign):
    if c.st.get("halted"):
        h = c.st["halted"]
        banner(c, "HALTED")
        print(f"halted at step {h['at']}: {h['verdict']} - {h['why']}")
        if h.get("msg"):
            print(f"prescribed action: {h['msg']}")
        print("The campaign is HALTED. Do not re-run steps. Do not modify anything under protocol/.")
        print("Report the ledger below verbatim, then stop:")
        print(c.ledger_p.read_text().rstrip())
        return
    pending = [s for s, v in c.st["steps"].items() if v.get("status") == "PENDING"]
    banner(c, "DONE")
    print("All runnable steps have completed.")
    print("The ONLY valid next command is:")
    print(f"     python3 protocol/run.py verdicts --campaign {c.cid}")
    print("Paste its output as the FIRST block of your report (G-1: the verdict is arithmetic).")


# --------------------------------------------------------------------------- commands
def cmd_start(a):
    scenario = None
    scen_doc: dict = {}
    if a.mode == "dry":
        if not a.scenario:
            die("--mode dry requires --scenario <dir under protocol/scenarios/>")
        scen = SCEN_ROOT / a.scenario if not a.scenario.startswith("/") else Path(a.scenario)
        if not (scen / "scenario.json").exists():
            die(f"no scenario.json under {scen}")
        scenario = str(scen)
        scen_doc = json.loads((scen / "scenario.json").read_text())
    # the scenario names its own steps files and vars, so a dry start has ZERO free choices
    steps_arg = a.steps or ",".join(scen_doc.get("steps", []))
    if not steps_arg:
        die("no steps: pass --steps, or use a scenario that declares them")
    files = [PROTO / "steps" / f if not f.startswith(("/", ".")) else Path(f)
             for f in steps_arg.split(",")]
    for f in files:
        if not f.exists():
            die(f"steps file {f} does not exist")
    steps = load_steps(files)
    vars = dict(scen_doc.get("vars") or {})
    for kv in a.var or []:
        k, _, v = kv.partition("=")
        if not _:
            die(f"--var needs NAME=VALUE, got {kv!r}")
        vars[k] = v
    c = Campaign(a.campaign)
    c.create([str(f) for f in files], a.mode, scenario, vars)
    c.trace("start", steps=[s["id"] for s in steps], vars=vars, mode=a.mode)
    print(f"campaign {a.campaign} created ({a.mode}, {len(steps)} steps loaded and validated)")
    _continue(c, steps, a)


def cmd_continue(a):
    c = Campaign(a.campaign)
    c.load()
    steps = load_steps([Path(f) for f in c.st["steps_files"]])
    _continue(c, steps, a)


def _continue(c, steps, a):
    if getattr(a, "auto_answer_truth", False) and os.environ.get("PROTOCOL_SELFTEST") != "1":
        die("--auto-answer-truth is a SELFTEST mechanism (set PROTOCOL_SELFTEST=1). An operator "
            "using it is answering judgements from the answer key, which voids the run.")
    waiting = advance(c, steps, load_failproofs(),
                      auto_truth=getattr(a, "auto_answer_truth", False))
    if waiting:
        print_wait_block(c, waiting)
    else:
        print_terminal(c)


def cmd_answer(a):
    c = Campaign(a.campaign)
    c.load()
    steps = load_steps([Path(f) for f in c.st["steps_files"]])
    step = next((s for s in steps if s["id"] == a.step), None)
    if step is None or step["kind"] != "judgement":
        die(f"{a.step!r} is not a judgement step")
    if (c.st["steps"].get(a.step) or {}).get("answer"):
        die(f"{a.step} is already answered ({c.st['steps'][a.step]['answer']}); answers are final")
    ok, why = runnable(c, step)
    if not ok and step_status(c, a.step) == "PENDING":
        die(f"{a.step} is not the step awaiting an answer ({why})")
    keys = set(step["judgement"]["answers"])
    key = a.value.split(":", 1)[0]
    if key not in keys:
        c.trace("invalid_answer", step=a.step, value=a.value)
        die(f"{a.value!r} is not a valid token. Valid: {' | '.join(sorted(keys))}")
    apply_answer(c, step, a.value, load_failproofs())
    _continue(c, steps, a)


def cmd_status(a):
    c = Campaign(a.campaign)
    c.load()
    steps = load_steps([Path(f) for f in c.st["steps_files"]])
    done = sum(1 for v in c.st["steps"].values() if v.get("status") in (GREEN, RED, "BLOCKED"))
    banner(c, "HALTED" if c.st.get("halted") else "IN_PROGRESS")
    print(f"steps: {done}/{len(steps)} resolved")
    for s in steps:
        st = c.st["steps"].get(s["id"], {})
        print(f"  {st.get('status','PENDING'):<10} {s['id']:<28} {st.get('verdict','')}")
    guests = c.st.get("guests") or {}
    for g, v in guests.items():
        print(f"guest {g}: {v['status']} (since {v.get('since','-')})")
    waiting = next((s for s in steps if s["kind"] == "judgement"
                    and runnable(c, s)[0]
                    and not (c.st["steps"].get(s["id"]) or {}).get("answer")), None)
    if c.st.get("halted"):
        print_terminal(c)
    elif waiting:
        print_wait_block(c, waiting)
    else:
        print("Next: python3 protocol/run.py continue --campaign", c.cid)


def cmd_verdicts(a):
    c = Campaign(a.campaign)
    c.load()
    print(f"ledger: {c.ledger_p}")
    r = subprocess.run(["bash", str(ROOT / "tools" / "campaign-verdict.sh"), str(c.ledger_p)],
                       capture_output=True, text=True)
    print(r.stdout.rstrip())
    if c.st["mode"] == "dry":
        print("\n(DRY-RUN ledger: these verdicts grade the PROTOCOL WALK, not any guest.)")
    sys.exit(r.returncode)


def cmd_validate(a):
    files = sorted((PROTO / "steps").glob("*.json")) if not a.steps else \
        [Path(f) for f in a.steps.split(",")]
    steps = load_steps(files, check_scenarios=not a.no_scenarios)
    n_j = sum(1 for s in steps if s["kind"] == "judgement")
    n_c = sum(1 for s in steps if s.get("check"))
    print(f"OK: {len(steps)} steps loaded ({n_j} judgement points, {n_c} verdict-emitting), "
          f"all falsifiability declarations present")


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    sub = ap.add_subparsers(dest="cmd", required=True)
    p = sub.add_parser("start");    p.set_defaults(f=cmd_start)
    p.add_argument("--campaign", required=True)
    p.add_argument("--steps", help="comma-separated files under protocol/steps/ (dry mode: defaults to the scenario's declared steps)")
    p.add_argument("--mode", choices=["dry", "live"], required=True)
    p.add_argument("--scenario")
    p.add_argument("--var", action="append")
    p.add_argument("--auto-answer-truth", action="store_true")
    p = sub.add_parser("continue"); p.set_defaults(f=cmd_continue)
    p.add_argument("--campaign", required=True)
    p.add_argument("--auto-answer-truth", action="store_true")
    p = sub.add_parser("answer");   p.set_defaults(f=cmd_answer)
    p.add_argument("--campaign", required=True)
    p.add_argument("--step", required=True)
    p.add_argument("--value", required=True)
    p = sub.add_parser("status");   p.set_defaults(f=cmd_status)
    p.add_argument("--campaign", required=True)
    p = sub.add_parser("verdicts"); p.set_defaults(f=cmd_verdicts)
    p.add_argument("--campaign", required=True)
    p = sub.add_parser("validate"); p.set_defaults(f=cmd_validate)
    p.add_argument("--steps")
    p.add_argument("--no-scenarios", action="store_true")
    a = ap.parse_args()
    a.f(a)


if __name__ == "__main__":
    main()
