# Task 4 scoped Steam launch guard

Status: DONE for the launch guard only. Task 4 graphics gate remains incomplete.
Base: 27a486bca91b2e7585fc69d17a92b4170d31c834.

## User constraint and change

User requires DST to start through Steam or through their own operation. The old CLI called run_game after a ready preflight, which created an app-id hint and spawned the executable directly. tools/preflight.py now returns exit 2 and JSON error STEAM_START_REQUIRED for --launch (including --launch --json), before preflight or any launch-side effect. The actual CLI launch tail was removed, leaving run_game and steam_app_id_hint reachable only by explicit library callers / existing isolated helper tests. No bypass flag was added.

--dry-run retains its original read-only precedence even with --launch, so tools/launch_dst.command --dry-run still prints its planned environment, working directory and preflight diagnostics. Ordinary invocation and --json retain the preflight output and ready/nonready exit semantics. This does not implement a Steam injection path or claim that the first-person runtime is loaded through Steam.

## TDD evidence and verification

New test: native.tests.tools_test.ToolsTest.test_cli_launch_requires_steam_before_spawn_or_hint. It executes the real main with a ready preflight and traps external launch/hint/subprocess boundaries. It also asserts a nonzero result, STEAM_START_REQUIRED, and absence of an output directory. Temporary locations are used; no real game starts even during RED.

RED command:
python3 -m unittest native.tests.tools_test.ToolsTest.test_cli_launch_requires_steam_before_spawn_or_hint -v

Both --launch and --launch --json failed before the fix:
AssertionError: 1 != 0 : CLI must not call run_game
Ran 1 test; FAILED (failures=2).

GREEN command:
python3 -m unittest native.tests.tools_test.ToolsTest.test_cli_launch_requires_steam_before_spawn_or_hint native.tests.tools_test.ToolsTest.test_preflight_missing_executable_blocks_launch native.tests.tools_test.ToolsTest.test_launcher_dry_run_is_scoped_and_writes_no_evidence -v

Ran 3 tests in 0.251s; OK. The existing JSON diagnostic test invokes the real read-only CLI with a missing executable; the existing dry-run test invokes the actual wrapper against the built loader fixture and confirms no evidence writes. git diff --check passed. No full-suite rerun was required for this scoped Python CLI guard under the controller's explicit instruction; native code and binaries were untouched.

## Self-review and remaining scope

Only tools/preflight.py and native/tests/tools_test.py were edited. The guard cannot be bypassed via --json or a ready result. Dry-run never reaches a launch path. Historical helper behavior is retained without a CLI call site. No game launch, Steam UI/config change, authentication/network change, or native build occurred.

Actual Task 4 calibration/composition still needs the controller's approved Steam/user startup path. The five real graphics acceptance fields remain NOT_VERIFIED. This guard is not Task 4 completion. Independent review of this new diff belongs to the controller.

Commit: b9279df — fix: require Steam for actual DST startup.
