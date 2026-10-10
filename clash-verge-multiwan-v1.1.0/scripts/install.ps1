<#
.SYNOPSIS
  把「多线聚合 (Multi-WAN Load Balancing)」扩展一键部署到 Clash Verge Rev 的当前订阅。

.DESCRIPTION
  做四件事:
    1) 自动探测本机三条出口网卡(手机USB共享 / 有线 / 无线), 并填入模板占位符
    2) 解析 %APPDATA%\io.github.clash-verge-rev.clash-verge-rev\profiles.yaml,
       找出当前订阅的扩展绑定(proxies / groups / rules / script 四项对应的文件)
    3) 把 templates\ 里的模板写入这些文件(原文件先备份)
    4) 把 DNS 自锁修复写入「全局扩展配置」(uid=Merge) 的文件, 对所有订阅生效

  为什么必须走这四个"扩展位"而不是全局 Merge:
    Clash Verge Rev v1.7+ 起, 「扩展配置」只做配置项覆写/合并,
    prepend-rules / prepend-proxies / prepend-proxy-groups 不再生效(会作为废键被原样合并)。
    加规则/节点/代理组必须用: 右键订阅 -> 编辑规则 / 编辑节点 / 编辑代理组。

.PARAMETER VergeDir
  Clash Verge Rev 的应用数据目录, 默认 %APPDATA%\io.github.clash-verge-rev.clash-verge-rev

.PARAMETER ProfileUid
  目标订阅的 uid; 默认取 profiles.yaml 里的 current。

.PARAMETER NicPhone / NicWired / NicWifi
  手工指定三块网卡名(默认自动探测)。

.PARAMETER SkipDnsFix
  跳过全局 DNS 自锁修复的写入。

.PARAMETER DryRun
  只打印将要执行的动作, 不写任何文件。

.EXAMPLE
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -DryRun
  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1
#>
[CmdletBinding()]
param(
  [string]$VergeDir = (Join-Path $env:APPDATA 'io.github.clash-verge-rev.clash-verge-rev'),
  [string]$ProfileUid = '',
  [string]$NicPhone = '',
  [string]$NicWired = '',
  [string]$NicWifi = '',
  [switch]$SkipDnsFix,
  [switch]$DryRun
)

$ErrorActionPreference = 'Stop'
$Utf8NoBom = [System.Text.UTF8Encoding]::new($false)
$RepoRoot  = Split-Path -Parent $PSScriptRoot
$TplDir    = Join-Path $RepoRoot 'templates'
$Stamp     = Get-Date -Format 'yyyyMMdd-HHmmss'

function Info($m) { Write-Host "  $m" }
function Head($m) { Write-Host "`n=== $m ===" -ForegroundColor Cyan }

# ---------------------------------------------------------------- 1. 前置检查
Head '1. 环境检查'
if (-not (Test-Path $VergeDir))            { throw "找不到 Clash Verge 数据目录: $VergeDir (用 -VergeDir 手工指定)" }
$profilesPath = Join-Path $VergeDir 'profiles.yaml'
if (-not (Test-Path $profilesPath))        { throw "找不到 profiles.yaml: $profilesPath" }
foreach ($t in 'proxies.yaml','groups.yaml','rules.yaml','merge-dns.yaml','cleanup-script.js') {
  if (-not (Test-Path (Join-Path $TplDir $t))) { throw "缺少模板文件: templates\$t" }
}
Info "Verge 数据目录: $VergeDir"
Info ("内核进程: " + @(Get-Process verge-mihomo -ErrorAction SilentlyContinue).Count + " 个")

# ---------------------------------------------------------------- 2. 探测网卡
Head '2. 探测三条出口网卡'
if (-not $NicPhone -or -not $NicWired -or -not $NicWifi) {
  $cands = Get-NetIPConfiguration | Where-Object {
    $_.NetAdapter.Status -eq 'Up' -and $_.IPv4DefaultGateway -and
    $_.InterfaceAlias -notmatch 'Loopback|Mihomo|TAP|wintun|Bluetooth'
  }
  foreach ($c in $cands) {
    $d = $c.NetAdapter.InterfaceDescription
    if (-not $NicPhone -and $d -match 'NDIS|Tethering|RNDIS|Android|iPhone') { $NicPhone = $c.InterfaceAlias; continue }
    if (-not $NicWifi  -and $d -match 'Wi-?Fi|Wireless|WLAN|802\.11')      { $NicWifi  = $c.InterfaceAlias; continue }
    if (-not $NicWired -and $d -match 'Ethernet|PCIe|GbE|Gigabit')         { $NicWired = $c.InterfaceAlias; continue }
  }
  # 兜底: 仍未识别的, 按顺序填空
  foreach ($c in $cands) {
    if (-not $NicWired -and $c.InterfaceAlias -ne $NicPhone -and $c.InterfaceAlias -ne $NicWifi) { $NicWired = $c.InterfaceAlias }
  }
}
Info "手机USB共享: '$NicPhone'"
Info "有线       : '$NicWired'"
Info "无线       : '$NicWifi'"
if (-not $NicPhone -or -not $NicWired -or -not $NicWifi) {
  Write-Warning '有网卡未识别到。可先确保三条链路都插好/连上再跑, 或用 -NicPhone/-NicWired/-NicWifi 手工指定。'
}

