# 第 4 轮：冷/热缓存 × 代理/直连 —— 四象限对照实验

> 目的：验证 HANDOFF 的 A 选项假设——「把 `app.notion.com` 从 Clash 代理链路上摘掉（直连）能否消除集体 stall」。
> 方法：把「缓存状态」这个混杂变量显式控制住，做 2×2 对照。
> 结论：**代理不是瓶颈，A 选项证据不支持；真正的分水岭是「冷缓存」。**

---

## 0. 结论先行（TL;DR）

| # | 结论 | 证据强度 |
|---|------|---------|
| 1 | **热缓存下，代理与直连完全一致**（106–107 res、top ~55ms、load 0.2s） | 强（两条件各 5 页，数值几乎逐位相同） |
| 2 | **集体 stall 在「关闭 Clash 直连」下同样复现** → 不是 Clash 独有现象 | 强（直连 5 页全部出现 8–10 元素簇） |
| 3 | 真正的分水岭是 **冷缓存 vs 热缓存**，不是代理 vs 直连 | 强（冷必 stall，热必不 stall） |
| 4 | **同条件重复运行的方差极大**（同一页面 248 res vs 996 res）→ n=1 的 A/B 无统计意义 | 强（两次冷+代理对照） |
| 5 | **A 选项（`app.notion.com` 直连）证据不支持**，不建议据此改 Clash 规则 | 中（受 #4 方差限制） |

---

## 1. 实验设计

### 1.1 为什么要重做

上一轮（19:29 冷 / 19:46+19:49 热）的「代理 8.2s → 直连 0.2s」看起来像「直连快 100 倍」，
但那两组**缓存状态不同**（一冷一热），是典型的**热缓存混杂**，不能用来判断代理优劣。

本轮把缓存状态做成显式自变量：

| | Clash 代理 ON | Clash 代理 OFF（真直连） |
|---|---|---|
| **冷缓存**（清空 HTTP Cache） | ✅ 组 A1 / A2 | ✅ 组 B |
| **热缓存**（刚加载过同样 5 篇） | ✅ 组 C | ✅ 组 D |

### 1.2 缓存清理与登录保持

```bash
CACHE='/data/data/com.notion.app/cache/WebView/Default/HTTP Cache'
adb shell "su -c 'rm -rf \"$CACHE/Cache_Data\" \"$CACHE/Code Cache\" \"$CACHE/No_Vary_Search\"'"
```

- Cookie 存在 `app_webview/Default/Cookies`，与 HTTP Cache 分离 → **清缓存不掉登录**（已实测）。
- 清完从 29MB → 3.5KB。

### 1.3 「真直连」的严格核验

关闭 Clash 后逐项确认，避免 TUN 关了但系统代理还在：

```
settings get global http_proxy              → null
settings get global global_http_proxy_host  → null
ip -o link show tun0                        → Device "tun0" does not exist
ip route show default                       → 仅 wlan2（WiFi 10.122.113.x）
ps -A | grep clash                          → 进程存活但处于 do_freezer_trap（已冻结）
```

→ **组 B 是货真价实的无代理直连**（走 WiFi，无 TUN、无系统代理）。

### 1.4 测试方法

沿用 `artifacts/perf-round-2/drive.sh`：`am start -n com.notion.app/.BrowserActivity --es pageId <id>`
脚本化打开 5 篇笔记 → 等到 `page perf` 出现 → 下划到底 4 次 → 返回。
样本来自 App 内探针 `PERF_COLLECT_SCRIPT`，落到 `files/notion_app_native_crash.log`，root adb 直读。

---

## 2. 四象限数据

### 2.1 热缓存 —— 代理 vs 直连（关键对照）

**组 C：热缓存 + Clash 代理（19:49）**

```
 # 页面                  res     KB   ttfb    DCL    load  top(ms)  簇   totalMs
 1 刷机全攻略(5c)         106   2476     37     99     220       54  1      2883
 2 []热点机-脚本(0c)      107   2491      8     51     221       58 10      3292
 3 【全】邮箱账号(7c)       107   2491     13     68     203       65  6      3542
 4 []出租房物品(0c)       107   2491      9    144     212       62  2      3291
 5 图床app开发(2c)        107   2491     11     54     200       59  3      2992
```

