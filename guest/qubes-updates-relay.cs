// Qubes updates-proxy forwarder for Windows (PLAN-updates-proxy.md, Stage 3-4).
//
// The Linux forwarder pipes each TCP connection straight into a qrexec stream. Windows
// qrexec-client-vm cannot do that: it TRIGGERS a service and exits; the vchan stdio is wired
// to a freshly spawned HANDLER process, never to the caller. So a TCP-to-qrexec bridge needs
// a connect-back relay, in two modes in one exe:
//
//   --listen [port] : bind 127.0.0.1:port (the updates-proxy endpoint the WU planes point at).
//       Per accepted connection A: mint a token, bind an ephemeral loopback control port P,
//       spawn  qrexec-client-vm.exe  "<target>|qubes.UpdatesProxy|<user>|<self> --relay P T",
//       accept the relay's connect-back B on P (token-checked), then pump A <-> B.
//
//   --relay <port> <token> : the qrexec HANDLER (its stdin/stdout ARE the vchan, 8-bit clean).
//       Connect to 127.0.0.1:<port>, send the token line, then pump that socket <-> raw stdio.
//
// Bytes:  WU -> A -> B -> relay.stdout=vchan -> qubes.UpdatesProxy -> netvm tinyproxy -> net
//         and the mirror on the way back. Fully duplex, half-close aware, no CRLF translation.
//
// NOTE (Stage 2 findings): qrexec-client-vm.exe is NOT on the qrexec-session PATH - call it by
// full path. And do NOT impose short read timeouts here - WU/BITS set their own, and a torified
// proxy adds seconds (a 50s+ round trip was observed).
//
// C# 5 ONLY: the in-box csc (Framework v4.0.30319) is pre-Roslyn - no string interpolation, no
// 'using var', no out-vars. Keep it that way so it compiles on-guest with no build infra.
//
// Target VM: --target (or QUBES_UPDATES_TARGET env), default "@default" so dom0 policy routes it.
using System;
using System.Diagnostics;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Collections.Concurrent;
using System.Threading;
using System.Threading.Tasks;

static class Relay
{
    const string Service = "qubes.UpdatesProxy";
    // Delivery Optimization opens a STORM of speculative connections (thousands, many closed
    // before sending a byte). A qrexec spawn per connection fork-bombs the proxy qube (R3).
    // Two defenses: (1) read the first request bytes BEFORE spawning, so abandoned connections
    // cost nothing; (2) cap concurrent qrexec handlers so the storm cannot exhaust RAM/tmpfs.
    static readonly SemaphoreSlim _gate = new SemaphoreSlim(MaxConn());

    // WARM POOL. Measured 2026-08-13: Windows Update's own downloader issues MANY short ranged
    // connections (~230 KB each), and each one paid the FULL setup cost on the critical path -
    // spawn qrexec-client-vm, dom0 policy evaluation, service start in the proxy qube, connect
    // back, token handshake. That is 5-6 s per connection even when almost no bytes move
    // (measured: up=958 down=958 ms=6481), which collapsed throughput to ~200 KB/s against the
    // ~13 MB/s a single long-lived connection achieves through the same relay.
    //
    // The setup cannot be made cheaper, but it CAN be paid in advance: keep a few channels
    // spawned and connected back, so an inbound connection takes a ready one immediately while
    // a background filler starts its replacement. A channel is used ONCE (an HTTP proxy session
    // ends with its client), so this trades a small number of speculative spawns for latency -
    // the same bargain the read-first check already makes in the other direction.
    class Ready
    {
        public TcpClient Relay;
        public NetworkStream Stream;
        public string Token;
        public DateTime Born;
    }
    static readonly ConcurrentQueue<Ready> _pool = new ConcurrentQueue<Ready>();
    static int PoolTarget()
    {
        int pt;
        if (int.TryParse(Environment.GetEnvironmentVariable("QUBES_UPDATES_POOL"), out pt) && pt >= 0) return pt;
        return 8;
    }
    // A pooled channel holds a proxy session open; tinyproxy will eventually drop an idle one,
    // so treat anything older than this as stale rather than handing out a dead socket.
    const int PoolMaxAgeSeconds = 25;

