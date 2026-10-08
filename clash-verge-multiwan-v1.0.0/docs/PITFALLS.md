# 踩坑清单（全部为真机实测，不是推测）

> 按"症状 → 根因 → 处置"组织。前三条是**会让整个网络看起来崩掉**的级别。

---

## 1. DNS 自锁 —— 症状是"整个网络全 timeout"，而这跟多线聚合其实无关

**症状**：所有站点都卡死/超时，`alive=false`，节点全部连不上。国内站点可能还能开，海外全挂。
清 DNS 缓存、换节点、重启内核都无效。

**根因链**（实测确证）：

```
订阅节点抖动/失效
  → 订阅的 dns 配了 fallback: [1.1.1.1, 8.8.8.8]
  → 而规则表里偏偏有 IP-CIDR,1.1.1.1/32 → <代理组> 和 8.8.8.8/32 → <代理组>
  → fallback 查询被送进已挂的代理节点 → 每个查询等 5 秒超时
  → 所有需要 fallback 的海外域名解析失败（包括节点自己的域名）
  → 节点永远连不上 → fallback 永远超时   ← 永久自锁
```

TUN 模式下**所有程序**的 DNS 都走内核，所以症状是"每个新域名都卡 5 秒"。

**判定证据**：`GET /dns/query?name=<域名>&type=A`
- 国内域名毫秒级返回 ✓
- 海外域名固定 **5001 ms** 后失败 ✗

**处置**：清空海外 fallback（`templates/merge-dns.yaml`），写进**全局扩展配置**。
走代理的域名由节点远端解析，本地 DNS 结果不影响它们，所以这个取舍是划算的。

**教训**："DNS 依赖代理"这个设计本身有自锁隐患。用国内 DoH/DoT 做 fallback 才是安全做法。

---

## 2. load-balance 没有健康检查 = 完全不轮询

**症状**：三条腿都配好了，但下载只走**第一条**腿，其他两条 0 字节。

**根因**：不写 `url` / `interval` 时，成员的 `alive` 恒为 `false`；
mihomo 的 load-balance 在此状态下退化成"只使用列表里的第一个成员"。

**实测对比**：
- 无健康检查：8 条并发流 → 全部走 `WAN-PHONE`（第一个成员）
- 有健康检查：8 条并发流 → **3/2/3** 分摊到三条腿（`9.55 / 6.27 / 9.38 MB`）

**处置**：`url: http://connect.rom.miui.com/generate_204` + `interval: 300`。

---

## 3. 健康检查 URL 选错 = 全部成员被判死

**症状**：`alive=false`、延迟 0ms，组内无可用成员。

**根因**：健康检查 URL 用了 `cp.cloudflare.com` / `www.gstatic.com` 这类**国内直连不可达**的端点
（实测返回 `HTTP 000`）→ 三个出口全部超时 → 判死。

**处置**：用国内可达的 204 端点。实测可用：
`connect.rom.miui.com` (0.19s) / `wifi.vivo.com.cn` (0.12s) / `connectivitycheck.platform.hicloud.com` (0.09s)；
`cp.cloudflare.com` **不可用**（`000`）。

---

## 4. 健康检查被 `GEOIP,CN` 绕回自己检测的那个组（环路）

**症状**：加了 `GEOIP,CN → 多线聚合` 之后，全部成员突然 `alive=false`。

**根因**：健康检查 URL 是**国内 IP**，被 `GEOIP,CN` 命中 → 送进"正在被检测的那个组" → 自己检测自己。
（是否真会形成环路取决于内核实现，但**实测出现该症状**。）

**处置**：规则最前面加 `DOMAIN-SUFFIX,rom.miui.com,DIRECT`。
即使内核本就不走规则，这条放行也无害 —— 属于"零代价保险"。

**安全网**：实测"全部判死"**不会**让流量断掉（mihomo 会退回到第一个成员继续工作），
所以这个故障是"降级"而不是"灾难"。

---

## 5. v1.7+ 起 `prepend-rules` 写进扩展配置完全无效

**症状**：规则写进「全局扩展配置」，重新应用后内核里一条都没有。

**根因**：Clash Verge Rev v1.7+ 起，「扩展配置」只做**配置项覆写/合并**。
`prepend-rules` / `prepend-proxies` / `prepend-proxy-groups` 会作为**废键**被原样合并进配置
（能在运行时 YAML 里看到 `prepend-rules:` 这个顶层键，但内核不认）。

**判定**：看 `clash-verge.yaml` 里有没有字面量 `prepend-` 顶层键；并直接问内核 `/rules` 条数。

