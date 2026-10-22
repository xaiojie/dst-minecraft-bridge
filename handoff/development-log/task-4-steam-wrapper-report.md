# Task 4 bounded Steam wrapper support report

Status: implemented and focused-test verified. This is support for the pending Task 4 live graphics gate, not Task 4 completion.

- Base: `b9279dfcde6b06cee4313c5da69942f97ca7b443`.
- Commit: `fcd1d45d213d098e223a2b7aa6123d39a3a2eab5` (`Add bounded Steam-mediated DST probe wrapper`).
- Committed exactly `tools/steam_dst.py` (executable), `tests/test_steam_dst.py`, and `docs/steam-start.md`.
- Controller changes to approved design/plan remain unstaged and untouched. This ignored report is not committed.

## Behavior delivered

The Steam Launch Options entry is:

```text
"/Users/jay/Documents/Codex/2026-10-20/https-mp-weixin-qq-com-s/work/dst-mc-bridge/.worktrees/implementation/tools/steam_dst.py" %command%
```

The wrapper accepts only the canonical `.app` containing `preflight.DEFAULT_EXE`. Actual execution requires at least one `SteamAppId`/`SteamGameId` equal to `322330`, with every provided marker agreeing; missing, empty, foreign, or contradictory markers reject before preflight/evidence/open. This guard is not authentication. No direct DST executable invocation was added.

It reuses `preflight.preflight` and rejects its blockers, non-x86_64 module architecture, or either missing/non-boolean-true required entitlement. Successful checks create a unique `ROOT/evidence/steam-launches/<PID>-<random>/` directory and persist `request.json` and the already computed `preflight.json` before calling `/usr/bin/open`. The request records PID, canonical app/executable, module path/SHA from preflight, output directory, selected Steam marker, exact open argv, and UTC timestamp. `completion.json` records return code and timestamp, including bounded OS-error reporting if open cannot execute.

Launch argv is `/usr/bin/open --env DYLD_INSERT_LIBRARIES=<merged libraries> --env DSTMC_PROBE_DIR=<directory> --env DSTMC_FIRST_PERSON=1 -n -W <app> --args <game args...>`. Existing Steam libraries take precedence in the merged list; existing DYLD insertion libraries are also retained and exact duplicate entries removed. All `DYLD_*` keys are removed from the open subprocess environment; other Steam environment entries are preserved. No shell reconstruction, eval, shell=True, global environment mutation, or forced flat namespace is used. Paths/game arguments with spaces, apostrophes, shell syntax, and wrapper-like flags after APP are retained as individual argv elements.

`--help` and `--dry-run` never create evidence or invoke open. A dry-run outside Steam reports the missing marker and can report preflight blockers; it cannot bypass actual checks. The existing preflight CLI and its blocked `--launch` behavior were not edited.

## RED / GREEN evidence

1. Wrote eight focused behavioral tests first. `python3 -m unittest tests.test_steam_dst -v` produced **8 FAIL**, each explicitly because the wrapper did not exist.
2. Implemented wrapper. The first implementation run exposed fixture-only macOS `/var` versus `/private/var` aliases in expected paths; fixture roots were resolved to match the actual preflight contract (which resolves paths).
3. Controller requested persisted `preflight.json` compatibility with the existing capture tool. Added a focused assertion, observed the explicit missing-preflight-evidence **FAIL**, added the write before open, and observed **8 PASS**.
4. Self-review added the external open OS-error completion test. Final focused command produced **9 tests, 0 failures/errors, OK**. This additional error-path test was added during self-review after that implementation branch existed; the report does not claim a separate initial RED for it.
5. Executed `./tools/steam_dst.py --help`: exit 0, correct Steam `%command%` usage and argument placement, no launch.
6. `git diff --cached --check`: exit 0 before commit. Only the three owned files were staged and committed.

