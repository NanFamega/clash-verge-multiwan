<#
.SYNOPSIS
  按「真实吞吐」而不是「延迟」挑选最快的代理节点, 并设为当前选择。

.DESCRIPTION
  为什么需要这个脚本:
    Clash 的 url-test / 自动选择 组是按**延迟**排序的 —— 延迟低 ≠ 速度快。
    实测踩坑: 自动选择挑中的节点延迟 389ms 看起来能用, 但吞吐只有 7.5 KB/s
    (下 2.5MB 用了 25 秒); 换一个"延迟稍高"的节点, 同一目标有 4 MB/s。
    机场的节点质量差异极大, 用延迟挑必然踩雷。

  本脚本:
    1) 从运行时配置里取出全部节点名
    2) 用内核 API 逐个测延迟, 先筛掉死的(这一步快)
    3) 对活着的节点逐个**实测下载吞吐**, 排序
    4) 把主策略组切到最快的那个
    5) 报告一张"节点吞吐排行榜", 便于你手工挑选

.PARAMETER SampleUrl
  吞吐测试用的下载地址。默认 Cloudflare 的测速端点(8MB 档)。
  若该地址在你的网络下不可用, 可换成任意大文件直链。

.PARAMETER PerNodeMB
  每个节点下载多少 MB 用于测速(默认 2.5MB)。

.PARAMETER MaxNodes
  最多测多少个活节点(默认 6, 避免长时间占用带宽)。

.PARAMETER Group
  要切换的目标组名; 默认自动从订阅的 MATCH 规则里取主策略组。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\pick-fastest-node.ps1
  powershell ... -File .\scripts\pick-fastest-node.ps1 -PerNodeMB 4 -MaxNodes 8
#>
[CmdletBinding()]
param(
  [string]$VergeDir = (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'),
  [string]$Group = '',
  [string]$SampleUrl = 'https://speed.cloudflare.com/__down?bytes=8000000',
  [double]$PerNodeMB = 2.5,
  [int]$MaxNodes = 6,
  [int]$DelayTimeout = 3000,
  [int]$Port = 7897
)
$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'mihomo-pipe.ps1')
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)

# ---------- 找主策略组 ----------
if (-not $Group) {
  $cur = ''
  foreach ($l in [System.IO.File]::ReadAllLines((Join-Path $VergeDir 'profiles.yaml'), $Utf8NoBom)) {
    if ($l -match '^current:\s*(\S+)') { $cur = $Matches[1]; break }
  }
  $pf = Join-Path $VergeDir "profiles\$cur.yaml"
  if (Test-Path $pf) {
    foreach ($l in [System.IO.File]::ReadAllLines($pf, $Utf8NoBom)) {
      if ($l -match 'MATCH\s*,\s*([^''"\s]+)') { $Group = $Matches[1] }
    }
  }
}
if (-not $Group) { throw '无法确定主策略组名, 请用 -Group 指定' }
Write-Host "主策略组: $Group" -ForegroundColor Cyan

$g = Invoke-MihomoApi -Path "/proxies/$([uri]::EscapeDataString($Group))" | ConvertFrom-MihomoJson
if (-not $g) { throw "组 $Group 不存在" }
Write-Host "  类型=$($g.type)  当前=$($g.now)  成员数=$($g.all.Count)"

# ---------- 筛出活节点 ----------
Write-Host "`n=== 1) 先用延迟筛掉死节点(每个 $DelayTimeout ms) ===" -ForegroundColor Cyan
$alive = @()
foreach ($n in $g.all) {
  $r = Invoke-MihomoApi -Path "/proxies/$([uri]::EscapeDataString($n))/delay?timeout=$DelayTimeout&url=http://www.gstatic.com/generate_204" -TimeoutMs ($DelayTimeout + 3000)
  if ($r.Body -match '"delay":(\d+)') {
    $alive += [pscustomobject]@{ Name = $n; Delay = [int]$Matches[1] }
    Write-Host ("  OK  {0,-34} {1} ms" -f $n, $Matches[1]) -ForegroundColor Green
  } elseif ($r.Error) {
    Write-Host ("  ??  {0,-34} 解析异常: {1}" -f $n, $r.Error) -ForegroundColor Magenta
  } else {
    Write-Host ("  --  {0,-34} 超时/不可用" -f $n)
  }
}
if ($alive.Count -eq 0) { Write-Host '没有活节点, 先把订阅更新一下' -ForegroundColor Yellow; return }

# ---------- 测吞吐 ----------
Write-Host "`n=== 2) 对活节点实测吞吐(每个最多 ${PerNodeMB}MB) ===" -ForegroundColor Cyan
$sorted = $alive | Sort-Object Delay | Select-Object -First $MaxNodes
$rows = @()
foreach ($n in $sorted) {
  [void](Set-MihomoSelection -Group $Group -Select $n.Name)
  Start-Sleep -Milliseconds 1500
  $bytes = [int]($PerNodeMB * 1MB)
  $r = (& curl.exe -x "http://127.0.0.1:$Port" -s -o NUL --max-time 25 -r "0-$($bytes - 1)" -w '%{http_code}|%{speed_download}|%{size_download}' $SampleUrl 2>&1) -join ''
  $q = $r -split '\|'
  $sp = 0.0; if ($q.Count -ge 2) { [void][double]::TryParse($q[1], [ref]$sp) }
  $rows += [pscustomobject]@{ Name = $n.Name; Delay = $n.Delay; MBs = [math]::Round($sp / 1MB, 2); Got = $q[2] }
  Write-Host ("  {0,-34} 延迟={1,5}ms  吞吐={2,6} MB/s  收到={3} B" -f $n.Name, $n.Delay, [math]::Round($sp / 1MB, 2), $q[2])
}

# ---------- 选最快 ----------
Write-Host "`n=== 3) 排行榜(按吞吐) ===" -ForegroundColor Cyan
$rank = $rows | Sort-Object MBs -Descending
$rank | Format-Table Name, Delay, MBs -AutoSize
$best = $rank | Select-Object -First 1
if ($best -and $best.MBs -gt 0) {
  [void](Set-MihomoSelection -Group $Group -Select $best.Name)
  Write-Host "  >>> 已把 [$Group] 切到最快节点: $($best.Name)  ($($best.MBs) MB/s, 延迟 $($best.Delay) ms)" -ForegroundColor Green
} else {
  Write-Host '  [!] 所有节点吞吐都接近 0 —— 机场侧问题, 建议换机场或更新订阅' -ForegroundColor Yellow
}
Write-Host "`n  提示: 延迟低不代表快。以后觉得慢就先跑一遍本脚本。" -ForegroundColor DarkGray
