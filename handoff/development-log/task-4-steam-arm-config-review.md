# Task 4 ARM Python launch configuration review

**Verdict: Approved.** No blocking issue in the corrected copyable command or rollback instructions. One minor documentation inconsistency should be cleaned up.

Scope: documentation-only change `1c1a8e34e88f42515289e45b08438cce3fd0f55b..1bb0bb1`, read from the supplied diff once. Compared claims against `evidence/task4-config/steam-start-failure-20261022/steam-diagnostic.log`, `root-cause.json`, and the controller's stated observation of the actual Steam `.app` argument. No fresh wrapper/code review, tests, or launcher actions were performed.

## Actionable note

**[P3] Update the stale `.app` verification statement — `docs/steam-start.md:31`.** The final source paragraph still calls Steam's `.app` substitution behavior “待本机验证”, while the revised opening says this has been confirmed in this computer's Steam logs. Replace the final statement with the current evidence state: local `.app` routing is confirmed; the corrected ARM Python entry's actual Steam relaunch, native loading, online status, and graphical acceptance remain pending. This does not invalidate the copyable command.

## Checks

- Both the Steam Launch Options line and terminal dry-run example use `/usr/bin/arch -arm64 /usr/bin/python3 -B` before the quoted absolute wrapper path. `%command%` remains outside the script-path quotes and in the original argument position; existing game arguments remain after it.
- The captured real Steam diagnostic shows the x86_64 loader rejecting the ARM-only CLT `libxcrun` and wrapper exit 1 before Python code runs. The root-cause record includes matching direct x86_64 Python failure, successful x86_64-shell-to-ARM-Python startup, and a same-context wrapper dry-run with no blockers. These support the stated interpreter correction, without establishing a real game start.
- The architecture explanation scopes the prefix to Python and does not request a native module rebuild or change to the game architecture.
- Rollback now removes the entire project-added prefix and wrapper configuration and restores the saved original options. This correctly covers the newly added `arch` and Python tokens.
- Documentation still requires the user to start through Steam and distinguishes preflight/request/open status from native module loading, callbacks, online state, and graphical acceptance.

Only this review note was written. No code, tests, Steam configuration, game files, environment settings, or native binaries were changed.
