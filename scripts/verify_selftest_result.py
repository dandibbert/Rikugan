#!/usr/bin/env python3
"""Verifies that a self-test JSON report belongs to *this* CI invocation and really passed.

The XCUITest runner may tolerate its own UI-snapshot timeouts, so the job's verdict must come from
an independent, unforgeable-by-staleness channel: the app's report. This script fails unless:

  * the report exists and is valid JSON;
  * runID equals the nonce this job generated and passed to the app;
  * suiteName equals the suite this job ran;
  * startedAt and finishedAt exist, finishedAt >= startedAt, and both are after the job started
    the test (so a report from an earlier run / app launch cannot pass);
  * the process that finished the run is the one that started it (no crash + relaunch);
  * result == PASS (or, with --allow-fail, the run finished at all), failureCount consistent;
  * assertionCount >= the suite's expected minimum (an empty or truncated run cannot pass).

Usage: verify_selftest_result.py REPORT --run-id ID --suite NAME --not-before EPOCH --min-checks N [--allow-fail]
Exit code 0 = accepted, 1 = rejected (reason printed).
"""
import argparse
import json
import sys
from datetime import datetime


def parse_time(value):
    if not value:
        return None
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def verify(report, run_id, suite, not_before, min_checks, allow_fail=False):
    """Returns None when accepted, otherwise the rejection reason."""
    if not isinstance(report, dict):
        return "report is not a JSON object"
    if report.get("runID") != run_id:
        return f"runID mismatch: report {report.get('runID')!r} != expected {run_id!r} (stale or foreign result)"
    if report.get("suiteName") != suite:
        return f"suiteName mismatch: {report.get('suiteName')!r} != {suite!r}"
    started = parse_time(report.get("startedAt"))
    finished = parse_time(report.get("finishedAt"))
    launched = parse_time(report.get("processLaunchedAt"))
    if started is None:
        return "startedAt missing"
    if finished is None:
        return f"finishedAt missing (result={report.get('result')!r}): the run never finished"
    if finished < started:
        return "finishedAt is before startedAt"
    if started < not_before or (launched is not None and launched < not_before):
        return "report was produced before this job started the test (stale result)"
    if launched is not None and launched > started:
        return "process launch time is after the run start (app relaunched into a different process)"
    result = report.get("result")
    failures = report.get("failureCount")
    count = report.get("assertionCount")
    if not isinstance(count, int) or not isinstance(failures, int):
        return "assertionCount / failureCount missing"
    if count < min_checks:
        return f"assertionCount {count} < expected minimum {min_checks} (truncated or empty run)"
    results = report.get("results")
    if isinstance(results, list):
        if len(results) != count:
            return f"assertionCount {count} does not match {len(results)} recorded results"
        if sum(1 for r in results if not r.get("passed")) != failures:
            return "failureCount does not match the recorded results"
    if result == "PASS":
        if failures != 0:
            return "result PASS but failureCount > 0"
        return None
    if allow_fail and result == "FAIL":
        return None
    return f"result is {result!r} with {failures} failure(s)"


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("report")
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--suite", required=True)
    parser.add_argument("--not-before", type=float, required=True, help="epoch seconds when the job started the test")
    parser.add_argument("--min-checks", type=int, required=True)
    parser.add_argument("--allow-fail", action="store_true", help="accept a finished FAIL result (report-only suites)")
    args = parser.parse_args()
    try:
        with open(args.report) as f:
            report = json.load(f)
    except (OSError, ValueError) as e:
        print(f"REJECTED: no valid report: {e}")
        return 1
    reason = verify(report, args.run_id, args.suite, args.not_before, args.min_checks, args.allow_fail)
    if reason:
        print(f"REJECTED: {reason}")
        return 1
    print(f"ACCEPTED: suite={args.suite} run={args.run_id} result={report.get('result')} checks={report.get('assertionCount')}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
