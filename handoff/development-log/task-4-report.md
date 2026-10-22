# Task 4 — First-person camera/native depth gate

Status: **WIP checkpoint; Task 4 incomplete. Graphics gate NOT_VERIFIED; Tasks 5–8 remain blocked.** Code and local tests are ready for separate review, while actual calibration requires normal Klei login to the existing test world.

Base commit: `b8b82820017427c6069c058d194e5fb007700264`.
Worktree: `/Users/jay/Documents/Codex/2026-10-20/https-mp-weixin-qq-com-s/work/dst-mc-bridge/.worktrees/implementation`.

## Implemented candidate

- Pure C++ `CameraService` pins the exact `FrameView` and its mmap owner, converts identity-axis MC pose into anchored DST coordinates, requires an exact-key acknowledgment, expires at 250 ms from first offer, rejects retired frame IDs, and invalidates pending control on release/resize/session change. A render-side alias retains both mmap and slot while composing.
- Native loopback HTTP on 39380 provides schema-shaped camera lease/applied and window responses. It discovers only the MC `/v2/status` exact key and maps only the identified complete frame; stale discovery is rejected for retry. HTTP calls no game or rendering API. Window geometry is sampled on the Cocoa main thread; physical dimensions come from actual profiled scene viewport, not backing pixels inferred from Retina.
- Controller approved adding `native/src/camera_http.mm` and its narrow header to keep Foundation HTTP/JSON/mmap/window snapshot separate from pure lease logic and entry hooks.
- Compositor reconstructs eye-space distances with each engine's inverse projection. Actual view translation/basis, ray-defining projection entries, physical viewport and depth range must match before it draws. Reflected native view bases currently fail closed under the unchanged identity transform. Premultiplied MC color blends only when nearer than verified scene depth. HUD is a separate late layer. All touched legacy raster state plus shader/FBO/PBO/texture bindings are restored.
- Supplemental scene depth copies verified ground depth, then immediately replays only the observed world-sprite shader fingerprint in the same scene target and perspective phase. It keeps the original shader, attributes, uniforms, textures and discard path; only depth/color-write state changes. Unrecognized draw roles are not assigned guessed depth. This mechanism has offscreen coverage but **has not established real tree/creature depth correctness**.
- DST adapter adds saved world UUID/shard identity and local non-dedicated Master-world connection guards. Connection defaults to calibration only (`connect=false`), so no accidental final MC pairing. Runtime camera requests are separate from 20 Hz exchange and single-flight; generation checks reject late callbacks. Pose updates happen inside the game camera update. Explicit release stops reacquisition.
- Bounded `DSTMCFirstPersonCalibrate()` applies player+(0,2,0), forward (0,0,-1), up (0,1,0), vertical FOV 90 for 12 real seconds without a handshake, then restores the normal camera. The two exported diagnostic functions use `GLOBAL.rawset` to comply with DST's strict-global environment.
- MC opt-in `-Ddstmc.firstPerson=true` requests transparent framebuffer and disables GLFW macOS Retina framebuffer scaling before window creation. A recent native composite is required before an input-retaining borderless floating window is enabled. Cocoa explicitly keeps mouse events and restores shadow/geometry/decorations/floating flags on release. Only the duplicate final MC screen blit is suppressed. Capture world/depth/HUD contracts remain unchanged; inactive fusion reconstructs normal opaque MC display after separate HUD capture.

## Tests and observed results

Initial lease RED:

```
xcrun clang++ -std=c++17 -arch x86_64 -Inative/include native/tests/lease_test.cpp -o /tmp/dstmc-lease-red
fatal error: 'camera_service.h' file not found
```

After implementation `make -C native lease-test` passed pinned matching pose, late ACK rejection, 250 ms expiry, retired-frame refusal, Retina resize cancellation, explicit release and new epoch reset. This was the test-first portion; the initial compositor/adapter tests were added after their first implementations, so this report does not claim complete TDD adherence.

Real strict-global regression RED was reproduced in a fresh Lua runtime executing the actual `modmain.lua` with an undeclared-global `__newindex` rejection:

```
...LuaCameraTests.test_mod_exports_respect_strict_globals -v
assign to undeclared variable DSTMCFirstPersonCalibrate
FAILED (errors=1)
```

Both exports changed to `G.rawset`; the same covering test then passed. Controller saw this error in the actual first calibration launch before the fix; a subsequent READY log from that failing launch was not treated as success.

