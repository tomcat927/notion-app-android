# 第二轮实测分析（2026-10-09 19:29，本设备 adb root 直采）

> 上一轮见 `notion-codeblock-test-v3.md` / `notion-log-analysis-v3.md`（18:06，经 OpenList 远程日志上传）。
> 本轮改用 **adb root 直读设备内日志**，并用 `am start` 自动驱动，无需配置远程日志。

## 0. 采集方式（本轮新增的能力）

| 项 | 说明 |
|---|---|
| 日志位置 | `/data/data/com.notion.app/files/notion_app_native_crash.log` |
| 谁写它 | `BrowserWebViewHolder.writeBrowserLog()` —— **不受任何调试开关控制，无条件写盘** |
| 探针输出 | `page perf: {...}` 经 `onConsoleMessage` 的 `NOTION_PERF:` 前缀回写该文件 |
| 读取方式 | 设备已 root（Magisk），`adb exec-out su -c "cat <log>"` 直读；**不需要 OpenList 远程日志** |
| 采集脚本 | `tools/pull_app_internal_logs.ps1`（本仓库新增，UTF-8 无损） |
| 自动驱动 | `am start -n com.notion.app/.BrowserActivity --es pageId <id> --es title <label>` |

**为什么能自动驱动**：`BrowserActivity` 虽 `exported=false`，但有 root 即可 `su -c am start`；
它接受 `pageId/title/blockId/snippet` 等 extra（`BrowserActivity.kt:759-764`）。
因此可以脚本化复现「依次打开 N 篇笔记」，不必手点。

**探针局限（重要）**：`PERF_COLLECT_SCRIPT` 只在 `onPageFinished` 后 **5 秒采样一次**
（`setTimeout(run, 5000)`，`BrowserActivity.kt:1256`）。
好处是 `onPageFinished` 本身很晚，长 stall 会被捕获；坏处是**页面加载完成后的后续事件采不到**。

## 1. 实测结果

真实 block 数由 Notion API 实读（`verify_blocks.py`），与 HANDOFF §5 完全一致，**未用标题推测**。

| # | 笔记 | code | img | blocks | res | KB | ttfb | DCL | load 事件 | 最慢一档 |
|---|---|---|---|---|---|---|---|---|---|---|
| ① | 刷机全攻略，root、面具、xp框架安装心得 | **5** | 6 | 440 | 926 | 15111 | 21 | 120 | **6.8s** | 1958ms |
| ② | []热点机-脚本 | **0** | 1 | 29 | 996 | 15896 | 1273 | 2096 | **17.8s** | 11983ms |
| ③ | 【全】邮箱账号数据 | **7** | 2 | 180 | 688 | 12951 | 1118 | 1879 | 未触发 | 1905ms |
| ④ | []出租房物品放置的位置 | **0** | 0 | 74 | 755 | 13517 | 1097 | 2260 | 未触发 | 1916ms |
| ⑤ | 图床app开发 | **2** | 0 | 10 | 998 | 15952 | 895 | 2086 | **16.4s** | 11716ms |

`res/KB` 取该篇资源数最多的那次采样；`load` 为 `loadComplete`（0 = 采样时尚未触发）。

## 2. 发现

### 2.1 代码块依然与"慢"无关（第三次证实）

- ②（**0 个代码块**）是本轮**最慢**的：996 资源、17.8s 才触发 load 事件。
- ④（0 code、0 img、仅 74 个 block）用了 755 资源、13.5MB。
- ①（5 code、440 block）反而只有 926 资源、6.8s 触发 load。
- ③（7 code）资源数最少（688）。

资源量与"是否含代码块"**没有相关性**，与 block 总量也弱相关——**基线成本由 Notion SPA 本身决定**。

### 2.2 "集体同耗时"特征仍在，只是幅度变小了

上一轮判据是「前 5 慢耗时差 <5% 且 >10s」，本轮**没有**命中（无 10s 级 stall）。
但把尺度放宽到 ±10% 后，同样的结构性特征非常清楚：

