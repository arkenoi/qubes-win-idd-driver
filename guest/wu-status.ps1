# qubes.WindowsUpdateStatus rpc handler (QWT-NG). Emits the current update-status.json on stdout -
# which, for an rpc SERVICE, is the vchan to the dom0 caller. dom0 polls this to see availability
# plus LIVE download/install progress (the status file is rewritten at each phase by
# qubes-windows-update.ps1). Read-only: it never acts on the guest, so it is safe to allow dom0 to
# call at will. If no scan has run yet, emit a well-formed "none" so the caller always gets JSON.
$ErrorActionPreference = 'SilentlyContinue'
$f = 'C:\ProgramData\Qubes\update-status.json'
if (Test-Path -LiteralPath $f) {
    [Console]::Out.Write((Get-Content -LiteralPath $f -Raw))
} else {
    [Console]::Out.Write('{"phase":"none","count":0,"available":[]}')
}
