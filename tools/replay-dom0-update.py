#!/usr/bin/python3
"""Replay dom0's stock qubes-vm-update command sequence against a Windows guest.

Mirrors qubes-core-admin-linux vmupdate/qube_connection.py step for step, using the same
qrexec services dom0 would use (qubes.VMExec for commands, qubes.VMShell for the tarball
copy) and the same encoding (qubesadmin.utils.encode_for_vmexec). Reports each step's exit
code, which is what dom0 turns into success/failure.

Usage: replay-dom0-update.py <vm> [--with-entrypoint]
"""
import subprocess
import sys
import tarfile
import io
import os

# qubesadmin lives in dom0; on a dev qube point QUBESADMIN_SRC at a checkout of
# qubes-core-admin-client (only utils.encode_for_vmexec is used).
sys.path.insert(0, os.environ.get("QUBESADMIN_SRC", "/usr/lib/python3.13/site-packages"))
from qubesadmin.utils import encode_for_vmexec  # noqa: E402

VM = sys.argv[1] if len(sys.argv) > 1 else "win11-fresh"
WORKDIR = "/run/qubes-update/"
ARCH = WORKDIR + "agent.tar.gz"


def vmexec(argv, timeout=120):
    """Step transport for a qube advertising `vmexec`.

    With --no-vmexec, route the same command the way qubesadmin's run_with_args() falls back
    for a qube WITHOUT that feature: shell-quoted over qubes.VMShell. That is what a real
    Windows qube gets today, because the Windows qubesdb-cmd cannot write the feature request.
    Note the agent run itself is NOT affected - dom0's progress path calls qubes.VMExec
    directly, with no feature check and no fallback.
    """
    if "--no-vmexec" in sys.argv and "entrypoint.py" not in " ".join(argv):
        import shlex
        return vmshell(" ".join(shlex.quote(a) for a in argv), b"", timeout) + (b"",)
    svc = "qubes.VMExec+" + encode_for_vmexec(argv)
    p = subprocess.run(["qrexec-client-vm", VM, svc], stdin=subprocess.DEVNULL,
                       capture_output=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def vmshell(command, payload=b"", timeout=120):
    # exactly what qubesadmin prepare_input_for_vmshell() builds for a Windows qube
    # (the `& exit` suffix is chosen on the `os` feature reading "Windows")
    data = command.encode() + b"& exit\n" + payload
    p = subprocess.run(["qrexec-client-vm", VM, "qubes.VMShell"], input=data,
                       capture_output=True, timeout=timeout)
    return p.returncode, p.stdout


def show(step, rc, out, err=b"", expect=None):
    verdict = "" if expect is None else ("  <-- OK" if rc in expect else "  <-- UNEXPECTED")
    print(f"[{step}] rc={rc}{verdict}")
    for label, blob in (("out", out), ("err", err)):
        text = blob.decode("utf-8", "replace").strip()
        if text:
            for line in text.splitlines()[:12]:
                print(f"    {label}: {line}")
    return rc


print(f"=== replaying dom0's qubes-vm-update sequence against {VM} ===")

# 1. mkdir -p /run/qubes-update/
show("mkdir", *vmexec(["mkdir", "-p", WORKDIR]), expect=(0,))

# 2. cat > /run/qubes-update/agent.tar.gz   (agent tarball on stdin, over VMShell)
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w:gz") as tf:
    info = tarfile.TarInfo("agent/entrypoint.py")
    body = b"#!/usr/bin/python3\nprint('stand-in for dom0's injected agent')\n"
    info.size = len(body)
    tf.addfile(info, io.BytesIO(body))
tarball = buf.getvalue()
print(f"    (tarball {len(tarball)} bytes)")
show("cat>tarball", *vmshell("cat > " + ARCH, tarball), expect=(0,))

# 3. tar -xzf <arch> -C <workdir>
show("tar", *vmexec(["tar", "-xzf", ARCH, "-C", WORKDIR]), expect=(0,))

# 4. the agent run itself (only with --with-entrypoint: it performs a real update pass)
if "--with-entrypoint" in sys.argv:
    print("[entrypoint] running - this drives a REAL update pass, may take minutes")
    rc, out, err = vmexec(["/usr/bin/python3", WORKDIR + "agent/entrypoint.py",
                           "--log", "INFO"], timeout=3600)
    show("entrypoint", rc, out, err, expect=(0, 100))
    floats = [l for l in err.decode("utf-8", "replace").splitlines()
              if l.strip().replace(".", "", 1).isdigit()]
    print(f"    progress floats seen on stderr: {floats}")

# 5. rm -r /run/qubes-update/
show("rm", *vmexec(["rm", "-r", WORKDIR]), expect=(0,))

# 6. cat the agent log
show("cat log", *vmexec(["cat", "/var/log/qubes/qubes-update/update-agent.log"]), expect=(0,))
