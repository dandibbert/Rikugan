#!/usr/bin/env python3
"""Negative tests for the self-test result verifier: stale, foreign, unfinished, truncated,
relaunched or inconsistent reports must be rejected; only a fresh, complete PASS is accepted."""
import copy
import sys
from datetime import datetime, timedelta, timezone

sys.path.insert(0, __file__.rsplit("/", 1)[0])
from verify_selftest_result import verify  # noqa: E402

JOB_START = datetime(2026, 9, 27, 12, 0, 0, tzinfo=timezone.utc)


def iso(dt):
    return dt.isoformat().replace("+00:00", "Z")


def good():
    return {
        "runID": "run-current", "suiteName": "core",
        "processLaunchedAt": iso(JOB_START + timedelta(seconds=30)),
        "startedAt": iso(JOB_START + timedelta(seconds=40)),
        "finishedAt": iso(JOB_START + timedelta(seconds=90)),
        "result": "PASS", "assertionCount": 3, "failureCount": 0,
        "results": [{"name": "a", "passed": True}, {"name": "b", "passed": True}, {"name": "c", "passed": True}],
    }


def check(name, report, expect_accept, min_checks=3, allow_fail=False):
    reason = verify(report, "run-current", "core", JOB_START.timestamp(), min_checks, allow_fail)
    ok = (reason is None) == expect_accept
    print(("ok   - " if ok else "FAIL - ") + name + ("" if reason is None else f" ({reason})"))
    return ok


def mutate(**changes):
    r = copy.deepcopy(good())
    for k, v in changes.items():
        if v is None:
            r.pop(k, None)
        else:
            r[k] = v
    return r


def main():
    results = []
    results.append(check("fresh complete PASS is accepted", good(), True))
    # The required negative test: a previous run's PASS (different nonce, earlier times).
    stale = mutate(runID="run-previous", processLaunchedAt=iso(JOB_START - timedelta(hours=1)),
                   startedAt=iso(JOB_START - timedelta(hours=1)), finishedAt=iso(JOB_START - timedelta(minutes=50)))
    results.append(check("stale PASS from a previous run is rejected", stale, False))
    results.append(check("PASS with the right nonce but produced before the job started is rejected",
                         mutate(processLaunchedAt=iso(JOB_START - timedelta(minutes=5)), startedAt=iso(JOB_START - timedelta(minutes=4))), False))
    results.append(check("foreign nonce is rejected", mutate(runID="someone-else"), False))
    results.append(check("wrong suite is rejected", mutate(suiteName="fonts"), False))
    results.append(check("unfinished run (IN PROGRESS, no finishedAt) is rejected", mutate(result="IN PROGRESS", finishedAt=None), False))
    results.append(check("FAIL is rejected", mutate(result="FAIL", failureCount=1,
                                                   results=[{"name": "a", "passed": True}, {"name": "b", "passed": False}, {"name": "c", "passed": True}]), False))
    results.append(check("PASS with failures is rejected", mutate(failureCount=1,
                                                                 results=[{"name": "a", "passed": True}, {"name": "b", "passed": False}, {"name": "c", "passed": True}]), False))
    results.append(check("truncated run (too few checks) is rejected", mutate(assertionCount=1, results=[{"name": "a", "passed": True}]), False))
    results.append(check("count inconsistent with recorded results is rejected", mutate(assertionCount=5), False, min_checks=3))
    results.append(check("relaunched process (launch after start) is rejected", mutate(processLaunchedAt=iso(JOB_START + timedelta(seconds=60))), False))
    results.append(check("finishedAt before startedAt is rejected", mutate(finishedAt=iso(JOB_START + timedelta(seconds=10))), False))
    results.append(check("missing counts are rejected", mutate(assertionCount=None), False))
    results.append(check("report-only suite: finished FAIL accepted with --allow-fail",
                         mutate(result="FAIL", failureCount=1, results=[{"name": "a", "passed": True}, {"name": "b", "passed": False}, {"name": "c", "passed": True}]),
                         True, allow_fail=True))
    results.append(check("report-only suite: unfinished run still rejected with --allow-fail",
                         mutate(result="IN PROGRESS", finishedAt=None), False, allow_fail=True))
    passed = sum(results)
    print(f"{passed}/{len(results)} verifier tests passed")
    return 0 if passed == len(results) else 1


if __name__ == "__main__":
    sys.exit(main())
