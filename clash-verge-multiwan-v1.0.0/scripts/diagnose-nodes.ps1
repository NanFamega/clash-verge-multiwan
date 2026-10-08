<#
.SYNOPSIS
  诊断"订阅节点大面积超时" —— 找出哪些节点端点还活着。
.DESCRIPTION
  很多机场把几十个"节点"都指向同一台服务器、只是端口不同; 服务器缩容后
  大部分端口会失效, 但订阅列表不会同步清理。表现为: 大部分节点 timeout,
  只有个别节点能用。

  本脚本:
    1) 从 Verge 的运行时配置里解析 每个节点名 -> 服务器:端口
    2) 按端口去重, 逐个用「内核自己的连接」测延迟(这是唯一权威的判据)
    3) 给出"可用端点/失效端点"清单

  重要提醒(踩过的坑):
    * 不要用系统侧 curl/Test-NetConnection 去测节点的服务器端口!
      TUN 模式下连接会被内核的隧道本地应答(0-1ms 就"成功"), 根本没到服务器 —— 结果无效。
      mihomo 的 /proxies/{name}/delay 用的是内核自己的 socket(绕过 TUN), 才是真的。
    * 若内核也解析不出节点域名(全部 5 秒超时), 先看是不是 DNS 自锁:
      见 templates\merge-dns.yaml 与 docs\PITFALLS.md 第 1 条。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\diagnose-nodes.ps1
  powershell ... -File .\scripts\diagnose-nodes.ps1 -MaxPorts 40 -Timeout 3000
#>
[CmdletBinding()]
param(
  [string]$VergeDir = (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'),
  [int]$MaxPorts = 25,
  [int]$Timeout = 4000
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'mihomo-pipe.ps1')
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
function Head($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

$cvPath = Join-Path $VergeDir 'clash-verge.yaml'
if (-not (Test-Path $cvPath)) { throw "找不到运行时配置: $cvPath (先在 Verge 里重新应用一次订阅)" }
$cv = [System.IO.File]::ReadAllLines($cvPath, $Utf8NoBom)

Head '1. 解析节点 -> 服务器:端口'
$map = New-Object System.Collections.Generic.List[object]
$curName = $null; $curServer = $null; $curPort = $null
foreach ($l in $cv) {
  if ($l -match '^- name:\s*(.+)$') {
    if ($curName -and $curPort) { $map.Add([pscustomobject]@{ Name = $curName; Server = $curServer; Port = $curPort }) }
    $curName = $Matches[1].Trim(); $curServer = $null; $curPort = $null; continue
  }
  if ($l -match '^proxy-groups:') {
    if ($curName -and $curPort) { $map.Add([pscustomobject]@{ Name = $curName; Server = $curServer; Port = $curPort }) }
    break
  }
  if ($l -match '^\s+server:\s*(.+)$') { $curServer = $Matches[1].Trim() }
  if ($l -match '^\s+port:\s*(.+)$')   { $curPort = $Matches[1].Trim() }
}
Write-Host "  节点总数: $($map.Count)"
$servers = ($map | Group-Object Server | ForEach-Object { "$($_.Name)($($_.Count)个节点)" }) -join ', '
Write-Host "  服务器:   $servers"
$byPort = $map | Group-Object Port | Sort-Object { [int]$_.Name }
Write-Host "  不同端口: $($byPort.Count)"

Head "2. 逐端口探测(内核自己的连接, 每个 ${Timeout}ms 超时)"
$alive = @(); $dead = @(); $i = 0
foreach ($g in $byPort) {
  $i++
  if ($i -gt $MaxPorts) { Write-Host "  (超过 -MaxPorts $MaxPorts, 其余跳过)"; break }
  $rep = $g.Group[0]
  $enc = [uri]::EscapeDataString($rep.Name)
  $r = Invoke-MihomoApi -Path "/proxies/$enc/delay?timeout=$Timeout&url=http://www.gstatic.com/generate_204" -TimeoutMs ($Timeout + 3000)
  if ($r.Body -match '"delay":(\d+)') {
    $d = [int]$Matches[1]
    $alive += [pscustomobject]@{ Port = $g.Name; Name = $rep.Name; Delay = $d }
    Write-Host ("  OK  端口 {0,-6} ({1,-26}) {2} ms" -f $g.Name, $rep.Name, $d) -ForegroundColor Green
  } else {
    $dead += $g.Name
    Write-Host ("  --  端口 {0,-6} ({1,-26}) 超时" -f $g.Name, $rep.Name)
  }
}

Head '3. 结论'
Write-Host "  可用端点: $($alive.Count) 个"
if ($alive.Count -gt 0) { Write-Host ("    " + (($alive | ForEach-Object { "$($_.Port)($($_.Delay)ms)" }) -join ', ')) -ForegroundColor Green }
Write-Host "  失效端口: $($dead.Count) 个" -ForegroundColor Yellow
if ($dead.Count -gt 0) { Write-Host ("    " + ($dead -join ', ')) }
if ($alive.Count -le 1) {
  Write-Host ''
  Write-Host '  [!] 可用端点极少 -> 基本可以判定是机场侧问题(服务器缩容/端口关闭),' -ForegroundColor Yellow
  Write-Host '      不是你的网络或配置问题。建议: 更新订阅 / 看机场公告 / 换机场。' -ForegroundColor Yellow
}