Covering native suite:

```
make -C native all gl-test lease-test reader-test loader-test
```

Passed: actual CGL compositor pixel tests; native GL state/observer/context tests; lease lifecycle; exact reader/scoped release; real DYLD loader, NSOpenGL presentation and imported draw hook. No native compiler warnings (`-Wall -Wextra -Werror`). This suite ran before the final HTTP-only hardening revision.

Later targeted native checks:

```
make -C native all compositor-test
/tmp/dstmc-task4-lua-tests/bin/python -m unittest tests.test_first_person_gate.NativeHttpTests -v
```

Passed: a near red MC surface at eye distance 2 replaces a blue host at distance 6 using different near/far projections; the transparent pixel preserves blue within one channel unit; shader/raster state restoration; reflected view rejection; expired composition skip. Added real CGL replay checks: original shader discard leaves supplemental depth 0.9 at the hole and writes 0.5 at the opaque pixel, without modifying host color; ground-only frames have no verified camera and are rejected.

The real injected HTTP fixture uses a copied protocol fixture, a mock MC discovery server, and a separate short-lived x86_64 native process. It passes empty/malformed input rejection, exact-frame mmap slot pin, matching pose response, accepted ACK, non-boolean ACK rejection, 250 ms expiration and rejection of the same retired frame. It does not open or pair either real game save. One combined run skipped HTTP due to TCP port reuse delay; after correcting the test's availability probe to use SO_REUSEADDR and verifying ports, the targeted HTTP test passed without skips on the final candidate.

**Corrected hypothesis:** code review initially suspected an empty HTTP POST might raise an uncaught Foundation exception. The isolated regression also passed on the old candidate; no crash was reproduced. The explicit dictionary check is defensive hardening, not a demonstrated crash fix. Canonical string slash escaping/UUID normalization and quick-restart SO_REUSEADDR were also tightened.

Python/Lua coverage: actual adapter source parsing; camera APIs run only on the camera update; real-clock expiration under zero simulation delta; explicit release; invalid projection; strict-global exports; single-flight camera polling; late response after release cannot reacquire. The optional Lua test runtime was installed in `/tmp/dstmc-task4-lua-tests`; it is not bundled into the project. Standard Python without lupa skips these Lua checks, so the recorded full Lua results use that isolated interpreter.

MC final covering command:

```
JAVA_HOME=/Library/Java/JavaVirtualMachines/liberica-jdk-21-full.jdk/Contents/Home ./gradlew build publisherTest exchangeTest --console plain
```

`BUILD SUCCESSFUL`. Existing core/coordinate/frame publisher/exchange contracts passed, including aarch64 Java to x86_64 native frame verification and leased-slot/resize cases. Gradle reported its existing Gradle 10 deprecation notice; no Java compilation failure. This verifies compilation and protocol/capture compatibility, **not actual transparent-window input**.

## Runtime evidence so far

- Controller owns all desktop UI, actual launches and game saves. Implementer launched only isolated offline test processes. No AppleScript/CGEvent automation was used.
- First candidate SHA256 `975040b25546d4d0ca6bae5781eaf2102d302a795009be6b34e94e6774840613`: actual native load; real Lua strict-global failure prevented calibration acceptance. HTTP negative-input checks were separate isolated native fixtures; the controller sent no negative POSTs to the actual game process. Evidence `evidence/first-person-calibration-1/`.
- Second candidate SHA256 `ea0e5f9c4a8b1c40f9d7ee4d4105cdb6893848004d9f3332aebe10ec12264616`: split HTTP/lease/render implementation plus strict fix; actual game reached menus, but Klei TLS login failed and official offline mode did not allow the existing online test world. No camera result or MC pairing. Evidence `evidence/first-person-calibration-2/`.
- Current calibration candidate SHA256 `6266d7a28f434227af09af12f90808ed394fecef34da475b1fae58f6dd8cb16b`: includes HTTP hardening; controller launched with its existing local system proxy supplied only to this child, loopback excluded, with TLS certificate checks unchanged. Child environment inheritance was verified, but Klei TLS login still failed. No world load or calibration occurred. Controller normally exited PID 14651 and verified all native game processes absent before authorizing the final rebuild. Evidence `evidence/first-person-calibration-3/`.
- Controller preserved save-only backups and disabled the old probe using actual UI after discovering menu state differed from the edited config. Final MC copy remains deliberately unpaired. No invented final pairing or reuse of Task3 mock identity.

