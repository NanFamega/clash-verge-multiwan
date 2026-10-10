// ============================================================================
// Clash Verge 扩展脚本 —— 清理「编辑节点」扩展的副作用
// 用途: 写入订阅绑定项 option.script 对应的 .js 文件。
//
// 【为什么需要】Verge 的「编辑节点(Proxies)」扩展除了把新增节点写进 proxies 列表,
//   还会把这三个本地直连出口塞进订阅主策略组的成员列表里(实测位置就在主组的
//   proxies 数组最前面)。那三个成员在代理组里毫无意义, 且一旦被误选就断网。
//
// 【处理】脚本在整条扩展链的最后一步执行(全局扩展配置 -> 全局扩展脚本 ->
//   订阅扩展配置 -> 订阅扩展脚本), 此时可以安全地把它们过滤掉。
//
// 【安全性】只做数组过滤, 不改动任何其它配置; 若抛异常 Verge 会跳过本脚本,
//   不会影响订阅本身。
// ============================================================================
function main(config, profileName) {
  var MINE = ["WAN-PHONE", "WAN-WIRED", "WAN-WIFI"];
  var KEEP = ["多线直连", "多线-省流量"];

  var groups = config["proxy-groups"];
  if (Array.isArray(groups)) {
    for (var i = 0; i < groups.length; i++) {
      var g = groups[i];
      if (!g || KEEP.indexOf(g.name) >= 0) { continue; }
      if (Array.isArray(g.proxies)) {
        var kept = [];
        for (var j = 0; j < g.proxies.length; j++) {
          if (MINE.indexOf(g.proxies[j]) < 0) { kept.push(g.proxies[j]); }
        }
        g.proxies = kept;
      }
    }
  }
  return config;
}
