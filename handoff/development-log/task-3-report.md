# Task 3 report — resumed implementation, 2026-10-22

Status: DONE. Final source build, fresh-process live capture, self-review, and final save checks passed. Commit:1900a29ed25231c61dcc701ed654d3eb220d160d (`feat: stream real Minecraft world and HUD frames with matched poses`). Tracked worktree is clean.
Base: f1f0fdd60976f88ce98659bf5c59d6c241721113. Branch: codex/dst-mc-first-person.

## Scope and implementation

Preserved and finished the interrupted Task3 changes; did not restart Tasks1/2 or modify native/DST/prototype sources. MC Loom1.14.10, Minecraft1.21.11, Fabric Loader0.19.5, Fabric API0.141.6+1.21.11, JDK21 are pinned. Split client source set is included in contract tests. Dev launch uses installed assets/index29, not copied assets; `-x downloadAssets` avoids redundant Loom downloads.

- Main/client entrypoints, stage dimension, server-thread initial invisible barrier plane/real stone, player positioning, loopback v2 handshake/status/empty heartbeat exchange.
- WorldExchange persists one MC UUID and first DST binding/origin per copied save; rejects another world/shard/dimension/region/origin and preserves first transform across restarts. Requires prepared-copy provenance before server startup.
- Status strict schema now exposes UNPAIRED/PAIRED, persistent MC UUID, PID/run UUID/start time/heartbeat, exact latest FrameKey and unique mapped-file path/generation/physical dimensions. All runtime uint64 JSON fields are explicitly checked in0..2^53-1; binary ABI unchanged.
- FrameCapture uses current GlTexture IDs, synchronous completed GPU glReadPixels before the hand depth clear, then clears color for HUD layering; captures after real GUI draw. Restores read framebuffer/pixel-pack state. Uses actual LevelRenderer projection and full `rotation * translate(-eye)` view, disables cosmetic camera distortion, skips sky/cloud background.
- FramePublisher stages same-generation complete world/depth/HUD, snapshots buffers, skips all-leased mappings, discards resize/context-generation leftovers, uses unique files across resize/rehandshake. OpenGL bottom-left rows, premultiplied RGBA; transparent RGB normalized to zero.
- Copy utility holds compatible POSIX record lock during complete copy, rejects active Java FileChannel owner/existing destination/symlinks, leaves source bytes unchanged, omits lock/old bridge identities and records provenance.
- Live acceptance uses a generated test-only x86_64 reader with the existing native `read_frame` exact-key RAII lease. It checks fresh PID/start/run, schema, matched pose, stone texture/depth/alpha/HUD, real stone-removal difference, and60seconds of new frame/heartbeat sampling. No old-file fallback.

Interfaces: `FrameCapture.captureWorld(Pose)` / `captureHud()`, `FramePublisher.publishCompleted(): Optional<FrameKey>`, `WorldExchange.handshake(UUID,String,Vec3): HandshakeResult` and strict-input overload. `BridgeMod.server` publishes current server; `BridgeServer.active()/framesDirectory()/updateStream()/invalidateStream()` are the render-thread handoff. `/v2/exchange` accepts only empty commands/damage in Task3; nonempty streams explicitly reject pending Task5.

## Diagnosed fixture isolation and startup issues

The initial run was blocked by accessibility onboarding (confirmed in pinned Minecraft.addInitialScreens/Options source). Only owned `mc/run/options.txt` was backed up to `evidence/task3-resume/options-before.txt` and changed to onboardAccessibility:false with the client stopped. Original `.minecraft/options.txt` was not touched.

During PID8448, logs show a different save selected, camera movement, exit, and deletion of both test copies through the game UI. The author of those actions was not established by this worker. The original property-only fixture marker erroneously let the live test bind that selected final-copy instance to a mock DST world. That old sample is INVALID acceptance evidence. Its last offline-diagnostic pose was(-7.3854,65.62,4.1546), looking upward; blank capture was not a proven render-hook fault. Logs remain in `client-onboarding-fixed.log`. Original44-file SHA256 manifest remained identical. After that process had exited and both destinations were absent, both independent copies were recreated through the locked copy utility. The final intended copy is again unopened/unpaired and has no bridge identity/session.lock.

Regression fix: fixture VM property AND exact actual save basename `DST-MC-Frame-Fixture` are mandatory. A different save under that dev launch throws FIXTURE_SAVE_MISMATCH before identity/HTTP creation. Focused regression first failed on DST-MC-FirstPerson-Test, then passed.

