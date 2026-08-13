// QWT-NG: a minimal `cat` for the Windows guest.
//
// dom0's qubes-vm-update ships its agent into the VM by running, over qubes.VMShell:
//     cat > /run/qubes-update/agent.tar.gz
// with the tarball following on stdin. cmd.exe has no `cat` and - being a builtin-free name -
// it is the one piece of dom0's sequence that PATH can satisfy, so this is shipped rather than
// intercepted. (`mkdir` cannot be handled this way: it is a cmd builtin and always wins.)
//
// Deliberately minimal and byte-exact: no flags, no text mode, no encoding. With no operands it
// copies stdin to stdout; with operands it concatenates those files, translating POSIX paths.
// A missing file is not an error - dom0 also cats logs that may never have been written.
using System;
using System.IO;

internal static class QubesPosixCat
{
    private static string ToWindowsPath(string p)
    {
        if (string.IsNullOrEmpty(p)) return p;
        string q = p.Replace('/', '\\');
        if (q.StartsWith("\\") && !q.StartsWith("\\\\"))
            q = Environment.GetEnvironmentVariable("SystemDrive") + q;
        return q;
    }

    private static int Main(string[] args)
    {
        try
        {
            using (Stream stdout = Console.OpenStandardOutput())
            {
                bool copiedAny = false;
                foreach (string arg in args)
                {
                    if (arg.StartsWith("-")) continue;          // no flags are implemented
                    string path = ToWindowsPath(arg);
                    if (!File.Exists(path)) { copiedAny = true; continue; }
                    using (FileStream f = File.OpenRead(path)) f.CopyTo(stdout);
                    copiedAny = true;
                }
                if (!copiedAny)
                {
                    using (Stream stdin = Console.OpenStandardInput()) stdin.CopyTo(stdout);
                }
                stdout.Flush();
            }
            return 0;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine("cat: " + e.Message);
            return 1;
        }
    }
}