    // Grace period for the second direction to finish once the first has ended. Override with
    // QUBES_UPDATES_DRAINMS if a slow link ever needs longer; 3000 was the original value and it
    // cost ~6 s of pure latency per connection (two drains in series).
    // ALLOWLIST. The relay carries whatever the guest aims at it, and the proxy is only up during
    // an update pass - which is exactly when every Windows background client discovers a working
    // route. Measured 2026-08-14 during ONE pass: Office telemetry (ecs.office.com) held a channel
    // 125 s, Defender (wdcpalt.microsoft.com) 133 s, OneDrive (g.live.com, oneclient.sfx.ms) 128 s,
    // plus 20 NCSI probes - against a warm pool of 8 and MAXCONN 32. That starves the update
    // traffic we raised the proxy for, and it is egress we never intended to grant: a qube with
    // no netvm should not be phoning home to Office because an update is running.
    // Suffix match, case-insensitive. Override with QUBES_UPDATES_ALLOW (comma-separated).
    static string[] AllowList()
    {
        string env = Environment.GetEnvironmentVariable("QUBES_UPDATES_ALLOW");
        if (!string.IsNullOrEmpty(env)) return env.Split(',');
        return new string[] {
            "windowsupdate.com",            // au.download..., ctldl... (cert trust lists)
            "update.microsoft.com",         // fe2cr/fe3cr, sls, catalog
            "delivery.mp.microsoft.com",    // tlu.dl... - the actual payload CDN
            "download.microsoft.com",
            "microsoftupdate.com",
        };
    }
    static bool Allowed(string target)
    {
        if (string.IsNullOrEmpty(target)) return false;
        int colon = target.IndexOf(':');
        string h = (colon > 0 ? target.Substring(0, colon) : target).Trim().ToLowerInvariant();
        foreach (string suffix in AllowList())
        {
            string sfx = suffix.Trim().ToLowerInvariant();
            if (sfx.Length == 0) continue;
            if (h == sfx || h.EndsWith("." + sfx)) return true;
        }
        return false;
    }

    // Pull the destination out of an HTTP proxy request: "GET http://host/path" or "CONNECT host:443".
    static string TargetOf(string requestLine)
    {
        if (string.IsNullOrEmpty(requestLine)) return "";
        string[] parts = requestLine.Split(' ');
        if (parts.Length < 2) return "";
        string u = parts[1];
        if (u.StartsWith("http://", StringComparison.OrdinalIgnoreCase)) u = u.Substring(7);
        else if (u.StartsWith("https://", StringComparison.OrdinalIgnoreCase)) u = u.Substring(8);
        int slash = u.IndexOf('/');
        if (slash >= 0) u = u.Substring(0, slash);
        return u;
    }

    static int DrainMs()
    {
        int d;
        if (int.TryParse(Environment.GetEnvironmentVariable("QUBES_UPDATES_DRAINMS"), out d) && d >= 0) return d;
        return 250;
    }
    static int MaxConn()
    {
        int mc;
        if (int.TryParse(Environment.GetEnvironmentVariable("QUBES_UPDATES_MAXCONN"), out mc) && mc > 0) return mc;
        return 32;
    }

    static int Main(string[] args)
    {
        try
        {
            if (args.Length >= 3 && args[0] == "--relay")
                return RunRelay(int.Parse(args[1]), args[2]);
            if (args.Length >= 1 && args[0] == "--listen")
                return RunListen(args);
            Console.Error.WriteLine("usage: qubes-updates-relay --listen [port] [--target VM] [--user U] [--log DIR]");
            Console.Error.WriteLine("       qubes-updates-relay --relay <controlPort> <token>   (internal; spawned via qrexec)");
            return 2;
        }
        catch (Exception e) { Console.Error.WriteLine("FATAL " + e); return 1; }
    }

    static string QrexecClientVm()
    {
        string v = Environment.GetEnvironmentVariable("QREXEC_CLIENT_VM");
        if (string.IsNullOrEmpty(v)) v = @"C:\Program Files\Qubes Tools\bin\qrexec-client-vm.exe";
        return Environment.ExpandEnvironmentVariables(v);
    }