**组 D：热缓存 + 关闭代理直连（19:46）**

```
 # 页面                  res     KB   ttfb    DCL    load  top(ms)  簇   totalMs
 1 刷机全攻略(5c)         106   2476     34    103     311       70  1      3358
 2 []热点机-脚本(0c)      107   2491      5     60     241       56  8      3039
 3 【全】邮箱账号(7c)       107   2491     10    153     223       59  8      3181
 4 []出租房物品(0c)       107   2491      8     61     200       57  2      2891
 5 图床app开发(2c)        107   2491      9    183     237       47 10      2773
```

> **两组逐页几乎逐位相同**：res 106↔107、KB 2476/2491 完全一致、top 全部 47–70ms。
> **结论：缓存热的时候，走不走代理对速度没有任何影响。** 代理链路在热缓存场景下不构成瓶颈。

### 2.2 冷缓存 —— 代理 vs 直连

**组 A2：冷缓存 + Clash 代理（19:53）**

```
 # 页面                  res     KB   ttfb    DCL    load  top(ms)  簇   totalMs
 1 刷机全攻略(5c)           0      0    277   6211    6218        0  0         0   ← 采样异常
 2 []热点机-脚本(0c)      248   3829   1826   3329       0     5007 10    312841
 3 【全】邮箱账号(7c)       448   6921   1125   1716       0     2130  1    134808
 4 【全】邮箱账号(7c)       986  13791   1125   1716   21994    13254  2   1210935
 5 []出租房物品(0c)       721  11971    947   1763       0     2033  2    352038
 6 图床app开发(2c)        975  14676    947   1763   18358    12091  1    431144
 7 图床app开发(2c)        758  13639   1116   1885       0     1339 10    281758
```

**组 B：冷缓存 + 关闭代理直连（19:56）**

```
 # 页面                  res     KB   ttfb    DCL    load  top(ms)  簇   totalMs
 1 刷机全攻略(5c)         210   5319   1514   3224       0     4861  9    268193
 2 []热点机-脚本(0c)      364   7439   1410   2982       0     1814  1    176971
 3 【全】邮箱账号(7c)       398   8070    963   2495       0     3189 10    416306
 4 []出租房物品(0c)       406   7005    956   2816       0     4690  1    163557
 5 图床app开发(2c)        676  11891    638   2274       0     2252  1    153290
```

**→ 直连组 5 页全部出现 8–10 元素簇**（下面第 3 节展开）。**stall 没有因为关掉 Clash 而消失。**

---

## 3. 「集体 stall」签名：直连下同样存在

探针输出的 `slowest` 里，同一页面上**大小差异巨大的多个文件在同一毫秒窗口内完成**——
独立请求不可能做到，只能是「连接级阻塞后同时释放」。

### 3.1 冷 + 代理

```
组 A2 #7 图床app开发  簇=10 带宽=7ms
    1339ms  12KB  SidebarMobile-e33901f57d28b1ea.js
    1338ms  90KB  19555-e1d07ed5a494451b.js
    1338ms   3KB  92474-00f3a6ca0e0b95e6.js
    1337ms  40KB  38511-1b8192701865e611.js
    1337ms   3KB  77051-f002af6f9f89a3a3.js
    1337ms   4KB  94867-f5388e4c65afa089.js
    1337ms   5KB  54107-d9ec56cd8467c270.js
    1336ms  13KB  60021-a7558de77540bd68.js
    1336ms  64KB  8884-8011d923e13961b3.js
    1332ms   3KB  45577-d244a6dbd4f5cf5d.js
```

3KB 与 90KB 用时相同（1337ms）——**物理上不可能**，除非它们被一起卡住再一起放行。

### 3.2 冷 + 直连（无代理！）

```
组 B #3 邮箱账号  簇=10 带宽=9ms
    3189ms  89KB  19555-e1d07ed5a494451b.js
    3187ms  12KB  SidebarMobile-e33901f57d28b1ea.js
    3187ms  40KB  38511-1b8192701865e611.js
    3187ms   3KB  92474-00f3a6ca0e0b95e6.js
    3187ms   3KB  77051-f002af6f9f89a3a3.js
    3185ms  64KB  8884-8011d923e13961b3.js
    3185ms   4KB  94867-f5388e4c65afa089.js
    3185ms  13KB  60021-a7558de77540bd68.js
    3185ms   5KB  54107-d9ec56cd8467c270.js
    3180ms  19KB  41591-2d04f83e10d5e080.js
```

