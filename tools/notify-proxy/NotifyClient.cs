// NotifyClient.cs — minimal Windows client for the EXISTING Qubes dom0 notification service
// `qubes.Notifications` (QubesOS/qubes-notification-proxy, shipped by default in Qubes R4.3:
// dom0's qubes-gui-daemon Requires qubes-notification-daemon, and qubes-core-admin's stock
// 90-default.policy already allows @anyvm -> @default with target=dom0).
//
// This is ONLY the VM-side client. All display safety is server-side in dom0: the server
// origin-marks every notification (summary prefixed "<qube>: ", app name "Qube: <qube>",
// qube-label icon — derived from qrexec's unforgeable QREXEC_REMOTE_DOMAIN) and sanitizes the
// text (safe-code-point allowlist, line/length caps, markup escaping). The wire protocol has no
// app-name or icon fields, so this client could not spoof identity even deliberately. Do NOT
// add client-side sanitization: the server rightly treats all input as untrusted anyway.
//
// Two roles in one exe:
//   NotifyClient.exe --send <summary> [body words...]   (also --send-file <utf8 file>)
//       Launcher. Writes the text to a spool file, then triggers the service via QWT's
//       qrexec-client-vm.exe with THIS exe (in --handler mode) as the local endpoint, and
//       waits for the handler's result file.
//   NotifyClient.exe --handler <spool-file>
//       The qrexec local program: spawned by qrexec-wrapper with stdin/stdout wired to the
//       data vchan. Speaks the notification-proxy wire protocol (4-byte version handshake,
//       then u32-LE-length-prefixed bincode-1.x fixint frames), sends ONE notification,
//       waits for the ack, writes <spool-file>.result.
//
// The two roles are separate processes because qrexec-client-vm.exe does NOT connect the
// caller's stdio to the vchan — it hands a command line to qrexec-agent and exits; the agent
// spawns the handler in the INTERACTIVE session (so a logged-on user is required, and the
// spool lives in ProgramData because the launcher may run as SYSTEM while the handler runs
// as the desktop user).
//
// Wire protocol (verified against qubes-notification-proxy src/lib.rs + notification-proxy-server.rs,
// v1.1.2; bincode 1.3.3 DefaultOptions + fixint + native endian (LE on x86-64) + reject_trailing_bytes):
//   1. Server writes u32 LE version = (major<<16)|minor = 0x00010000. Client aborts unless
//      major == 1, then replies u32 LE (1<<16) | min(server_minor, 0) = 0x00010000.
//   2. Client frames: u32 LE payload length (<= 0x1000000), then Message:
//        id u64 LE                      (client-chosen sequence, echoed in replies)
//        Notification enum tag u32 LE   = 0 (V1)
//        suppress_sound u8, transient u8, resident u8   (bools)
//        urgency Option: u8 0=None (or 1 + u32 LE 0/1/2)
//        replaces_id u32 LE             (0 = new notification)
//        summary: u64 LE byte-len + UTF-8
//        body:    u64 LE byte-len + UTF-8
//        actions: u64 LE count (0)      (must be even when present)
//        category Option: u8 0=None
//        expire_timeout i32 LE          (-1 = server default)
//        image Option: u8 0=None        (server discards images anyway)
//   3. Server frames (same u32-LE-length framing), ReplyMessage tag u32 LE:
//        0=Id{id u32, sequence u64}  1=DBusError{name String, message Option<String>, sequence u64}
//        2=UnknownError{sequence u64}  3=Dismissed{id u32, reason u32}
//        4=ActionInvoked{id u32, action String}  5=ServerRestart
//
// C# 5 / in-box csc only (C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe), matching
// the rest of the guest tooling. No external dependencies.

using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Text;

static class NotifyClient
{
    const string Service = "qubes.Notifications";
    const uint MaxMessageSize = 0x1000000;  // MAX_MESSAGE_SIZE, server-enforced
    const uint OurMajor = 1;
    const uint OurMinor = 0;