The focused tests cover missing/conflicting Steam IDs before effects; wrong app/raw executable/unknown first flag; running/unsupported/unknown-process/missing-library preflight blockers; exact architecture token and both literal-true entitlements; exact open argv and overlay preservation; no DYLD inheritance by open; immutable input environment; game argument preservation; manifest before launch; preflight evidence; no credential environment dump; no steam_appid.txt; unique launch directories; completion return codes; open OS failure; read-only help and both blocked/ready dry-run.

No unrelated suite was run, per the explicit task brief. Tests use temporary fixture paths and a mocked external open boundary and fixture preflight; they do not establish live codesign/lipo/process findings or real Steam operation.

## Self-review and outstanding limits

Reviewed the requested path whitelist, marker ordering, preflight reuse, architecture/entitlement enforcement, argument and environment handling, evidence timing, diagnostic no-write path, and owned-file commit scope. The short user instructions include backing up existing Launch Options, the exact quoted absolute line, game-argument placement, and restoration steps. The source link is the controller-supplied primary author's note at https://gist.github.com/sgentle/8cace35bfad585a2866a9e825a5203af; its Steam `.app` substitution behavior remains anecdotal and unverified on this computer.

No real game, Steam client restart, Steam configuration write, native build, network change, app bundle/signature/Info.plist change, launchctl/global environment change, credential/account-config/save-content read, or steam_appid.txt creation was performed. The local wrapper alone was made executable.

`open` completion is expressly not proof of native load or online state. Pending controller/user validation must show actual Steam `%command%` app routing, native `loaded.json` and `heartbeat.json` in the new directory, live callbacks, and the separate Task 4 graphical acceptance evidence. The implementation has no compatibility issue requiring a controller ruling at handoff.

## Fix round1 — read-only import caching

Independent review found P2: importing local `preflight` before parsing options or checking Steam markers could create/update bytecode on help, dry-run, and rejected invocation paths. Controller accepted this finding against the explicit no-write requirement. Scope for the fix was only `tools/steam_dst.py` and `tests/test_steam_dst.py`, against base `f39f3347dfc1832cccf0aca9a1751644c1b5f5fb`.

Commit: `1c1a8e34e88f42515289e45b08438cce3fd0f55b` (`Suppress import cache writes before Steam wrapper diagnostics`). Only those two files were changed and committed; the working tree was clean afterward. The three-line behavior change imports built-in `sys` first and sets `sys.dont_write_bytecode = True` before any cacheable imports, suppressing subsequent bytecode writes for the wrapper interpreter without environment/global OS configuration changes.

Added a fresh-interpreter behavioral regression using temporary copies of the actual wrapper plus a non-launching preflight fixture and a fail-closed local external-process stub. Each of six cases gets its own isolated `PYTHONPYCACHEPREFIX`: help, dry-run, missing marker, wrong marker, conflicting markers, and wrong app. The test checks the expected exit code, absence of the wrapper/local-helper cache subtree and local `__pycache__`, and absence of evidence writes. It deliberately excludes Python's pre-script bootstrap stdlib cache from the wrapper no-write assertion.

- RED: `python3 -m unittest tests.test_steam_dst.FreshInterpreterReadOnlyTests -v` ran one test with **six failing subcases**; all six reported newly written local `preflight.cpython-39.pyc` and fixture helper cache.
- GREEN: after the early bytecode flag, `python3 -m unittest tests.test_steam_dst -v` ran **10 tests, 0 failures/errors, OK** in 0.562 seconds, covering the original nine plus the new fresh-interpreter regression.
- `git diff --check` and staged whitespace validation passed.

Self-review confirmed the flag precedes all cacheable wrapper imports and does not alter marker checks, app whitelist, preflight behavior, open argv/environment, manifest persistence, or the documented Launch Options line. No Steam/game operation, external open, native build, interpreter installation, or unrelated suite run occurred. Actual Steam loading and Task 4 graphics acceptance remain pending. This fix is ready for controller scoped re-review.