**同样的簇、同样的那批 chunk（`19555` / `SidebarMobile` / `38511` / `8884` / `92474` …），
在完全没有代理的情况下 9ms 带宽内集体完成。**

### 3.3 热缓存下完全没有这个签名

组 C / D 的 `top` 全部是 47–70ms，没有任何 5s 级别的簇。
**→ stall 与「冷/热」强相关，与「代理/直连」不相关。**

---

## 4. 方差分析：为什么 n=1 的 A/B 不可信

我有**两次同条件（冷 + 代理）**运行，正好用来估计噪声本底：

| 页面 | 冷+代理 第1次(19:29) res | 冷+代理 第2次(19:53) res | 差异 |
|---|---|---|---|
| 刷机全攻略(5c) | 926 | 0（采样异常） | — |
| []热点机-脚本(0c) | 996 | 248 | **4.0×** |
| 【全】邮箱账号(7c) | 688 | 986 | **1.43×** |
| []出租房物品(0c) | 755 | 721 | 1.05× |
| 图床app开发(2c) | 998 | 975 | 1.02× |

| 页面 | 冷+代理 第1次 top | 冷+代理 第2次 top | 差异 |
|---|---|---|---|
| []热点机-脚本(0c) | 11983ms | 5007ms | **2.4×** |
| 【全】邮箱账号(7c) | 1905ms | 13254ms | **7.0×** |
| 图床app开发(2c) | 11716ms | 12091ms | 1.03× |

**同条件的波动（同页面 248 ↔ 996 res）远大于「代理 vs 直连」的差异（586 vs 410 res）。**
所以：

> 用单次采样比较代理与直连，**测到的差异完全落在噪声里**，不能作为「直连更快」的依据。

---

## 5. 根因推断

### 5.1 冷加载的规模

| 状态 | 请求数 | 传输量 | top 慢请求 | load |
|---|---|---|---|---|
| 冷 | **248–998**（典型 ~700–1000） | **4–16 MB**（典型 ~13MB） | 1.9–13.3 s | 最长 22 s |
| 热 | **106–107** | **~2.5 MB** | 47–70 ms | 0.2 s |

冷加载时，**~900 个请求里 936/986 个都在 `app.notion.com` 这一个源上**（见组 A2 #4 的 domains：
`app.notion.com n=936 kb=13635`）。同源 ≈ 同一个 HTTP/2 连接。
**只要这条连接出现一次丢包/重传/流控停顿，上面所有在途请求就会一起卡住、再一起完成**——
这正是簇签名的成因。

### 5.2 为什么热缓存没事

热缓存下只剩 106 个请求（多为不可缓存/需回源的），量级小、并发低，**撞上连接级停顿的概率极低**。

### 5.3 结论

> 瓶颈不是 Clash，而是 **「冷加载要拉 ~900 个请求 / ~14MB」这件事本身**。
> 请求量越大，撞上一次连接级 stall 的概率越高；Clash 只是**可能放大**（历史上出现过 42.9s 的极端值），
> 但**不是必要条件**——本次直连同样 stall。

---

## 6. 代码侧发现（可作为下一步的着力点）

| 位置 | 事实 | 影响 |
|---|---|---|
| `MainActivity.kt:347-371` `prewarmWebView()` | 预热加载的是 **`https://www.notion.so`**，而笔记在 **`app.notion.com`** | **预热打错了源**。实测 `www.notion.so` 返回 200 无跳转（是营销站），预热它只写 cookie，**不会**把 SPA 的 ~900 个 chunk 灌进缓存。改成预热 `app.notion.com` 可把「用户打开第一篇笔记」从冷加载变成热加载。 |
| `cache_cleanup_service.dart:36` `cleanupStartupCaches()` | 只清 `apk_updates` 与 `webview_upload_*` 临时文件 | **不会**清 HTTP 缓存 → 缓存不会被自动清（实测缓存 32MB / 1020 文件且持续增长）。 |
| `MainActivity.kt:373-387` `clearWebViewCache()` | 仅由手动「清理缓存」入口触发 | 同上，非自动。 |
| `BrowserWebViewHolder.kt:154` | `cacheMode = LOAD_CACHE_ELSE_NETWORK` | 缓存策略本身是偏「优先用缓存」的，没问题。 |
| `app.notion.com` 响应头 | `Cache-Control: no-cache`、`CF-Cache-Status: DYNAMIC` | HTML 每次需回源校验；chunk 是内容哈希命名、可长缓存。 |