    static int Usage()
    {
        Console.Error.WriteLine("usage:");
        Console.Error.WriteLine("  NotifyClient --send <summary> [body words...] [--user U] [--target T] [--timeout SEC] [--spool DIR]");
        Console.Error.WriteLine("  NotifyClient --send-file <utf8-file>  (first line = summary, rest = body; same options)");
        Console.Error.WriteLine("  NotifyClient --handler <spool-file>   (internal: spawned by qrexec, stdio = vchan)");
        Console.Error.WriteLine("defaults: user from QUBES_NOTIFY_USER else 'user' when running as SYSTEM else current");
        Console.Error.WriteLine("          user name; target '@default' (NEVER an explicit dom0 - policy + sys-gui routing");
        Console.Error.WriteLine("          both key on @default); timeout 30; spool %ProgramData%\\qubes-notify-proxy");
        return 2;
    }

    static int Main(string[] args)
    {
        string mode = null, summary = null, bodyFile = null, handlerFile = null;
        string user = null, target = "@default", spool = null;
        int timeoutSec = 30;
        StringBuilder body = new StringBuilder();

        for (int i = 0; i < args.Length; i++)
        {
            string a = args[i];
            if (a == "--handler" && i + 1 < args.Length) { mode = "handler"; handlerFile = args[++i]; }
            else if (a == "--send" && i + 1 < args.Length) { mode = "send"; summary = args[++i]; }
            else if (a == "--send-file" && i + 1 < args.Length) { mode = "sendfile"; bodyFile = args[++i]; }
            else if (a == "--user" && i + 1 < args.Length) { user = args[++i]; }
            else if (a == "--target" && i + 1 < args.Length) { target = args[++i]; }
            else if (a == "--spool" && i + 1 < args.Length) { spool = args[++i]; }
            else if (a == "--timeout" && i + 1 < args.Length) { timeoutSec = int.Parse(args[++i]); }
            else if (mode == "send") { body.Append(body.Length > 0 ? " " : "").Append(a); }
            else return Usage();
        }
        if (mode == null) return Usage();

        if (mode == "handler")
            return Handler(handlerFile);

        if (mode == "sendfile")
        {
            string text = File.ReadAllText(bodyFile, Encoding.UTF8);
            int nl = text.IndexOf('\n');
            if (nl < 0) { summary = text.TrimEnd('\r'); }
            else { summary = text.Substring(0, nl).TrimEnd('\r'); body.Append(text.Substring(nl + 1)); }
        }

        return Send(summary, body.ToString(), user, target, timeoutSec, spool);
    }

    // ---- launcher --------------------------------------------------------------------------

