#!/usr/bin/env node
/**
 * 用无头 Chromium 以「App 同款移动端 UA」真实渲染 Notion 页面，dump 与大纲相关的 DOM 事实。
 *
 * 解决什么问题：
 *   Notion 是纯 SPA —— 直接 `curl` 只能拿到一个空壳 HTML（没有 .notion-page-content、
 *   没有 h1、没有任何渲染内容），所以「移动端 web 到底有没有内置页面级大纲」这类问题
 *   必须执行 JS 后才能回答。本脚本负责执行并采集。
 *
 * 典型用途：
 *   1) 判断 Notion 移动端 web 是否自带可复用的「页面级目录 / 大纲」
 *   2) 判断笔记标题在 DOM 里的位置（是 h1 吗？在 .notion-page-content 内还是外？）
 *
 * 用法：
 *   node tools/probe_notion_dom.js <url> [url...]
 *
 * 环境变量：
 *   CHROMIUM_PATH  可选。chromium 可执行文件路径。
 *                  默认取本机 Playwright 缓存里的 chromium-1243。
 *   HTTPS_PROXY    可选但**本机环境必需**。不传代理会 ERR_CONNECTION_CLOSED。
 *
 * 注意：
 *   - 公开页（*.notion.site、www.notion.so/help）匿名即可访问，**不需要 token**。
 *   - 登录态的工作区笔记页需要 notion.so 的登录态 cookie，本脚本无法直接覆盖；
 *     那种场景请在设备上用 MCP 操控浏览器执行等价的 page.evaluate 逻辑。
 */

const { chromium } = require('playwright');

// App 实际使用的 UA，见 android/.../BrowserWebViewHolder.kt 的 MOBILE_USER_AGENT
const APP_UA =
  'Mozilla/5.0 (Linux; Android 10; K) AppleWebKit/537.36 (KHTML, like Gecko) ' +
  'Chrome/141.0.0.0 Mobile Safari/537.36';

const CHROMIUM_PATH =
  process.env.CHROMIUM_PATH ||
  'C:/Users/Administrator/AppData/Local/ms-playwright/chromium-1243/chrome-win64/chrome.exe';

const PROXY = process.env.HTTPS_PROXY || process.env.https_proxy || null;

const urls = process.argv.slice(2);
if (!urls.length) {
  console.error('用法: node tools/probe_notion_dom.js <url> [url...]');
  process.exit(1);
}

function collectReport() {
  const cls = (el) =>
    (el.className && el.className.toString ? el.className.toString() : '').slice(0, 120);

  const out = {};
  out.title = document.title;
  out.url = location.href;
  out.hasPageContent = !!document.querySelector('.notion-page-content');

  // ---- 1. 所有标题节点：tag / class / 文本 / 是否在正文容器内 / 祖先链 ----
  const heads = Array.from(document.querySelectorAll('h1, h2, h3'));
  out.headingCount = heads.length;
  out.headings = heads.slice(0, 20).map((n) => ({
    tag: n.tagName,
    cls: cls(n),
    text: (n.innerText || n.textContent || '').replace(/\s+/g, ' ').trim().slice(0, 40),
    insidePageContent: !!n.closest('.notion-page-content'),
    inTitleRow: !!n.closest('.notion-page-view-title-row'),
    chain: (() => {
      const a = [];
      let p = n.parentElement;
      let i = 0;
      while (p && i < 4) {
        a.push(p.tagName + '.' + cls(p).split(' ').slice(0, 2).join('.'));
        p = p.parentElement;
        i++;
      }
      return a.join(' < ');
    })(),
  }));

  // ---- 2. TOC / outline 相关 class ----
  const tocish = Array.from(document.querySelectorAll('[class]'))
    .filter((el) => /toc|table_of_contents|table-of-contents|outline/i.test(cls(el)))
    .slice(0, 20)
    .map((el) => ({
      tag: el.tagName,
      cls: cls(el),
      text: (el.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 60),
      insidePageContent: !!el.closest('.notion-page-content'),
    }));
  out.tocishCount = tocish.length;
  out.tocish = tocish;

  // ---- 3. fixed / sticky 元素：内置悬浮大纲若存在，必然在这里 ----
  const floating = [];
  document.querySelectorAll('*').forEach((el) => {
    const cs = getComputedStyle(el);
    if (cs.position !== 'fixed' && cs.position !== 'sticky') return;
    const r = el.getBoundingClientRect();
    if (r.width < 8 || r.height < 8) return;
    floating.push({
      tag: el.tagName,
      cls: cls(el),
      pos: cs.position,
      right: Math.round(window.innerWidth - r.right),
      top: Math.round(r.top),
      w: Math.round(r.width),
      h: Math.round(r.height),
      text: (el.innerText || '').replace(/\s+/g, ' ').trim().slice(0, 40),
    });
  });
  out.floatingCount = floating.length;
  out.floating = floating.slice(0, 25);

  // ---- 4. 无障碍标签里提到目录 / 大纲的 ----
  out.ariaToc = Array.from(document.querySelectorAll('[aria-label]'))
    .filter((el) => /目录|大纲|outline|table of contents|toc/i.test(el.getAttribute('aria-label') || ''))
    .slice(0, 10)
    .map((el) => ({ tag: el.tagName, cls: cls(el), label: el.getAttribute('aria-label') }));

  return out;
}

(async () => {
  const launchOpts = { headless: true, executablePath: CHROMIUM_PATH };
  if (PROXY) launchOpts.proxy = { server: PROXY };
  const browser = await chromium.launch(launchOpts);

  const ctx = await browser.newContext({
    userAgent: APP_UA,
    viewport: { width: 412, height: 915 },
    isMobile: true,
    hasTouch: true,
    locale: 'zh-CN',
    ignoreHTTPSErrors: true,
  });

  for (const url of urls) {
    const page = await ctx.newPage();
    try {
      await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
      // SPA 需要时间把内容渲染出来
      await page.waitForTimeout(9000);
      const report = await page.evaluate(collectReport);
      console.log('===== ' + url);
      console.log(JSON.stringify(report, null, 2));
    } catch (e) {
      console.log('===== ' + url + ' ERROR: ' + e.message);
    }
    await page.close();
  }

  await browser.close();
})();
