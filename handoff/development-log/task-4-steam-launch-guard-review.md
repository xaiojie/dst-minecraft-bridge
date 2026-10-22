# Task 4 Steam launch guard review

Verdict: **Approved** for this scoped guard. Spec compliance: **Pass**. No actionable severity-tagged findings.

Reviewed base `27a486bca91b2e7585fc69d17a92b4170d31c834` to head `b9279dfcde6b06cee4313c5da69942f97ca7b443` using the supplied `review-27a486b..b9279df.diff`, read once. Also read `task-4-steam-launch-guard-report.md` for the reported verification. No changed-file rereads, Git commands, test reruns, game or Steam actions, native builds, or subagents were used. This review adds only this review document.

## Spec compliance

- `tools/preflight.py:77–78` returns exit 2 with machine-readable error `STEAM_START_REQUIRED` for actual `--launch` requests. The branch precedes `preflight()`, path resolution, environment construction, and every former launch-side effect. `--json` does not alter this branch.
- The former CLI launch tail was removed. `main()` no longer creates the evidence directory, writes `preflight.json` or `launch.log`, or calls `run_game()`. Therefore the CLI cannot reach the app-id hint or direct executable spawn through this path.
- `tools/preflight.py:79–81` preserves ordinary preflight diagnostics and their ready/nonready exit semantics. The existing `--dry-run` branch is retained, including its diagnostic precedence when combined with `--launch`.
- Keeping `run_game()` and `steam_app_id_hint()` is within the explicit allowance for historical or isolated helper tests. This change adds no bypass flag or replacement launch mechanism.
- The implementation report correctly confines completion to the guard and leaves Steam loading and Task 4 graphics acceptance incomplete.

## Code quality and verification

The guard is small and placed at the earliest meaningful CLI decision after argument parsing. Its error explains the required user action, and returning a distinct nonzero status is suitable for shell callers. Removing the old CLI tail also reduces the chance of accidental re-entry into the direct launch path.

`native/tests/tools_test.py:9–21` exercises the real `main()` for both `--launch` and `--launch --json`, supplies an otherwise ready preflight, traps `run_game`, the app-id hint, and subprocess execution, checks the error and nonzero result, and verifies that the requested output directory was not created. The supplied report records a failing RED run on the old launch boundary and a passing focused GREEN run covering the new guard, missing-executable JSON diagnostics, and the actual wrapper dry-run with no evidence writes; it also records a successful whitespace check. These runs were reported by the implementer and were not independently rerun during this review, in accordance with the requested scope. The diff presents no specific unresolved doubt requiring another test or outside-diff check.

## Findings and remaining boundary

No P0, P1, P2, or P3 findings identified in the supplied diff.

Approval applies only to rejecting direct CLI starts while retaining read-only diagnostics. It does not verify a Steam startup/injection path, a loaded first-person runtime, or any of Task 4's five real graphics acceptance fields.
