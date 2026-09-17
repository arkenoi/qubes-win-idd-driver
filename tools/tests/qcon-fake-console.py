#!/usr/bin/env python3
"""qcon-fake-console.py - a fake of the guest's PV console login handler, for the offline
self-test of tools/qcon (QCON_TRANSPORT=fake:<socket>).

WHAT IT IMITATES (from the measured console, findings/install.md and tools/qcon's header):
  dom0 prints "[ATTACHED]" the moment it binds the console, before the guest says anything;
  a fresh pty has NO SCROLLBACK, so nothing more appears until a CR wakes it; then
  "<HOST> login: " -> user name -> "Password: " -> password -> banner + "C:\\Users\\<user>>";
  cmd.exe echoes the typed line, prints the command's output, then a blank line and the prompt.
  Commands understood: `set K=V`, `echo X` (with %VAR% expansion), `ver`, `exit`, plus a
  fake-only `hang N` that produces NOTHING for N seconds (a stalled command).

THE ONE-ATTACHER RULE IT ENFORCES - the measured shape, not a theory about its cause.
Specimen 10 (win11de-gwt, 2026-09-17): the FIRST attach printed the login prompt; the second
(the login), made after the first had been closed, received zero bytes; five more attaches over
thirty minutes received zero bytes. So by default this fake SERVES EXACTLY ONE CONNECTION for its
whole lifetime: the first connection is the attacher; every later connection - concurrent OR after
the first has gone - is accepted, its input is read and dropped, and it is NEVER written to.
`--attaches-served N` relaxes that to N sequential attachers (a healthy guest, where the old
attach-per-command tool worked for weeks), so the self-test can also prove the fake distinguishes
the two.

Usage: qcon-fake-console.py <socket path> [--user U --pass P] [--host NAME]
                            [--attaches-served N] [--start-state login|shell]
Runs until SIGTERM/SIGINT. Single-threaded; deliberately simple.
"""
import argparse
import os
import select
import signal
import socket
import sys
import time


