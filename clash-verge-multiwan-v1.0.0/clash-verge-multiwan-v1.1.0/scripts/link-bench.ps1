<#
.SYNOPSIS
  多链路带宽实测: 逐链路容量 / 多线分摊 / 默认路由吞吐。
.DESCRIPTION
  三种模式:
    -Mode proxy   (默认) 经系统代理拉多线程下载, 统计各"物理网卡"接收字节数。
                  这是 TUN 开启时唯一有效的叠加验证方法(因为 TUN 会吞掉源 IP 绑定)。
    -Mode bound   逐链路绑定源 IP 实测容量。**要求先关闭 TUN** ——
                  TUN 的 auto-route 会把绑定了源 IP 的报文也吸进隧道后丢弃,
                  表现为全部 HTTP=000(这是个非常容易踩的坑)。
    -Mode unbound 走默认路由(不绑定), 用于验证 Speedify 之类"聚合器"是否真把流量散开了。

  统计口径(重要): 求和时**必须排除 Mihomo/Meta Tunnel 虚拟网卡** ——
  它看到的流量与物理腿是同一份, 一起相加会让结果翻倍(踩过一次)。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\link-bench.ps1
  powershell ... -File .\scripts\link-bench.ps1 -Mode bound -Streams 3 -ChunkMB 20
#>
[CmdletBinding()]
param(
  [ValidateSet('proxy', 'bound', 'unbound')][string]$Mode = 'proxy',
  [string]$Url = 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ls-lR.gz',
  [int]$Streams = 6,
  [int]$ChunkMB = 4,
  [int]$TimeoutSec = 40,
  [string]$Proxy = 'http://127.0.0.1:7897'
)
$ErrorActionPreference = 'Continue'
function Head($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
$Chunk = $ChunkMB * 1MB

function Get-PhysicalLinks {
  Get-NetIPConfiguration | Where-Object {
    $_.NetAdapter.Status -eq 'Up' -and $_.IPv4DefaultGateway -and
    $_.InterfaceAlias -notmatch 'Loopback|Mihomo|TAP|wintun|Bluetooth'
  } | ForEach-Object {
    [pscustomobject]@{
      Alias = $_.InterfaceAlias
      Index = $_.InterfaceIndex
      IP    = ($_.IPv4Address | Select-Object -First 1).IPAddress
      GW    = ($_.IPv4DefaultGateway | Select-Object -First 1).NextHop
      Speed = (Get-NetAdapter -InterfaceIndex $_.InterfaceIndex).LinkSpeed
    }
  }
}
$physical = Get-PhysicalLinks
Head '物理链路'
$physical | Format-Table Alias, Index, IP, GW, Speed -AutoSize
$hasTun = [bool](Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'Meta Tunnel|wintun' })
Write-Host ("  TUN 隧道: " + $(if ($hasTun) { '已开启' } else { '未开启' }))

function Snapshot($names) {
  $h = @{}; foreach ($n in $names) { $h[$n] = (Get-NetAdapterStatistics -Name $n).ReceivedBytes }; return $h
}
function Report($before, $names, $seconds, $label) {
  Write-Host "  --- $label 期间各物理网卡承载 ---"
  $sum = 0.0; $used = @()
  foreach ($n in $names) {
    $now = (Get-NetAdapterStatistics -Name $n).ReceivedBytes
    $d = $now - $before[$n]
    if ($d -gt 50000) {
      Write-Host ("    {0,-14} {1,13:N0} B  ({2,7:N2} MB, {3,6:N2} MB/s)" -f $n, $d, ($d / 1MB), ($d / $seconds / 1MB))
      $sum += $d; $used += $n
    }
  }
  Write-Host ("    物理腿合计: {0:N2} MB ({1:N2} MB/s)" -f ($sum / 1MB), ($sum / $seconds / 1MB))
  return $used
}
function RunStreams($extraArgs, $n, $chunk) {
  $jobs = @()
  for ($i = 0; $i -lt $n; $i++) {
    $from = $i * $chunk; $to = $from + $chunk - 1
    $jobs += Start-Job -ScriptBlock {
      param($u, $r, $extra)
      $base = @('-s', '-o', 'NUL', '--max-time', $using:TimeoutSec, '-r', $r, '-w', '%{size_download}|%{speed_download}|%{http_code}')
      & curl.exe @($extra + $base + @($u))
    } -ArgumentList $Url, "$from-$to", $extraArgs
  }
  Wait-Job $jobs -Timeout ($TimeoutSec + 90) | Out-Null
  $bytes = 0.0; $sp = 0.0; $det = @()
  foreach ($j in $jobs) {
    $o = (Receive-Job $j) -join ''; $q = $o -split '\|'
    if ($q.Count -ge 3 -and [double]$q[1] -gt 0) { $bytes += [double]$q[0]; $sp += [double]$q[1]; $det += ('{0:N2}' -f ([double]$q[1] / 1MB)) }
    else { $det += 'x' }
    Remove-Job $j -Force
  }
  return [pscustomobject]@{ Bytes = $bytes; Sum = $sp; Detail = ($det -join ' / ') }
}

