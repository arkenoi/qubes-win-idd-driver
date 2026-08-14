// qwt-bootstrap - shipped at the root of the tools ISO as qubes-tools-<version>.exe.
//
// WHY IT EXISTS. Anything that installs Qubes Windows Tools automatically looks for the
// shape the vendor has always shipped: ONE installer at the root of the ISO, matched by the
// glob `qubes-tools-*.exe` (qvm-create-windows-qube's tools/auto-qwt/install-qwt.bat does
// exactly this) and run with /passive. This package is an installer TREE instead - a
// test-signed build cannot be installed in one shot, because testsigning has to be enabled
// and the guest rebooted before the kernel will load the drivers, so the work is staged and
// driven by install.cmd.
//
// Against a tree that glob matches NOTHING. There is no error and no dialog: the qube
// finishes provisioning with no tools installed at all, which reads as "Qubes Windows Tools
// failed" rather than "its installer was never run". Reported from the field, forum 42717
// post 27. This executable closes that gap by BEING the file everyone looks for: it does
// nothing except hand control to install.cmd in its own directory.
//
// Argument mapping, deliberately forgiving. An automated caller passes an unattended switch
// (/passive, /quiet, /qn or /auto) and expects no interaction, which is install.cmd /auto -
// it reboots and resumes by itself. Anything else, including a double-click with no
// arguments, runs install.cmd interactively so a human sees what happens.

#include <windows.h>
#include <shlwapi.h>
#include <strsafe.h>
#include <stdio.h>

#pragma comment(lib, "shlwapi.lib")

static bool IsUnattendedSwitch(const wchar_t *arg)
{
    return _wcsicmp(arg, L"/passive") == 0 || _wcsicmp(arg, L"-passive") == 0 ||
           _wcsicmp(arg, L"/quiet")   == 0 || _wcsicmp(arg, L"-quiet")   == 0 ||
           _wcsicmp(arg, L"/qn")      == 0 || _wcsicmp(arg, L"-qn")      == 0 ||
           _wcsicmp(arg, L"/auto")    == 0 || _wcsicmp(arg, L"-auto")    == 0 ||
           _wcsicmp(arg, L"/s")       == 0 || _wcsicmp(arg, L"-s")       == 0;
}

int wmain(int argc, wchar_t **argv)
{
    wchar_t self[MAX_PATH] = { 0 };
    if (!GetModuleFileNameW(NULL, self, MAX_PATH))
    {
        fwprintf(stderr, L"qubes-tools: cannot determine my own path (%lu)\n", GetLastError());
        return 1;
    }
    PathRemoveFileSpecW(self);

    wchar_t installer[MAX_PATH] = { 0 };
    if (FAILED(StringCchPrintfW(installer, MAX_PATH, L"%s\\install.cmd", self)) ||
        GetFileAttributesW(installer) == INVALID_FILE_ATTRIBUTES)
    {
        // Say which file is missing and where we looked. A caller that only checks the exit
        // code still gets a nonzero one; a human gets something actionable.
        fwprintf(stderr, L"qubes-tools: install.cmd is not next to me (looked in %s).\n", self);
        fwprintf(stderr, L"qubes-tools: this executable only starts the real installer - "
                         L"run it from the tools medium, not from a copy of itself.\n");
        return 2;
    }

    bool unattended = false;
    for (int i = 1; i < argc; i++)
        if (IsUnattendedSwitch(argv[i]))
            unattended = true;

    // cmd /c so the .cmd is interpreted; quoted because the medium can be mounted anywhere.
    wchar_t cmdline[MAX_PATH * 2] = { 0 };
    if (FAILED(StringCchPrintfW(cmdline, MAX_PATH * 2, L"cmd.exe /c \"\"%s\"%s\"",
                                installer, unattended ? L" /auto" : L"")))
        return 1;

    wprintf(L"qubes-tools: starting %s%s\n", installer, unattended ? L" /auto" : L"");

    STARTUPINFOW si = { sizeof(si) };
    PROCESS_INFORMATION pi = { 0 };
    if (!CreateProcessW(NULL, cmdline, NULL, NULL, FALSE, 0, NULL, self, &si, &pi))
    {
        fwprintf(stderr, L"qubes-tools: could not start install.cmd (%lu)\n", GetLastError());
        return 3;
    }

    // WAIT. The caller's next step is usually "the guest will shut down when the installer
    // is done"; returning early would make it look finished before it started.
    WaitForSingleObject(pi.hProcess, INFINITE);
    DWORD rc = 1;
    GetExitCodeProcess(pi.hProcess, &rc);
    CloseHandle(pi.hThread);
    CloseHandle(pi.hProcess);
    wprintf(L"qubes-tools: install.cmd exited with %lu\n", rc);
    return (int)rc;
}