class Guest:
    """The login handler + cmd.exe for the ONE served attacher."""

    def __init__(self, conn, a):
        self.conn, self.a = conn, a
        self.inbuf = b""
        self.env = {}
        self.state = "idle" if a.start_state == "login" else "shell-fresh"
        self.user = "user"
        self.pending = None          # (resume_at, remaining parts) while `hang` is in progress
        self.queue = []              # lines received while a hang is in progress
        self.send("\r\n[ATTACHED]\r\n")          # dom0's banner, before any guest output

    def send(self, s):
        try:
            self.conn.sendall(s.encode())
        except OSError:
            pass

    def prompt(self):
        return f"C:\\Users\\{self.user}>"

    def feed(self, data):
        self.inbuf += data
        while True:
            i = self.inbuf.find(b"\r")
            j = self.inbuf.find(b"\n")
            cut = min(x for x in (i, j) if x >= 0) if (i >= 0 or j >= 0) else -1
            if cut < 0:
                return
            line = self.inbuf[:cut].decode("utf-8", "replace")
            self.inbuf = self.inbuf[cut + 1:]
            if self.pending:
                self.queue.append(line)
            else:
                self.line(line)

    def line(self, line):
        st = self.state
        if st == "idle":                              # fresh pty: the wake CR reveals the prompt
            self.state = "login"
            self.send(f"\r\n{self.a.host} login: ")
        elif st == "shell-fresh":                     # already logged in from an earlier session
            self.state = "shell"
            self.send("\r\n" + self.prompt())
        elif st == "login":
            if line == "":
                self.send(f"\r\n{self.a.host} login: ")
                return
            self.pending_user = line
            self.send(line + "\r\nPassword: ")
            self.state = "password"
        elif st == "password":
            ok = (self.a.user is None or
                  (self.pending_user == self.a.user and line == (self.a.password or "")))
            if not ok:
                self.send(f"\r\nLogin failed.\r\n\r\n{self.a.host} login: ")
                self.state = "login"
                return
            self.user = self.pending_user
            self.state = "shell"
            self.send("\r\n\r\nMicrosoft Windows [Version 10.0.19045.fake]\r\n"
                      "(c) Fake Corporation. All rights reserved.\r\n\r\n" + self.prompt())
        elif st == "shell":
            self.send(line + "\r\n")                  # terminal echo of the typed line
            parts = [p.strip() for p in line.split("&")]
            self.execute(parts)

    def expand(self, s):
        out, i = "", 0
        while i < len(s):
            if s[i] == "%":
                j = s.find("%", i + 1)
                if j > i:
                    out += self.env.get(s[i + 1:j], "")
                    i = j + 1
                    continue
            out += s[i]
            i += 1
        return out

    def execute(self, parts):
        while parts:
            p = parts.pop(0)
            if not p:
                continue
            verb, _, arg = p.partition(" ")
            v = verb.lower()
            if v == "set" and "=" in arg:
                k, _, val = arg.partition("=")
                self.env[k.strip()] = self.expand(val)
            elif v == "echo":
                self.send(self.expand(arg) + "\r\n")
            elif v == "ver":
                self.send("\r\nMicrosoft Windows [Version 10.0.19045.fake]\r\n")
            elif v == "hang":
                self.pending = (time.time() + float(arg or "5"), parts)
                return                                # NOTHING until the hang expires
            elif v == "exit":
                self.state = "idle"
                self.env = {}
                self.send("\r\n")                     # xencons_monitor restarts the login handler
                return
            else:
                self.send(f"'{verb}' is not recognized as an internal or external command,\r\n"
                          "operable program or batch file.\r\n")
        self.send("\r\n" + self.prompt())

    def tick(self):
        if self.pending and time.time() >= self.pending[0]:
            _, rest = self.pending
            self.pending = None
            self.execute(rest)
            q, self.queue = self.queue, []
            for line in q:
                self.line(line)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sock")
    ap.add_argument("--user")
    ap.add_argument("--password", "--pass", dest="password")
    ap.add_argument("--host", default="FAKEHOST")
    ap.add_argument("--attaches-served", type=int, default=1)
    ap.add_argument("--start-state", choices=("login", "shell"), default="login")
    a = ap.parse_args()

    def bye(sig, _f):
        raise SystemExit(128 + sig)
    signal.signal(signal.SIGTERM, bye)
    signal.signal(signal.SIGINT, bye)

    try:
        os.unlink(a.sock)
    except OSError:
        pass
    ls = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    ls.bind(a.sock)
    ls.listen(16)
    served = 0
    guest = None                    # the ONE attacher's Guest, or None
    silent = []                     # connections that will never hear anything
    log = lambda m: print(f"fake-console: {m}", file=sys.stderr, flush=True)
    log(f"listening on {a.sock}; will serve {a.attaches_served} attach(es)")
    try:
        while True:
            fds = [ls] + silent + ([guest.conn] if guest else [])
            r, _, _ = select.select(fds, [], [], 0.1)
            if guest:
                guest.tick()
            for fd in r:
                if fd is ls:
                    conn, _ = ls.accept()
                    if guest is None and served < a.attaches_served:
                        served += 1
                        guest = Guest(conn, a)
                        log(f"attach #{served}: SERVED")
                    else:
                        silent.append(conn)
                        log(f"attach #{served + len(silent)}: SILENT (one attacher; "
                            f"{'attacher present' if guest else 'served quota exhausted'})")
                elif guest and fd is guest.conn:
                    try:
                        d = conn_read(fd)
                    except OSError:
                        d = b""
                    if not d:
                        log("attacher hung up")
                        guest.conn.close()
                        guest = None
                    else:
                        guest.feed(d)
                else:
                    try:
                        d = conn_read(fd)
                    except OSError:
                        d = b""
                    if not d:
                        silent.remove(fd)
                        fd.close()
                    # else: dropped on the floor - a silent attacher hears nothing, ever
    finally:
        ls.close()
        try:
            os.unlink(a.sock)
        except OSError:
            pass


def conn_read(fd):
    return fd.recv(4096)


if __name__ == "__main__":
    sys.exit(main())
