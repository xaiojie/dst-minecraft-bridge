# Task 4 Steam wrapper bounded review

Scope: the three-file support change from `b9279dfcde6b06cee4313c5da69942f97ca7b443` to `fcd1d45d213d098e223a2b7aa6123d39a3a2eab5`, reviewed from the supplied diff once. The separately approved preflight launch guard and the controller's unstaged design/plan changes are outside this review.

## Verdict

**Spec: substantially satisfied, with one unmet explicit no-write requirement. Task quality: Needs fixes.**

The change correctly implements a Steam-mediated candidate route and does not claim live Steam or graphics acceptance. The remaining finding is narrow and does not require changing the launch design.

## Finding

**[P2] Prevent import-time cache writes on read-only and rejected invocations — `tools/steam_dst.py:13-16`.**

The local `preflight` module is imported before argument parsing and Steam-marker checks. With normal Python bytecode behavior, a fresh checkout or changed module causes this import to create/update `tools/__pycache__/preflight.cpython-*.pyc`, even for `--help`, `--dry-run`, and an invocation rejected for missing/mismatching Steam IDs. The brief explicitly requires diagnostics to have NO writes and rejected Steam markers to fail before writes. The present tests only assert absence of `evidence/`, so they miss this side effect.

A focused fresh-cache subprocess check ran only `--help`, with Python's cache directory redirected to a temporary directory so the checkout was not modified. It exited 0 and created `.../tools/preflight.cpython-39.pyc`. No preflight checks, external `open`, game launch, or native build were invoked. Disable local-module bytecode writes before this import (or otherwise make script startup read-only), and cover a fresh interpreter/cache in the diagnostic/rejection test. The solution should not require global environment changes.

## Strengths and requirement coverage

- Actual execution rejects absent, empty, foreign, or conflicting Steam markers before preflight/evidence/open; help and dry-run do not offer a launch bypass.
- The canonical app whitelist derives from `preflight.DEFAULT_EXE`, and the only launch boundary is `/usr/bin/open` with an argv list. Game arguments remain individual elements after APP, including spaces, apostrophes, and option-like strings.
- Preflight blockers, the dylib's exact `x86_64` token, and both literal-true entitlements gate launch. The focused outside-diff check of `preflight.py` confirmed the consumed result shape and that invoking `preflight.preflight` does not enter the old direct-launch helper.
- Steam overlay insertion libraries are retained and deduplicated; existing insertion libraries are merged; all `DYLD_*` keys are removed from the open subprocess environment while other environment entries are preserved. No forced flat namespace, global mutation, or direct executable fallback was added.
- A unique evidence directory contains both `request.json` and the required `preflight.json` before open. Completion return codes and bounded OS-error information are recorded separately. Documentation consistently distinguishes a request/open return status from native load, callbacks, online state, and graphical acceptance.
- User steps include backing up Launch Options, the exact quoted wrapper entry, argument placement, and restoration. The Steam `.app` substitution route remains explicitly pending real-machine validation.
- Behavioral tests target the external launch boundary, cover failure and success cases, and avoid a real game or native build. The report provides initial RED/GREEN evidence plus the controller addendum's separate RED/GREEN cycle; its extra OS-error test is accurately described as later self-review coverage.

## Verification limits

The supplied implementation report's 9-test passing result was reviewed rather than rerun. The only additional execution was the focused import-cache diagnostic above, because its specific no-write risk was not addressed by the existing evidence. No real launcher, Steam/game configuration, game bundle, signature, Info.plist, global environment, or native build was changed. This review establishes no real Steam startup, module load, online state, or Task 4 graphical completion.
