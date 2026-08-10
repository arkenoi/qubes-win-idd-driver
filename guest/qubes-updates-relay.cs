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
using System.Threading.Tasks;

static class Relay
{
    const string Service = "qubes.UpdatesProxy";

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
        while (true)
        {
            TcpClient inbound = listener.AcceptTcpClient();
            TcpClient captured = inbound;
            Task.Run(delegate { HandleInbound(captured, self, target, user, logPath).Wait(); });
        }
    }

    static async Task HandleInbound(TcpClient inbound, string self, string target, string user, string logPath)
    {
        string token = Guid.NewGuid().ToString("N");
        TcpListener control = new TcpListener(IPAddress.Loopback, 0);   // ephemeral
        control.Start();
        int cport = ((IPEndPoint)control.LocalEndpoint).Port;
        Stopwatch sw = Stopwatch.StartNew();
        long up = 0, down = 0;
        try
        {
            string handler = "\"" + self + "\" --relay " + cport + " " + token;
            ProcessStartInfo psi = new ProcessStartInfo();
            psi.FileName = QrexecClientVm();
            psi.Arguments = "\"" + target + "|" + Service + "|" + user + "|" + handler + "\"";
            psi.UseShellExecute = false;
            psi.CreateNoWindow = true;
            Process.Start(psi);

            Task<TcpClient> accept = control.AcceptTcpClientAsync();
            if (await Task.WhenAny(accept, Task.Delay(20000)) != accept)
            { Log(logPath, "CONN token=" + token + " relay never connected back"); return; }
            TcpClient relay = accept.Result;
            NetworkStream rs = relay.GetStream();
            byte[] tk = Encoding.ASCII.GetBytes(token + "\n");
            byte[] got = new byte[tk.Length];
            if (!await ReadExact(rs, got, got.Length) || Encoding.ASCII.GetString(got) != token + "\n")
            { Log(logPath, "CONN token=" + token + " bad token from relay"); relay.Close(); return; }

            using (inbound)
            using (relay)
            {
                NetworkStream a = inbound.GetStream();
                Task t1 = Pump(a, rs, delegate(int n) { up += n; });        // WU -> vchan
                Task t2 = Pump(rs, a, delegate(int n) { down += n; });      // vchan -> WU
                await Task.WhenAny(t1, t2);
                await Task.WhenAny(Task.WhenAll(t1, t2), Task.Delay(3000)); // half-close drain
            }
        }
        catch (Exception e) { Log(logPath, "CONN token=" + token + " error " + e.Message); }
        finally { control.Stop(); Log(logPath, "CONN token=" + token + " up=" + up + " down=" + down + " ms=" + sw.ElapsedMilliseconds); }
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
            Task t1 = Pump(ns, vout, delegate(int n) { });   // socket (from WU) -> vchan out
            Task t2 = Pump(vin, ns, delegate(int n) { });    // vchan in -> socket (to WU)
            Task.WhenAny(t1, t2).Wait();
            Task.WhenAny(Task.WhenAll(t1, t2), Task.Delay(3000)).Wait();
        }
        return 0;
    }

    // ---- byte pump -----------------------------------------------------------------------
    static async Task Pump(Stream from, Stream to, Action<int> count)
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
        }
        catch { /* peer closed / reset: normal teardown */ }
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
