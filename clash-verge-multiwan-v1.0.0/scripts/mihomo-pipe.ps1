# ============================================================================
#  mihomo-pipe.ps1 —— 通过命名管道直连 mihomo 内核 RESTful API 的工具函数
#
#  用法:  . .\scripts\mihomo-pipe.ps1
#         $g = Invoke-MihomoApi -Path '/proxies/%E5%A4%9A%E7%BA%BF%E8%81%9A%E5%90%88' | ConvertFrom-MihomoJson
#
#  为什么需要它:
#    Clash Verge 默认把内核的 external-controller 关掉(config.yaml 里是 ''), 改用
#    Windows 命名管道 \\.\pipe\verge-mihomo-production-<hash> 通信。
#    所以想"问内核"只能走管道; 管道里跑的是 HTTP, 且 /connections /rules 等大响应
#    用 Transfer-Encoding: chunked —— 必须做字节级分块解码, 否则 JSON 解不出来。
#
#  已验证端点: /version /proxies /proxies/{name} /proxies/{name}/delay /rules
#             /connections /cache/fakeip/flush /cache/dns/flush /configs(PUT)
# ============================================================================

function Get-MihomoPipeName {
  [CmdletBinding()]
  param()
  $pipes = [System.IO.Directory]::GetFiles('\\.\pipe\') | Where-Object { $_ -match 'verge-mihomo' }
  $p = ($pipes | Where-Object { $_ -match 'production' } | Select-Object -First 1)
  if (-not $p) { $p = ($pipes | Select-Object -First 1) }
  if (-not $p) { throw '找不到 mihomo 命名管道 —— 确认 Clash Verge 正在运行且内核已启动' }
  return ($p -replace '^\\\\\.\\pipe\\', '')
}

function Invoke-MihomoApi {
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Path,
    [ValidateSet('GET', 'PUT', 'POST', 'PATCH', 'DELETE')][string]$Method = 'GET',
    [string]$Body = $null,
    [string]$Secret = 'set-your-secret',
    [int]$TimeoutMs = 15000,
    [string]$PipeName = ''
  )
  if (-not $PipeName) { $PipeName = Get-MihomoPipeName }
  $ps = New-Object System.IO.Pipes.NamedPipeClientStream('.', $PipeName, [System.IO.Pipes.PipeDirection]::InOut)
  try {
    $ps.Connect(5000)
    $h = "$Method $Path HTTP/1.1`r`nHost: localhost`r`nAccept: application/json`r`nConnection: close`r`n"
    if ($Secret) { $h += "Authorization: Bearer $Secret`r`n" }
    $bb = $null
    if ($null -ne $Body) {
      $bb = [System.Text.Encoding]::UTF8.GetBytes($Body)
      $h += "Content-Type: application/json`r`nContent-Length: $($bb.Length)`r`n"
    }
    $h += "`r`n"
    $hb = [System.Text.Encoding]::ASCII.GetBytes($h)
    $ps.Write($hb, 0, $hb.Length)
    if ($bb) { $ps.Write($bb, 0, $bb.Length) }
    $ps.Flush()

    # 读满整个响应直到管道关闭(不要用"看到 } 就停"的启发式, 会在分块边界截断)
    $ms = New-Object System.IO.MemoryStream
    $buf = New-Object byte[] 65536
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $TimeoutMs) {
      try { $n = $ps.Read($buf, 0, $buf.Length) } catch { break }
      if ($n -le 0) { break }
      $ms.Write($buf, 0, $n)
      if ($ms.Length -gt 16000000) { break }
    }
    $all = $ms.ToArray()
    $split = -1
    for ($i = 0; $i -lt $all.Length - 3; $i++) {
      if ($all[$i] -eq 13 -and $all[$i + 1] -eq 10 -and $all[$i + 2] -eq 13 -and $all[$i + 3] -eq 10) { $split = $i; break }
    }
    if ($split -lt 0) { return [pscustomobject]@{ Status = ''; Body = ''; Raw = '' } }
    $hdr = [System.Text.Encoding]::ASCII.GetString($all, 0, $split)
    $bp = $split + 4
    $body = $all[$bp..($all.Length - 1)]
    if ($hdr -match '(?i)Transfer-Encoding:\s*chunked') {
      $out = New-Object System.Collections.Generic.List[byte]
      $pos = 0
      while ($pos -lt $body.Length) {
        $nl = -1
        for ($k = $pos; $k -lt $body.Length - 1; $k++) { if ($body[$k] -eq 13 -and $body[$k + 1] -eq 10) { $nl = $k; break } }
        if ($nl -lt 0) { break }
        $sh = ([System.Text.Encoding]::ASCII.GetString($body, $pos, $nl - $pos) -split ';')[0].Trim()
        $size = 0
        try { $size = [Convert]::ToInt32($sh, 16) } catch { break }
        if ($size -le 0) { break }
        $st = $nl + 2
        if ($st + $size -gt $body.Length) { $size = $body.Length - $st }
        for ($k = 0; $k -lt $size; $k++) { $out.Add($body[$st + $k]) }
        $pos = $st + $size + 2
      }
      $body = $out.ToArray()
    }
    return [pscustomobject]@{
      Status = ($hdr -split "`r`n")[0]
      Body   = [System.Text.Encoding]::UTF8.GetString($body)
      Raw    = $hdr
    }
  }
  finally { $ps.Dispose() }
}

function ConvertFrom-MihomoJson {
  [CmdletBinding()]
  param([Parameter(ValueFromPipeline = $true)]$InputObject)
  process {
    $text = $null
    if ($InputObject -is [string]) { $text = $InputObject }
    elseif ($InputObject -and $InputObject.Body) { $text = $InputObject.Body }
    if (-not $text) { return $null }
    $i = $text.IndexOf('{')
    if ($i -lt 0) { return $null }
    try { return ($text.Substring($i) | ConvertFrom-Json) } catch { return $null }
  }
}

function Set-MihomoSelection {
  <#  切换 select 组的当前选择, 例如:
        Set-MihomoSelection -Group '多线聚合' -Select '多线-省流量'
      注意: Body 必须用文件或字节传递 —— PowerShell 5.1 向原生程序传参时会吃掉双引号。 #>
  [CmdletBinding()]
  param(
    [Parameter(Mandatory = $true)][string]$Group,
    [Parameter(Mandatory = $true)][string]$Select
  )
  $enc = [uri]::EscapeDataString($Group)
  $body = '{"name":"' + $Select + '"}'
  $r = Invoke-MihomoApi -Method PUT -Path "/proxies/$enc" -Body $body
  return $r.Status
}
