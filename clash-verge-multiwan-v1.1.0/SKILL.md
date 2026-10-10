---
name: clash-verge-multiwan
description: 在 Windows 的 Clash Verge Rev (mihomo 内核) 上启用多链路负载均衡——把有线/无线/手机USB共享按连接轮询分发，含一键开关、DNS 自锁修复、订阅级扩展绑定、内核级验证与故障诊断。当用户提到"多线聚合 / 带宽叠加 / 多网卡负载均衡 / 让下载走多条线路 / 手机USB共享+宽带一起用 / 校园网多条出口"时使用。
---

# 多线聚合（Clash Verge Rev + mihomo，Windows）

## 何时使用

用户希望**同时使用多条网络出口**来提升多线程下载速度、或让某条出口故障时自动切换。典型场景：宿舍有线 + 校园 Wi-Fi + 手机 USB 共享。

## 关键前提（先确认，别直接动手）

1. 客户端是 **Clash Verge Rev 2.x**（不是原版 Clash Verge、不是 Clash for Windows）。判定：存在 `%APPDATA%\io.github.clash-verge-rev.clash-verge-rev\profiles.yaml`。
2. **内核版本 ≥ v1.19**（`mihomo -v`）。判定方式：脚本里通过命名管道 `GET /version`。
3. **至少两条**已连接且带默认网关的物理出口。用 `Get-NetIPConfiguration` 枚举（`Status -eq 'Up'` 且有 `IPv4DefaultGateway`），排除 `Meta Tunnel / wintun / TAP / Loopback / Bluetooth`。
4. 用户是否接受"出口 IP 会轮换"（会影响登录/支付类站点的风控）。

## 部署步骤

```powershell
# 0) 先看清要改什么（不写任何文件）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -DryRun

# 1) 部署：自动探测三条网卡、定位当前订阅的扩展位、写入模板、原文件备份
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1
```

`install.ps1` 会把 5 个模板写进 Verge 的这五个位置（**必须是这五个，见下方"致命约束"**）：

| 模板 | 写入位置 | 作用 |
|---|---|---|
| `templates/proxies.yaml` | 订阅 `option.proxies` 对应的文件 | 3 个 `type: direct` + `interface-name` 绑定网卡的出口 |
| `templates/groups.yaml` | 订阅 `option.groups` 对应的文件 | `多线聚合`(select 开关) / `多线直连`(load-balance×3) / `多线-省流量`(×2) |
| `templates/rules.yaml` | 订阅 `option.rules` 对应的文件 | 哪些流量走多线（含内网/校园网/IP敏感保护 + `GEOIP,CN` 兜底） |
| `templates/cleanup-script.js` | 订阅 `option.script` 对应的文件 | 清理 Verge 往主策略组里塞 WAN-* 的副作用 |
| `templates/merge-dns.yaml` | 全局项（`uid: Merge`）的文件 | 修复 DNS 自锁（对所有订阅生效） |

## 致命约束（违反任一条都会静默失效）

1. **v1.7+ 起「扩展配置」不再处理 `prepend-rules` / `prepend-proxies` / `prepend-proxy-groups`。**
   写进全局 Merge 只会变成废键（内核里一条都不生效）。加规则/节点/代理组**必须**用订阅的
   `option.rules` / `option.proxies` / `option.groups`（UI 里是：右键订阅 → 编辑规则 / 编辑节点 / 编辑代理组）。
2. **load-balance 组必须带 `url` + `interval` 健康检查。**
   没有它时成员 `alive` 恒为 `false`，mihomo 会退化成"**只使用列表里的第一个成员**"，叠加完全失效。
   实测：带健康检查时 8 条并发流严格 3/2/3 分摊。
3. **健康检查 URL 必须是国内可达的 204 端点，且其域名要在规则里放行为 DIRECT。**
   推荐 `http://connect.rom.miui.com/generate_204`（实测 0.1s 返回 204）。
   `cp.cloudflare.com` / `gstatic.com` 在国内直连返回 `000`，会把**全部**成员判死。
   规则最前面必须有 `DOMAIN-SUFFIX,rom.miui.com,DIRECT`，否则它可能被 `GEOIP,CN` 送回正在检测的组形成环路。
