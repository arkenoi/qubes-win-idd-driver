#!/usr/bin/env python3
"""Local fix: qvm-block/qvm-usb/qvm-pci crash on Python 3.14.

qubesadmin.tools.qvm_device.get_parser() smuggles the fixed device class in as a
hidden POSITIONAL argument with action="store_const". Python 3.14 tightened argparse
to reject zero-argument actions on positionals, so the parser blows up at
construction time - every invocation fails, including --help:

    ValueError: action 'store_const' is not valid for positional arguments

nargs=0 is not an escape either ("nargs for positionals must be != 0").
set_defaults() gives downstream code the same args.devclass without a CLI argument.

Run with sudo. Keeps a .orig-preclaude backup. Idempotent.
Undone by any qubes-core-admin-client update (and by a template rebuild if the qube
is an AppVM) - apply in the template to make it stick.
"""
import argparse, glob, sys

OLD = '''    if device_class:
        parser.add_argument(
            "devclass",
            const=device_class,
            action="store_const",
            help=argparse.SUPPRESS,
        )'''
NEW = '''    if device_class:
        # LOCAL PATCH (Python 3.14 argparse): a fixed device class can no longer be
        # passed as a hidden positional with store_const; set_defaults is equivalent
        # for every downstream reader of args.devclass.
        parser.set_defaults(devclass=device_class)'''

paths = glob.glob('/usr/lib/python3*/site-packages/qubesadmin/tools/qvm_device.py')
if not paths:
    sys.exit('qvm_device.py not found')
for p in paths:
    s = open(p).read()
    if 'LOCAL PATCH (Python 3.14 argparse)' in s:
        print(f'{p}: already patched')
        continue
    if s.count(OLD) != 1:
        print(f'{p}: pattern not found (upstream changed?) - skipped')
        continue
    open(p + '.orig-preclaude', 'w').write(s)
    open(p, 'w').write(s.replace(OLD, NEW))
    print(f'{p}: patched (backup at {p}.orig-preclaude)')