    static string SpoolDir(string overrideDir)
    {
        string d = overrideDir;
        if (string.IsNullOrEmpty(d)) d = Environment.GetEnvironmentVariable("QUBES_NOTIFY_SPOOL");
        if (string.IsNullOrEmpty(d))
            d = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.CommonApplicationData),
                             "qubes-notify-proxy");
        Directory.CreateDirectory(d);
        return d;
    }

    static string LocalUser(string overrideUser)
    {
        if (!string.IsNullOrEmpty(overrideUser)) return overrideUser;
        string u = Environment.GetEnvironmentVariable("QUBES_NOTIFY_USER");
        if (!string.IsNullOrEmpty(u)) return u;
        u = Environment.UserName;
        // A SYSTEM caller (e.g. qubes.VMShell on the testbed) is not a logon account the agent
        // can target; the handler runs in the interactive session, so name the desktop account.
        if (string.IsNullOrEmpty(u) || u.Equals("SYSTEM", StringComparison.OrdinalIgnoreCase)
            || u.EndsWith("$", StringComparison.Ordinal))
            u = "user";
        return u;
    }

    static string QrexecClientVm()
    {
        string v = Environment.GetEnvironmentVariable("QREXEC_CLIENT_VM");
        if (string.IsNullOrEmpty(v)) v = @"C:\Program Files\Qubes Tools\bin\qrexec-client-vm.exe";
        return Environment.ExpandEnvironmentVariables(v);
    }

    static int Send(string summary, string body, string user, string target, int timeoutSec, string spoolOverride)
    {
        if (summary == null) return Usage();
        string self = Assembly.GetEntryAssembly().Location;
        string qrexec = QrexecClientVm();
        if (!File.Exists(qrexec))
        {
            Console.Error.WriteLine("FAIL qrexec-client-vm.exe not found at " + qrexec + " (set QREXEC_CLIENT_VM)");
            return 2;
        }

        string spoolDir = SpoolDir(spoolOverride);
        string msgFile = Path.Combine(spoolDir, "n-" + Guid.NewGuid().ToString("N") + ".txt");
        string resultFile = msgFile + ".result";
        // Spool format: first line = summary (newlines folded), rest = body. UTF-8, no BOM.
        File.WriteAllText(msgFile,
            summary.Replace("\r", " ").Replace("\n", " ") + "\n" + body,
            new UTF8Encoding(false));

        ProcessStartInfo psi = new ProcessStartInfo();
        psi.FileName = qrexec;
        // Do NOT wrap the whole pipe-string in quotes: qrexec-client-vm's GetArgument() splits the
        // RAW command line on '|' and does not strip quotes, so an outer quote leaks into the
        // target field and dom0 refuses. Quotes INSIDE field 4 are fine — that whole field is the
        // handler command line, parsed by CreateProcess. (Same pattern as guest/qubes-updates-relay.cs.)
        psi.Arguments = target + "|" + Service + "|" + LocalUser(user) + "|\"" + self + "\" --handler \"" + msgFile + "\"";
        psi.UseShellExecute = false;
        psi.CreateNoWindow = true;
        Process p = Process.Start(psi);
        p.WaitForExit();
        if (p.ExitCode != 0)
        {
            Console.WriteLine("FAIL qrexec-client-vm exited " + p.ExitCode);
            try { File.Delete(msgFile); } catch { }
            return 2;
        }

        // Exit 0 above means "handed to qrexec-agent", NOT allowed or delivered: a dom0 policy
        // refusal is invisible to the caller, and wait-for-session=1 blocks the service until a
        // dom0 GUI session exists. So the ack comes from our handler via the result file.
        for (int i = 0; i < timeoutSec * 10; i++)
        {
            if (File.Exists(resultFile))
            {
                System.Threading.Thread.Sleep(200); // let the handler finish its write
                string r = File.ReadAllText(resultFile).Trim();
                try { File.Delete(resultFile); } catch { }
                // The handler tries to delete the spool file too, but when the launcher ran as
                // SYSTEM the desktop-user handler may lack delete rights on it - clean up here.
                try { File.Delete(msgFile); } catch { }
                Console.WriteLine(r);
                return r.StartsWith("OK") ? 0 : 1;
            }
            System.Threading.Thread.Sleep(100);
        }
        Console.WriteLine("NOACK no result after " + timeoutSec + "s - possible causes: dom0 policy refusal"
            + " (invisible to callers), no dom0 GUI session yet (wait-for-session blocks), no logged-on"
            + " guest session (handler needs the interactive session), or handler crash."
            + " Late result would land at: " + resultFile);
        return 3;
    }

    // ---- handler (stdio = vchan to the dom0 server) ----------------------------------------

    static int Handler(string msgFile)
    {
        string result;
        int code = 1;
        try
        {
            string text = File.ReadAllText(msgFile, Encoding.UTF8);
            try { File.Delete(msgFile); } catch { }
            string summary, body;
            int nl = text.IndexOf('\n');
            if (nl < 0) { summary = text.TrimEnd('\r'); body = ""; }
            else { summary = text.Substring(0, nl).TrimEnd('\r'); body = text.Substring(nl + 1); }

            Stream vin = Console.OpenStandardInput();
            Stream vout = Console.OpenStandardOutput();

            // 1. Handshake — the server speaks first.
            uint server = ReadU32(vin);
            uint smajor = server >> 16, sminor = server & 0xFFFF;
            if (smajor != OurMajor)
            {
                result = "FAIL handshake: server protocol major " + smajor + " (want " + OurMajor + ")";
            }
            else
            {
                WriteU32(vout, (OurMajor << 16) | Math.Min(sminor, OurMinor));
                vout.Flush();

                // 2. One notification, sequence id 1.
                byte[] payload = EncodeMessage(1UL, summary, body);
                if ((uint)payload.Length > MaxMessageSize)
                {
                    result = "FAIL message too large (" + payload.Length + " > " + MaxMessageSize + ")";
                }
                else
                {
                    WriteU32(vout, (uint)payload.Length);
                    vout.Write(payload, 0, payload.Length);
                    vout.Flush();

                    // 3. Read replies until ours is acked. Tags 3/4 (Dismissed/ActionInvoked) are
                    // async user events we don't consume in v1 — skip them.
                    result = "FAIL no reply";
                    for (; ; )
                    {
                        uint len = ReadU32(vin);
                        if (len > MaxMessageSize) { result = "FAIL oversized reply frame " + len; break; }
                        byte[] rep = ReadExact(vin, (int)len);
                        if (rep.Length < 4) { result = "FAIL short reply frame"; break; }
                        uint tag = GetU32(rep, 0);
                        if (tag == 0 && rep.Length >= 16)        // Id{id u32, sequence u64}
                        {
                            uint id = GetU32(rep, 4);
                            ulong seq = GetU64(rep, 8);
                            if (seq == 1UL) { result = "OK id=" + id; code = 0; break; }
                        }
                        else if (tag == 1)                        // DBusError{name, Option<message>, sequence}
                        {
                            result = "FAIL DBusError " + ParseDBusError(rep);
                            break;
                        }
                        else if (tag == 2) { result = "FAIL UnknownError"; break; }
                        else if (tag == 5) { result = "FAIL ServerRestart before ack"; break; }
                        // tags 3/4: ignore, keep draining
                    }
                }
            }
        }
        catch (EndOfStreamException)
        {
            result = "FAIL stream closed before ack (dom0 policy refusal? malformed frame killed the server?)";
        }
        catch (Exception e)
        {
            result = "FAIL " + e.GetType().Name + ": " + e.Message;
        }
        try { File.WriteAllText(msgFile + ".result", result + "\r\n"); } catch { }
        Console.Error.WriteLine(result); // stderr is safe - only stdout is the vchan
        return code;
    }

    // Message { id: u64, notification: Notification::V1 { ... } } — bincode fixint LE.
    static byte[] EncodeMessage(ulong id, string summary, string body)
    {
        byte[] s = Encoding.UTF8.GetBytes(summary);
        byte[] b = Encoding.UTF8.GetBytes(body);
        MemoryStream m = new MemoryStream();
        W64(m, id);                 // Message.id (echoed as `sequence` in replies)
        W32(m, 0);                  // Notification enum tag: 0 = V1
        m.WriteByte(0);             // suppress_sound = false
        m.WriteByte(0);             // transient = false
        m.WriteByte(0);             // resident = false
        m.WriteByte(0);             // urgency: Option None
        W32(m, 0);                  // replaces_id: 0 = new notification
        W64(m, (ulong)s.Length); m.Write(s, 0, s.Length);   // summary: String
        W64(m, (ulong)b.Length); m.Write(b, 0, b.Length);   // body: String
        W64(m, 0);                  // actions: Vec<String> count 0
        m.WriteByte(0);             // category: Option None
        WI32(m, -1);                // expire_timeout: -1 = server default
        m.WriteByte(0);             // image: Option None (server discards images)
        return m.ToArray();
    }

    static string ParseDBusError(byte[] rep)
    {
        try
        {
            int off = 4;
            ulong nameLen = GetU64(rep, off); off += 8;
            string name = Encoding.UTF8.GetString(rep, off, (int)nameLen); off += (int)nameLen;
            string msg = "";
            if (rep[off++] == 1)
            {
                ulong msgLen = GetU64(rep, off); off += 8;
                msg = ": " + Encoding.UTF8.GetString(rep, off, (int)msgLen);
            }
            return name + msg;
        }
        catch { return "(unparseable)"; }
    }

    // ---- little-endian primitives (explicit, independent of host BitConverter) --------------

    static void W32(Stream s, uint v)
    {
        s.WriteByte((byte)v); s.WriteByte((byte)(v >> 8)); s.WriteByte((byte)(v >> 16)); s.WriteByte((byte)(v >> 24));
    }
    static void WI32(Stream s, int v) { W32(s, unchecked((uint)v)); }
    static void W64(Stream s, ulong v) { W32(s, (uint)v); W32(s, (uint)(v >> 32)); }
    static void WriteU32(Stream s, uint v) { W32(s, v); s.Flush(); }

    static byte[] ReadExact(Stream s, int n)
    {
        byte[] buf = new byte[n];
        int got = 0;
        while (got < n)
        {
            int r = s.Read(buf, got, n - got);
            if (r <= 0) throw new EndOfStreamException();
            got += r;
        }
        return buf;
    }
    static uint ReadU32(Stream s) { return GetU32(ReadExact(s, 4), 0); }
    static uint GetU32(byte[] b, int o)
    {
        return (uint)(b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | ((uint)b[o + 3] << 24));
    }
    static ulong GetU64(byte[] b, int o) { return GetU32(b, o) | ((ulong)GetU32(b, o + 4) << 32); }
}