In a subsequent exclusive run, read-only screen diagnostics confirmed BackupConfirmScreen with the experimental-world warning. Controller authorized a narrowly scoped in-engine fixture loader. `FixtureStartup` + `FixtureWorldLoadMixin` enter only the source-confirmed `WorldOpenFlows.askForBackup` gate, require the dev property AND exact current level ID, perform official `makeWorldBackup()` successfully, then invoke the supplied official world-load continuation. No desktop clicks, keyboard/mouse injection, general screen bypass, or normal-save bypass. Guards, backup-before-continuation order, and fail-closed backup exceptions are tested. This is only a dev fixture loader and does not validate future Task4 real input routing.

## Tests and honest RED/GREEN evidence

Previous worker's reported publisher/copy RED/GREEN history was inherited narrative only; this worker did not recreate or claim missing historic logs. Freshly executed:

1. `python3 -m unittest tests.test_test_copy -v`:3/3 PASS, actual separate Java FileChannel lock holder.
2. `JAVA_HOME=/Library/Java/JavaVirtualMachines/liberica-jdk-21-full.jdk/Contents/Home ./gradlew build coreTest --console plain` from mc: final20/20 PASS, build successful. `evidence/task3-resume/build-final.log`.
3. Fresh guard RED: `./gradlew exchangeTest --console plain`, fixture property accepted wrong save, then GREEN in full build. `fixture-guard-red.log`.
4. Fresh startup RED: `./gradlew coreTest --console plain`, fixture not continued, then GREEN. `startup-red.log`.
5. Fresh HTTP number RED: `./gradlew exchangeTest --console plain`, unsafe negative accepted; final tests cover negative,2^53,Long.MAX_VALUE rejection and0/2^53-1 acceptance. `http-integer-red.log`.
6. Initial live test correctly failed before world entry (connection refused), then wrong-save/moved-camera sample failed no opaque pixels. Neither used as acceptance. `live-first.log`, `live-onboarding-fixed.log`.
7. `DSTMC_EXPECT_PID=9369 DSTMC_LAUNCH_AFTER_MS=$(cat evidence/task3-resume/launch-after-ms) evidence/task3-resume/venv/bin/python3 -m unittest tests.test_live_frames -v`: PASS68.077s,38.195 FPS,19.99984Hz heartbeat,119 samples over60second loop. This preceded the final general HTTP integer guard; final exact code was rebuilt and a fresh process passed below.

The test-local venv installs jsonschema4.25.1; no global Python packages were changed. Build has existing Gradle deprecation notice; offline Fabric dev username produces expected Realms authentication warnings. No game process was running during any build. Each terminated PID was verified as the owned dev client immediately before normal SIGTERM; sessions were awaited. No other user process was terminated.

## Self-review / boundaries

Checked source save identity, instance guards, actual render hook positions against1.21.11 source, actual camera matrices versus nominal FOV, RGBA byte order, readback completion/generation ownership, mmap lease backpressure, strict status fields, original anchor persistence, game-thread operations, loopback-only binding, and exact Lua integer bound. `git diff --check` clean. No native or DST source edits. Full window resize/context-loss scenarios are covered by publisher generation contracts, not claimed as real desktop resize acceptance. Task4 fusion, transparent native window/input behavior, sprite depth, and real DST pairing remain intentionally outside Task3.

Evidence directories are ignored local runtime artifacts; full assets/accounts/save contents are not committed. Core source and tests are committed; this report is kept in controller's ignored SDD directory.

## Final exact-code live acceptance and exit

Final build included the unified HTTP integer guard and passed20 checks. New actual ARM64 Minecraft PID10016, run ID `ac039e0a-3eb8-4fff-83b9-6c64be46fbe5`, started_at_ms1792653296449, persistent fixture MC UUID `e8970f48-129e-4a2c-ae36-0c9021c56f38`. Actual command line was checked for dev property, this worktree's launch config, and `--quickPlaySingleplayer DST-MC-Frame-Fixture`. Active save was `mc/run/saves/DST-MC-Frame-Fixture`; guarded official backup was `mc/run/backups/2026-10-22_15-14-56_DST-MC-Frame-Fixture.zip` (2,451,168 bytes). No mock identity was put in the recreated final copy.

Exact final test command from worktree root:

```
DSTMC_EXPECT_PID=10016 DSTMC_LAUNCH_AFTER_MS=$(cat evidence/task3-resume/launch-after-ms) evidence/task3-resume/venv/bin/python3 -m unittest tests.test_live_frames -v
```

