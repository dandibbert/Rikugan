#!/usr/bin/env python3
"""Generates docs/CHROME_API_MATRIX.md from Sources/Rikugan/Resources/JS/chrome-api-matrix.json.

The JSON is the single source of truth; scripts/test_js.cjs verifies it against the JS shim and
the native bridge on every CI run, and CI checks that this Markdown is up to date
(`python3 scripts/gen_api_matrix.py --check`)."""
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "Sources/Rikugan/Resources/JS/chrome-api-matrix.json")
OUT = os.path.join(ROOT, "docs/CHROME_API_MATRIX.md")
ICON = {"Supported": "✅", "Partial": "🟡", "Unsupported": "⛔"}
ORDER = ["runtime", "storage", "scripting", "tabs", "permissions", "action", "contextMenus", "cookies", "downloads",
         "webNavigation", "declarativeNetRequest", "webRequest", "i18n", "alarms", "notifications", "windows", "commands", "extension"]


def esc(s):
    return str(s).replace("|", "\\|")


def render(data):
    namespaces = data["namespaces"]
    names = sorted(namespaces, key=lambda n: (ORDER.index(n) if n in ORDER else 999, n))
    lines = ["# Chrome 扩展 API 兼容性矩阵", "",
             "> 由 `scripts/gen_api_matrix.py` 从 `Sources/Rikugan/Resources/JS/chrome-api-matrix.json` 生成，请勿手改。",
             "> CI（`scripts/test_js.cjs`）逐方法校验：标为 Supported / Partial 的方法必须在 JS shim 中是真实实现，且（除标注 JS-only 的方法）在",
             "> `ChromeAPIBridge.swift` 中有原生分支；标为 Unsupported 的方法必须是调用即以 `Unsupported API` 拒绝并上报到诊断页的桩函数。", "",
             "## 总览", "", "| 命名空间 | 级别 | 已实现 / 方法数 | 说明 |", "|---|---|---|---|"]
    totals = {"Supported": 0, "Partial": 0, "Unsupported": 0}
    for name in names:
        ns = namespaces[name]
        methods = ns.get("methods", {})
        implemented = sum(1 for m in methods.values() if m[0] != "Unsupported")
        for m in methods.values():
            totals[m[0]] = totals.get(m[0], 0) + 1
        count = f"{implemented}/{len(methods)}" if methods else "—"
        lines.append(f"| `chrome.{name}` | {ICON.get(ns['level'], '?')} {ns['level']} | {count} | {esc(ns.get('reason', ''))} |")
    lines += ["", f"方法合计：✅ {totals['Supported']} · 🟡 {totals['Partial']} · ⛔ {totals['Unsupported']}", ""]
    for name in names:
        ns = namespaces[name]
        methods = ns.get("methods", {})
        actions = ns.get("actions", {})
        if not methods and not actions and not ns.get("differences"):
            continue
        lines += [f"## chrome.{name} — {ICON.get(ns['level'], '?')} {ns['level']}", "", esc(ns.get("reason", "")), ""]
        if ns.get("differences"):
            lines.append("与 Chrome 的语义差异：")
            lines += [f"- {esc(d)}" for d in ns["differences"]]
            lines.append("")
        for title, table in (("方法 / 事件", methods), ("规则动作", actions)):
            if not table:
                continue
            lines += [f"| {title} | 级别 | 实现位置 | 说明 |", "|---|---|---|---|"]
            for m in sorted(table, key=lambda k: (k.startswith("on"), k)):
                spec = table[m]
                where = "JS shim" if len(spec) > 2 and spec[2] else "原生桥"
                if spec[0] == "Unsupported":
                    where = "—"
                lines.append(f"| `{m}` | {ICON.get(spec[0], '?')} {spec[0]} | {where} | {esc(spec[1] if len(spec) > 1 else '')} |")
            lines.append("")
    return "\n".join(lines) + "\n"


def main():
    with open(SRC) as f:
        text = render(json.load(f))
    if "--check" in sys.argv:
        current = open(OUT).read() if os.path.exists(OUT) else ""
        if current != text:
            print("docs/CHROME_API_MATRIX.md is out of date: run python3 scripts/gen_api_matrix.py")
            sys.exit(1)
        print("docs/CHROME_API_MATRIX.md is up to date")
        return
    with open(OUT, "w") as f:
        f.write(text)
    print("wrote", OUT)


if __name__ == "__main__":
    main()