## Self-review and outstanding acceptance

- No shared transform or protocol schema changes made. Existing identity axes remain a hard gate. A real handedness calibration must precede binding the final MC world. Any reflection requires a controller ruling and consistent persisted-transform/frame-reader/schema changes; an endpoint sign flip is not acceptable.
- Real camera matrix/ray correspondence, tree/creature foreground/background occlusion, physical pixel/point alignment, real transparent-window movement plus one block placement, normal UI restoration, and 60-second performance remain unaccepted until controller supplies actual evidence.
- Offscreen synthetic depth replay proves the mechanism preserves discard, not that the profiled sprite geometric depth is a correct physical representation of every DST object. Unknown draw paths remain unsupported.
- The current `/v2/window` is available only after a recent composite, so a dedicated MC window must start at matching physical size for first activation. Retina-off hint implementation is compiled but its actual MC framebuffer dimensions still need measurement.
- `camera_http.mm` owns process-lifetime server state; unloading/reloading the injected dylib in a live process is not supported. Dedicated launch/normal process exit is the lifecycle.
- The first camera code iteration exposed a real strict-global issue; report preserves the failure and fix. Source inspection suspicions are distinguished from reproduced failures.

## Final checkpoint changes and validation

- Local avatar uses a reversible render-alpha override while the lease/calibration is active. Entity visibility is left intact because DST AI queries it. Release and real-clock expiry restore the saved alpha; a fresh Lua regression failed before this implementation and passes after it. Real gameplay rendering has not yet exercised it.
- Supplemental sprite replay now also rejects final alpha zero with legacy alpha test, covering hidden avatars even if the shader silhouette discard happens before tint multiplication. The real CGL regression confirms zero-alpha pixels keep ground depth and alpha-test state restores. This is local GPU evidence, not proof of actual avatar/trees in-game.
- Self-review found pinned leases could mask a newly announced MC physical size. The exact HTTP fixture first reproduced `200 != 409: resize must invalidate a pinned lease`. Discovery now refreshes dimensions before returning an existing pin, cancels on resize, and rejects its late ACK. It retains exact-key discovery and does not acquire a second reader on a pinned slot.
- FrameCapture preserves the publisher across a GL-context change, retaining monotonically increasing frame IDs within the existing epoch while rebuilding capture buffers/generation. Window alignment does not close the publisher. This prevents the native retired-ID guard from blocking a same-session restart at frame 1.
- After these changes, `make -C native all compositor-test` succeeded and `/tmp/dstmc-task4-lua-tests/bin/python -m unittest tests.test_first_person_gate -v` passed **10 tests with no skips**, including actual CGL, injected HTTP, Lua camera/strict globals/avatar/late callbacks. Latest MC `compileClientJava publisherTest --console plain` passed; `remapJar` refreshes the review artifact without re-running unrelated tests.
- `git diff --check` found no whitespace errors. Source SHA-256 inventory is `evidence/first-person-gate/source-sha256.json`; binary hashes are in `evidence/first-person-gate/binary-sha256.json`. These identify the local checkpoint, not an accepted live deployment.

`evidence/first-person-gate/result.json` records camera, same-frame, transparency, depth occlusion and UI individually as **NOT_VERIFIED**. No numerical or visual actual fused-frame acceptance exists. The previous known reflected native view remains an unresolved architecture risk; final MC stays unpaired. The minimal next action is normal login restoration followed by the already prepared bounded native handedness calibration, then only any justified transform ruling and actual two-game gate checks. No further blind login launches or Task 5 implementation were performed.

Self-review also notes runtime role recognition currently relies on the observed shader fingerprints and scene phase. The controller's executable-build preflight anchors the actual launch; this candidate does not independently enforce an executable hash in the injected module. Unknown draw programs fail to contribute supplemental depth. Actual UI/input restoration and frame-time cost must be measured before this WIP can satisfy Task 4.

Final native candidate SHA-256: `12a2484760df968eb9d3404aed5655b9b21c6244b954e4ebba28e83f88d0bd1e`. Final `remapJar` completed successfully. This candidate has not been launched in the actual game.

WIP source checkpoint: `2ea975d63592f11a263462550a7a5da5fbf41419` (24 owned files). Tracked worktree clean after commit. Separate controller-led spec/quality review is still pending; this self-review is not external review. Report and evidence remain in the project-ignored working evidence directories.

## Independent review fix round 1 (code only)