4. **内网 / 校园网 / IP 敏感保护规则必须排在 `GEOIP,CN` 之前。**
5. **改完文件 Verge 不会自动重载**：必须在配置页把扩展项「禁用 → 再启用」，或点卡片右上角 🔥。

## 验证门禁（必须全部通过才算成功）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify.ps1 -DistributionTest
```

| 门禁 | 通过标准 | 不通过的含义 |
|---|---|---|
| 三个组存在 | `多线聚合`(Selector) / `多线直连`(LoadBalance) / `多线-省流量`(LoadBalance) | 扩展位写错或没重载 |
| 出口 `alive` | 三个都是 `true` 且延迟 > 0 | 健康检查没工作 → 轮询必然失效 |
| 规则表 | 首条是 `rom.miui.com`，含 `多线聚合` 目标 | 规则没进内核 |
| **实际分摊** | 至少 2 条**物理**网卡同时有流量 | 只有 1 条在动 = 没轮询 |
| 分流未破坏 | 国内站点 200、被墙站经代理 204 | 规则顺序压坏了原有分流 |

**统计口径**：求和时必须**排除 Mihomo/Meta Tunnel 虚拟网卡** —— 它和物理腿是同一份流量，一起相加会翻倍。

## 失败模式 → 处置

| 症状 | 根因 | 处置 |
|---|---|---|
| 只有 1 条腿有流量 | 健康检查缺失/失效 | 给 load-balance 组补 `url` + `interval` |
| 全部 `alive=false`、延迟 0 | 健康检查 URL 不可达，或被 `GEOIP,CN` 送回本组形成环路 | 换国内 204 端点 + 规则顶部放行该域名 |
| **整个网络卡死/全部 timeout** | **DNS 自锁**：`dns.fallback` 是海外 DNS，而规则把 `1.1.1.1/8.8.8.8` 送进了代理组；节点一挂 → fallback 全超时 → 连节点域名都解析不出来 | 写 `templates/merge-dns.yaml`（清空 fallback）到全局扩展配置；见 PITFALLS 第 1 条 |
| Windows 下 `interface-name` 疑似无效 | 误用系统侧测试（TUN 会吞掉源 IP 绑定，结果全 000） | 用内核 API 验证：`/proxies/{name}` 的 `alive` + `/connections` 的 `chains` + 各物理网卡字节数 |
| 改完没反应 | Verge 未重载 | 配置页「禁用 → 启用」或点 🔥 |
| 换订阅后全失效 | 每个订阅的扩展位是**独立的 uid 命名文件** | 对新订阅重跑 `install.ps1`（它会按 `profiles.yaml` 的 `option` 绑定自动定位） |
| 单个站点打不开/掉登录 | 多出口 IP 轮换触发风控 | 把域名加进规则 ③ 段（DIRECT） |
| Steam 下载只有 3~4 MB/s | 内容下载走代理 → Steam 分配境外 CDN → 再绕回节点 | 放行 `steamserver.net` / `steamcontent.com` / `steamstatic.com` 到多线，商店/社区保持走代理 |

## 诊断其它常见问题

- **订阅节点大面积超时**：`scripts/diagnose-nodes.ps1` 逐端口探测。
  很多机场把几十个"节点"指向同一台服务器的不同端口，缩容后大部分端口失效。
  ⚠️ 判断节点死活**只能**用内核的 `/proxies/{name}/delay`；系统侧 curl 测端口在 TUN 下会被隧道本地应答（0–1 ms 假成功）。
- **带宽/叠加实测**：`scripts/link-bench.ps1`。注意 `-Mode bound`（源 IP 绑定）**要求先关 TUN**。

## 不要做的事

- 不要用系统侧 `curl --interface <物理IP>` 或 `Test-NetConnection` 在 **TUN 开启时**测链路 —— 结果无意义。
- 不要把 WAN-* 出口塞进订阅的代理组（Verge 会自动塞，脚本负责清）。
- 不要为了"让单线程也变快"去改这些配置 —— 那是包级 bonding，本项目不提供。
- 不要覆盖用户订阅本身的规则文件；只写 `option` 指向的扩展文件。