**处置**：加规则/节点/代理组必须用订阅的 `option.rules / proxies / groups`（UI：右键订阅 → 编辑规则/节点/代理组）。
⚠️ 网上大量教程仍在教旧写法。

---

## 6. 每个订阅的扩展位是**独立文件**，换订阅后全部失效

**症状**：换了新机场订阅，多线聚合功能消失。

**根因**：Verge 给每个订阅在 `profiles.yaml` 里维护一组 `option` 绑定，指向**以 uid 命名的文件**
（如 `pa1HxIvWQgyo.yaml`）。

**处置**：对当前订阅重跑 `install.ps1`（它按 `profiles.yaml` 的 `option` 自动定位）。
全局项（`uid: Merge` 的扩展配置）对所有订阅生效，DNS 修复不需要重做。

---

## 7. TUN 开启时，源 IP 绑定测试全部失败 —— 这是**测试方法**的问题

**症状**：`curl --interface <物理网卡IP>` 对任何目标都返回 `HTTP 000`，看起来"网卡坏了"。

**根因**：TUN 的 `auto-route` 抢走了默认路由。绑定源 IP 的报文仍然按目的地址查路由
→ 被吸进隧道 → 内核发现源 IP 不是自己的 → 丢弃。

**证据**：同一时刻只有绑到隧道地址（`198.18.0.1`）的测试能通。

**处置**：
- 要测逐链路容量 → **先关 TUN**，再跑 `link-bench.ps1 -Mode bound`
- TUN 开启时 → 用 `link-bench.ps1`（默认 proxy 模式）或 `verify.ps1 -DistributionTest`：
  经系统代理拉多流，看**各物理网卡的字节数**

---

## 8. 统计网卡流量时不能把 Mihomo 虚拟网卡算进去（否则翻倍）

**症状**：算出 "66 MB/s (528 Mbps)"，实际只有一半。

**根因**：`Mihomo` 虚拟网卡看到的流量与三条物理腿**是同一份**。
`12.04 + 9.26 + 11.69 + 33.12(Mihomo) = 66.11`，而 `33.12` 恰好等于三条腿之和。

**处置**：求和时排除名称/描述含 `Mihomo`、`Meta Tunnel`、`wintun` 的适配器。

---

## 9. 单条 TCP 连接永远不会变快

**根因**：连接级的负载均衡只能在"新建连接"时选出口；一条已建立的 TCP 流锁死在一条链路上。

**表现**：浏览器单线程下载 ≈ 单腿速度；IDM/aria2 -x16/BT 才能吃满多条之和。

**想给单连接提速**只有包级 bonding（Speedify / Dispatch PRO 之类），本项目不提供。

---

## 10. 判断"节点是不是死了"不能用系统侧测端口

**症状**：`Test-NetConnection` / `curl` 连节点服务器的端口，**0–1 ms 就"成功"**，看起来全都活着。

**根因**：TUN 开启时，本地内核先把 TCP 握手应答了（隧道本地终止），报文根本没到服务器。

**处置**：只用内核自己的探测：`GET /proxies/{name}/delay?timeout=4000&url=...`
（它用 mihomo 自己的 socket，绕过隧道）。

---

## 11. 机场的"几十个节点"常常只是同一台服务器的不同端口

**实测**：47 个节点 → 41 个不同端口 → **全部指向同一台服务器**；逐端口探测后
**只有 1 个端口活着**（`44444`，111 ms），其余全超时。

**结论**：这种"大部分节点 timeout"是**机场侧问题**（服务器缩容/端口关闭），
不是本地网络、不是校园网、不是配置问题。

**处置**：`scripts/diagnose-nodes.ps1` 出清单；然后更新订阅 / 看机场公告 / 换机场。
**风险**：只剩一个可用端点时，它挂掉就全断，别拖。

---

## 12. 游戏平台下载走"裸 IP"，域名规则抓不到

**实测**：WeGame 的 `TinyDL64.exe` 直连 `39.134.x.x` / `39.136.x.x`（移动 CDN）与
`*.myqcloud.com`，**没有域名**，所以 `DOMAIN-SUFFIX` 规则一律不命中。

**处置**：靠规则 ④ 的 `GEOIP,CN → 多线聚合` 兜底（实测 `repo.huaweicloud.com` 与游戏 CDN 都能被兜住）。

---

## 13. `PROCESS-NAME` 规则在 Windows + TUN 下不可靠

**实测**：给 `TinyDL64` 写了 `PROCESS-NAME` 规则，内核 `/connections` 里明明显示
`processPath = TinyDL64.exe`，但规则**没有命中**，流量落到了后面的 `GEOIP,CN,DIRECT`。