Input checkpoint: `2ea975d63592f11a263462550a7a5da5fbf41419`. This round addresses the three scoped review findings only. User is handling network recovery. No game launch, UI operation, network diagnosis/change, world write, or process termination was performed.

Fresh inventory found native game PID 16095, treated as user-owned. Read-only `lsof` found no candidate dylib in that process and no listener on 39379/39380. All new native compilation went to `/tmp/dstmc-task4-review1`, and fixtures used their own short-lived process. The repository `native/build/libdstmc_probe.dylib` is still SHA `12a2484760df968eb9d3404aed5655b9b21c6244b954e4ebba28e83f88d0bd1e`; it was not overwritten. Default native tests consequently still refer to the previous binary unless the environment override below is supplied.

1. **Complete discovery status validation.** A normal PAIRED status can contain null stream fields. Width/height/generation are now validated as non-boolean JSON numbers, finite integral and bounded, before Foundation numeric conversion. Path and latest-key object must be present. An incomplete stream releases any pending lease and returns GATE_NOT_READY. The validated width/height are reused when checking the mapped frame.
   - Initial null-stream run happened to return 409 and recover; this did not establish the absence of the bug, because discovery itself can fail before reaching numeric conversion.
   - Repeated old-candidate run reproduced `RemoteDisconnected`, and captured child stderr confirmed **uncaught NSInvalidArgumentException: -[NSNull unsignedIntValue]**, with `bridge::discover` in the stack. This is an actual reproduced failure, distinct from the earlier disproved empty-POST hypothesis.
   - GREEN covers null stream; string width, boolean height, null/fractional generation and oversized width rejection; then a valid frame can be leased/acknowledged, expire, and be cancelled by resize. Child process remains alive.

2. **Window response lifetime.** Introduced a small game-independent `WindowActivation` policy used by PassthroughWindow. Each dispatch captures active handshake object identity, a local session generation and an absolute monotonic deadline. Session change cancels pending requests and clears local activation proof; `active()` also compares current session before the next client tick. A completion may activate only that session before its original dispatch deadline. Background HTTP parsing does not access game state.
   - To make the old behavior reproducible without real GLFW, the policy was first extracted with the original consume-time extension/unconditional acceptance behavior. The executable Java lifecycle test reported **old_response_after_repair=true, completed_response_after_deadline=true** (RED).
   - After the fix, the same test rejects both old/late responses, accepts a timely current response, expires precisely at the dispatch deadline, and clears proof on session change (GREEN).
   - This binds the local pending/cached proof. Existing `/v2/window` protocol remains unchanged and does not itself return Pair/Epoch. Real input/transparent-window activation is still untested.

3. **Incremental test prerequisites.** Added camera_service.h, frame_protocol.h and gl_observer.h as compositor_test prerequisites. `make -C native -n -W include/<header> build/compositor_test` selected recompilation for each of the three headers. No actual game artifact was touched by this dry-run check.

Commands/results:

```
make -C native BUILD=/tmp/dstmc-task4-review1 all /tmp/dstmc-task4-review1/lease_test
# succeeded (-Wall -Wextra -Werror)
DSTMC_TEST_NATIVE_BUILD=/tmp/dstmc-task4-review1 /tmp/dstmc-task4-lua-tests/bin/python -m unittest tests.test_first_person_gate.NativeHttpTests -v
# 1 test, OK, no skips
/tmp/dstmc-task4-lua-tests/bin/python -m unittest tests.test_first_person_gate.WindowActivationTests -v
# 1 test, OK, no skips (also passed in the first combined fixed-candidate run)
JAVA_HOME=/Library/Java/JavaVirtualMachines/liberica-jdk-21-full.jdk/Contents/Home ./gradlew compileClientJava --console plain
# BUILD SUCCESSFUL; existing Gradle 10 deprecation warning
```

The first combined fixed-candidate run failed to connect before the isolated x86 process was listening; its one-second startup loop was inadequate for a newly built process. Test startup now waits up to five seconds for the explicit camera_service_started log, rejects bind-failure events, and captures stderr for child failures. The subsequent targeted HTTP test passed. No graphics/lease logic changed in response to that harness timing issue.

