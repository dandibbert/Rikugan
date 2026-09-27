// ==UserScript==
// @name         Rikugan Demo Script
// @version      1.0.0
// @description  验证脚本注入、独立 GM 存储与菜单命令
// @match        https://example.com/*
// @match        http://127.0.0.1/*
// @run-at       document-end
// @noframes
// @grant        GM_getValue
// @grant        GM_setValue
// @grant        GM_registerMenuCommand
// ==/UserScript==
const visits = GM_getValue('visits', 0) + 1;
GM_setValue('visits', visits);
const panel = document.createElement('section');
panel.id = 'rikugan-userscript-result';
panel.style.cssText = 'padding:18px;margin:12px;background:#e8edff;color:#202c69;font:16px system-ui;border-radius:14px';
const title = document.createElement('strong'); title.textContent = '用户脚本运行成功';
const marker = document.createElement('div'); marker.id = 'rikugan-userscript-marker'; marker.textContent = '脚本标记已写入';
const detail = document.createElement('div'); detail.textContent = 'GM 存储计数：' + visits;
panel.append(title, detail, marker); document.body.prepend(panel);
GM_registerMenuCommand('测试脚本菜单', () => alert('脚本菜单运行成功'));

