#!/usr/bin/python3
"""Prove the agent tarball dom0 pipes in with `cat > file` arrives BYTE-EXACT.

An exit code of 0 from cmd.exe only means `exit` ran; it says nothing about the payload.
This re-sends a known tarball and reads the landed file's size + SHA256 back out of the guest.
"""
import subprocess, sys, io, tarfile, hashlib, os
# qubesadmin is installed on this dev qube; QUBESADMIN_SRC only matters if it is not
# (point it at a qubes-core-admin-client checkout - only utils.encode_for_vmexec is used).
if os.environ.get("QUBESADMIN_SRC"):
    sys.path.insert(0, os.environ["QUBESADMIN_SRC"])
from qubesadmin.utils import encode_for_vmexec  # noqa: E402

VM = sys.argv[1] if len(sys.argv) > 1 else "win11-fresh"
WORKDIR, ARCH = "/run/qubes-update/", "/run/qubes-update/agent.tar.gz"


def vmexec(argv, timeout=120):
    p = subprocess.run(["qrexec-client-vm", VM, "qubes.VMExec+" + encode_for_vmexec(argv)],
                       stdin=subprocess.DEVNULL, capture_output=True, timeout=timeout)
    return p.returncode, p.stdout.decode("utf-8", "replace")


def vmshell(command, payload=b"", timeout=180):
    p = subprocess.run(["qrexec-client-vm", VM, "qubes.VMShell"],
                       input=command.encode() + b"& exit\n" + payload,
                       capture_output=True, timeout=timeout)
    return p.returncode


# a payload big enough that buffering/binary problems would show: ~1 MB of incompressible data
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w:gz") as tf:
    body = os.urandom(1024 * 1024)
    info = tarfile.TarInfo("agent/blob.bin"); info.size = len(body)
    tf.addfile(info, io.BytesIO(body))
tarball = buf.getvalue()
want = hashlib.sha256(tarball).hexdigest().upper()
print(f"sending {len(tarball)} bytes, sha256={want}")

vmexec(["mkdir", "-p", WORKDIR])
rc = vmshell("cat > " + ARCH, tarball)
print(f"cat> rc={rc}")

rc, out = vmexec(["powershell", "-NoProfile", "-Command",
                  "$f='C:\\run\\qubes-update\\agent.tar.gz';"
                  "if(Test-Path $f){(Get-Item $f).Length;"
                  "(Get-FileHash $f -Algorithm SHA256).Hash}else{'MISSING'}"])
got = [l.strip() for l in out.splitlines() if l.strip()]
print(f"guest reports: {got}")
ok = len(got) >= 2 and got[0] == str(len(tarball)) and got[1].upper() == want
print("VERDICT:", "BYTE-EXACT" if ok else "MISMATCH - the copy step is broken")
vmexec(["rm", "-r", WORKDIR])
sys.exit(0 if ok else 1)
