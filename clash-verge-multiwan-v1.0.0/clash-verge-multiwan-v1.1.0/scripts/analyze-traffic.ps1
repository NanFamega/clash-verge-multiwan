<#
.SYNOPSIS
  分析当前正在跑的流量, 找出"值得加进多线聚合"的下载目标(Steam 那种处理的自动化版)。

.DESCRIPTION
  工作原理:
    轮询内核的 /connections, 按 域名(或IP) 聚合出每个目标的流量、所属进程、以及它的出口链;
    然后把"走了代理、但流量很大"的目标挑出来 —— 这些就是候选:
    它们要么被墙(必须走代理, 加规则也没用), 要么只是"名字没被我们的规则命中",
    完全可以改走本地多线聚合, 从而不再挤占机场带宽。

  输出:
    1) 流量排行榜(目标 / 进程 / 峰值字节 / 出口链)
    2) 候选清单 + 直接可粘贴的规则行
    3) 用 -AbTest 还能对候选逐个做"代理 vs 直连"的 A/B 实测(临时把主组切 DIRECT 再切回)

.PARAMETER Seconds
  采样时长(默认 15 秒)。让被测应用在这段时间内保持下载。

.PARAMETER MinMB
  只报告峰值超过该值的候选(默认 20MB)。

.PARAMETER AbTest
  对候选逐个做 A/B 实测(会临时改动主策略组的当前选择, 结束时还原)。

.EXAMPLE
  # 先在 Steam / Epic / 浏览器里开始下载, 然后运行:
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\analyze-traffic.ps1 -Seconds 20
  powershell ... -File .\scripts\analyze-traffic.ps1 -Seconds 20 -AbTest
#>
[CmdletBinding()]
param(
  [int]$Seconds = 15,
  [double]$MinMB = 20,
  [string]$MultiWanGroup = '多线聚合',
  [switch]$AbTest,
  [string]$VergeDir = (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev')
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'mihomo-pipe.ps1')

Write-Host "采样 ${Seconds}s …… 请让被测应用保持下载" -ForegroundColor Cyan
$agg = @{}
$deadline = (Get-Date).AddSeconds($Seconds)
while ((Get-Date) -lt $deadline) {
  $r = Invoke-MihomoApi -Path '/connections' -TimeoutMs 6000
  if ($r.Error) { Write-Host "  [!] /connections 解析异常: $($r.Error)" -ForegroundColor Magenta; break }
  $o = $r | ConvertFrom-MihomoJson
  if ($o) {
    foreach ($c in $o.connections) {
      $h = if ($c.metadata.host) { [string]$c.metadata.host } else { 'IP:' + [string]$c.metadata.destinationIP }
      $p = [string](($c.metadata.processPath -split '\\')[-1])
      $key = "$h | $p"
      if (-not $agg.ContainsKey($key)) { $agg[$key] = [pscustomobject]@{ Host = $h; Proc = $p; Bytes = 0; Chain = '' } }
      $tot = [double]$c.download + [double]$c.upload
      if ($tot -gt $agg[$key].Bytes) { $agg[$key].Bytes = $tot }
      $agg[$key].Chain = [string]($c.chains -join ' > ')
    }
  }
  Start-Sleep -Milliseconds 400
}

Write-Host "`n=== 1) 流量排行榜(峰值) ===" -ForegroundColor Cyan
$rows = $agg.Values | Sort-Object Bytes -Descending | Select-Object -First 15
$rows | ForEach-Object {
  Write-Host ("  {0,-14} {1,9:N2} MB  {2,-28} {3}" -f '', ($_.Bytes / 1MB), $_.Host, $_.Chain)
}

Write-Host "`n=== 2) 候选: 流量大但走了代理的目标 ===" -ForegroundColor Cyan
$cand = $agg.Values | Where-Object {
  ($_.Bytes / 1MB) -ge $MinMB -and
  $_.Chain -notmatch '多线|DIRECT|^$'
} | Sort-Object Bytes -Descending
if (-not $cand) {
  Write-Host '  没有候选(要么流量都不大, 要么已经走了多线聚合/DIRECT)' -ForegroundColor Green
} else {
  foreach ($c in $cand) {
    Write-Host ("  {0,-28} {1,8:N2} MB  进程={2}" -f $c.Host, ($c.Bytes / 1MB), $c.Proc) -ForegroundColor Yellow
    Write-Host ("      当前出口链: {0}" -f $c.Chain)
    Write-Host ("      可加入规则: - DOMAIN-SUFFIX,{0},{1}" -f $c.Host, $MultiWanGroup) -ForegroundColor Green
  }
  Write-Host ''
  Write-Host '  注意: 被墙的目标(Google/GitHub raw 等)即使加进多线聚合也连不上, 必须走代理;'
  Write-Host '        加规则前先用 -AbTest 实测一下 "直连是否真的更快"。'
}

if ($AbTest -and $cand) {
  $cur = ''
  foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $VergeDir 'profiles.yaml'), [System.Text.UTF8Encoding]::new($false))) {
    if ($l -match '^current:\s*(\S+)') { $cur = $Matches[1]; break }
  }
  $main = ''
  $pf = Join-Path $VergeDir "profiles\$cur.yaml"
  if (Test-Path $pf) { foreach ($l in [System.IO.File]::ReadAllLines($pf, [System.Text.UTF8Encoding]::new($false))) { if ($l -match 'MATCH\s*,\s*([^''"\s]+)') { $main = $Matches[1] } } }
  if (-not $main) { Write-Host '  找不到主策略组, 跳过 A/B' -ForegroundColor Yellow }
  else {
    Write-Host "`n=== 3) A/B 实测(主组 [$main] 先走节点, 再切 DIRECT 对照) ===" -ForegroundColor Cyan
    $g = Invoke-MihomoApi -Path "/proxies/$([uri]::EscapeDataString($main))" | ConvertFrom-MihomoJson
    $orig = $g.now
    foreach ($phase in @('proxy', 'direct')) {
      if ($phase -eq 'direct') { [void](Set-MihomoSelection -Group $main -Select 'DIRECT'); Start-Sleep -Seconds 2 }
      Write-Host ("  --- {0} ---" -f $(if ($phase -eq 'proxy') { "经节点($orig)" } else { '直连' }))
      foreach ($c in ($cand | Select-Object -First 5)) {
        $url = "https://$($c.Host)/"
        $r2 = (& curl.exe -x 'http://127.0.0.1:7897' -sL -o NUL --max-time 15 -r 0-1200000 -w '%{http_code}|%{speed_download}' $url 2>&1) -join ''
        $q = $r2 -split '\|'; $sp = 0.0
        if ($q.Count -ge 2) { [void][double]::TryParse($q[1], [ref]$sp) }
        Write-Host ("    {0,-30} HTTP={1,-4} {2,6} MB/s" -f $c.Host, $q[0], [math]::Round($sp / 1MB, 2))
      }
    }
    if ($orig) { [void](Set-MihomoSelection -Group $main -Select $orig); Write-Host "  已还原主组为 $orig" }
  }
}
