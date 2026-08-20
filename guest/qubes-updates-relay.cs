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
using System.Runtime.InteropServices;
using System.IO;
using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Collections.Concurrent;
using System.Collections.Generic;
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
    // Channels TakeWarm found stale/dead go here, NOT closed inline: the filler closes them PACED
    // (100 ms apart), off the request path. Without this, a sparse-active regime (every request finds
    // the whole pool aged past PoolAgeSeconds) would fire an up-to-8-wide grant-revoke BURST on a
    // client's critical path - the very burst the paced idle-drain exists to avoid.
    static readonly ConcurrentQueue<Ready> _toClose = new ConcurrentQueue<Ready>();

    // DEMAND LATCH + CHURN COUNTERS (2026-08-20). Per-channel churn is the suspected trigger of the
    // grant-revoke spin that intermittently wedges the guest, so the filler now warms the pool only
    // while there is DEMAND: an allowed, non-abandoned inbound within PoolIdleSeconds(). The latch
    // starts at "now" - this relay is only started for an update pass, so startup counts as demand and
    // the first-request prewarm (the filler start in RunListen) survives. NoteDemand() is called in
    // exactly two places, both strictly AFTER read-first and the allowlist, so abandoned sockets and
    // denied telemetry can never keep the pool warm.
    static long _lastDemandTicks = DateTime.UtcNow.Ticks;
    static void NoteDemand() { Interlocked.Exchange(ref _lastDemandTicks, DateTime.UtcNow.Ticks); }
    // _opened counts EVERY OpenChannel success - one open is one vchan channel whose grants are
    // permitted and later revoked (one open implies exactly one eventual close), so its growth RATE is
    // the churn this redesign reduces, counted at the single choke point every channel passes through.
    // All longs go through Interlocked: this can run as a 32-bit process, where long loads are not atomic.
    static long _opened = 0;
    static long _drained = 0;
    static long _deadAtTake = 0, _staleAtTake = 0;
    static long _warmHits = 0, _warmMisses = 0;

    static int PoolTarget()
    {
        int pt;
        if (int.TryParse(Environment.GetEnvironmentVariable("QUBES_UPDATES_POOL"), out pt) && pt >= 0) return pt;
        return 8;
    }
    // A pooled channel holds a proxy session open; the far end will eventually drop an idle one, so
    // treat anything older than this as stale. 25 was a GUESS. The CONN log says the tunnel side never
    // closes an active session first (eof=tunnel 0/342) and tinyproxy's request-read timeout defaults
    // to 600 s - but the compiled default does not move on inference: it stays 25 until
    // guest/wu-idle-tolerance.ps1 has MEASURED the real idle drop on this deployment, then it gets
    // bumped to just under the measured value. Override with QUBES_UPDATES_POOLAGE (the probe does).
    static int PoolAgeSeconds()
    {
        int s;
        if (int.TryParse(Environment.GetEnvironmentVariable("QUBES_UPDATES_POOLAGE"), out s) && s > 0) return s;
        return 25;
    }
    // How long with no demand before the filler stops warming and DRAINS the pool to zero. Measured
    // 2026-08-19: the always-on filler cycled ~8 channels per 25 s age-out with no traffic at all
    // (~4600 spawn/close cycles in 4 idle hours) - grant permit/revoke churn with zero benefit, in
    // exactly the regime suspected of wedging the guest. Override with QUBES_UPDATES_IDLESECS.
    // Keep IDLESECS >= POOLAGE: if POOLAGE is later raised above this, every think-gap in a pass would
    // trip a full drain+refill; raise IDLESECS alongside any POOLAGE bump.
    static int PoolIdleSeconds()
    {
        int s;
        if (int.TryParse(Environment.GetEnvironmentVariable("QUBES_UPDATES_IDLESECS"), out s) && s > 0) return s;
        return 60;
    }

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
            // Defender signature updates. Measured 2026-08-21: the FULL package is an ordinary
            // HTTPS GET (203 MB), NOT Delivery-Optimization-only as previously recorded - but the
            // version parameters are mandatory (the bare URL 404s), so the fwlink redirect has to be
            // followed to learn the current packageVersion/engineVersion.
            "definitionupdates.microsoft.com",  // the signature package itself - single purpose
            // NOTE, deliberately: go.microsoft.com is a general REDIRECTOR, so this is the widest
            // entry in the list - it can point the caller at many Microsoft properties, not one file
            // server. Added on the owner's explicit instruction (2026-08-21). The exposure stays
            // bounded by the two gates that already exist and must NOT be removed: the positional
            // peer allowlist (only the update process may use the proxy at all) and the temporal
            // gate (the proxy is torn down when the pass ends).
            "go.microsoft.com",             // ONLY to resolve the Defender fwlink redirect
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
            {
                // Optional --log so the HANDLER can record why its pumps stopped. It is spawned by
                // qrexec with no console anyone reads, so without a file it can only fail silently.
                string ld = null;
                for (int i = 3; i + 1 < args.Length; i++) if (args[i] == "--log") ld = args[i + 1];
                return RunRelay(int.Parse(args[1]), args[2], ld);
            }
            if (args.Length >= 1 && args[0] == "--listen")
                return RunListen(args);
            if (args.Length >= 1 && args[0] == "--selftest")
                return SelfTest();
            Console.Error.WriteLine("usage: qubes-updates-relay --listen [port] [--target VM] [--user U] [--log DIR]");
            Console.Error.WriteLine("       qubes-updates-relay --selftest                      (response-framing contract)");
            Console.Error.WriteLine("       qubes-updates-relay --relay <controlPort> <token>   (internal; spawned via qrexec)");
            return 2;
        }
        catch (Exception e) { Console.Error.WriteLine("FATAL " + e); return 1; }
    }

    // ---- SELFTEST: the response-framing contract ----------------------------------------
    // Runs ReadResponse against canned streams. No network, no qrexec, no PowerShell interop -
    // deterministic and fast, so it can gate a build. Every case here corresponds to a defect that
    // actually shipped (see the comments on MaxVerifyBytes and the honesty gate in HandlePlainHttp).
    // Re-introduce any of those defects and the matching case fails; that is the point of it.
    static int SelfTest()
    {
        int failed = 0;
        Func<byte[], byte[], byte[]> cat = delegate(byte[] x, byte[] y)
        {
            byte[] o = new byte[x.Length + y.Length];
            Buffer.BlockCopy(x, 0, o, 0, x.Length);
            Buffer.BlockCopy(y, 0, o, x.Length, y.Length);
            return o;
        };
        Action<string, bool> check = delegate(string name, bool ok)
        {
            Console.WriteLine((ok ? "PASS " : "FAIL ") + name);
            if (!ok) failed++;
        };

        // 1. A body past MaxVerifyBytes must arrive WHOLE (spill), not be cut at the mark.
        int big = 20 * 1024 * 1024;
        byte[] r1in = cat(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: " + big + "\r\n\r\n"), new byte[big]);
        MemoryStream c1 = new MemoryStream();
        HttpResponse r1 = ReadResponse(new MemoryStream(r1in), c1).Result;
        check("large: body delivered whole (" + r1.GotBody + "/" + big + ")", r1.GotBody >= big);
        // NOT "> 16MB": the truncating build still read one 64KB chunk past the mark before breaking,
        // so that comparison passed on a broken binary and proved nothing. Demand the client got the
        // ENTIRE response - headers plus every body byte - which only the spill path can deliver.
        check("large: client received the whole response (" + c1.Length + "/" + r1in.Length + ")", c1.Length == r1in.Length);
        check("large: spilled to client", r1.Streamed && c1.Length > 16 * 1024 * 1024);
        check("large: reported complete", r1.Complete);

        // 2. A short Content-Length body must read INCOMPLETE so the caller can refuse it.
        HttpResponse r2 = ReadResponse(
            new MemoryStream(cat(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Length: 5000\r\n\r\n"), new byte[1000])),
            new MemoryStream()).Result;
        check("short: reported incomplete", !r2.Complete);

        // 3. A terminated chunked body is COMPLETE. It used to report False, and the updater's
        //    give-up regex counted that false negative as a lost fetch.
        HttpResponse r3 = ReadResponse(
            new MemoryStream(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n0\r\n\r\n")),
            new MemoryStream()).Result;
        check("chunked: terminated reads complete", r3.Complete && r3.Chunked);

        // 4. A chunked body cut before its terminator is INCOMPLETE.
        HttpResponse r4 = ReadResponse(
            new MemoryStream(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n\r\n5\r\nhello\r\n")),
            new MemoryStream()).Result;
        check("chunked: truncated reads incomplete", !r4.Complete);

        // 5. Close-delimited: the clean close IS the framing, so it is complete.
        HttpResponse r5 = ReadResponse(
            new MemoryStream(Encoding.ASCII.GetBytes("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\n\r\nsome body bytes")),
            new MemoryStream()).Result;
        check("close-delimited: complete on EOF", r5.Complete);

        Console.WriteLine(failed == 0 ? "=== SELFTEST OK ===" : ("=== SELFTEST FAILED (" + failed + ") ==="));
        return failed == 0 ? 0 : 1;
    }

    static string QrexecClientVm()
    {
        string v = Environment.GetEnvironmentVariable("QREXEC_CLIENT_VM");
        if (string.IsNullOrEmpty(v)) v = @"C:\Program Files\Qubes Tools\bin\qrexec-client-vm.exe";
        return Environment.ExpandEnvironmentVariables(v);
    }

    // ---- POSITIONAL access control ------------------------------------------------------
    //
    // The proxy must be reachable BY THE UPDATE PROCESS, not BY ANYTHING THAT HAPPENS TO RUN
    // WHILE AN UPDATE IS IN FLIGHT. Time-scoping ("the proxy is only up during a pass") is not
    // access control: while it is up, every background HTTP client in the guest discovers the
    // system proxy and phones home - measured on an "offline" guest as 147 dom0
    // qubes.UpdatesProxy policy hits in one afternoon, still dripping hours after the last scan.
    //
    // BOTH GATES ARE KEPT, deliberately (user, 2026-08-15). This positional gate does NOT
    // replace the temporal one - the pass still brings the proxy up only for its own duration and
    // tears it down afterwards (Ensure-Proxy / Remove-Proxy, "proxy removed, relay stopped").
    // They fail differently, which is the point: the positional gate depends on our own
    // process-identity logic being right, and if it is ever wrong - a new svchost split, a
    // service we did not anticipate, a bug in the TCP-table lookup - the temporal gate still
    // bounds the exposure to the minutes a pass takes. And if a pass is somehow left open, the
    // positional gate still refuses everything that is not the update. Neither is sufficient
    // alone; removing either because the other exists is the mistake to avoid.
    //
    // The relay is the only place that can tell WHO is calling, so it decides. Each accepted
    // connection is mapped back to the owning process through the TCP table, and only processes
    // that ARE the update are served: the service host running Windows Update / Delivery
    // Optimization / BITS / Defender, the servicing stack, and our own agent. Everything else is
    // refused and logged by name, so a denial is diagnosable rather than mysterious.
    //
    // QUBES_UPDATES_PEER_ALLOWLIST=off disables the check (diagnostics only - it restores the
    // old, purely temporal behaviour).
    [DllImport("iphlpapi.dll", SetLastError = true)]
    static extern uint GetExtendedTcpTable(IntPtr table, ref int size, bool order, int af,
                                           int tableClass, int reserved);

    [StructLayout(LayoutKind.Sequential)]
    struct MIB_TCPROW_OWNER_PID
    {
        public uint state; public uint localAddr; public uint localPort;
        public uint remoteAddr; public uint remotePort; public uint owningPid;
    }

    const uint ERROR_INSUFFICIENT_BUFFER = 122;
    internal const int PidLookupFailed = -2;   // distinct from -1 "scanned, no such port"

    // Returns the owning PID of a local port, -1 if the port is genuinely not in the table, or
    // PidLookupFailed if the table could not be read at all.
    //
    // THE RACE THIS EXISTS TO SURVIVE: the table is sized by one call and fetched by a second, and
    // ANY process opening a socket in between makes it grow - the fetch then fails with
    // ERROR_INSUFFICIENT_BUFFER. That used to `return -1`, which the caller reads as "not an update
    // process" and answers with an RST. A LEGITIMATE Windows Update connection was therefore denied
    // at random, and Windows concluded it had no internet. Re-size and retry, with slack on top so
    // the common case does not even need a second pass. Still fail-CLOSED: a lookup that never
    // succeeds denies, it just says so distinctly instead of masquerading as a verdict.
    static int PidForLocalPort(int port)
    {
        // AF_INET=2, TCP_TABLE_OWNER_PID_ALL=5. Ports in the table are big-endian in the low word.
        for (int attempt = 0; attempt < 5; attempt++)
        {
            int size = 0;
            GetExtendedTcpTable(IntPtr.Zero, ref size, true, 2, 5, 0);
            if (size <= 0) continue;
            size += 16 * 1024;   // room for rows added between the sizing call and the fetch
            IntPtr buf = Marshal.AllocHGlobal(size);
            try
            {
                uint rc = GetExtendedTcpTable(buf, ref size, true, 2, 5, 0);
                if (rc == ERROR_INSUFFICIENT_BUFFER) continue;   // grew again - size it afresh
                if (rc != 0) return PidLookupFailed;
                int rows = Marshal.ReadInt32(buf);
                IntPtr row = (IntPtr)((long)buf + 4);
                int rowSize = Marshal.SizeOf(typeof(MIB_TCPROW_OWNER_PID));
                for (int i = 0; i < rows; i++)
                {
                    MIB_TCPROW_OWNER_PID r = (MIB_TCPROW_OWNER_PID)Marshal.PtrToStructure(row, typeof(MIB_TCPROW_OWNER_PID));
                    int p = (int)(((r.localPort & 0xFF) << 8) | ((r.localPort & 0xFF00) >> 8));
                    if (p == port) return (int)r.owningPid;
                    row = (IntPtr)((long)row + rowSize);
                }
                return -1;   // the table WAS read; this port simply is not in it
            }
            finally { Marshal.FreeHGlobal(buf); }
        }
        return PidLookupFailed;
    }

    // PIDs that ARE the update: the hosts of the update-related services, plus this process and
    // whatever launched it (our agent drives catalog downloads through this same relay).
    static readonly string[] BuiltinServices = { "wuauserv", "DoSvc", "BITS", "WinDefend", "cryptsvc", "TrustedInstaller" };
    static readonly string[] BuiltinImages   = { "MpCmdRun", "TiWorker", "TrustedInstaller", "dism", "DismHost", "MsMpEng" };

    // GRANULAR POLICY. Because the decision is made by identity rather than by time, access can
    // be granted to one more updater without opening the proxy to everything else. Two
    // REG_MULTI_SZ values under HKLM\SOFTWARE\Qubes\UpdatesProxy extend the built-in sets:
    //     AllowedImages    process names, without .exe   (e.g. "MyVendorUpdater")
    //     AllowedServices  service names                 (e.g. "MyVendorUpdateSvc")
    // They are ADDITIVE and re-read every few seconds, so a qube can be granted a third-party
    // updater by policy - per qube, per updater - instead of by leaving a hole open in time.
    static string[] PolicyList(string valueName)
    {
        try
        {
            using (Microsoft.Win32.RegistryKey k = Microsoft.Win32.Registry.LocalMachine.OpenSubKey(
                       @"SOFTWARE\Qubes\UpdatesProxy"))
            {
                if (k == null) return new string[0];
                string[] v = k.GetValue(valueName) as string[];
                return v ?? new string[0];
            }
        }
        catch { return new string[0]; }
    }

    static string[] UpdateServices
    {
        get
        {
            List<string> l = new List<string>(BuiltinServices);
            l.AddRange(PolicyList("AllowedServices"));
            return l.ToArray();
        }
    }
    static string[] UpdateImages
    {
        get
        {
            List<string> l = new List<string>(BuiltinImages);
            l.AddRange(PolicyList("AllowedImages"));
            return l.ToArray();
        }
    }

    // A denied client retries, and a log line per retry buries everything else. One line per
    // distinct caller per minute keeps the signal ("who was refused") without the noise.
    static readonly Dictionary<string, DateTime> _denyLogged = new Dictionary<string, DateTime>();
    static void DenyLog(string logPath, string who)
    {
        lock (_denyLogged)
        {
            DateTime last;
            if (_denyLogged.TryGetValue(who, out last) && (DateTime.UtcNow - last).TotalSeconds < 60) return;
            _denyLogged[who] = DateTime.UtcNow;
        }
        Log(logPath, "DENY " + who + " - not part of the update. The proxy serves the update process only; "
                     + "this caller sees an unreachable proxy, exactly as it would on an offline guest.");
    }

    static bool PeerIsUpdate(int pid, out string why)
    {
        why = "pid " + pid;
        if (pid <= 0) { why = "unknown pid"; return false; }
        try
        {
            Process p = Process.GetProcessById(pid);
            why = p.ProcessName + " (pid " + pid + ")";
            if (pid == Process.GetCurrentProcess().Id) return true;
            foreach (string img in UpdateImages)
                if (string.Equals(p.ProcessName, img, StringComparison.OrdinalIgnoreCase)) return true;
            // svchost hosts many services, and the socket cannot say which one - so ask the SCM
            // which PIDs host the update services and compare. Cached: this runs per connection.
            string svcName = ServiceHostedBy(pid);
            if (svcName != null) { why = p.ProcessName + " hosting " + svcName + " (pid " + pid + ")"; return true; }
            // Our own agent: PowerShell running the updater, and whatever it spawns.
            if (string.Equals(p.ProcessName, "powershell", StringComparison.OrdinalIgnoreCase) ||
                string.Equals(p.ProcessName, "qubes-updates-relay", StringComparison.OrdinalIgnoreCase))
                return true;
        }
        catch (Exception e) { why = "pid " + pid + " (" + e.GetType().Name + ")"; }
        return false;
    }

    // SCM directly, not WMI and not System.ServiceProcess: this file is compiled on the guest by
    // the in-box csc with no references, and it must stay that way.
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr OpenSCManagerW(string machine, string database, uint access);
    [DllImport("advapi32.dll", SetLastError = true, CharSet = CharSet.Unicode)]
    static extern IntPtr OpenServiceW(IntPtr scm, string service, uint access);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool QueryServiceStatusEx(IntPtr svc, int level, IntPtr buf, int bufSize, out int needed);
    [DllImport("advapi32.dll", SetLastError = true)]
    static extern bool CloseServiceHandle(IntPtr h);

    static readonly object _svcLock = new object();
    static Dictionary<int, string> _svcPids = new Dictionary<int, string>();
    static DateTime _svcPidsAt = DateTime.MinValue;

    static string ServiceHostedBy(int pid)
    {
        lock (_svcLock)
        {
            if ((DateTime.UtcNow - _svcPidsAt).TotalSeconds > 5)
            {
                Dictionary<int, string> fresh = new Dictionary<int, string>();
                IntPtr scm = OpenSCManagerW(null, null, 0x0004 /*SC_MANAGER_ENUMERATE_SERVICE*/);
                if (scm != IntPtr.Zero)
                {
                    foreach (string svc in UpdateServices)
                    {
                        IntPtr h = OpenServiceW(scm, svc, 0x0004 /*SERVICE_QUERY_STATUS*/);
                        if (h == IntPtr.Zero) continue;
                        int needed = 0;
                        int size = 64;   // SERVICE_STATUS_PROCESS
                        IntPtr buf = Marshal.AllocHGlobal(size);
                        try
                        {
                            if (QueryServiceStatusEx(h, 0 /*SC_STATUS_PROCESS_INFO*/, buf, size, out needed))
                            {
                                int servicePid = Marshal.ReadInt32(buf, 28);   // dwProcessId
                                if (servicePid > 0) fresh[servicePid] = svc;
                            }
                        }
                        finally { Marshal.FreeHGlobal(buf); CloseServiceHandle(h); }
                    }
                    CloseServiceHandle(scm);
                }
                _svcPids = fresh;
                _svcPidsAt = DateTime.UtcNow;
            }
            string name;
            return _svcPids.TryGetValue(pid, out name) ? name : null;
        }
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
            if (!"off".Equals(Environment.GetEnvironmentVariable("QUBES_UPDATES_PEER_ALLOWLIST"),
                              StringComparison.OrdinalIgnoreCase))
            {
                int peerPort = ((IPEndPoint)inbound.Client.RemoteEndPoint).Port;
                int peerPid = PidForLocalPort(peerPort);
                string who;
                if (!PeerIsUpdate(peerPid, out who))
                {
                    // Say WHICH kind of denial this is. A lookup that never completed is an
                    // infrastructure failure denying a possibly-legitimate caller, not a policy
                    // decision about a known process, and it must not read like one in the log.
                    if (peerPid == PidLookupFailed) who = "pid-lookup-failed(port " + peerPort + ")";
                    // LOOK UNREACHABLE, NOT BROKEN. A denied caller must see what it would see on
                    // a guest with no network at all - a connection that does not come up - and
                    // NOT a proxy that accepts and then breaks mid-protocol. So: abort with RST
                    // (SO_LINGER 0) rather than a graceful close, and do it before reading a byte.
                    // The client gets a connection reset at connect time, backs off the way it
                    // does when a proxy is unreachable, and Windows reports no internet - the
                    // correct state for an offline qube - instead of retrying against something
                    // that half-answers. It also fails FAST: never a hang waiting for a timeout.
                    try { inbound.Client.LingerState = new LingerOption(true, 0); } catch { }
                    try { inbound.Close(); } catch { }
                    DenyLog(logPath, who);
                    continue;
                }
            }
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

        // PLAIN HTTP GETS VERIFIED AND RETRIED; CONNECT IS LEFT ALONE.
        //
        // Measured 2026-08-14 with both ends instrumented: this qube hands the FULL body to the
        // transport every time (30/30 sends of 80321/80454 bytes, verified by a byte-counting shim
        // in the proxy qube) while the Windows guest receives a short body on about a THIRD of
        // them - 20/30 full, the rest anywhere from 20883 to 77135. Every send ends in a clean EOF,
        // so nothing here or in tinyproxy truncates it; the bytes are lost inside the qrexec/vchan
        // hop. It survives with our relay removed entirely (guest/proxy-probe.cs), so it is not the
        // pool, the drain or the teardown.
        //
        // Why it matters far more than a third of a file: this is how Windows refreshes its
        // certificate trust list on a FRESH image. A short authrootstl.cab means TLS validation of
        // the update endpoints fails, the WU searcher dies with 0x80072F8F, and the whole update
        // feature is dead before the agent logs a line. Once ONE complete CTL lands, Windows caches
        // it and the failure vanishes - which is exactly why the same build worked at 09:53 and
        // failed all afternoon on rebuilt clones. Luck, not configuration.
        //
        // CONNECT is untouched: it carries our .msu downloads, moved 4.8 GB byte-perfect through
        // this same transport, and is opaque to us by construction.
        if (!IsConnect(head, hlen))
        {
            await HandlePlainHttp(inbound, head, hlen, self, target, user, logPath);
            return;
        }

        // Past read-first AND the allowlist: this is real, allowed demand - keep the pool warm.
        NoteDemand();
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
            Ready ch = TakeWarm(logPath);
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

    static bool IsConnect(byte[] head, int hlen)
    {
        if (hlen < 7) return false;
        string s = Encoding.ASCII.GetString(head, 0, Math.Min(hlen, 8));
        return s.StartsWith("CONNECT", StringComparison.OrdinalIgnoreCase);
    }

    static int PlainRetries()
    {
        int r;
        if (int.TryParse(Environment.GetEnvironmentVariable("QUBES_UPDATES_RETRIES"), out r) && r >= 0) return r;
        return 4;
    }
    // Only bodies up to this are BUFFERED for verification. Larger ones are not truncated: once the
    // buffer would pass this mark the response SPILLS to the client and the rest is pumped straight
    // through (see ReadResponse). Buffering exists to make a retry possible, and a retry is only
    // possible while nothing has been written to the client yet.
    //
    // It used to `break` here instead, which silently CUT every large response at exactly 16 MB and
    // handed it over as a 200. Measured 2026-08-20 from the updater log - the resume ladder is the
    // fingerprint, at exact 16 MB multiples:
    //     stream ended early at 16 / 32.1 / 48.1 of 75.6 MB
    //     stream ended early at 16.1 / 32.1 / 48.1 / 64.2 / 80.2 of 85.2 MB
    // Fetch-Msu's 14-attempt resume loop was compensating for OUR OWN cap, and its comment blaming
    // "the relay intermittently churns its warm channel" was wrong. A file needs ceil(size/16MB)
    // attempts that way, so anything past ~224 MB could never complete inside the attempt budget -
    // the 776 MB November CU could not have downloaded through here at all.
    const int MaxVerifyBytes = 16 * 1024 * 1024;

    // Read one HTTP response off the tunnel, and say whether it arrived COMPLETE.
    //
    // Completeness is judged per FRAMING, so the answer is honest for all three shapes rather than
    // only for Content-Length (which used to log every chunked reply as complete=False, and that
    // false negative is counted by the updater's give-up regex - a genuine 0-update scan that
    // happened to overlap a chunked response could be read as a relay failure):
    //     Content-Length   -> complete when that many body bytes arrived
    //     chunked          -> complete when the terminating zero-length chunk arrived
    //     close-delimited  -> complete when the peer closed cleanly; EOF *is* the framing
    //
    // SPILL: a response past MaxVerifyBytes is neither truncated nor held in memory. At the mark,
    // everything buffered is written to `client` and the remainder is pumped straight through. From
    // that point the response is COMMITTED (Streamed=true) - the bytes are already on the client's
    // wire, so the caller must neither retry it nor write it a second time.
    class HttpResponse
    {
        public byte[] Bytes;
        public bool HeadersFound;   // did a complete header block arrive at all?
        public bool LengthKnown;    // ...and did it carry a Content-Length?
        public bool Chunked;
        public bool Complete;
        public bool Streamed;       // spilled to the client: committed, unretryable
        public long Expected;
        public long GotBody;
    }

    // Keep the last few bytes seen, so the chunked terminator can still be spotted after a spill
    // has emptied the buffer.
    static void TailPush(byte[] tail, ref int tailLen, byte[] src, int srcLen)
    {
        for (int i = Math.Max(0, srcLen - tail.Length); i < srcLen; i++)
        {
            if (tailLen < tail.Length) { tail[tailLen++] = src[i]; }
            else { Array.Copy(tail, 1, tail, 0, tail.Length - 1); tail[tail.Length - 1] = src[i]; }
        }
    }

    static bool IsChunkTerminator(byte[] b, int len)
    {
        // "0\r\n\r\n"
        if (len < 5) return false;
        return b[len - 5] == (byte)'0' && b[len - 4] == 13 && b[len - 3] == 10
            && b[len - 2] == 13 && b[len - 1] == 10;
    }

    static async Task<HttpResponse> ReadResponse(Stream rs, Stream client)
    {
        MemoryStream buf = new MemoryStream();
        byte[] tmp = new byte[65536];
        int headerEnd = -1;
        long expected = -1;
        bool chunked = false;
        bool chunkDone = false;
        bool spilled = false;
        bool sawEof = false;
        long got = 0;                  // body bytes seen, buffered or streamed
        byte[] tail = new byte[5];
        int tailLen = 0;

        while (true)
        {
            int n = await rs.ReadAsync(tmp, 0, tmp.Length);
            if (n <= 0) { sawEof = true; break; }

            if (spilled)
            {
                await client.WriteAsync(tmp, 0, n);
                got += n;
                TailPush(tail, ref tailLen, tmp, n);
                if (chunked && IsChunkTerminator(tail, tailLen)) { chunkDone = true; break; }
            }
            else
            {
                buf.Write(tmp, 0, n);
                if (headerEnd < 0)
                {
                    byte[] cur = buf.GetBuffer();
                    int len = (int)buf.Length;
                    for (int i = 3; i < len; i++)
                    {
                        if (cur[i - 3] == 13 && cur[i - 2] == 10 && cur[i - 1] == 13 && cur[i] == 10) { headerEnd = i + 1; break; }
                    }
                    if (headerEnd > 0)
                    {
                        string hdrs = Encoding.ASCII.GetString(cur, 0, headerEnd);
                        foreach (string line in hdrs.Split('\n'))
                        {
                            string t = line.Trim();
                            if (t.StartsWith("Content-Length:", StringComparison.OrdinalIgnoreCase))
                            {
                                long v;
                                if (long.TryParse(t.Substring(15).Trim(), out v)) expected = v;
                            }
                            else if (t.StartsWith("Transfer-Encoding:", StringComparison.OrdinalIgnoreCase)
                                     && t.IndexOf("chunked", StringComparison.OrdinalIgnoreCase) >= 0)
                            {
                                chunked = true;
                            }
                        }
                    }
                }
                if (headerEnd > 0)
                {
                    got = buf.Length - headerEnd;
                    if (chunked)
                    {
                        byte[] cur = buf.GetBuffer();
                        if (IsChunkTerminator(cur, (int)buf.Length)) { chunkDone = true; break; }
                    }
                }
            }

            if (headerEnd > 0 && expected >= 0 && got >= expected) break;

            // Spill point: hand over what we have and pump the rest, rather than cutting the body.
            if (!spilled && headerEnd > 0 && buf.Length > MaxVerifyBytes)
            {
                if (client == null) break;   // nowhere to spill: stop rather than grow unbounded
                byte[] all = buf.ToArray();
                await client.WriteAsync(all, 0, all.Length);
                await client.FlushAsync();
                TailPush(tail, ref tailLen, all, all.Length);
                buf.SetLength(0);
                spilled = true;
            }
        }

        HttpResponse r = new HttpResponse();
        r.Bytes = spilled ? new byte[0] : buf.ToArray();
        r.Streamed = spilled;
        r.Expected = expected;
        r.HeadersFound = (headerEnd > 0);
        r.LengthKnown = (headerEnd > 0 && expected >= 0);
        r.Chunked = chunked;
        r.GotBody = got;
        if (r.LengthKnown) r.Complete = (got >= expected);
        else if (chunked) r.Complete = chunkDone;
        else r.Complete = (headerEnd > 0 && sawEof);   // close-delimited: the close is the framing
        return r;
    }

    // Plain-HTTP path: send the request, verify the response is whole, and re-issue on a FRESH
    // channel if the transport lost part of it. Nothing is written to the client until a complete
    // response is in hand, so a short body is never handed to Windows as if it were the file.
    static async Task HandlePlainHttp(TcpClient inbound, byte[] head, int hlen,
                                      string self, string target, string user, string logPath)
    {
        NoteDemand();   // allowed plain-HTTP demand (read-first + allowlist already passed in HandleInbound)
        await _gate.WaitAsync();
        Stopwatch sw = Stopwatch.StartNew();
        string reqLine = "";
        int nl0 = Array.IndexOf(head, (byte)'\n', 0, Math.Min(hlen, 200));
        if (nl0 < 0) nl0 = Math.Min(hlen, 60);
        reqLine = Encoding.ASCII.GetString(head, 0, Math.Max(0, Math.Min(nl0, 120))).Trim();
        HttpResponse best = null;
        int attempts = 0;
        try
        {
            using (inbound)
            {
                NetworkStream a = inbound.GetStream();
                int maxTries = PlainRetries() + 1;
                // A DEAD WARM CHANNEL IS NOT A FAILED REQUEST. Measured 2026-08-15 during a
                // Windows Update metadata sync: attempts failed at ~400 ms intervals with
                // bytes=0 headers=False, then a later attempt on a fresh channel returned the
                // file intact - the pooled channel had already been closed at the far end, so
                // the write went nowhere and the read saw EOF. Counting those against the retry
                // budget burned all five attempts on dead channels and handed Windows Update an
                // empty metadata file, which is how a scan can report "0 updates available"
                // while the guest is in fact behind. Give dead channels their own bounded
                // allowance and stop drawing from the pool for the rest of this request.
                int deadChannels = 0;
                const int MaxDeadChannels = 8;   // the pool target; cannot outlive the pool
                bool avoidWarm = false;
                for (attempts = 1; attempts <= maxTries; )
                {
                    Ready ch = avoidWarm ? null : TakeWarm(logPath);
                    bool wasWarm = ch != null;
                    if (ch == null) ch = await OpenChannel(self, target, user, logPath);
                    if (ch == null) break;
                    HttpResponse r = null;
                    using (ch.Relay)
                    {
                        try
                        {
                            await ch.Stream.WriteAsync(head, 0, hlen);
                            await ch.Stream.FlushAsync();
                            r = await ReadResponse(ch.Stream, a);
                        }
                        catch (Exception e) { Log(logPath, "PLAIN read error " + e.GetType().Name + ": " + e.Message); }
                    }
                    // A spilled response is already on the client's wire. It cannot be retried and it
                    // must not be written again - it IS the answer, complete or not, and the log below
                    // says which.
                    if (r != null && r.Streamed) { best = r; break; }
                    if (r != null && (best == null || r.Bytes.Length > best.Bytes.Length)) best = r;
                    // ACCEPT only a response that actually ARRIVED. The first version of this
                    // accepted `!LengthKnown` as "unverifiable, pass it through", which silently
                    // exempted the worst case: an EMPTY response has no headers, so LengthKnown is
                    // false and a zero-byte reply was handed straight to Windows without a retry.
                    // That is exactly how the first cold-cache pass still failed - the trust-list
                    // fetch came back with 0 bytes, tries=1, and the searcher died on 0x80072F8F.
                    // Headers must be present; then either the body is complete, or there was no
                    // Content-Length to check it against (chunked / close-delimited), which stays
                    // pass-through rather than being retried on a guess.
                    // Complete is now framing-aware (Content-Length / chunked terminator / clean EOF),
                    // so this no longer has to exempt "unknown length" wholesale - a truncated chunked
                    // body is caught instead of being waved through as unverifiable.
                    bool usable = r != null && r.HeadersFound && r.Complete;
                    if (usable) break;
                    // Nothing at all came back on a channel we took from the pool: that is the
                    // channel, not the server. Retry on a fresh one without spending an attempt.
                    if (wasWarm && (r == null || (!r.HeadersFound && r.Bytes.Length == 0)) &&
                        deadChannels < MaxDeadChannels)
                    {
                        deadChannels++;
                        avoidWarm = true;
                        Log(logPath, "PLAIN dead warm channel (" + deadChannels + ") - fresh channel, attempt " + attempts + " not spent");
                        continue;
                    }
                    attempts++;
                    Log(logPath, "PLAIN incomplete attempt=" + (attempts - 1)
                                 + " bytes=" + (r == null ? -1 : r.Bytes.Length)
                                 + " headers=" + (r != null && r.HeadersFound)
                                 + " got=" + (r == null ? -1 : r.GotBody)
                                 + " expected=" + (r == null ? -1 : r.Expected) + " - retrying on a fresh channel");
                }
                // THE HONESTY GATE. This used to write `best` whenever it held any bytes at all, which
                // contradicted this function's own contract ("nothing is written to the client until a
                // complete response is in hand") and handed Windows a SHORT body under a 200 - the
                // failure mode the retry loop above exists to prevent. A response leaves here only if
                // it is complete; otherwise the client is told plainly that the fetch failed.
                if (best != null && best.Streamed)
                {
                    // Already delivered by the spill path; nothing left to write.
                }
                else if (best != null && best.HeadersFound && best.Complete && best.Bytes.Length > 0)
                {
                    await a.WriteAsync(best.Bytes, 0, best.Bytes.Length);
                    await a.FlushAsync();
                }
                else
                {
                    byte[] err = Encoding.ASCII.GetBytes(
                        "HTTP/1.1 502 Bad Gateway\r\nContent-Length: 0\r\nConnection: close\r\n\r\n");
                    await a.WriteAsync(err, 0, err.Length);
                    await a.FlushAsync();
                    Log(logPath, "PLAIN REFUSED after " + attempts + " attempt(s) - 502 to client"
                               + " bytes=" + (best == null ? 0 : best.Bytes.Length)
                               + " body=" + (best == null ? 0 : best.GotBody)
                               + "/" + (best == null ? -1 : best.Expected)
                               + " headers=" + (best != null && best.HeadersFound)
                               + " chunked=" + (best != null && best.Chunked)
                               + " req=[" + reqLine + "]");
                }
            }
        }
        catch (Exception e) { Log(logPath, "PLAIN error " + e.Message); }
        finally
        {
            _gate.Release();
            Log(logPath, "PLAIN tries=" + attempts + " bytes=" + (best == null ? 0 : best.Bytes.Length)
                       + " body=" + (best == null ? 0 : best.GotBody) + "/" + (best == null ? -1 : best.Expected)
                       + " complete=" + (best != null && best.Complete)
                       + " streamed=" + (best != null && best.Streamed)
                       + " chunked=" + (best != null && best.Chunked)
                       + " ms=" + sw.ElapsedMilliseconds + " req=[" + reqLine + "]");
        }
    }

    // Spawn one qrexec handler and complete its connect-back handshake. This is the expensive
    // part (dom0 policy + service start in the proxy qube), and the whole point of the pool is
    // to run it OFF the critical path. Every success is counted in _opened - one open is one vchan
    // channel that will eventually be torn down, so _opened's growth rate is the grant churn.
    static async Task<Ready> OpenChannel(string self, string target, string user, string logPath)
    {
        string token = Guid.NewGuid().ToString("N");
        TcpListener control = new TcpListener(IPAddress.Loopback, 0);   // ephemeral
        control.Start();
        int cport = ((IPEndPoint)control.LocalEndpoint).Port;
        TcpClient relay = null;   // hoisted: the catch must close an accepted-but-failed socket
        try
        {
            string handlerLogDir = "";
            try { handlerLogDir = Path.GetDirectoryName(logPath); } catch { handlerLogDir = ""; }
            string handler = "\"" + self + "\" --relay " + cport + " " + token
                           + (string.IsNullOrEmpty(handlerLogDir) ? "" : " --log \"" + handlerLogDir + "\"");
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
            {
                Log(logPath, "CHAN token=" + token + " relay never connected back");
                // A connect-back that lands AFTER the timeout would orphan the accepted socket (and
                // its handler) - 'return null' is not an exception, so the catch below never runs.
                // Close it whenever it eventually arrives. Fire-and-forget by design (CS4014 suppressed).
#pragma warning disable 4014
                accept.ContinueWith(delegate(Task<TcpClient> t) {
                    if (t.Status == TaskStatus.RanToCompletion) { try { t.Result.Close(); } catch { } }
                });
#pragma warning restore 4014
                return null;
            }
            relay = accept.Result;
            NetworkStream rs = relay.GetStream();
            byte[] tk = Encoding.ASCII.GetBytes(token + "\n");
            byte[] got = new byte[tk.Length];
            if (!await ReadExact(rs, got, got.Length) || Encoding.ASCII.GetString(got) != token + "\n")
            { Log(logPath, "CHAN token=" + token + " bad token from relay"); relay.Close(); return null; }

            Ready r = new Ready();
            r.Relay = relay; r.Stream = rs; r.Token = token; r.Born = DateTime.UtcNow;
            Interlocked.Increment(ref _opened);
            return r;
        }
        catch (Exception e)
        {
            Log(logPath, "CHAN token=" + token + " error " + e.Message);
            // An exception between accept and return used to LEAK the accepted connect-back socket:
            // nothing owned it, so it - and the handler pumping into it - lingered. Close is
            // synchronous, so this is legal in a C# 5 catch (no await here).
            if (relay != null) { try { relay.Close(); } catch { } }
            return null;
        }
        finally { control.Stop(); }
    }

    // Take a channel that is still fresh AND still connected; defer the rest to the filler's PACED
    // close (via _toClose), so a sparse-active request never fires an 8-wide revoke burst inline.
    //
    // "Connected" is a CACHED snapshot of the last socket op, so it lies about a peer that closed
    // while the channel sat pooled - and a longer pool age makes far-end drops MORE likely, not less.
    // So ask the socket: Poll(0, SelectRead) is non-blocking and fires on a DELIVERED FIN or on
    // unsolicited queued bytes, either of which disqualifies a virgin channel (tinyproxy never speaks
    // before a request). A far-end drop propagates all the way here (tinyproxy close -> vchan EOF ->
    // handler exits -> FIN on the connect-back socket) - exactly the death this must catch before
    // handing the channel to a CONNECT client that has no dead-warm retry. Poll cannot see an
    // UNdelivered FIN; the plain-HTTP dead-warm allowance stays behind this as the backstop. Discards
    // are logged WITH AGE: the dead-age distribution is the in-band data that refines POOLAGE.
    static Ready TakeWarm(string logPath)
    {
        Ready r;
        while (_pool.TryDequeue(out r))
        {
            double age = (DateTime.UtcNow - r.Born).TotalSeconds;
            bool stale = age > PoolAgeSeconds();
            bool dead = false;
            try
            {
                Socket s = r.Relay.Client;
                dead = (s == null) || !r.Relay.Connected || s.Poll(0, SelectMode.SelectRead);
            }
            catch { dead = true; }
            if (!stale && !dead) { Interlocked.Increment(ref _warmHits); return r; }
            if (dead) Interlocked.Increment(ref _deadAtTake); else Interlocked.Increment(ref _staleAtTake);
            Log(logPath, "POOL discard reason=" + (dead ? "dead" : "stale") + " age=" + (int)age + "s");
            _toClose.Enqueue(r);   // filler closes it PACED, off this request's critical path
        }
        Interlocked.Increment(ref _warmMisses);
        return null;
    }

    // Keep the pool topped up WHILE THERE IS DEMAND; drain it to nothing when there is none, and close
    // TakeWarm's deferred victims PACED. Spawns run concurrently, so the refill rate is not capped by
    // the 5-6 s each one takes.
    //
    // Idle = no allowed inbound for PoolIdleSeconds(). While idle the relay holds ZERO pooled channels,
    // handlers, vchans, or grants, and spends zero permit/revoke cycles. Every close (the idle drain AND
    // TakeWarm's _toClose victims) is PACED 100 ms apart on this background task, never on a connection's
    // critical path - insurance in case the wedge is triggered by revoke BURSTS rather than sustained
    // churn. The drain is also the ONLY eviction (staleness lives solely in TakeWarm, which runs only on
    // a request), so without it an idle pool would sit on 8 aging channels forever. Demand resumption is
    // noticed within <=1 s; the first post-idle request pays a cold open (it cannot wait for the filler)
    // and the pool is warm for the burst that follows. While there IS demand, the 2026-08-13
    // deficit/batch-of-4 refill is unchanged, so burst throughput is protected.
    static async Task PoolFiller(string self, string target, string user, string logPath)
    {
        int target_n = PoolTarget();
        if (target_n <= 0) return;
        Log(logPath, "POOL warm channels target=" + target_n);
        Log(logPath, "POOL policy age=" + PoolAgeSeconds() + "s idle=" + PoolIdleSeconds() + "s");
        DateTime lastStat = DateTime.UtcNow;
        while (true)
        {
            int pause = 0;
            // NOTE: no await inside catch - C# 5 forbids it, and the in-box csc is C# 5.
            try
            {
                // Close a few of TakeWarm's deferred victims, PACED, off any request path.
                Ready v; int vc = 0;
                while (vc < 4 && _toClose.TryDequeue(out v))
                { try { v.Relay.Close(); } catch { } Interlocked.Increment(ref _drained); vc++; await Task.Delay(100); }

                bool idle = (DateTime.UtcNow.Ticks - Interlocked.Read(ref _lastDemandTicks))
                            > (long)PoolIdleSeconds() * TimeSpan.TicksPerSecond;
                if (idle)
                {
                    Ready victim; int d = 0;
                    while (_pool.TryDequeue(out victim))
                    { try { victim.Relay.Close(); } catch { } d++; Interlocked.Increment(ref _drained); await Task.Delay(100); }
                    if (d > 0) Log(logPath, "POOL drain n=" + d + " idle");
                    pause = 1000;
                }
                else
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
                // Stat in BOTH branches (every 60 s) so an idle soak's 'opened= flat' is observable.
                if ((DateTime.UtcNow - lastStat).TotalSeconds >= 60)
                {
                    lastStat = DateTime.UtcNow;
                    Log(logPath, "POOL stat target=" + target_n + " pool=" + _pool.Count
                               + " opened=" + Interlocked.Read(ref _opened)
                               + " drained=" + Interlocked.Read(ref _drained)
                               + " hit=" + Interlocked.Read(ref _warmHits)
                               + " miss=" + Interlocked.Read(ref _warmMisses)
                               + " dead=" + Interlocked.Read(ref _deadAtTake)
                               + " stale=" + Interlocked.Read(ref _staleAtTake));
                }
            }
            catch { pause = 500; }
            if (pause > 0) await Task.Delay(pause);
        }
    }

    // ---- relay side (qrexec handler; stdio == vchan) -------------------------------------
    static int RunRelay(int controlPort, string token, string logDir)
    {
        string hlog = null;
        try { if (!string.IsNullOrEmpty(logDir)) hlog = Path.Combine(logDir, "relay-handler.log"); } catch { hlog = null; }
        using (TcpClient sock = new TcpClient())
        {
            sock.Connect(IPAddress.Loopback, controlPort);
            NetworkStream ns = sock.GetStream();
            byte[] tk = Encoding.ASCII.GetBytes(token + "\n");
            ns.Write(tk, 0, tk.Length); ns.Flush();

            Stream vin = Console.OpenStandardInput();
            Stream vout = Console.OpenStandardOutput();
            long outBytes = 0, inBytes = 0;
            string outEnd = "-", inEnd = "-";
            Stopwatch hsw = Stopwatch.StartNew();
            Task t1 = Pump(ns, vout, delegate(int n) { outBytes += n; }, delegate(string w) { outEnd = w; });  // request:  socket -> vchan
            Task t2 = Pump(vin, ns, delegate(int n) { inBytes += n; }, delegate(string w) { inEnd = w; });     // response: vchan -> socket
            Task firstDone = Task.WhenAny(t1, t2).Result;
            string firstName = (firstDone == t1) ? "request(sock->vchan)" : "response(vchan->sock)";
            Task.WhenAny(Task.WhenAll(t1, t2), Task.Delay(DrainMs())).Wait();

            // THE SMOKING-GUN FIELDS. Leaving this block disposes `sock`, so if the RESPONSE pump
            // is still running at this point we are about to cut a transfer mid-body - and the
            // listen side would then observe a perfectly clean EOF with a short body, which is
            // exactly the symptom under investigation. Record it as a fact rather than inferring
            // it later: cut_response=True means the truncation is OURS and the fix is teardown
            // ORDERING; cut_response=False with a short `in` count means the vchan delivered a
            // short body and the defect is upstream of this process.
            if (hlog != null)
            {
                Log(hlog, "HANDLER token=" + token + " ms=" + hsw.ElapsedMilliseconds
                        + " request_bytes=" + outBytes + " response_bytes=" + inBytes
                        + " first_to_finish=" + firstName
                        + " requestEnd=" + outEnd + " responseEnd=" + inEnd
                        + " cut_response=" + (!t2.IsCompleted) + " cut_request=" + (!t1.IsCompleted));
            }
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