```
采样#5 【全】邮箱账号数据(7code)   top10 全部落在 1894~1905ms（差 11ms）
      1905ms 19555-e1d07ed5a494451b.js      (89KB)
      1905ms SidebarMobile-e33901f57d28b1ea.js (12KB)
      1902ms 92474-00f3a6ca0e0b95e6.js      (3KB)
      1901ms 38511-1b8192701865e611.js      (40KB)
      1900ms 8884-8011d923e13961b3.js       (64KB)
      ...（共 10 个互不相同的 JS chunk，1KB~89KB 不等，耗时几乎相同）

采样#7 图床app开发(2code)          top10 全部落在 1556~1564ms（差 8ms）
采样#1 刷机全攻略(5code)           top10 中 8 个落在 1442~1452ms（差 10ms）
采样#3 []热点机-脚本(0code)        top10 中 9 个落在 1577~1586ms（差 9ms）
```

**1KB 的 chunk 和 89KB 的 chunk 耗时几乎一样** → 时间不由传输量决定，而是由一个共同的时间成分决定。
这正是"链路级停顿后同时释放"或"统一高延迟"的特征，**不是"某个资源慢"**。

另有一档更大的停顿：②和⑤都出现
`msgstore-002.app.notion.com/primus-v8` 与 `aif.notion.so` **同时 ≈11.7s**
（②：11983 / 11720ms；⑤：11716 / 11706ms）——两个**不同域名**的请求同时卡住。

### 2.3 与上一轮对比：幅度显著下降

| 指标 | 上一轮 18:06 | 本轮 19:29 |
|---|---|---|
| 最大 stall | **42.9s**（5 个请求差 112ms，code=0 笔记） | **无 10s 级**；簇 ≈1.9s |
| DCL | 3338 ~ 17488ms | 120 ~ 2260ms |
| load 事件 | 7218 ~ 55244ms | 6.8s / 17.8s / 16.4s，或未触发 |
| 资源数 | 270 ~ 995 | 518 ~ 998 |

**链路状况比 18:06 那轮好很多**（Clash 订阅 19:03 刚更新过）。但 ②（0 code）依然最慢，
说明"慢"的分布仍然**不跟随代码块**。

### 2.4 单篇的绝对成本

每篇笔记都要重新加载整个 SPA：**518~998 个资源请求、10~16MB**（`totalKB` 含缓存资源的
`encodedBodySize`，实际网络传输量低于此值）。笔记正文本身只占极小一部分
（④ 仅 74 个 block，却仍产生 755 个资源请求）。

## 3. 结论

1. **代码块不是原因**——第三次独立证实。0 代码块的笔记反而是最慢的。
2. **瓶颈在链路**——所有慢请求呈现"互不相关的资源同耗时"特征，且同时刻成簇出现；
   这是链路级现象，不是应用层渲染问题。
3. **本轮无 10s 级 stall，但结构性特征（≈1.5~2.1s 成簇）仍在**。
   无法仅凭 `duration` 区分「统一高延迟」与「微型停顿后同时释放」——
   **这正是 P0（给 `app.notion.com` 换独立出口）要判别的**。
4. 每篇笔记的基线成本是 Notion SPA 全量重载，与笔记内容量基本无关。

## 4. 局限（诚实说明）

- 探针只采 2 次且都在早期，**采不到"页面加载完成后才有的事件"**（HANDOFF §3.3 已指出）。
- `slowest` 只给 top10，**拿不到全量耗时分布**（P50/P95），因此无法区分
  「10 个慢」与「600 个都慢」。
- 自动驱动用 `am start` 直接拉起 `BrowserActivity`，绕过了主界面点击；
  但日志显示两者最终都走 `open page: <id> url=https://www.notion.so/<id>`
  → `target page committed: https://app.notion.com/p/<id>`，路径一致。
- 滑动操作用 `input swipe` 模拟，与真人手势有别。

## 5. 下一步

**P0 实验**：给 `app.notion.com` 加独立策略（专属节点 或 DIRECT），
用同一套脚本重跑，对比「簇耗时」是否下降。
这是唯一能区分"统一高延迟 vs 微型停顿"的手段。

---

*产物目录：`artifacts/perf-round-2/`（原始日志、驱动脚本、分析脚本）*
*原始日志含个人笔记标题，未入库；需要时用 `tools/pull_app_internal_logs.ps1` 重新拉取。*
