#!/usr/bin/env python3
"""Turns Documents/SelfTestReports/*.json (pulled from the simulator) into Markdown for the
GitHub job summary. Usage: selftest_report.py <reports dir> [<reports dir> ...]"""
import glob
import json
import os
import sys


def esc(text):
    return str(text).replace("|", "\\|").replace("\n", " ")


def render(report):
    out = [f"### Suite `{report['suite']}` — {report['summary'].split(' — ')[0]}",
           f"Build `{report.get('build')}` · {report.get('environment')} · {report.get('os')} · {report.get('date')}", ""]
    extras = report.get("extras", {})
    if report["suite"] == "compat" and "extensions" in extras:
        areas = ["install", "manifest", "permissions", "background", "content_scripts", "popup", "storage", "messaging",
                 "ports", "scripting", "tabs", "dnr", "unsupported_apis", "behavior"]
        icon = {"ok": "✅", "partial": "🟡", "fail": "❌", "n/a": "—", "untested": "⚪"}
        out.append("| Extension | Version | " + " | ".join(areas) + " |")
        out.append("|---|---|" + "---|" * len(areas))
        for ext in extras["extensions"]:
            cells = [icon.get(ext.get("areas", {}).get(a, {}).get("status", "untested"), "?") for a in areas]
            out.append(f"| {esc(ext['name'])} | {esc(ext.get('version'))} | " + " | ".join(cells) + " |")
        out.append("")
        for ext in extras["extensions"]:
            out.append(f"<details><summary>{esc(ext['name'])} {esc(ext.get('version'))} — details</summary>\n")
            out.append(f"Source: {ext.get('source')}  sha256: `{ext.get('sha256')}`\n")
            for a, v in ext.get("areas", {}).items():
                out.append(f"- **{a}**: {v.get('status')} — {esc(v.get('detail'))}")
            if ext.get("unsupportedCalls"):
                out.append(f"- unsupported calls: {esc(ext['unsupportedCalls'])}")
            if ext.get("runtimeErrors"):
                out.append(f"- runtime errors: {esc(' | '.join(ext['runtimeErrors']))}")
            out.append("</details>\n")
    for rnd in extras.get("rounds", []) if isinstance(extras.get("rounds"), list) else []:
        if rnd.get("failures"):
            out.append(f"**Round {rnd.get('round', 0) + 1} failures (full):**")
            out += [f"- {esc(f)}" for f in rnd["failures"]]
            out.append("")
    if report.get("runID"):
        out.append(f"runID `{report.get('runID')}` · started {report.get('startedAt')} · finished {report.get('finishedAt')} · result {report.get('result')}")
        out.append("")
    failed = [r for r in report.get("results", []) if not r["passed"]]
    passed = len(report.get("results", [])) - len(failed)
    out.append(f"{passed} passed, {len(failed)} failed")
    out.append("")
    out.append("| | Check | Detail |")
    out.append("|---|---|---|")
    for r in report.get("results", []):
        out.append(f"| {'✅' if r['passed'] else '❌'} | {esc(r['name'])} | {esc(r['detail'])[:300]} |")
    out.append("")
    return "\n".join(out)


def main():
    files = []
    for d in sys.argv[1:]:
        files += sorted(glob.glob(os.path.join(d, "*.json")))
    if not files:
        print("No self-test reports found.")
        return
    for f in files:
        with open(f) as fh:
            print(render(json.load(fh)))


if __name__ == "__main__":
    main()
