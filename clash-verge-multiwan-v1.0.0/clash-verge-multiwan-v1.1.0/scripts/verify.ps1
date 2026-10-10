<#
.SYNOPSIS
  验证「多线聚合」是否真的生效 —— 直接问 mihomo 内核要答案。
.DESCRIPTION
  依次检查:
    1) 三个策略组是否存在、开关现在选的是哪一档
    2) 三个出口的 alive 与延迟(健康检查是否工作 —— 这是轮询的前提)
    3) 规则表里多线规则的位置与数量
    4) TUN / 系统代理 状态
    5) 三链路实际分摊(可选, -DistributionTest): 经系统代理拉多线程, 统计各物理网卡字节数
       —— 这是唯一在 TUN 开启时仍然有效的"叠加验证"方法
.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify.ps1
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify.ps1 -DistributionTest
#>
[CmdletBinding()]
param(
  [string]$Group = '多线聚合',
  [string]$Url = 'https://mirrors.tuna.tsinghua.edu.cn/ubuntu/ls-lR.gz',
  [int]$Streams = 6,
  [int]$ChunkMB = 4,
  [switch]$DistributionTest
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'mihomo-pipe.ps1')
function Head($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }
$enc = [uri]::EscapeDataString($Group)

Head '1. 策略组状态'
foreach ($n in @($Group, '多线直连', '多线-省流量')) {
  $e = [uri]::EscapeDataString($n)
  $o = Invoke-MihomoApi -Path "/proxies/$e" | ConvertFrom-MihomoJson
  if ($o) { Write-Host ("  {0,-12} type={1,-12} 成员={2} 当前={3}" -f $o.name, $o.type, $o.all.Count, $o.now) }
  else    { Write-Host ("  {0,-12} 查询失败(组不存在?)" -f $n) -ForegroundColor Yellow }
}

Head '2. 出口健康(轮询的前提)'
foreach ($m in 'WAN-PHONE', 'WAN-WIRED', 'WAN-WIFI') {
  $o = Invoke-MihomoApi -Path "/proxies/$m" | ConvertFrom-MihomoJson
  if ($o) {
    $d = '无记录'
    if ($o.history -and $o.history.Count -gt 0) { $d = "$($o.history[-1].delay) ms" }
    $flag = ''
    if (-not $o.alive) { $flag = '  <-- alive=false: load-balance 会退化成只用第一个成员!' }
    Write-Host ("  {0,-10} alive={1,-6} 延迟={2}{3}" -f $m, $o.alive, $d, $flag)
  }
}

Head '3. 规则表'
$rl = (Invoke-MihomoApi -Path '/rules').Body
if ($rl) {
  $cnt = ([regex]::Matches($rl, '"type":"[A-Za-z]+"')).Count
  Write-Host "  规则总数: $cnt"
  Write-Host "  含多线聚合目标: $($rl -match '多线聚合')"
  $first = [regex]::Matches($rl, '"payload":"([^"]{0,40})"') | Select-Object -First 4
  Write-Host ("  前几条: " + (($first | ForEach-Object { $_.Groups[1].Value }) -join ' , '))
  if ($rl -notmatch 'rom\.miui\.com') { Write-Host '  [!] 缺少 rom.miui.com -> DIRECT 放行规则, 健康检查可能被 GEOIP,CN 送回本组形成环路' -ForegroundColor Yellow }
}

Head '4. TUN / 系统代理'
$app = Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'
$vy = Join-Path $app 'verge.yaml'
if (Test-Path $vy) { (Select-String -Path $vy -Pattern 'enable_tun_mode|enable_system_proxy' | ForEach-Object { Write-Host "  $($_.Line.Trim())" }) }
$tun = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceDescription -match 'Meta Tunnel|wintun' }
Write-Host ("  TUN 网卡: " + $(if ($tun) { ($tun.Name -join ',') } else { '(无)' }))
$is = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
Write-Host "  系统代理: $($is.ProxyServer)  ProxyEnable=$($is.ProxyEnable)"

Head '5. 连通性'
$cn = & curl.exe -s -o NUL --max-time 10 -w '%{http_code}|%{time_total}' 'https://www.baidu.com/' 2>$null
Write-Host "  国内 百度        : $cn"
$gg = & curl.exe -x 'http://127.0.0.1:7897' -s -o NUL --max-time 15 -w '%{http_code}|%{time_total}' 'https://www.google.com/generate_204' 2>$null
Write-Host "  国外 google(代理): $gg"

if ($DistributionTest) {
  Head "6. 三链路实际分摊($Streams 流 x ${ChunkMB}MB 经系统代理)"
  $physical = Get-NetAdapter | Where-Object { $_.Status -eq 'Up' -and $_.InterfaceDescription -notmatch 'Meta Tunnel|wintun|TAP|Loopback' }
  $a0 = @{}; foreach ($n in $physical.Name) { $a0[$n] = (Get-NetAdapterStatistics -Name $n).ReceivedBytes }
  $jobs = @()
  for ($i = 0; $i -lt $Streams; $i++) {
    $from = $i * $ChunkMB * 1MB; $to = $from + $ChunkMB * 1MB - 1
    $jobs += Start-Job -ScriptBlock {
      param($u, $r)
      & curl.exe -x 'http://127.0.0.1:7897' -s -o NUL --max-time 60 -r $r -w '%{size_download}|%{speed_download}' $u
    } -ArgumentList $Url, "$from-$to"
  }
  Wait-Job $jobs -Timeout 120 | Out-Null
  $total = 0.0; $bytes = 0.0
  foreach ($j in $jobs) {
    $v = (Receive-Job $j) -join ''; $q = $v -split '\|'
    if ($q.Count -ge 2) { $bytes += [double]$q[0]; $total += [double]$q[1] }
    Remove-Job $j -Force
  }
  $sum = 0.0; $used = @()
  foreach ($n in $physical.Name) {
    $now = (Get-NetAdapterStatistics -Name $n).ReceivedBytes
    $d = $now - $a0[$n]
    if ($d -gt 100000) { Write-Host ("  {0,-14} {1,12:N0} B ({2,6:N2} MB)" -f $n, $d, ($d / 1MB)); $sum += $d; $used += $n }
  }
  Write-Host ("  共取到 {0:N2} MB; 并发速率合计 {1:N2} MB/s ({2:N1} Mbps)" -f ($bytes / 1MB), ($total / 1MB), ($total * 8 / 1MB))
  if ($used.Count -ge 2) { Write-Host "  ✓ 多线生效: $($used.Count) 条物理腿在同时承载 -> $($used -join ' / ')" -ForegroundColor Green }
  else { Write-Host "  ✗ 只有 $($used -join '') 在动 —— 轮询没生效(检查健康检查是否工作)" -ForegroundColor Yellow }
  Write-Host '  注: 统计已排除 Mihomo 虚拟网卡 —— 它和物理腿是同一份流量, 相加会翻倍。'
}