    // ---- listener side (long-running service) --------------------------------------------
    static int RunListen(string[] args)
    {
        int port = 8082;
        string target = Environment.GetEnvironmentVariable("QUBES_UPDATES_TARGET");
        if (string.IsNullOrEmpty(target)) target = "@default";
        string user = "user";
        string logDir = @"C:\Users\Public";
        for (int i = 1; i < args.Length; i++)
        {
            if (args[i] == "--target" && i + 1 < args.Length) target = args[++i];
            else if (args[i] == "--user" && i + 1 < args.Length) user = args[++i];
            else if (args[i] == "--log" && i + 1 < args.Length) logDir = args[++i];
            else { int p; if (int.TryParse(args[i], out p)) port = p; }
        }
        string self = Process.GetCurrentProcess().MainModule.FileName;
        string logPath = Path.Combine(logDir, "qubes-updates-relay.log");
        Log(logPath, "listen 127.0.0.1:" + port + " target=" + target + " user=" + user + " self=" + self);

        TcpListener listener = new TcpListener(IPAddress.Loopback, port);
        listener.Start();

        // Start warming channels immediately, so the first request does not pay setup either.
        Task filler = Task.Run(delegate { return PoolFiller(self, target, user, logPath); });
        GC.KeepAlive(filler);
        while (true)
        {
            TcpClient inbound = listener.AcceptTcpClient();
            TcpClient captured = inbound;
            Task.Run(delegate { HandleInbound(captured, self, target, user, logPath).Wait(); });
        }
    }