$names = $physical.Alias
switch ($Mode) {

  'proxy' {
    Head "经系统代理多流下载($Streams x ${ChunkMB}MB) —— 验证多线分摊"
    $a0 = Snapshot $names
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = RunStreams @('-x', $Proxy) $Streams $Chunk
    $sw.Stop()
    $used = Report $a0 $names $sw.Elapsed.TotalSeconds '下载'
    Write-Host ("  各流平均: $($r.Detail) MB/s")
    Write-Host ("  并发速率合计: {0:N2} MB/s ({1:N1} Mbps)" -f ($r.Sum / 1MB), ($r.Sum * 8 / 1MB))
    if ($used.Count -ge 2) { Write-Host "  ✓ 多线生效: $($used.Count) 条腿在同时承载" -ForegroundColor Green }
    elseif ($used.Count -eq 1) { Write-Host "  ✗ 只有 $($used -join '') 在动 —— 检查多线组的健康检查是否工作" -ForegroundColor Yellow }
    Write-Host '  注: 已排除 Mihomo 虚拟网卡(与物理腿是同一份流量, 相加会翻倍)。'
  }

  'bound' {
    if ($hasTun) {
      Write-Host '  [!] TUN 已开启: 源 IP 绑定会被隧道吞掉, 本模式结果全为 000。' -ForegroundColor Yellow
      Write-Host '      请先在 Verge 里关闭 TUN 模式, 再运行本模式。' -ForegroundColor Yellow
    }
    Head "逐链路独立容量(绑定源 IP, $Streams 并发 x ${ChunkMB}MB)"
    $solo = @{}
    foreach ($l in $physical) {
      $a0 = Snapshot $names
      $sw = [System.Diagnostics.Stopwatch]::StartNew()
      $r = RunStreams @('--interface', $l.IP) $Streams $Chunk
      $sw.Stop()
      $solo[$l.Alias] = $r.Sum / 1MB
      Write-Host ("  [{0,-14}] {1:N2} MB/s ({2:N1} Mbps)  各流: {3}" -f $l.Alias, ($r.Sum / 1MB), ($r.Sum * 8 / 1MB), $r.Detail)
    }
    $sum = ($solo.Values | Measure-Object -Sum).Sum
    $max = ($solo.Values | Measure-Object -Maximum).Maximum
    Write-Host ("  >>> 单条最好 {0:N2} MB/s; 全部之和 {1:N2} MB/s (= 理论叠加上限)" -f $max, $sum) -ForegroundColor Green
  }

  'unbound' {
    Head "默认路由吞吐($Streams 并发 x ${ChunkMB}MB) —— 验证聚合器"
    $a0 = Snapshot $names
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $r = RunStreams @() $Streams $Chunk
    $sw.Stop()
    $used = Report $a0 $names $sw.Elapsed.TotalSeconds '下载'
    Write-Host ("  并发速率合计: {0:N2} MB/s ({1:N1} Mbps)" -f ($r.Sum / 1MB), ($r.Sum * 8 / 1MB))
    Write-Host '  判定: 若该值明显高于任何单条链路的独立容量, 说明聚合器真的把流量散开了。'
  }
}