### 6.1 设备端直接验证：「预热打错源」确凿

方法：清空 HTTP 缓存 → 冷启动 App 只到首页（**不点任何笔记**，只让预热跑）→ 等 35s →
`grep` 缓存目录里所有 URL 主机名 → 再打开 1 篇笔记，同样统计一次。

| 状态 | 缓存大小 | 文件数 | `app.notion.com` 条目数 |
|---|---|---|---|
| 只跑预热（当前实现，加载 `www.notion.so`） | 1.6 MB | 96 | **8** |
| 打开 1 篇笔记后 | 22 MB | 830 | **751** |

预热后缓存里装的其实是**营销站**：

```
 71 https://www.notion.com          ← 营销首页
 27 https://images.ctfassets.net    ← 营销站图床
  8 https://app.notion.com          ← 只是 HTML 里的 preconnect 提示，不是 chunk
  8 https://www.youtube.com / hcaptcha.com / accounts.google.com / platform.twitter.com …
```

**结论**：
1. 一篇笔记可缓存的核心资源约 **751 条，全部在 `app.notion.com`**；
2. 当前预热只贡献了其中 **8 条**（而且只是 preconnect 提示，不是 chunk）；
3. 也就是说预热**每次冷启动白拉 1.6MB 营销站资源**（含 YouTube/hCaptcha/Twitter 等第三方组件），
   对笔记首屏**零收益**。

→ 把预热 URL 改成 `app.notion.com`，命中同一批缓存条目，即可让首篇笔记走热路径。

---

## 7. 对 P0 的影响与建议

### 7.1 对原 P0（改 Clash 规则）的判定

- **A 选项（`app.notion.com` 走 DIRECT）**：本次实验**不支持**。直连下 stall 照样出现，且代理/直连差异淹没在噪声里。
- **B/C 选项（钉单节点 / 调 url-test 参数）**：热缓存下代理与直连毫无差别，说明**稳定节点本身不是收益来源**；
  只有在「恰好选中抖动节点」时才会额外恶化。属于**降风险**而非**治本**。

### 7.2 建议的优先级

1. **【已实施】修预热目标** —— `MainActivity.kt` 的 `prewarmWebView()`：
   - URL 由 `https://www.notion.so` 改为 `https://app.notion.com`；
   - **`onPageFinished` 不再立刻 `destroy()`**，改为延后 `PREWARM_SETTLE_MS`(10s) 再销毁。
     原因：SPA 的 `onPageFinished` 只代表主文档完成，~751 条 chunk 是在此之后才开始下载的；
     立刻 destroy 会把在途请求掐断，chunk 落不进缓存，改了 URL 也白改。
     仍保留 30s 硬上限兜底。
   - 配套把 `home_screen.dart` / `private_search_screen.dart` 里「加载 notion.so」的注释同步更正。
2. **【配套】冷加载削峰** —— 确认能否在冷加载时降低并发/分批加载，减少「900 请求压一条连接」的暴露面。
3. **【保留】Clash 规则** —— 可作为稳定性兜底，但需明确**它不是根因**，不要期待改完规则速度就正常。

### 7.3 真机验证结果（v0.1.0-20261009203448）

装包：`adb install -r notion-app-v0.1.0-20261009203448.apk`（versionCode `1791536040` → `1791549288`，
cookie 与缓存均保留）。协议：`force-stop` → 清空 HTTP 缓存（3.5K）→ 冷启动 `MainActivity`
→ 等 35–45s 让预热跑 → 开笔记读 `page perf`。

**A. 预热是否真的把 SPA 灌进缓存 —— 是**

