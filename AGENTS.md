# AGENTS.md — 多线聚合（Clash Verge Rev / Windows）

> 本文件面向 Codex / Antigravity 等读取 `AGENTS.md` 的 agent。
> **完整说明见 [SKILL.md](SKILL.md)**，本文件只给最短可执行路径。

## 一句话

把**有线 + 无线 + 手机 USB 共享**三条出口，通过 Clash Verge Rev 的订阅级扩展，做成
"按连接轮询"的多线负载均衡，并配一个可一键切换的开关组。

## 最短执行路径

```powershell
# 1) 预演（不写文件）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -DryRun

# 2) 部署
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1

# 3) 让 Verge 重载：配置页 → 改动过的扩展项 → 右键「禁用」再「启用」（或点 🔥）
#    然后：代理页/托盘 → 组 [多线聚合] → 选 多线直连 / 多线-省流量 / DIRECT

# 4) 验证（必须看到 ≥2 条物理网卡同时在承载）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify.ps1 -DistributionTest
```

## 五条不可违反的约束

1. **规则/节点/代理组只能写进订阅的扩展位**（`profiles.yaml` 里该订阅 `option.rules / proxies / groups / script` 指向的文件）。
   v1.7+ 起写在全局 Merge 里的 `prepend-rules` 等**完全无效**（会变成废键）。
2. **load-balance 组必须带 `url` + `interval`**；否则成员 `alive=false`，mihomo 只用第一个成员，叠加静默失效。
3. **健康检查 URL 用国内可达的 204 端点**（`http://connect.rom.miui.com/generate_204`），
   并在规则最前面加 `DOMAIN-SUFFIX,rom.miui.com,DIRECT`。
4. **内网 / 校园网 / 登录支付类保护规则必须排在 `GEOIP,CN` 之前**。
5. **改完文件必须让 Verge 重载**（禁用→启用，或点 🔥），否则内核看不到。

## 验证门禁

| 检查 | 通过标准 |
|---|---|
| 组 | `多线聚合`(Selector) / `多线直连`(LoadBalance,3) / `多线-省流量`(LoadBalance,2) |
| 出口健康 | 三个出口 `alive=true` 且延迟 > 0 |
| 规则 | 首条 `rom.miui.com`；规则表含 `多线聚合` 目标 |
| 分摊 | **≥2 条物理网卡**同时有流量（统计时排除 Mihomo 虚拟网卡，否则翻倍） |
| 分流 | 国内站点 200；被墙站经代理 204 |

## 高频故障对照

| 症状 | 立即处置 |
|---|---|
| 整个网络卡死 / 全部 timeout | **DNS 自锁**：把 `templates/merge-dns.yaml` 写进全局扩展配置（清空海外 fallback） |
| 只有一条腿在动 | 给 load-balance 组补健康检查 |
| 全部 `alive=false` | 健康检查 URL 不可达 / 被 `GEOIP,CN` 绕回本组 → 换国内 204 + 顶部放行 |
| 改完没反应 | 让 Verge 重载（禁用→启用 / 🔥） |
| 换订阅后失效 | 对新订阅重跑 `install.ps1`（扩展位是每个订阅独立的 uid 文件） |
| 订阅节点大片超时 | 跑 `scripts/diagnose-nodes.ps1`；多半是机场侧端口失效，不是本地问题 |

## 禁止事项

- 不要在 **TUN 开启时**用系统侧 `curl --interface` / `Test-NetConnection` 测链路（隧道会本地应答，结果无效）。
- 不要改动订阅本身的规则文件，只写 `option` 指向的扩展文件。
- 不要承诺"单条 TCP 连接也会变快"——那需要包级 bonding。

更多实测教训见 [docs/PITFALLS.md](docs/PITFALLS.md)。