**根因**：TUN 新建连接时做进程匹配存在竞态（连接刚建立那一刻查不到进程），规则静默漏过。

**处置**：进程规则只当"锦上添花"，**必须**有 IP/域名规则兜底。

---

## 14. Steam 下载慢：不是带宽问题，是"被当成国外用户"

**实测**：Steam 内容下载走 `*.steamserver.net`（当时是 `cmp3-hkg1` 香港节点），
被 `MATCH,<代理组>` 送进订阅节点 → 只有 **3–4 MB/s**。
而放行后走本地直连，速度立刻恢复正常。

**根因**：下载走代理 → Steam 看到的是节点出口 IP → 把它当国外用户 → 分配香港/新加坡 CDN
→ 数据再经节点绕回来。**双重惩罚。**

**处置**：只放行**内容下载**域名到多线（`steamserver.net` / `steamcontent.com` / `steamstatic.com`），
**商店/社区/聊天保持走代理**（`steamcommunity.com` / `steam-chat.com` / `steampowered.com`）。
放行后重启 Steam 让它重选 CDN，必要时手动把下载区域设成国内城市。

---

## 15. 「编辑节点」扩展会把新节点塞进订阅主策略组

**现象**：Verge 运行时配置里，主策略组（如 `传送门`）的 `proxies` 数组**最前面**多出
`WAN-PHONE / WAN-WIRED / WAN-WIFI`。虽然没被选中，但列表不干净，误选就断网。

**处置**：用订阅的**扩展脚本**（`option.script`）在最后一步过滤掉。
执行链：全局扩展配置 → 全局扩展脚本 → **订阅扩展配置** → **订阅扩展脚本**，脚本能看到并修正最终结果。

---

## 16. PowerShell 5.1 读 YAML 必须显式指定 UTF-8

**症状**：`Get-Content` 读 Verge 的配置，中文全变乱码（`传送门` → `浼犻€侀棬`），
把内容写回去直接破坏配置（实测导致 YAML 解析失败 `line 26: did not find expected key`）。

**根因**：PS 5.1 的 `Get-Content` 默认按系统 ANSI（中文机器上是 GBK）解码。

**处置**：
```powershell
[System.IO.File]::ReadAllLines($path, [System.Text.UTF8Encoding]::new($false))
[System.IO.File]::WriteAllText($path, $text, [System.Text.UTF8Encoding]::new($false))
```
写入 .ps1 脚本本身时若要含中文，需要 **带 BOM 的 UTF-8**（否则 PS 5.1 也会按 ANSI 解析脚本）。

---

## 17. mihomo 的 select 组切换：PowerShell 传 JSON 会吃掉引号

**症状**：`curl -X PUT -d '{"name":"DIRECT"}'` 返回 400，切换无效。

**根因**：PS 5.1 向原生程序传参时会剥离内嵌双引号，curl 收到的是 `{name:DIRECT}`。

**处置**：把 body 写进文件用 `--data-binary "@file"`，或用内核管道（见 `mihomo-pipe.ps1` 的 `Set-MihomoSelection`）。

---

## 18. mihomo 的 `/connections` `/rules` 是 chunked 编码，必须字节级解分块

**症状**：`Content-Length: 0`、JSON 解析失败、或者 JSON 被截断。

**根因**：这两个端点用 `Transfer-Encoding: chunked`；用"读到 `}` 就停"的启发式会在分块边界截断。

**处置**：读满整个响应 → 定位 `\r\n\r\n` → 按 chunk 长度逐块拼接 → 再按 UTF-8 解码。
（`scripts/mihomo-pipe.ps1` 已实现。）

---

## 19. 改完文件 Verge 不会自动重载

**处置**：配置页 → 对应扩展项 → 右键「禁用」再「启用」，或点卡片右上角 🔥。
`install.ps1` 结束时也会提示这一步。

---

## 20. 校园网两条腿可能"同源"但仍能叠加

**实测**：有线与无线的公网出口 IP 不同（`58.241.163.208` / `.204`），说明校园网**按出口 IP/会话限速**
→ 两条腿能线性相加（实测达成率 103.8%）。
后来手机改走校园 Wi-Fi 共享，拿到第三个出口 IP（`.203`），三腿仍能相加。

**但要注意**：若三条腿共用同一个受总带宽限制的上游，叠加收益会明显变小。

**附带经验**：把手机从 5G 换成校园 Wi-Fi 共享，是用**速度**换**零流量** ——
手机腿的贡献从 ~25 MB/s 降到 ~12 MB/s，三腿合计从 ~50 MB/s 降到 ~33 MB/s。