| 预热实现 | 缓存总量 | 其中 `app.notion.com` 条目 |
|---|---|---|
| 旧（`www.notion.so`） | 1.6 MB | **8** |
| 新（`app.notion.com`，成功时） | 20–23 MB | **187 / 235 / 250 / 276 / 282** |

**B. 首篇笔记的打开成本 —— 成功时降到热加载基线**

| 条件 | resourceCount | 最慢单请求 | 集体 stall 簇 |
|---|---|---|---|
| 修复前·冷加载 | 248–998 | 1.9–13.3 s | **5/5 篇都有** |
| 修复前·热加载基线 | 106–107 | 47–70 ms | 无 |
| **修复后·预热成功** | **95 / 96 / 98 / 110 / 166 / 203** | 55–60 ms（多数） | **3/5 篇无簇** |
| 修复后·预热失败 | 443 / 582 / 703 / 741 / 952 | 1.4–3.2 s | 有 |

同一篇 `图床app开发` 的对照最直观：**975（冷）→ 110（修复后）**。

**C. 遗留问题：预热本身不可靠（约 7/10 成功）**

10 次受控冷启动中，`app.notion.com` 条目数为：
`95 ✓ / 208 ✓ / 0 ✗ / 0 ✗ / 0 ✗ / 187 ✓ / 235 ✓ / 250 ✓ / 276 ✓ / 282 ✓`。

- 失败时缓存停在 **64K**，笔记重新退回冷加载（443–952 请求 + stall）。
- **失败成簇出现**（21:01–21:07 连续 3 次失败，之后 5 次连续成功）→ 与网络/节点状态相关，
  不是固定的代码缺陷。logcat 同期可见
  `ssl_client_socket_impl.cc:949 handshake failed ... net_error -100`（ERR_CONNECTION_CLOSED）
  与 `spdy_session.cc:3188 Received HEADERS for invalid stream`（HTTP/2 连接被拆）。
- Clash 日志显示 `Notion` 组在 `电信优选1` / `电信优选3` 之间切换 —— 预热若恰好撞上节点切换/劣化就会失败。

**D. 结论**

修复**方向正确、成功时效果显著**（首屏请求量降到热加载基线、多数页面不再出现 stall），
但**不能指望它 100% 生效**：预热自身也是一次完整的 SPA 冷加载，同样暴露在同一条不稳定链路上。
若要提高可靠性，可考虑：
1. 把 `prewarmMaxLifetimeMs` 由 30s 放宽（慢链路上 30s 可能不够）；
2. 预热失败（`onReceivedError`）时重试一次；
3. 更彻底的做法是让预热 WebView 常驻复用，而不是加载完就销毁。

### 7.4 第二轮真机验证（v0.1.0-20261009214812，含可靠性改进）

装包：`adb install -r notion-app-v0.1.0-20261009214812.apk`（sha256 校验一致）。
协议：`force-stop` → 清空 HTTP 缓存（实测降到 0）→ 冷启动 `MainActivity` → 等 60s → 计数 / 开笔记。

**A. 预热可靠性：7/10 → 10/10**

10 次受控冷启动后缓存中 `app.notion.com` 条目数：

`257 / 251 / 251 / 248 / 249 / 250 / 244 / 197 / 231 / 248` —— **10 次全部成功，0 次失败**。

每轮 logcat 均为 `attempt 1 loadUrl` → `onPageFinished`（约 3.5s）→ `released (finished+settle)`，
**没有一次触发重试**，即失败情形在本窗口内未复现。

> 诚实说明：上一轮的失败是**成簇**出现的（21:01–21:07 连败 3 次），本轮窗口（22:38–22:48）链路未失败。
> 因此「10/10」中**有多少归功于重试逻辑、有多少只是没撞上失败，无法从本轮数据拆分**。
> 能确定的是：新代码在最坏情况下不会比旧代码更差（重试只会多争取机会）。

**B. 重试逻辑单元验证（飞行模式强制失败）** —— 让重试路径真正跑一次

关闭 WiFi 并开启飞行模式（`notion=000`、走代理 `baidu=000` 双重确认无网）后冷启动：

