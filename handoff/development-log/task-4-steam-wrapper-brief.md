# Task 4 support: Steam-mediated macOS probe loader

Implement a narrow executable wrapper for DST's Steam Launch Options. User requires all actual DST starts through Steam or user operation. The old preflight --launch now rejects; do not weaken it. Do not start real games, edit Steam configuration, or rebuild native in this task.

## Ownership

Own new `tools/steam_dst.py` (executable), new focused `tests/test_steam_dst.py`, and new `docs/steam-start.md`. Other files require controller ruling. You are not alone in the codebase; do not revert others' work. No subagents.

## Requirements

- This wrapper is invoked BY Steam as `ABSOLUTE_WRAPPER_PATH %command%`. Steam substitutes the actual .app bundle and optional game args. No shell -c, eval, shell=True, or string-split reconstructed commands. Preserve paths/arguments including spaces and apostrophes as argv.
- macOS route: subprocess `/usr/bin/open --env DYLD_INSERT_LIBRARIES=<steam-libraries plus our absolute dylib> --env DSTMC_PROBE_DIR=<unique evidence directory> --env DSTMC_FIRST_PERSON=1 -n -W <DST app> --args <optional game args>`. Prefer `STEAM_DYLD_INSERT_LIBRARIES`; also preserve an existing DYLD_INSERT_LIBRARIES if present, avoiding duplicate paths. Do not put DYLD vars in the open process environment or global environment. Preserve Steam's existing non-DYLD environment. No DYLD_FORCE_FLAT_NAMESPACE unless evidence requires it (none does yet).
- Actual operation requires SteamAppId or SteamGameId equal 322330; reject absent/mismatching/conflicting IDs before writes/open. This is an operational misuse guard, not a security/authentication claim. Accept ONLY the canonical app bundle containing preflight.DEFAULT_EXE; reject other apps, executables, unknown flags as first arg. Do not add any path to invoke the DST binary directly.
- Reuse preflight.preflight for the executable/library/running-process checks. If not ready, fail without invoking open. Enforce dylib x86_64 and both existing required entitlements true from its result. Do not read/log credentials, all env, account configuration, or save contents.
- Unique per-launch evidence directory under ROOT/evidence/steam-launches. Record a small request manifest (PID, selected app/path, requested module SHA/path, output dir, app ID marker, open invocation, timestamp) before open, and completion return code. No claim native loaded or online from open's exit status. Native `loaded.json` and live callbacks establish actual module load separately.
- Provide --help and --dry-run diagnostics that have NO writes and do not open/launch anything; dry-run may show a command for planned use and missing Steam marker/preflight blockers, but it cannot be used as an actual bypass. Make clear CLI shape so game args are preserved. Keep old preflight CLI --launch blocked.
- No steam_appid.txt, no game bundle/Info.plist/signature changes, no launchctl/global env, no Steam client restart. Local wrapper permissions may be executable.

## Context/evidence

Source route: primary firsthand 2026 comment https://github.com/ValveSoftware/steam-for-linux/issues/5548#issuecomment (page latest comment by sgentle Aug 2 2026; controller verified full page). It reports %command% resolves to .app on Mac and first argument must be an executable. This is a candidate, not established behavior for Jay's current Steam. Current `/usr/bin/open -h` explicitly supports --env VAR, -n, -W, --args. Wrapper must be described as pending real Steam validation.

Existing helper tools/preflight.py is small. DEFAULT_EXE resolves to `/Users/jay/Library/Application Support/Steam/steamapps/common/Don't Starve Together/dontstarve_steam.app/Contents/MacOS/dontstarve_steam`; ROOT is repo worktree. Native constructor writes loaded.json to DSTMC_PROBE_DIR. Existing binary built reviewed HEAD SHA8079000eb6e56fa915e91fe1d5c6ae465e5eeaf494b1efced3480f0c2737a77d. Do not rebuild or hardcode that SHA for future builds.

## Tests / report

Use focused behavioral RED/GREEN before implementation: absent/mismatch Steam markers -> no side effects; wrong app -> no open; running/unsupported checks -> no open; success with fixture preflight -> exact open argv, Steam overlay preserved, DYLD removed from open's env, game arguments preserved, unique evidence; --dry-run -> no writes/open. Use temp locations and mocked external open boundary; no real game launch or UI. Test behavior, avoid copy-of-implementation assertions. No unrelated test-suite reruns.

Read applicable TDD skill. Self-review and commit minimal wrapper + tests + short user steps (backup existing Launch Options; paste quoted absolute wrapper + %command%; remove only added wrapper to revert; actual Steam load still pending). The controller owns approved design/plan and ledger edits. Report full results, RED/GREEN, caveats, commit to `.superpowers/sdd/2026-10-21-dst-mc-first-person/task-4-steam-wrapper-report.md`. Return only status, commit, one-line test result and concerns. This is not Task4 graphics completion.
