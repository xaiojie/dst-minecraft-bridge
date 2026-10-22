# Task 2 — native render diagnostics

Status: Task 2 diagnostic implementation, full offline regression and actual native scene sampling verified. Native ground depth exists; tree/crow/avatar sprite depth is absent, and Task 4 must validate a supplemental alpha-aware depth path. No FrameView ABI change. All game UI and lifecycle actions were controller-owned.

## Implemented interfaces and scope

- `native/include/gl_observer.h`: RenderProbe, ShaderMatrix and ProbeCapture; inspect_draw, observe_draw, capture_probe_frame; scoped FrameView consumer.
- `native/src/gl_observer.mm`: current-context/current-FBO physical viewport RGBA8 and native float32 depth readback; all active mat4 shader uniforms; fixed-function matrices explicitly distinguished; depth, blending, alpha-test, framebuffer, program, draw and present phase metadata. Up to two requested frames, eight full-resolution checkpoints per frame; no synthetic rendering. Captures are requested only after the controller enters the desired scene.
- `native/src/entry.mm`: x86_64 dylib constructor record, NSOpenGLContext flushBuffer and class-local dealloc hooks, dyld interposition of imported glDrawArrays/glDrawElements and CGLDestroyContext. Thread-local recursion guard; exceptions do not escape into game drawing. Original methods/calls are always forwarded.
- `native/src/frame_reader.cpp`: read_frame-scoped callback holding an existing move-only FrameView lease, with automatic release. No mapper, truncation, format or ABI changes.
- `tools/preflight.py`: executable/library SHA-256, architecture, execute permission, two relevant entitlements, exact executable process IDs, loopback port occupancy, narrowly scoped cluster lock filename report. Save lock remains unknown because no reliable engine lock API was identified.
- `tools/launch_dst.command`: sets loader variables for one exec only, working directory Contents/data; blocks duplicate DST processes and existing evidence-directory reuse. Does not select a world, modify executable/signatures, change saves or terminate processes.
- `tools/capture_render_probe.py`: verifies fresh present heartbeat and live loaded PID, requests bounded sample, preserves raw color/depth/matrices, produces PNG previews, depth statistics and version/hash-bound identification groups. Every group is unverified pending manual scene and alpha-edge inspection.

## RED evidence

1. `make -C native gl-test`: built runnable x86_64 CGL test with empty observer implementation; exited 2 at actual assertion `capture.color.size()==16*12*4 && "capture must read actual current FBO viewport"`.
2. `make -C native reader-test`: built runnable scoped-consumer test with no-op implementation; exited 2 at `ok&&called&&"consumer must receive leased FrameView"`.
3. `make -C native reader-test loader-test`: reader GREEN; real DYLD-injected loader test failed at `loaded.good()&&"native extension constructor must record loading"` with empty entry implementation.
4. `python3 -m unittest discover -s native/tests -p '*_test.py' -v`: three actual failing assertions against minimal scripts: missing preflight executable report, missing stale-extension rejection, dry-run launch exit 1. An initial test used a missing dict key and errored; changed to an explicit key assertion and reran to observe three assertion failures before implementation.

## GREEN evidence

- `make -C native all gl-test reader-test loader-test contract-test`: all passed. GL test sets nondefault viewport, active texture/binding, linked shader program and real MatrixP, FBO/renderbuffer, blend/depth state, depth range, PBO and pixel packing; validates actual color/depth content and identical state after capture. Driver supplied 32 depth bits for requested DEPTH_COMPONENT24; the test now accepts >=24 and checks actual depth readback. Context destroy/recreate obtains a fresh observer generation and default program/target. No diagnostic GL objects exist to reuse.
- Loader test creates real NSOpenGLContext, invokes its actual flushBuffer and glDrawArrays through dyld injection, and checks emitted loaded/draw evidence. This is offline harness evidence, not evidence of successful game injection.
- Cross-language suite: Java aarch64 writer and C++ x86_64 reader pass leased backpressure and 200 concurrent publications plus all fixture/header/epoch/pair/sequence/size/nonfinite rejection cases.
- Python tool tests: 3/3 passed. Dry-run test uses the compiled loader harness executable to remain independent of whether controller DST is currently running.
- `cd mc && ./gradlew check --console plain`: BUILD SUCCESSFUL; all 10 core contract tests pass. `test` alone reports NO-SOURCE; coreTest is the actual suite registered under check.
- `git diff --check`: passed.
- One broad command accidentally invoked `./gradlew` at repository root after other checks had passed, yielding exit 127; reran from mc, then inspected its build file and ran the actual `check` task successfully. No failing test was suppressed.

