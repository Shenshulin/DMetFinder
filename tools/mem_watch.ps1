param(
  [Parameter(Mandatory=$true)][string]$Out,
  [Parameter(Mandatory=$true)][string]$Match,
  [int]$IntervalSec = 5
)
# 只统计命令行里含 $Match 的 Rscript 进程（排除其它在跑的 R / Shiny）
$max = 0
$samples = 0
$idle = 0
$seen = $false
while ($true) {
  $procs = @(Get-CimInstance Win32_Process -Filter "Name='Rscript.exe'" |
             Where-Object { $_.CommandLine -and $_.CommandLine.Contains($Match) })
  if ($procs.Count -gt 0) {
    $seen = $true
    $idle = 0
    $sum = ($procs | Measure-Object -Property WorkingSetSize -Sum).Sum
    $samples++
    if ($sum -gt $max) { $max = $sum }
    "$(Get-Date -Format HH:mm:ss)`t$([math]::Round($sum/1MB,1))`t$($procs.Count)" |
      Out-File -Append -Encoding utf8 $Out
  } else {
    $idle++
    if ($seen -and $idle -ge 2) { break }
  }
  Start-Sleep -Seconds $IntervalSec
}
"PEAK_MB=$([math]::Round($max/1MB,1))`tSAMPLES=$samples" | Out-File -Append -Encoding utf8 $Out
