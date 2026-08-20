# A1, the number that actually decides whether the leak can KILL a guest.
#
# Grants die with the domain, so leakage only accumulates WITHIN one boot. The threshold recorded in
# FINDINGS is ~144 staging grants (7200 pages each) to exhaust the grant table. So the question is
# not "how many were leaked ever" but "what is the MAXIMUM number of staging grants taken during a
# single boot, and how close did that come to exhaustion".
$ErrorActionPreference='Continue'
$out='C:\ProgramData\Qubes\gui-staging-perboot.txt'
$L=@()

# real boot times from the event log (6005 = event log service started ~ boot)
$boots=@()
try {
  $boots = Get-WinEvent -FilterHashtable @{LogName='System'; Id=6005} -MaxEvents 60 -EA SilentlyContinue |
           ForEach-Object { $_.TimeCreated } | Sort-Object
} catch {}
if(-not $boots -or @($boots).Count -eq 0){
  $L += "no 6005 events - falling back to 10-minute gap clustering"
}
$L += ("boot events found: " + @($boots).Count)

$ld='Q:\Qubes Logs'; if(-not (Test-Path $ld)){ $ld='C:\Program Files\Qubes Tools\log' }
# only logs that actually took a staging grant
$granting=@()
foreach($f in (Get-ChildItem $ld -Filter 'gui-agent*.log' -EA SilentlyContinue)){
  $txt = Get-Content -LiteralPath $f.FullName -Raw -EA SilentlyContinue
  if($txt -and $txt -match 'STAGING granted'){ $granting += [pscustomobject]@{ t=$f.LastWriteTime; n=$f.Name } }
}
$granting = $granting | Sort-Object t
$L += ("logs that took a staging grant: " + @($granting).Count)

if(@($boots).Count -gt 0){
  $L += "--- staging grants per boot session ---"
  $arr=@($boots)
  $rows=@()
  for($i=0;$i -lt $arr.Count;$i++){
    $start=$arr[$i]
    $end = if($i+1 -lt $arr.Count){ $arr[$i+1] } else { Get-Date }
    $c = @($granting | Where-Object { $_.t -ge $start -and $_.t -lt $end }).Count
    if($c -gt 0){ $rows += [pscustomobject]@{ boot=$start; grants=$c; pages=$c*7200 } }
  }
  foreach($r in ($rows | Sort-Object grants -Descending | Select-Object -First 12)){
    $pct = [math]::Round(100*$r.grants/144,1)
    $L += ("   boot " + $r.boot.ToString('MM-dd HH:mm') + "  grants=" + $r.grants + "  pages=" + $r.pages + "  = " + $pct + "% of the ~144 exhaustion estimate")
  }
  $max = ($rows | Measure-Object grants -Maximum).Maximum
  $L += ("WORST SINGLE BOOT: " + $max + " staging grants = " + ($max*7200) + " pages leaked in one boot")
  $L += ("  (~144 grants is the recorded exhaustion point; this boot reached " + [math]::Round(100*$max/144,1) + "% of it)")
}
$L | Out-File -LiteralPath $out -Encoding ASCII