## Live preflight observed before controller launch

- Executable SHA-256: `771f9cf6d743152432e9991129cb932107409b5c90c1b76d833af0b957fcaf67`.
- Executable and dylib architecture: x86_64.
- allow-dyld-environment-variables = true; disable-library-validation = true.
- DST process_ids = []; ports 39379/39380 available at that instant.
- Cluster inspected only for lock filenames: `/Users/jay/Documents/Klei/DoNotStarveTogether/434082735/Cluster_1`; no matching lock filenames. Lock status explicitly unknown.
- Initial dylib hash at handoff: `53269f38f5fe7a404435865c9ab4e7ce4740e197588ae2203c427fbff26dae60`.

## Controller handoff

From this implementation worktree:

```
tools/launch_dst.command --out "$PWD/evidence/render-probe"
python3 tools/capture_render_probe.py --seconds 10 --out evidence/render-probe
```

Controller owns launch, world selection, scene composition, save/exit and all desktop UI. Use 960x540 or similar, maximum physical dimensions 1920x1080. Enter ground/tree/creature/UI scene before requesting capture. Launcher runs foreground and redirects game output to launch.log.

Expected evidence: preflight.json, loaded.json, heartbeat.json, launch.log; draws.jsonl; ctx*-f*-d*.json/.rgba/.depth.f32/.png/-depth.png; summary.json and identification.json. Full-resolution samples are capped at 16; current-frame draw metadata capped at 20,000. Fixed-function matrices are not engine-camera proof. Shader matrix values are obtained with glGetActiveUniform/glGetUniformfv from each actual current program.

## Self-review and limitations

- Query/readback code does not bind owned textures/programs/FBOs or allocate persistent GL objects. Pixel pack buffer and all modified packing state restored with RAII. Context registry is retired by both native CGL destruction and NSOpenGLContext dealloc; it retains CPU metadata only.
- Observed calls only cover imported glDrawArrays/glDrawElements plus NSOpenGLContext flushBuffer. Runtime must confirm the game actually traverses these hooks. Unsupported hooks must be reported, not replaced with fabricated scenes.
- Capture classification is intentionally unverified. Uniform names alone do not identify UI vs world. Shader fragment alpha discard is not established by GL_ALPHA_TEST alone; visual alpha-edge and native-depth review remains required.
- Native perspective/depth suitability, actual ground/tree/creature coverage and missing sprite-depth objects are all pending runtime evidence. No depth reconstruction or comparison between MC/DST raw depth values is attempted here. Task 4 owns any supplemental depth pass.
- Synchronous GL readback and JSON logging intentionally impose transient overhead on two diagnostic frames; this is not a performance acceptance test. Fixed-function state queries target this observed OpenGL 2.1 compatibility game and are not advertised as a generic core-profile observer.
- Physical viewports above 1920x1080 are rejected rather than resized or mis-indexed. Original raw data stays bottom-left; PNG previews vertically flip only for viewing.
- Heartbeat currently writes per presented frame; this is lightweight diagnostic IO but may merit throttling before sustained operation.

Commit: recorded in final completion entry below.

## Follow-up safety and Steam launch correction

Self-review exposed two unsafe readback states. Real offscreen FBO tests first failed at `disabled_read_buffer_must_not_issue_readback` and then `multisample_FBO_must_not_issue_readback`. Observer now detects GL_NONE read buffers and multisampled non-default FBOs, records explicit unsupported-state errors, and skips glReadPixels without introducing GL errors. The expanded GL test and native all/reader/loader/contract suite passed again.

First real launch evidence (controller-owned `evidence/render-probe/`): dylib loaded in PID 17680, but DST build 756039 exited in Steam initialization before GL presentation. Controller confirmed Steam client was running and that Steam relaunched the game as PID 17701 without this dylib. Therefore this run proves constructor loading only, not runtime render interception.