    static async Task HandleInbound(TcpClient inbound, string self, string target, string user, string logPath)
    {
        NetworkStream a = inbound.GetStream();

        // READ-FIRST: buffer the client's initial request before spending a qrexec spawn.
        // DO's speculative connections close without sending anything - drop them for free.
        byte[] head = new byte[65536];
        int hlen = 0;
        try
        {
            a.ReadTimeout = 10000;
            hlen = await a.ReadAsync(head, 0, head.Length);
        }
        catch { hlen = 0; }
        if (hlen <= 0) { inbound.Close(); return; }   // abandoned/empty: NO spawn, NO log spam

        // Enforce the allowlist BEFORE spending a channel or a gate slot: a denied request must
        // cost nothing but a 403 and a log line.
        {
            string headPeek = Encoding.ASCII.GetString(head, 0, Math.Min(hlen, 512));
            int e0 = headPeek.IndexOf('\n');
            string line0 = (e0 > 0 ? headPeek.Substring(0, e0) : headPeek).Trim();
            string dest = TargetOf(line0);
            if (!Allowed(dest))
            {
                try
                {
                    byte[] deny = Encoding.ASCII.GetBytes(
                        "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                    await a.WriteAsync(deny, 0, deny.Length);
                }
                catch { }
                Log(logPath, "DENY host=" + (dest.Length > 0 ? dest : "(unparsed)") + " req=[" + line0 + "]");
                inbound.Close();
                return;
            }
        }

        // Cap concurrency so a burst of real requests cannot fork-bomb the proxy qube.
        await _gate.WaitAsync();
        Stopwatch sw = Stopwatch.StartNew();
        long up = hlen, down = 0, ttfb = -1;
        string token = "-";
        string reqLine = "", connHdr = "(none)", eofSide = "-";
        bool warm = false;
        Func<string> endReasons = null;   // set once the pumps exist; reports WHY each direction stopped
        try
        {
            Ready ch = TakeWarm();
            if (ch != null) { warm = true; }
            else { ch = await OpenChannel(self, target, user, logPath); }
            if (ch == null) { inbound.Close(); return; }
            token = ch.Token;
            TcpClient relay = ch.Relay;
            NetworkStream rs = ch.Stream;

            using (inbound)
            using (relay)
            {
                // Replay the buffered request head into the tunnel first, then pump both ways.
                // Record the request LINE and the time to first byte back: without splitting
                // those out, a slow connection cannot be told apart from a slow START, and the
                // warm pool proved that guessing which one it is wastes hours.
                // Keep-alive evidence: what the CLIENT asked for, and which side ends first.
                // If the client says "close", it never wanted reuse and the keep-alive hypothesis
                // dies. If it asks for keep-alive and the TUNNEL side EOFs first, the close is
                // imposed on it - which is the mechanism under test.
                string headTxt = Encoding.ASCII.GetString(head, 0, Math.Min(hlen, 2048));
                int ci = headTxt.IndexOf("Connection:", StringComparison.OrdinalIgnoreCase);
                if (ci >= 0) {
                    int ce = headTxt.IndexOf('\n', ci);
                    connHdr = headTxt.Substring(ci, (ce < 0 ? Math.Min(headTxt.Length, ci + 40) : ce) - ci).Trim();
                }
                int nl = Array.IndexOf(head, (byte)'\n', 0, Math.Min(hlen, 200));
                if (nl < 0) nl = Math.Min(hlen, 60);
                reqLine = Encoding.ASCII.GetString(head, 0, Math.Max(0, Math.Min(nl, 120))).Trim();
                await rs.WriteAsync(head, 0, hlen); await rs.FlushAsync();
                a.ReadTimeout = Timeout.Infinite;
                string upEnd = "-", downEnd = "-";
                Task t1 = Pump(a, rs, delegate(int n) { up += n; }, delegate(string w) { upEnd = w; });        // WU -> vchan
                Task t2 = Pump(rs, a, delegate(int n) { if (down == 0) ttfb = sw.ElapsedMilliseconds; down += n; }, delegate(string w) { downEnd = w; });
                endReasons = delegate() { return "upEnd=" + upEnd + " downEnd=" + downEnd; };
                Task first = await Task.WhenAny(t1, t2);
                eofSide = (first == t1) ? "client" : "tunnel";
                // HALF-CLOSE DRAIN. This was 3000 ms here and another 3000 ms in the handler, so
                // EVERY connection lived ~6 s after its data had arrived - measured: down=14524
                // ttfb=70 ms=6090, and down=0 ttfb=-1 ms=6138. A fixed tail is invisible on one
                // huge transfer (our own downloader pays it once for 4.8 GB and still sees
                // 13 MB/s) and crippling for Windows Update, which issues hundreds of small
                // ranged GETs and pays it on every one. The drain only needs to let an
                // already-finished direction flush, not to wait out a timeout.
                await Task.WhenAny(Task.WhenAll(t1, t2), Task.Delay(DrainMs()));
            }
        }
        catch (Exception e) { Log(logPath, "CONN token=" + token + " error " + e.Message); }
        finally { _gate.Release(); Log(logPath, "CONN warm=" + (warm ? 1 : 0) + " up=" + up + " down=" + down + " ttfb=" + ttfb + " ms=" + sw.ElapsedMilliseconds + " eof=" + eofSide + " " + (endReasons != null ? endReasons() : "upEnd=- downEnd=-") + " [" + connHdr + "] req=[" + reqLine + "]"); }
    }

    // Spawn one qrexec handler and complete its connect-back handshake. This is the expensive
    // part (dom0 policy + service start in the proxy qube), and the whole point of the pool is
    // to run it OFF the critical path.
    static async Task<Ready> OpenChannel(string self, string target, string user, string logPath)
    {
        string token = Guid.NewGuid().ToString("N");
        TcpListener control = new TcpListener(IPAddress.Loopback, 0);   // ephemeral
        control.Start();
        int cport = ((IPEndPoint)control.LocalEndpoint).Port;
        try
        {
            string handler = "\"" + self + "\" --relay " + cport + " " + token;
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = QrexecClientVm();
            // Do NOT wrap the whole pipe-string in quotes. qrexec-client-vm's GetArgument() splits
            // the RAW command line on '|' and does not strip quotes, so an outer quote leaks into
            // field 1 -> target parses as "@default, whose illegal '"' qrexec sanitizes to '_' ->
            // dom0 logs `target '_@default' does not exist, using @default instead` on every spawn.
            psi.Arguments = target + "|" + Service + "|" + user + "|" + handler;
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            Process.Start(psi);

            Task<TcpClient> accept = control.AcceptTcpClientAsync();
            if (await Task.WhenAny(accept, Task.Delay(20000)) != accept)
            { Log(logPath, "CHAN token=" + token + " relay never connected back"); return null; }
            TcpClient relay = accept.Result;
            NetworkStream rs = relay.GetStream();
            byte[] tk = Encoding.ASCII.GetBytes(token + "\n");
            byte[] got = new byte[tk.Length];
            if (!await ReadExact(rs, got, got.Length) || Encoding.ASCII.GetString(got) != token + "\n")
            { Log(logPath, "CHAN token=" + token + " bad token from relay"); relay.Close(); return null; }

            Ready r = new Ready();
            r.Relay = relay; r.Stream = rs; r.Token = token; r.Born = DateTime.UtcNow;
            return r;
        }
        catch (Exception e) { Log(logPath, "CHAN token=" + token + " error " + e.Message); return null; }
        finally { control.Stop(); }
    }

    // Take a channel that is still fresh AND still connected; drop the rest.
    static Ready TakeWarm()
    {
        Ready r;
        while (_pool.TryDequeue(out r))
        {
            bool stale = (DateTime.UtcNow - r.Born).TotalSeconds > PoolMaxAgeSeconds;
            bool dead = false;
            try { dead = !r.Relay.Connected; } catch { dead = true; }
            if (!stale && !dead) return r;
            try { r.Relay.Close(); } catch { }
        }
        return null;
    }

    // Keep the pool topped up. Spawns run concurrently, so the refill rate is not capped by the
    // 5-6 s each one takes.
    static async Task PoolFiller(string self, string target, string user, string logPath)
    {
        int target_n = PoolTarget();
        if (target_n <= 0) return;
        Log(logPath, "POOL warm channels target=" + target_n);
        while (true)
        {
            int pause = 0;
            // NOTE: no await inside catch - C# 5 forbids it, and the in-box csc is C# 5.
            try
            {
                int deficit = target_n - _pool.Count;
                if (deficit <= 0) { pause = 250; }
                else
                {
                    Task[] batch = new Task[Math.Min(deficit, 4)];
                    for (int i = 0; i < batch.Length; i++)
                    {
                        batch[i] = Task.Run(async delegate
                        {
                            Ready r = await OpenChannel(self, target, user, logPath);
                            if (r != null) _pool.Enqueue(r);
                        });
                    }
                    await Task.WhenAll(batch);
                }
            }
            catch { pause = 500; }
            if (pause > 0) await Task.Delay(pause);
        }
    }

    // ---- relay side (qrexec handler; stdio == vchan) -------------------------------------
    static int RunRelay(int controlPort, string token)
    {
        using (TcpClient sock = new TcpClient())
        {
            sock.Connect(IPAddress.Loopback, controlPort);
            NetworkStream ns = sock.GetStream();
            byte[] tk = Encoding.ASCII.GetBytes(token + "\n");
            ns.Write(tk, 0, tk.Length); ns.Flush();

            Stream vin = Console.OpenStandardInput();
            Stream vout = Console.OpenStandardOutput();
            Task t1 = Pump(ns, vout, delegate(int n) { }, null);   // socket (from WU) -> vchan out
            Task t2 = Pump(vin, ns, delegate(int n) { }, null);    // vchan in -> socket (to WU)
            Task.WhenAny(t1, t2).Wait();
            Task.WhenAny(Task.WhenAll(t1, t2), Task.Delay(DrainMs())).Wait();
        }
        return 0;
    }

    // ---- byte pump -----------------------------------------------------------------------
    // WHY A PUMP ENDED IS EVIDENCE, NOT NOISE. This used to swallow every exception with a bare
    // `catch {}` commented "normal teardown", which is true for a tunnel that has finished and
    // indistinguishable from a mid-body reset. Plain-HTTP responses are being TRUNCATED about half
    // the time - the same 80043-byte file arrives as anything from 17 KB up - and with the
    // exception discarded there was nothing in the log to say whether the copy stopped because the
    // peer was done or because it broke. Three hypotheses (the allowlist, the drain timeout, the
    // warm pool) were each refuted by measurement, so the next step is to stop guessing and record
    // the actual termination reason.
    static async Task Pump(Stream from, Stream to, Action<int> count, Action<string> ended)
    {
        byte[] buf = new byte[65536];
        try
        {
            int n;
            while ((n = await from.ReadAsync(buf, 0, buf.Length)) > 0)
            {
                await to.WriteAsync(buf, 0, n);
                await to.FlushAsync();
                count(n);
            }
            if (ended != null) ended("eof");
        }
        catch (Exception e)
        {
            if (ended != null) ended(e.GetType().Name + ":" + (e.Message ?? "").Replace('\n', ' ').Replace('\r', ' '));
        }
    }

    static async Task<bool> ReadExact(Stream s, byte[] buf, int len)
    {
        int off = 0;
        while (off < len)
        {
            int n = await s.ReadAsync(buf, off, len - off);
            if (n <= 0) return false;
            off += n;
        }
        return true;
    }

    static readonly object _logLock = new object();
    static void Log(string path, string msg)
    {
        try { lock (_logLock) File.AppendAllText(path, DateTime.Now.ToString("HH:mm:ss.fff") + " " + msg + "\r\n"); }
        catch { }
    }
}