PASS68.893s (`evidence/task3-resume/live-final-integers.log`). A second60second sample was already in progress before controller said the older performance sample need not repeat; it completed successfully:51.07749 FPS,19.99558Hz server heartbeat,119 samples, frames471→3521. Physical1920×1080 from requested960×540 logical window; these are deliberately distinguished. Final raw frame has69,238 fully opaque stone pixels,2,003,094 alpha-zero background pixels,81 opaque texture RGB colors,70,506 valid world-depth pixels (minimum0.9802932143, background1.0),64,720 HUD alpha pixels. World/HUD both passed premultiplied RGB<=alpha and zero-background checks. Real stone removal eliminated the block pixels. Eye(.5,65.62,.5), actual forward(-.0580451,-.263873,.962809) were captured with the same frame; camera stays in the expected fixture vicinity and looks toward the stone. Native reader is a verified Mach-O x86_64 executable reading the ARM64 producer's leased mapping.

Final evidence under `evidence/task3-live-ac039e0a-3eb8-4fff-83b9-6c64be46fbe5/`:
- `result.json`: complete status/key/mapping generation and continuous samples.
- `stone.raw`, `removed-stone.raw`: exact native-leased world/depth/HUD bytes.
- `stone-world.png`, `stone-hud.png`, `removed-stone-world.png`, `removed-stone-hud.png`: actual captured PNGs, not synthesized geometry or desktop screenshots.
- `stone-pose.json`, `removed-stone-pose.json`, `pixel-summary.json`: matched pose and numeric pixel/depth evidence.
- `read-frame.cpp`, `read-frame`: test-only native reader and executable.

After success, verified PID10016's current command, sent normal SIGTERM, awaited runClient session exit, and confirmed PID absent. Gradle runClient reports exit1 because its child was intentionally terminated; this is not a build/live-test failure. No rebuild followed the live run. Final `evidence/task3-resume/final-save-verification.json` confirms all44 original-save SHA256 values unchanged, recreated final copy exists with no bridge identity and no session.lock, and PID10016 exited. Source-before manifest, logs, backup, wrong-save diagnostic evidence and passing fresh evidence remain available locally.

No blocking concerns. Synchronous readback is intentionally simple and met30FPS capture target here; it is not a claim about native fused performance. Actual OS window resizing, native transparency/input, actor/terrain/damage integration and real DST-world pairing remain for later tasks. Expected dev Realms/GL shader warnings and Gradle deprecation are recorded in logs.

## Review follow-up round1 — tests only

Core Task3 review was Approved; two minor test-coverage follow-ups are now completed. Production capture/server/protocol code and build configuration are unchanged, and no game was launched or60second sample repeated.

1. `FramePublisherTest.alpha_and_channel_order` now publishes an already-premultiplied half-alpha red pixel through actual ARM64 `FramePublisher.world/hud/publishCompleted`: worldRGBA(128,0,0,128), depthfloat32.25, HUDRGBA(0,0,64,64). It compiles `mc/src/contractTest/cpp/publisher_rgba_reader.cpp` explicitly forx86_64 and launches under `/usr/bin/arch -x86_64`. The helper uses the real existing `dstmc::read_frame` exact key + RAII slot lease and asserts allRGBA channels, depth, HUD and dimensions. The helper has an architecture compile guard. It does not duplicate the binary parser or call the conversion helper. A second deliberately red/blue-swapped actual publication is required to be rejected with code7, proving the assertions detect the channel failure; this expected negative-control rejection is not a failed test.
2. `evaluate_samples` is shared by the live test and focused offline checks. The live acceptance now requires capture>=30FPS and heartbeat19–21Hz instead of merely100new frames. Focused tests accept threshold/jitter boundaries and reject29FPS,18Hz and22Hz. New result records include heartbeat_hz. The evaluator was run directly on the existing final119 samples, yielding PASS51.07748898FPS /19.99558093Hz; no reclassification of a new run is claimed.

Executed covering checks only:
- From mc: `JAVA_HOME=/Library/Java/JavaVirtualMachines/liberica-jdk-21-full.jdk/Contents/Home ./gradlew publisherTest --console plain` —4/4 PASS, build successful. Log:`evidence/task3-resume/fix1-publisher.log`.
- `python3 -m unittest tests.test_live_frames.LiveSampleEvaluation -v` —3/3 PASS.
- Imported `evaluate_samples` and evaluated `evidence/task3-live-ac039e0a-3eb8-4fff-83b9-6c64be46fbe5/result.json`119 samples — PASS above.
- `git diff --check` — clean.

Self-review checked reader lease lifetime before unmapping, exact-key hash/epoch/id passing, independent expected world/depth/HUD values, already-premultiplied bytes avoiding double multiplication, x86_64 enforcement, sensible cadence thresholds, and no production/source-save modifications. Gradle deprecation stays parked as third-party maintenance per review. No blocking concerns. Follow-up commit recorded below.

Follow-up commit:`1369dd1e46f332451ad1ac550d11fc3d2fd35647` (`test: verify cross-architecture RGBA publication and capture cadence`). Tracked worktree clean.