```
attempt 2 main-frame error: code=-6 desc=net::ERR_CONNECTION_CLOSED
released (code=-6 desc=net::ERR_CONNECTION_CLOSED)
attempt 3 loadUrl https://app.notion.com        ← 间隔 3.0s，与 prewarmRetryDelayMs 一致
attempt 3 main-frame error: code=-6 desc=net::ERR_CONNECTION_CLOSED
giving up after 3 attempt(s)
```

→ **错误捕获、立即释放、3s 退避重试、上限 3 次、give-up 全部按设计生效**，重试链无死锁、无误杀。
恢复网络后再次冷启动：`attempt 1` 一次成功，缓存 305 条。

**C. 端到端：开「第一篇」笔记的成本**

| 笔记 | 预热条目 | resourceCount | totalKB | ttfb | 最慢簇 |
|---|---|---|---|---|---|
| noteA #1 | 239 | 222 | 390 | 3178 | 5 个 @ 3730ms |
| noteA #2 | 198 | 178 | 4829 | 4840 | 5 个 @ 2739ms |
| noteB | 222 | **93** | 254 | 6454 | **无**（最慢仅 80ms） |
| noteC | 246 | 202 | 389 | 7594 | 10 个 @ 3529ms |

对照：

- 预热**失败**时（§7.3 基线）：443 / 582 / 703 / 741 / 952
- 本轮：93 / 178 / 202 / 222 —— **全部低于失败基线**；最好的 noteB 已完整复现热加载特征
  （93 请求、最慢 80ms、无 stall 簇）。
- 但本轮 **ttfb 高达 3.2–7.6s**（上一轮仅 0.8–3.2s）→ 测试窗口内链路明显劣化，
  且 stall 簇仍在（2.7–3.8s、5–10 个元素）。

**D. 仍然存在的缺口（决定了下一步）**

预热只灌进 **~200–300 条**，而打开一篇笔记实际会用到 **~750 条** `app.notion.com` 条目
（§6.1 实测）。剩余 ~450–550 条仍要在开笔记时现拉 —— **这就是 stall 簇仍然出现的直接原因**。
预热把「冷加载」变成了「半热加载」，但没能变成「热加载」。要继续往前，方向应是
**让预热覆盖得更深**（延长 settle、预热时触发 SPA 路由），而不是继续调重试参数。

---

## 8. 局限（必须明示）

1. **每个格子 n=1**。方差已证明极大（同条件 4× 波动），本报告只做**定性**判断，不做定量结论。
2. **探针为单次采样**（`setTimeout(run, 5000)`，注入于 `onPageFinished`）。
   `performance.getEntriesByType('resource')` **只返回已完成资源**，采样时刻仍在途的不会出现 →
   **资源数会被低估**，且「采样边界」本身可能对簇统计有轻微影响。
3. 组 A2 #1（刷机全攻略 res=0）为**采样异常**，已剔除，不参与平均。
4. 两组的资源数不同（586 vs 410），说明两次采样落在**不同的加载阶段**，进一步削弱了横向可比性。
5. 全部测试在同一 WiFi（`wlan2`, 10.122.113.x）下进行；未做「蜂窝 vs WiFi」对照，
   因此**无法排除本地 WiFi 链路本身**是连接级停顿的来源。

---

## 9. 复现命令

```bash
# 清 HTTP 缓存（保登录）
CACHE='/data/data/com.notion.app/cache/WebView/Default/HTTP Cache'
adb shell "su -c 'rm -rf \"$CACHE/Cache_Data\" \"$CACHE/Code Cache\" \"$CACHE/No_Vary_Search\"'"

# 跑一轮
cd artifacts/perf-round-2
OUT=../perf-cold-proxy bash drive.sh

# 分析
python dump_samples.py   ../perf-cold-proxy/round2-native.log "冷+代理"
python cluster_report.py ../perf-cold-proxy/round2-native.log "冷+代理"
python compare.py        ../perf-cold-proxy/round2-native.log ../perf-cold-direct/round2-native.log
```

分析脚本：`artifacts/perf-round-2/{dump_samples,cluster_report,compare}.py`
原始日志：`artifacts/{perf-round-2,perf-round-2-direct,perf-round-3-proxy,perf-cold-proxy,perf-cold-direct}/`
