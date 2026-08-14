#!/usr/bin/python3
"""Byte-counting shim between qubes.UpdatesProxy and tinyproxy, run in THIS qube.

WHY. Same tinyproxy instance, same URL, same minute: this qube's own curl gets the full 80043-byte
body 6 times out of 6, while the Windows guest gets 21040/23864/27219/70240/76248/80043 through
qrexec. tinyproxy at LogLevel Info does not log response sizes, so it cannot say whether it handed
over a full body that was lost afterwards, or a short one.

This sits on 127.0.0.1:8082 (where /etc/qubes-rpc/qubes.UpdatesProxy points) and forwards to
tinyproxy moved to 127.0.0.1:8083, counting bytes in BOTH directions per connection. Then:

    shim reports 80043 toward the client, guest receives 21040  -> lost in qrexec/vchan
    shim reports 21040                                          -> lost upstream of the shim

Usage: proxy-bytecount-shim.py [listen_port] [upstream_port] [logfile]
Deliberately dependency-free and unprivileged; ports and paths are all user-space.
"""
import socket
import socketserver
import sys
import threading
import time

LISTEN = int(sys.argv[1]) if len(sys.argv) > 1 else 8082
UPSTREAM = int(sys.argv[2]) if len(sys.argv) > 2 else 8083
LOGFILE = sys.argv[3] if len(sys.argv) > 3 else "/tmp/proxy-shim.log"
_lock = threading.Lock()
_n = [0]


def log(msg):
    with _lock:
        with open(LOGFILE, "a") as f:
            f.write("%s %s\n" % (time.strftime("%H:%M:%S"), msg))


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        with _lock:
            _n[0] += 1
            cid = _n[0]
        client = self.request
        up = socket.create_connection(("127.0.0.1", UPSTREAM), timeout=60)
        counts = {"c2u": 0, "u2c": 0}
        first_line = [b""]
        ends = {}

        def pump(src, dst, key):
            try:
                while True:
                    data = src.recv(65536)
                    if not data:
                        ends[key] = "eof"
                        break
                    if key == "c2u" and not first_line[0]:
                        first_line[0] = data.split(b"\r\n")[0][:120]
                    counts[key] += len(data)
                    dst.sendall(data)
            except Exception as e:
                ends[key] = "%s:%s" % (type(e).__name__, e)
            finally:
                try:
                    dst.shutdown(socket.SHUT_WR)
                except Exception:
                    pass

        t1 = threading.Thread(target=pump, args=(client, up, "c2u"))
        t2 = threading.Thread(target=pump, args=(up, client, "u2c"))
        t1.start()
        t2.start()
        t1.join()
        t2.join()
        try:
            up.close()
        except Exception:
            pass
        log("conn=%d req=%r to_upstream=%d to_client=%d endC2U=%s endU2C=%s"
            % (cid, first_line[0].decode("ascii", "replace"), counts["c2u"], counts["u2c"],
               ends.get("c2u", "-"), ends.get("u2c", "-")))


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


if __name__ == "__main__":
    log("shim listening on %d -> %d" % (LISTEN, UPSTREAM))
    Server(("127.0.0.1", LISTEN), Handler).serve_forever()
