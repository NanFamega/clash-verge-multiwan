# clash-verge-multiwan · 多线聚合

> 在 **Clash Verge Rev (mihomo 内核 / Windows)** 上启用**多链路负载均衡**：
> 把**有线 + 无线 + 手机 USB 共享**三条出口按连接轮询分发，配一键开关、订阅级扩展绑定、内核级验证。
> 可作为 Connectify Dispatch PRO / Speedify 的免费替代方案。

[![Platform](https://img.shields.io/badge/platform-Windows%2010%2F11-blue)]()
[![Client](https://img.shields.io/badge/client-Clash%20Verge%20Rev%202.x-green)]()
[![Core](https://img.shields.io/badge/core-mihomo%20v1.19%2B-orange)]()
[![License](https://img.shields.io/badge/license-MIT-lightgrey)]()

---

## 它解决什么问题

Windows 默认只在**一条**默认路由上发包（多条网卡同时在线时，只有度量最低的那条被使用，其余闲置）。
本项目通过 mihomo 的策略组把"新建连接"轮流分散到多条出口，从而：

- **多线程下载**（IDM / aria2 -x16 / 迅雷 / BT / 游戏平台）能吃满多条链路之和
- **一条腿断了自动跳过**（健康检查），不会断网
- **一键切换**：面板/托盘里选 `多线直连` / `多线-省流量` / `DIRECT`
- **国内流量不花手机流量**（可选）

## 实测数据（真机，非理论值）

| 场景 | 结果 |
|---|---|
| 有线单条（100 Mbps 网口，物理层上限） | 12.27 MB/s（98.2 Mbps） |
| 无线单条（Wi-Fi 7，校园 AP 限速） | 11.74 MB/s（93.9 Mbps） |
| 手机 USB 共享（5G）单条 | 25.00 MB/s（200 Mbps），多流可达 ~37 MB/s |
| **三条同时（手机走 5G）** | **50.16 MB/s（401 Mbps）**，达成率 103.8% |
| **三条同时（手机也走校园网）** | **≈33 MB/s**，因为三条腿都受校园网接入限制 |
| 8 条并发流的分摊 | 3 / 2 / 3 条流 → 9.55 / 6.27 / 9.38 MB，**严格 1/3 轮询** |

> ⚠️ **单条 TCP 连接不会变快**。Windows 层的多线聚合只能分散"不同连接"，
> 想给单连接提速需要包级 bonding（Speedify 那类）。这是原理限制，不是配置问题。

## 快速开始

```powershell
# 1. 部署（自动探测网卡、自动定位当前订阅的扩展位、原文件自动备份）
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1 -DryRun   # 先看会改什么
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\install.ps1

# 2. 让 Verge 重新生成配置
#    打开 Clash Verge → 配置页 → 找到改动的扩展项 → 右键「禁用」再「启用」
#    （或点该卡片右上角的 🔥）

# 3. 选档位：代理页/托盘 → 组 [多线聚合] → 多线直连 / 多线-省流量 / DIRECT

# 4. 验证
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\verify.ps1 -DistributionTest
```

## 目录结构

```
├─ scripts/
│  ├─ install.ps1          一键部署(推荐入口)：自动探测网卡 + 定位订阅扩展位 + 写入模板
│  ├─ verify.ps1           验证：组/健康/规则/TUN/连通性 + 三链路实际分摊
│  ├─ mihomo-pipe.ps1      通过命名管道直连 mihomo API 的工具函数(含 chunked 解码)
│  ├─ diagnose-nodes.ps1   诊断"订阅节点大面积超时"：逐端口找出还活着的端点
│  └─ link-bench.ps1       带宽实测：逐链路容量 / 多线分摊 / 默认路由吞吐
├─ templates/
│  ├─ proxies.yaml         「编辑节点」：3 个绑定物理网卡的直连出口
│  ├─ groups.yaml          「编辑代理组」：负载均衡组 + 一键开关
│  ├─ rules.yaml           「编辑规则」：哪些流量走多线（含内网/校园网/IP敏感保护）
│  ├─ merge-dns.yaml       「全局扩展配置」：修复 DNS 自锁（对所有订阅生效）
│  └─ cleanup-script.js    「扩展脚本」：清理 Verge 往主策略组里塞的副作用
└─ docs/
   └─ PITFALLS.md          踩坑清单（20 条实测教训，强烈建议先读）
```

## 工作原理

```
                    ┌──────────────────────────────┐
   应用流量 ──────► │ 规则表 (prepend，最优先)      │
 (系统代理或 TUN)   │  ① 大流量域名/进程 → 多线聚合 │
                    │  ② 内网/校园网     → DIRECT   │
                    │  ③ IP 敏感服务     → DIRECT   │
                    │  ④ GEOIP,CN        → 多线聚合 │
                    └──────────────┬───────────────┘
                                   ▼
                        ┌────────────────────┐
                        │ 多线聚合 (select)   │  ← 面板/托盘一键切换
                        └────────┬───────────┘
              ┌──────────────────┼──────────────────┐
              ▼                  ▼                  ▼
        多线直连(3条)      多线-省流量(2条)        DIRECT
        load-balance       load-balance         (单条默认路由)
        round-robin        round-robin
              │                  │
              ▼                  ▼
    WAN-PHONE / WAN-WIRED / WAN-WIFI   ← 各自 interface-name 绑定物理网卡
```

## 环境要求

- Windows 10 / 11
- [Clash Verge Rev](https://github.com/clash-verge-rev/clash-verge-rev) 2.x（内核 mihomo v1.19+）
- **至少两条**已连接且带默认网关的出口（本项目按三条设计：手机 USB 共享 + 有线 + 无线）
- 手机 USB 共享需要手机打开「USB 网络共享」

已验证环境：Windows 11 专业版 · Clash Verge Rev 2.5.7 · mihomo v1.19.32 · Qualcomm FastConnect 7800 (Wi-Fi 7) · Realtek RTL8126 (100 Mbps 协商) · 三星手机 USB 共享

## 已知边界

| 边界 | 说明 |
|---|---|
| 单连接不提速 | TCP 单流锁在一条链路上 |
| 应用需进入 mihomo | 要么吃系统代理，要么开 TUN 模式；否则流量绕过规则 |
| 出口 IP 会轮换 | 登录/支付/聊天类站点可能触发风控 → 已在规则 ③ 段做保护，可按需增补 |
| 网盘可能绑定出口 IP | 出现 403/中断时改用 `consistent-hashing` 或注释掉对应规则 |
| 校园网可能按设备限并发 | 手机与电脑同时上校园网时注意学校策略 |

更多真实故障与处置见 **[docs/PITFALLS.md](docs/PITFALLS.md)**。

## 给 AI Agent 使用

- **[SKILL.md](SKILL.md)** —— 面向 DSH / Claude Skills 等支持 SKILL.md 的 agent
- **[AGENTS.md](AGENTS.md)** —— 面向 Codex / Antigravity 等读取 AGENTS.md 的 agent

两个文件都包含：何时使用、部署步骤、**必须通过的验证门禁**、失败模式与处置。

## License

MIT