# ------------------------------------------------------- 3. 解析订阅扩展绑定
Head '3. 解析当前订阅的扩展绑定'
$current = ''
$items = New-Object System.Collections.Generic.List[object]
$cur = $null; $inOpt = $false
foreach ($line in [System.IO.File]::ReadAllLines($profilesPath, $Utf8NoBom)) {
  if ($line -match '^current:\s*(\S+)') { $current = $Matches[1]; continue }
  if ($line -match '^\s*-\s*uid:\s*(\S+)') {
    if ($cur) { $items.Add([pscustomobject]$cur) }
    $cur = [ordered]@{ uid = $Matches[1]; type = ''; file = ''; option = @{} }
    $inOpt = $false; continue
  }
  if (-not $cur) { continue }
  if ($line -match '^\s*type:\s*(\S+)') { $cur.type = $Matches[1]; continue }
  if ($line -match '^\s*file:\s*(\S+)') { $cur.file = $Matches[1]; continue }
  if ($line -match '^\s*option:\s*$')   { $inOpt = $true; continue }
  if ($inOpt -and $line -match '^\s+(merge|script|rules|proxies|groups):\s*(\S+)') { $cur.option[$Matches[1]] = $Matches[2]; continue }
}
if ($cur) { $items.Add([pscustomobject]$cur) }

if (-not $ProfileUid) { $ProfileUid = $current }
Info "目标订阅 uid: $ProfileUid  (current=$current)"
$profile = $items | Where-Object { $_.uid -eq $ProfileUid } | Select-Object -First 1
if (-not $profile) { throw "profiles.yaml 里找不到 uid=$ProfileUid 的订阅项" }
Info "订阅类型: $($profile.type)  文件: $($profile.file)"

function Resolve-File([string]$optUid) {
  if (-not $optUid) { return '' }
  $it = $items | Where-Object { $_.uid -eq $optUid } | Select-Object -First 1
  if ($it -and $it.file) { return $it.file }
  return "$optUid.yaml"
}

$targets = [ordered]@{}
foreach ($k in 'proxies','groups','rules','script') {
  $u = $profile.option[$k]
  if ($u) { $targets[$k] = Resolve-File $u } else { Info "[$k] 未绑定 -> 需要先在 UI 里创建" }
}
foreach ($k in $targets.Keys) { Info "[$k] -> $($targets[$k])" }

$missing = @('proxies','groups','rules','script') | Where-Object { -not $targets.Contains($_) }
if ($missing.Count -gt 0) {
  Write-Warning ("缺少扩展绑定: {0}" -f ($missing -join ', '))
  Write-Warning '解决办法: 在 Verge 里右键该订阅 -> 分别点一次「编辑节点 / 编辑代理组 / 编辑规则 / 扩展脚本」(各保存一次即可创建绑定), 然后重新运行本脚本。'
}

# ---------------------------------------------------------------- 4. 写入文件
Head '4. 写入扩展文件'
function Write-Utf8([string]$Path, [string]$Text) {
  $b = $null
  if (Test-Path $Path) { $b = "$Path.bak-$Stamp"; Copy-Item $Path $b -Force }
  if ($DryRun) { Info "[DryRun] 将写入 $Path  ($($Text.Length) 字符)" + $(if ($b) { "  备份 -> $b" } else { '' }) ; return }
  [System.IO.File]::WriteAllText($Path, $Text, $Utf8NoBom)
  Info "已写入 $Path" + $(if ($b) { "   (备份 $b)" } else { '   (新建)' })
}

$map = [ordered]@{
  proxies = @{ tpl = 'proxies.yaml';      file = $targets['proxies'] }
  groups  = @{ tpl = 'groups.yaml';       file = $targets['groups']  }
  rules   = @{ tpl = 'rules.yaml';        file = $targets['rules']   }
  script  = @{ tpl = 'cleanup-script.js'; file = $targets['script']  }
}
foreach ($k in $map.Keys) {
  if (-not $map[$k].file) { continue }
  $text = [System.IO.File]::ReadAllText((Join-Path $TplDir $map[$k].tpl), $Utf8NoBom)
  if ($k -eq 'proxies') {
    $text = $text.Replace('{{NIC_PHONE}}', $NicPhone).Replace('{{NIC_WIRED}}', $NicWired).Replace('{{NIC_WIFI}}', $NicWifi)
  }
  Write-Utf8 (Join-Path $VergeDir "profiles\$($map[$k].file)") $text
}

# ------------------------------------------------- 5. 全局 DNS 自锁修复
if (-not $SkipDnsFix) {
  Head '5. 写入全局 DNS 自锁修复 (对所有订阅生效)'
  $mergeItem = $items | Where-Object { $_.uid -eq 'Merge' } | Select-Object -First 1
  if (-not $mergeItem) {
    Write-Warning 'profiles.yaml 里没有 uid=Merge 的全局扩展配置项, 跳过 DNS 修复。'
    Write-Warning '可手工把 templates\merge-dns.yaml 的内容贴进「全局扩展配置」。'
  } else {
    $mf = if ($mergeItem.file) { $mergeItem.file } else { 'Merge.yaml' }
    $text = [System.IO.File]::ReadAllText((Join-Path $TplDir 'merge-dns.yaml'), $Utf8NoBom)
    Write-Utf8 (Join-Path $VergeDir "profiles\$mf") $text
  }
} else { Head '5. 已按 -SkipDnsFix 跳过 DNS 修复' }

# ---------------------------------------------------------------- 6. 下一步
Head '6. 接下来必须做的事'
Info '1) 打开 Clash Verge -> 配置页 -> 找到刚改动的扩展项, 右键「禁用」再「启用」'
Info '   (或点该卡片右上角的 🔥), 让 Verge 重新生成运行时配置。'
Info '2) 在「代理」页把开关组 [多线聚合] 切成 [多线直连](三链路) 或 [多线-省流量](不耗手机流量)。'
Info '3) 验证:  powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify.ps1'
Info ''
Info '注意: mihomo 的 load-balance 组必须带 url/interval 健康检查才会轮询;'
Info '      没有健康检查时会退化成"只用第一个成员"(模板里已经带上, 别删)。'
