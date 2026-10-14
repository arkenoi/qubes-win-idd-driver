#!/usr/bin/env python3
"""declare-level.py - wire a declared severity into a harness log line, BY LINE NUMBER.

    tools/declare-level.py <file> <lineno> <level> <anchor>

<anchor> is the text that must appear EXACTLY ONCE on that line; the level is inserted directly
before it. The level goes in the message so tools/sweep-gate.sh's bracketed reader can see it.

WHY BY LINE NUMBER. logvol-lib.sh carries two byte-identical failure lines ("no image at $img", at
322 and 338), and several files repeat a message inside the comment that explains it. A
string-keyed edit cannot tell those apart: on 2026-10-09 a replace(OLD, NEW, 1) hit the copy of a
line inside its own explanatory comment, the code landed mid-comment, parsed clean, and failed only
on a guest 35 minutes later. So the line number selects, and the anchor only VERIFIES - and it must
be unique WITHIN that line, or this refuses.
"""
import sys


def main(argv):
    if len(argv) != 5:
        sys.stderr.write(__doc__)
        return 2
    path, lineno, level, anchor = argv[1], int(argv[2]), argv[3], argv[4]
    if level not in ("[ERROR]", "[WARN]"):
        sys.stderr.write("declare-level: level must be [ERROR] or [WARN], got %r\n" % level)
        return 2

    with open(path, encoding="utf-8") as fh:
        lines = fh.readlines()
    if not 1 <= lineno <= len(lines):
        sys.stderr.write("declare-level: %s has no line %d\n" % (path, lineno))
        return 1

    line = lines[lineno - 1]
    n = line.count(anchor)
    if n != 1:
        sys.stderr.write("declare-level: REFUSED - %s:%d carries the anchor %d time(s), need exactly 1\n  %s"
                         % (path, lineno, n, line))
        return 1
    if "[ERROR]" in line or "[WARN]" in line:
        sys.stderr.write("declare-level: REFUSED - %s:%d already declares a level\n  %s" % (path, lineno, line))
        return 1

    lines[lineno - 1] = line.replace(anchor, level + " " + anchor, 1)
    with open(path, "w", encoding="utf-8") as fh:
        fh.writelines(lines)
    sys.stdout.write("%s:%d %s\n  %s" % (path, lineno, level, lines[lineno - 1].lstrip()))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