Offline-only candidate: `/tmp/dstmc-task4-review1/libdstmc_probe.dylib`, SHA-256 `bab372540cc473381341ec6b138818ca662e5b86461adc24ca16cb94ac7c6928`. Java source compiled, but this round did not refresh the deployable jar. Scoped source hashes are `evidence/first-person-gate/review1-source-sha256.json`. `git diff --check` passed. All five actual graphics gate fields remain NOT_VERIFIED; Task 4 is incomplete and Task 5 remains blocked. Fresh independent scoped re-review is required after this fix commit.

Review fix round 1 commit: `7c7804808187c6a7cec6ea35cf7e0b1016c47b35` (five scoped files), tracked worktree clean.

## Independent review fix round 2 — native proof identity

Input checkpoint: `7c7804808187c6a7cec6ea35cf7e0b1016c47b35`. Scoped re-review identified that fixing local request lifetime alone was insufficient: a fresh request from session B could receive the still-young native composition proof from session A. Controller explicitly authorized minimal identity binding on the GET query; WindowResponse and binary frame schemas remain unchanged.

- `/v2/window?pair_hash=<64 lowercase hex>&epoch=<lowercase UUID>` now compares the requested identity to the actual FrameKey recorded after the COMPOSITED/render presentation path. `entry.mm` passes `displayed->key` only when its existing successful-compose and ready-frame checks pass. Neither offer nor camera ACK records this proof.
- The production `WindowProof` helper stores that key plus monotonic completion time. The HTTP router directly uses its exact identity and <250 ms check under the existing window mutex. Missing/wrong/extra query identity and expired/missing proof fail closed. Previous-session proof cannot satisfy a current-session query.
- MC uses its current handshake Pair hash and Epoch to construct the canonical query and retains round-1 local session-generation/deadline protections. `protocol/frame-v2.md` specifies the exact request spelling; no response or mapped-frame layout change.
- The focused test calls the same production proof helper with controlled FrameKeys and clock values. It first ran with the extracted previous TTL-only decision and failed at `fresh_B_request_must_reject_A_composite` (exit 134). After identity checking was added it passed: current A accepted, B with changed Epoch rejected, different Pair rejected, missing/extra identity rejected, proof expired at 250 ms, B accepted only after its own recorded proof, old A then rejected. This is a production-helper lifecycle test with synthetic identities, not a real GPU frame or visual acceptance claim.

Fresh inventory again found user-owned native PID 16095. No game operation or network change was performed. The native build stayed in `/tmp/dstmc-task4-review2`; before the HTTP fixture, a fresh port inventory showed no listeners on 39379/39380. No process was terminated except normal exit of our own short-lived fixture. Repository native binary remained unchanged.

Commands/results:

```
make -C native BUILD=/tmp/dstmc-task4-review2 all /tmp/dstmc-task4-review2/lease_test
/tmp/dstmc-task4-review2/lease_test
# native build succeeded; production proof and lease assertions PASS
DSTMC_TEST_NATIVE_BUILD=/tmp/dstmc-task4-review2 /tmp/dstmc-task4-lua-tests/bin/python -m unittest tests.test_first_person_gate.NativeGateTests.test_lease_lifecycle tests.test_first_person_gate.NativeHttpTests -v
# 2 tests OK, no skips
JAVA_HOME=/Library/Java/JavaVirtualMachines/liberica-jdk-21-full.jdk/Contents/Home ./gradlew compileClientJava --console plain
# BUILD SUCCESSFUL; existing Gradle deprecation notice
```

The first attempt to use the `lease-test` convenience target with an absolute BUILD path compiled successfully but its pre-existing `./$(BUILD)` run recipe could not launch an absolute path. Executing the produced binary directly gave the expected RED above; subsequent commands target the binary and run it by its absolute path. No unrelated Makefile recipe refactor was made. The lease binary prerequisites were minimally extended for the production proof header now used by the focused test.

Offline-only candidate SHA-256: `bd3fed78cb464ef8ca09e05350b4a0f3cb4592d3de8c8911d52e8de10f3abfda` at `/tmp/dstmc-task4-review2/libdstmc_probe.dylib`. Repository native binary remains `12a2484760df968eb9d3404aed5655b9b21c6244b954e4ebba28e83f88d0bd1e`. Deploy jar was not refreshed. Source manifest: `evidence/first-person-gate/review2-source-sha256.json`. `git diff --check` passed. Scoped independent re-review is pending. Five actual graphics gate items remain NOT_VERIFIED; Task 4 incomplete, no Task 5 work.

Review fix round 2 commit: `60c5591b80c6ba2455026b359e508c0121f77c6f` (eight scoped files), tracked worktree clean.