The controller requested the documented Steamworks direct-launch fix after confirming installed appmanifest app ID 322330. [Steamworks SteamAPI_RestartAppIfNecessary documentation](https://partner.steamgames.com/doc/api/steam_api#SteamAPI_RestartAppIfNecessary) describes the working-directory steam_appid.txt development hint that prevents automatic Steam relaunch; normal Steam client/license initialization remains in effect. The launcher now creates this hint with O_EXCL only when absent, preserves a matching existing file, rejects mismatches, waits for the child, and removes only an unchanged same-inode owned file afterward. No Steam API hooks, game executable changes or credential handling are used.

RED: real-child tool tests failed because the app-ID hint was absent (child exit 1 vs expected 17) and mismatching hint did not block launch. GREEN: all 7 Python tool tests passed, including child failure cleanup, original file preservation, mismatch refusal before child execution, and retaining a hint changed by the child. Tests use temporary directories and do not touch the installed game hint.

Updated runtime handoff uses fresh `evidence/render-probe-2/`. Current dylib SHA-256 is `9ae083afcf2271ddd31efe2da7342deb7604ace8a54d7e0eed9717c9b230e57b`. Runtime scene capture remains pending.

Collector regression: a skipped unsupported native target was being summarized as generic incomplete color. Added a real metadata/raw-file fixture test; it failed with `disabled_read_buffer does not match incomplete color capture`, then passed after preserving the explicit native error. Python suite now 8/8 GREEN. No native rebuild for this collector-only change.

Controller observed second launch passing Steam initialization into login UI. loaded.json and fresh heartbeat both identify PID 18608; worker independently read heartbeat frame 2603/context 1. This establishes live injected presentation interception, but world draw/depth/alpha evidence remains pending. Controller retained foreground launcher session so owned hint cleanup can run at exit. Dylib has not been rebuilt while game is running.

Self-review watch item sent to controller: child processes may inherit injection environment. Constructor currently writes loaded.json for any injected process; a headless child could overwrite the PID. Collector detects loaded/heartbeat mismatch. Controller to verify identity after hosting; executable gating will be required if observed. No speculative runtime patch has been applied.

## Actual first scene and bounded second-pass implementation

Controller captured `evidence/render-probe-2/`: PID 18608, frames 7497/7498, 788 actual draws, 14 supported captures, plus two explicitly rejected 1700x1700 UI-atlas captures. Controller visually confirmed native ground, Pig King, pigs and HUD. GL viewport was 483x270 while desktop screenshot was approximately twice that raster; this is actual renderer viewport evidence, not assumed Retina sizing. All captured native depth samples were 1.0. Early state-transition quota exhausted before the late scene, so this alone does not establish ground-depth absence.

Draw metadata analysis (first frame): 101–109, target 1/program 85, depth test/write enabled; 110–117 test disabled; 118–134, target 1/program 76, test/write enabled; 135–260, target 1, depth test/write disabled; 261 onward postprocessing; 266 target 0 final composition; 267 onward HUD. Actual world MatrixP on draws 162/163 has index 11=-1, index 15=0, z coefficients -1.0100503 and -2.0100503, confirming perspective (near about 1, far about 200). UI draw 267 has identity MatrixV and orthographic MatrixP index 11=0/index 15=1. This establishes native camera evidence from shader uniforms.

Controller moved to a native deciduous forest with birds for tree/creature coverage, disconnected through UI, observed serialized snapshot 13 and main menu, exited, and confirmed PID 18608 absent. Foreground launcher returned 0 and its owned steam_appid.txt was absent. Rebuild occurred only after this confirmation.

Added repeatable diagnostic selection:
- `--metadata-only --batch forest-map`: all draw metadata plus only before-present images (two full-resolution captures total).
- `--draws N,N,... --batch forest-depth`: one to seven exact observed draw endpoints plus before-present, capped at eight captures per selected frame.
- Repeated requests require no restart; batch directories refuse overwrite and preserve earlier source evidence.

RED: real GL tests failed for missing requested draw 3, accepting eight requested checkpoints, and early-draw capture during metadata-only mode. GREEN after parser/selection implementation. Python tests failed for missing batch copies and wrong serialized checkpoint request; now pass with cap/uniqueness/range enforcement and preserved prior evidence. Suite now 10/10 Python tests.

Added actual linked shader-source SHA-256, aggregate program fingerprint from sorted stage-type/source-hash pairs, source availability and literal discard/FragDepth-token observations. Full shader sources are not stored. Fingerprints are unavailable rather than invented if shaders are detached or GL does not expose sources. Identification groups include fingerprints, actual sample matrices, target/phase and explicit classification uncertainty. A token's presence does not prove branch execution, and GL_ALPHA_TEST is separate from shader discard.

RED fingerprint test failed at missing linked shader sources. Initial exact hash assumption exposed driver normalization: source without trailing newline was returned with trailing newline. Test now supplies a trailing newline explicitly and asserts its independently calculated SHA-256 `cefbc84fea6d2fb8cf35e56cf72316a5a782933e9c2a3fba2d801ec04a82126b`. Expanded native all/gl/reader/loader/contract suites and 10 Python tests GREEN.

v3 handoff binary SHA-256: `08a352b01722235fae4560ca9cc231002336b5f0d1bf9307d7bb28ed98d5a92d`; next launch directory `evidence/render-probe-3/`. New runtime endpoint evidence pending.

## Final runtime diagnostic result — verified

Live extension PID 20074 passed Steam initialization, hooked actual NSOpenGL presentation and actual game draws, and exposed active linked shader sources/matrices. Physical renderer viewport verified at 960x540. All actual evidence remains outside git under evidence/render-probe-3; source hashes replace shader source copies.

The initial moving forest capture had changing draw counts. Its explicit checkpoints did not all hit intended phases, and it is retained without claiming phase-end acceptance. Controller paused the native world through Escape, then took metadata and endpoint samples without intervening UI changes. `forest-paused-depth` returned exit 0, 1446 draw records and 14 captures, zero collection errors; frames 18586 and 18587 have identical verified phase ranges.

| Endpoint | Actual phase | Native depth result |
|---|---|---|
| d267 target2/program85 | early terrain | all1.0 |
| d272 target2/program88 | early overlay | all1.0 |
| d286 target2/program76 | ground-only image, depth-writing pass ended | min0.9632332921,max0.9844031930;4504distinct values |
| d310 target2/program70 | ground/road before sprites | byte-identical to d286 |
| d566 target2/program28 | complete world with trees,crows,avatar; no HUD | byte-identical to d286 and d310 |
| d572 target0/program151 | final world composite | all1.0 |
| d723 target0/program7 | before-present HUD/pause UI | all1.0 |

The exact same-frame d286/d310/d566 native depth SHA-256 in both sampled frames is `09ad91105fb7fedbf5c5c710caf1e7e96678182660b00711a31c0f2084916489`. World sprite draws312..566 have both depth test and depth writes disabled. Controller and worker independently inspected paired color PNGs: d286 shows terrain, d310 adds road/terrain overlays, and d566 adds actual trees, crows and the native avatar. Natural canopy/feather outlines lack rectangular card backgrounds; actual linked world sprite fragment source has a discard token. This establishes native color alpha behavior at the observed silhouettes, while token presence alone does not prove every branch's execution.

Conclusion: native perspective shader matrices and a useful ground-depth attachment are available in the scene FBO. Native tree/crow/player sprite depth is absent in these frames. The final default framebuffer does not preserve scene depth. Task 4 requires an alpha-aware supplemental sprite depth path and must validate its actual silhouette/occlusion effects. Task 2 has not implemented or accepted that future path.

Updated `evidence/render-probe-3/forest-paused-depth/identification.json` is accepted only for diagnostic phase identification, with `depth_compositing_ready=false`, executable/dylib hashes, game build756039, stable source fingerprints, actual matrices, per-group classification confidence/evidence and explicit numeric-ID instability. Unisolated passes remain unverified. Program/FBO IDs must not be reused across restarts; matching must also consider actual projection and phase/target role.

Observed shader fingerprints:
- Ground depth program76: see classified identification profile (full SHA-256).
- World sprite program28: see classified identification profile (full SHA-256).
- Final composite program151: see classified identification profile (full SHA-256).

No further native changes were made after v3 handoff. Supplemental JSON serialization smoke test ran the real injected offline loader and parsed its emitted rows successfully. Final owned-source commit follows below. Remaining limitations: transient diagnostic readback overhead, per-present heartbeat IO, imported-draw hook scope, opaque save-lock status, and no guarantee for unseen game builds/render paths. In this actual hosted session, loaded and heartbeat PID matched after world load; the potential child-process evidence overwrite was not observed.

## Completion

Owned implementation committed as `d376032` (`feat: add macOS DST render diagnostics and isolated launcher`), 12 owned files, 438 insertions. Report and controller evidence are intentionally outside the implementation commit. Git working tree was clean after commit. Full native all/gl/reader/loader/contract suite, Java check/coreTest, 10 Python tool tests and actual injected JSON smoke check passed as detailed above. Actual runtime diagnostics are complete for this observed build/scene; future compositor and supplemental sprite-depth acceptance are explicitly pending Task 4.

Full verified shader fingerprints:
- Ground native-depth shader: `833d35bdce5a6750698019fa17b075405c0915e72b44dea61690ffef1a57bfd4`.
- World sprite shader: `4832ea38aab44e14f22f77a2345a4631960e1b1a340ccfe3a752e0dfa854c063`.
- Final composite shader: `ed33d4a7d595c16b5eeb8f21dfc6e6c23b9f514c2eff4fd51207248decf983fd`.

## Independent review fix round 1 — atomic request publication and context identity

Base: `d376032`. Findings read from `task-2-review-findings.md` and verified against the actual producer/consumer code. The controller explicitly resumed this round and confirmed no DST or Java game processes remained before the native rebuild. No game was launched for this fix.

Changes:
- `publish_request` writes and closes a unique sibling temporary file, then atomically replaces `capture.request`. A partial or failed write leaves the previous public request intact; temporary files are cleaned up. Native polling sees only the previous complete request or the new complete request.
- Native parsing accepts exactly `default`, `metadata`, or `checkpoints` with one through seven distinct decimal draw numbers in 1..20000. Empty/whitespace-only input, unknown modes, trailing arguments for no-argument modes, missing/invalid checkpoint values and out-of-range requests are rejected without arming sampling. Invalid input cancels pending selected frames and leaves a diagnostic error record.
- Capture summaries retain context_id; persistent draw selection matches `(context_id, frame_no)` rather than frame_no alone.
- Expanded GL state inspection, active matrix/source inspection, serialization, readback/packing restoration, request parsing and presentation blocks into readable functions and statements. Their GL behavior/order and JSON field contract remain unchanged outside request validation.
- Loader harness's historical undocumented `1` request was replaced with documented `default`, so the real native injection integration test also exercises strict-mode compatibility. Native startup hooks were not changed.

RED commands/results:

```
python3 -m unittest discover -s native/tests -p '*_test.py' -v
Ran 13 tests; FAILED (failures=3).
```

Exact failures: cross-context draw selection included context1/frame7 while only context2/frame7 was captured; failed request writes left public content `che` instead of the prior complete `metadata\n`; a renderer reading between real filesystem writes observed `checkpoi` and then the new request before publication instead of the previous complete `default\n`. The deterministic writer adapters perform actual filesystem writes/flushes and only control when the consumer observes the public path; assertions check real file content and cleanup, not mock-call counts.

```
make -C native gl-test
FAIL malformed request rejected=0 captured=1 payload=[]
FAIL malformed request rejected=0 captured=1 payload=[  ...]
FAIL malformed request rejected=0 captured=1 payload=[unknown...]
FAIL malformed request rejected=0 captured=1 payload=[default trailing...]
FAIL malformed request rejected=0 captured=1 payload=[metadata trailing...]
Assertion failed: empty_unknown_or_malformed_requests_must_not_sample
make exit 2
```

The real CGL test submits the malformed request files, advances presentation/draw boundaries, and checks both error records and absence of that context/frame's capture. Existing cap, exact checkpoint, metadata-only, source-fingerprint and GL-state restoration assertions remain active.

GREEN focused iterations:
- `python3 -m unittest discover -s native/tests -p '*_test.py' -v` → 13/13 OK after atomic publication and context/frame selection.
- `make -C native gl-test` → PASS after strict parsing and readability refactor.

Final covering command:

```
make -C native all gl-test loader-test && python3 -m unittest discover -s native/tests -p '*_test.py' -v && git diff --check
```

Exit 0. Native output: `PASS gl_state_restored shader_matrices actual_color_depth context_recreated strict_request_modes bounded_checkpoints metadata_only`; `PASS isolated_loader actual_NSOpenGL_present imported_draw_hook`. Python: `Ran 13 tests ... OK`. No compiler warnings or whitespace errors. No unrelated Java suites rerun.

Additional covering serialization check: ran the real offline DYLD-injected loader in a temporary directory, parsed every emitted draw/capture JSON record with Python json.loads and checked context/source fields → `PASS real injected JSON serialization: 1 draws, 1 captures`.

Self-review: the request file remains a single outstanding-request mechanism; this change does not introduce a concurrent multi-producer queue. Same-directory os.replace gives publication atomicity, not crash-durable journaling. Parser failures cannot silently fall back to default captures. The original accepted forest endpoint evidence and its original binary hash were not modified. New dylib SHA-256 is `db08a392edbb700d4df24f027104be2c1f2c039148355848b7feb10ebb40f764`; this binary has covering offline validation only, not a new live-game acceptance claim. Sprite-depth supplementation remains Task 4.

Round 1 commit: `cc2900cac488cb0c7deb3f081dfb20fea42d4a73` (`fix: publish render probe requests atomically and retain context identity`). Five owned implementation/test files committed; working tree clean afterward. Review report/evidence remain outside git as before.
