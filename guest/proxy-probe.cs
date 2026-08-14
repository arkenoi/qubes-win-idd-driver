// Minimal qubes.UpdatesProxy client: reproduces the plain-HTTP truncation WITHOUT our relay.
//
// WHY THIS EXISTS. The relay's own instrumentation says both of its halves are faithful (every
// truncated response ends in a clean EOF, and cut_response=False on every handler line). That is
// evidence, not proof, because the handler is still OUR code - async pumps, a warm pool, a drain
// timeout and a teardown race are all in the picture. Before blaming the transport, replace the
// handler with something that obviously cannot be the cause and see whether the truncation
// survives.
//
// This program IS the qrexec local program: its stdout is the vchan to qubes.UpdatesProxy in the
// proxy qube, and its stdin is the reply. So it is invoked as
//     qrexec-client-vm.exe @default|qubes.UpdatesProxy|user|proxy-probe.exe <reqfile> <outfile>
//
// Deliberately primitive: synchronous, single-threaded, no pooling, no timeouts, no drain, and it
// reads stdin to EOF before exiting. If a response is short HERE, nothing of ours truncated it.
//
// C# 5 / in-box csc only, to match the rest of the guest tooling.
using System;
using System.IO;

static class ProxyProbe
{
    static int Main(string[] args)
    {
        if (args.Length < 2)
        {
            // stderr is safe to write - only stdout is the vchan
            Console.Error.WriteLine("usage: proxy-probe <request-file> <output-file>");
            return 2;
        }
        string reqFile = args[0];
        string outFile = args[1];
        try
        {
            byte[] req = File.ReadAllBytes(reqFile);
            Stream vout = Console.OpenStandardOutput();
            vout.Write(req, 0, req.Length);
            vout.Flush();

            Stream vin = Console.OpenStandardInput();
            long total = 0;
            using (FileStream fs = new FileStream(outFile, FileMode.Create, FileAccess.Write))
            {
                byte[] buf = new byte[65536];
                int n;
                // Read to EOF. No timeout, no drain, no second task that could tear this down.
                while ((n = vin.Read(buf, 0, buf.Length)) > 0)
                {
                    fs.Write(buf, 0, n);
                    total += n;
                }
                fs.Flush();
            }
            File.AppendAllText(outFile + ".meta", "bytes=" + total + " ok\r\n");
            return 0;
        }
        catch (Exception e)
        {
            try { File.AppendAllText(outFile + ".meta", "EXCEPTION " + e.GetType().Name + ": " + e.Message + "\r\n"); }
            catch { }
            return 1;
        }
    }
}
