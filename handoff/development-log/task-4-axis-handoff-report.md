# Task 4 axis WIP handoff — stopped on controller request

Date: 2026-10-22 Asia/Shanghai. Repository/worktree: `/Users/jay/Documents/Codex/2026-10-20/https-mp-weixin-qq-com-s/work/dst-mc-bridge/.worktrees/implementation`.
Base and current HEAD: `676d46ac8fdc8417f98b002e5095f417f4157aa5`.
Worker made **no commits**. Product changes and tests remain uncommitted WIP. Controller owns final WIP commit, push, user-facing handoff and directory cleanup. On the stop instruction this worker performed only a status/HEAD/diff-stat read and wrote this report; no further builds/tests/product edits.

## Current implementation scope

- Java `WorldTransform` has immutable `IDENTITY` / `REFLECT_X` modes, fixed origins, position and direction helpers. The old two-origin constructor remains identity; returned axes are defensive arrays.
- `PairingStore` writes private DSP3 records with both origins and mode, reads DSP2 as identity, rejects a requested mismatching mode without rewriting. Existing stable lock inode / forced atomic write behavior retained.
- Production `WorldExchange` creates REFLECT_X DMB3 records with both origins and mode; DMB2 decodes identity, then handshake returns `TRANSFORM_MISMATCH` before activation. A legacy valid identity record does not crash world loading solely because its mode is identity. Malformed versions/modes/origins/trailing bytes reject. Existing single server-thread ownership and forced atomic write behavior retained.
- `FrameLayout` disallows changing transform within one mapping. Existing binary offsets, three slots and identity golden fixture unchanged.
- `BridgeServer` status now includes nullable `dst_origin`, `mc_origin`, `axes`, non-null for active binding even before a frame exists. Existing HTTP error envelope exposes the handshake mismatch reason.
- Native frame reader supports exactly identity / diag(-1,1,1). Shared `WorldTransform` helpers convert camera position, directions and column-major view (`V_DST = V_MC * [S, mcOrigin - S*dstOrigin]`). Actual camera matching retains original matrix/ray/viewport tolerances.
- Native status decoder rejects absent, nonnumeric, boolean, nonfinite, wrong-length or unsupported axis/origin metadata. Discovery compares active binding with newly mapped and cached frame metadata; failure releases frame and clears window proof. Camera service rejects same-session transform changes. TTL/lease/window proof identities otherwise retained.
- Inverse-projection depth shader remains unchanged: after the strict transformed-view check, both inverse projections reconstruct the same camera-space basis. No image flip, renderer profile change, endpoint sign hack, or general affine matrix support.
- Protocol text and strict JSON schema updated for both supported bases and required status binding metadata. Old status producers without these fields intentionally fail closed. Matching Java/native versions are required.
- Dedicated shared-writer Java test entry now returns after the writer mode instead of accidentally running unrelated client suites from native cwd. This fixes a pre-existing test harness failure observed below; it does not change production behavior.

## Uncommitted files at stop

Worker-owned modified tracked files:

- `mc/src/contractTest/java/dev/jay/dstmc/ContractTests.java`
- `mc/src/contractTest/java/dev/jay/dstmc/protocol/ProtocolContractTest.java`
- `mc/src/contractTest/java/dev/jay/dstmc/server/WorldExchangeTest.java`
- `mc/src/main/java/dev/jay/dstmc/protocol/FrameLayout.java`
- `mc/src/main/java/dev/jay/dstmc/protocol/PairingStore.java`
- `mc/src/main/java/dev/jay/dstmc/protocol/WorldTransform.java`
- `mc/src/main/java/dev/jay/dstmc/server/BridgeServer.java`
- `mc/src/main/java/dev/jay/dstmc/server/WorldExchange.java`
- `native/Makefile`
- `native/include/camera_service.h`
- `native/include/frame_protocol.h`
- `native/src/camera_http.mm`
- `native/src/camera_service.cpp`
- `native/src/compositor.mm`
- `native/tests/compositor_test.mm`
- `native/tests/frame_contract_test.cpp`
- `native/tests/lease_test.cpp`
- `protocol/frame-v2.md`
- `protocol/http-v2.schema.json`
- `tests/test_first_person_gate.py` (existing isolated HTTP fixture status now supplies transform fields; its listener test was NOT run)

Worker-owned untracked files:

- `native/tests/transform_status_test.mm`
- `tests/test_axis_contract.py`
- this report (the `.superpowers` area may be ignored by Git)

Controller-owned modifications visible in status, not edited or reverted by worker:

- `docs/steam-start.md`
- `docs/superpowers/plans/2026-10-21-dst-mc-first-person.md`
- `docs/superpowers/specs/2026-10-21-dst-mc-first-person-design.md`

The final status read showed 23 modified tracked files and the two untracked test files above. Tracked diff-stat was 369 insertions / 61 deletions, including controller changes; it excludes untracked files. Do not use an indiscriminate restore/reset to separate ownership.

## Actual commands and results already observed

Commands below are historical results, not new verification performed after stop. `ROOT` in descriptions means the worktree above; native commands used `ROOT/native`, Java wrapper commands used ROOT or `ROOT/mc` as stated. All native outputs were directed to `/tmp/dstmc-axis-native.6kxghW`; no native build targeted repository `native/build`.

### Behavioral RED

1. From `mc`: `./gradlew exchangeTest --console plain` after adding production reflection / legacy rejection tests: exit 1, two expected failed assertions:
   - `production_reflection_persists`: `production +X must reflect about saved origins`.
   - `legacy_production_binding_rejected_without_mutation`: `legacy identity binding activated for reflected stage`.
   Existing exchange tests passed.
2. Compiled lease and compositor tests with `make BUILD=/tmp/dstmc-axis-native.6kxghW /tmp/dstmc-axis-native.6kxghW/lease_test /tmp/dstmc-axis-native.6kxghW/compositor_test` (native cwd): compile exit 0. Running each then aborted with assertion/exit 134:
   - lease: `reflected_position_about_nonzero_origins`.
   - compositor: `matching_reflected_view_accepted`.
3. `mc/gradlew -p mc coreTest --console plain` after adding mapping immutability test: exit 1; `mapping_rejects_transform_changes_within_epoch` failed with `same mapping published changed calibration`; other protocol assertions passed.
4. `uv run --with jsonschema python -m unittest tests.test_axis_contract -v` against old schema: exit 1, two tests ran. `test_only_two_calibrated_bases` failed because unsupported axes were accepted. `test_paired_transform_required_even_before_stream` raised the schema ValidationError that `axes`, `dst_origin`, `mc_origin` were unexpected additional properties. This was a semantic rejection by the old schema, not a runtime product failure.

### Final GREEN observations before stop

1. `mc/gradlew -p mc check --console plain`: last run exit 0, `BUILD SUCCESSFUL in 4s`; compileJava/compileClientJava up-to-date after prior successful recompilation; contract classes recompiled. All 28 Java named assertions passed:
   - coordinate_roundtrip
   - restart_keeps_origin
   - reflected_pair_store_and_direction_roundtrip
   - legacy_pair_record_stays_identity
   - malformed_pair_records_fail_closed
   - foreign_epoch_rejected
   - receipt_is_not_application
   - applied_survives_restart
   - exclusive_ledger_owner
   - reused_id_and_terminal_mutation_rejected
   - mutable_number_snapshot_matches_receipt
   - exact_finite_json_numbers_preserved
   - reflected_shared_frame_metadata
   - mapping_rejects_transform_changes_within_epoch
   - java_exports_binary_frame
   - leased_slot_not_overwritten
   - partial_readback_not_published
   - resize_discards_pending_readback
   - alpha_and_channel_order
   - http_uint64_requires_exact_lua_integer
   - fixture_requires_property_and_exact_save
   - world_identity_persisted
   - pairing_keeps_original_anchor
   - different_dst_world_rejected
   - production_reflection_persists
   - legacy_production_binding_rejected_without_mutation
   - malformed_world_binding_rejected_without_mutation
   - fixture_startup_dual_guard_and_backup_order
   The publisher test also printed native RGBA/depth/HUD channels verified and intentionally `contract rejected: 7` for its red/blue negative control; Java asserted that expected exit. Gradle printed pre-existing deprecated-features / Gradle 10 compatibility warnings. `test` has NO-SOURCE; real checks are `coreTest` via `check`.
2. Native compile command (native cwd):
   `make BUILD=/tmp/dstmc-axis-native.6kxghW all /tmp/dstmc-axis-native.6kxghW/transform_status_test /tmp/dstmc-axis-native.6kxghW/compositor_test /tmp/dstmc-axis-native.6kxghW/frame_reader_test /tmp/dstmc-axis-native.6kxghW/gl_state_test`
   Exit 0. Compiler used x86_64 C++17, `-Wall -Wextra -Werror -O2`, Cocoa/OpenGL for Objective-C++.
   Later final test-only additions were compiled with:
   `make -C native BUILD=/tmp/dstmc-axis-native.6kxghW /tmp/dstmc-axis-native.6kxghW/lease_test /tmp/dstmc-axis-native.6kxghW/transform_status_test`
   Exit 0.
3. `/tmp/dstmc-axis-native.6kxghW/lease_test`: final exit 0:
   `PASS window_proof_current_identity_only missing_and_expired_proof_rejected`
   `PASS reflected_lease_and_transform_mismatch`
   `PASS lease_pins_matching_pose late_camera_ack_rejected stale_frame_releases_camera retina_resize_cancels_lease release_invalidates_old_callbacks`
   Includes nonzero-origin position/directions, rotated column-major view, same-session changed transform invalidation.
4. `/tmp/dstmc-axis-native.6kxghW/transform_status_test`: final exit 0:
   `PASS strict_status_transform_and_cached_binding_invalidation`
   Includes missing/invalid axes, booleans/string/nonfinite/shear/unsupported bases, malformed origins and clearing cached lease/ack readiness. This executable calls pure parsing/service code and does not start an HTTP listener.
5. `/tmp/dstmc-axis-native.6kxghW/compositor_test`: exit 0:
   `PASS measured_native_reflection_and_origins_match`
   `PASS transparent_pixel_preserves_host closer_surface_wins ui_state_restored reflected_view_rejected expired_compose_skipped sprite_discard_preserves_hole_depth`
   Literal measured frames 8947/8948 MatrixV and projection are fixtures only. Offscreen GL tests also accepted matching reflected view and rejected identity view for reflected binding.
6. `/tmp/dstmc-axis-native.6kxghW/frame_reader_test` (native cwd): exit 0:
   `PASS scoped_frame_consumer rejects_wrong_key releases_lease`.
7. `/tmp/dstmc-axis-native.6kxghW/gl_state_test`: exit 0; `observed depth bits=32`; then
   `PASS gl_state_restored shader_matrices actual_color_depth context_recreated strict_request_modes bounded_checkpoints metadata_only`.
8. `DSTMC_JAVA=/Library/Java/JavaVirtualMachines/liberica-jdk-21-full.jdk/Contents/Home/bin/java /tmp/dstmc-axis-native.6kxghW/frame_contract_test ../protocol/fixtures/frame-v2.bin` (native cwd): final exit 0. ARM64 Java shared writer reported leased-slot backpressure plus 200 concurrent publications. All native assertions passed: java_fixture_is_readable, reflected_frame_is_readable, unsupported_reflection_rejected, scaled_axes_rejected, nan_axes_rejected, sheared_axes_rejected, truncated_file_rejected, odd_sequence_rejected, oversize_rejected, nan_matrix_rejected, layer_offset_rejected, foreign_epoch_rejected, foreign_pair_rejected, writer_lease_rejected, oversize_stride_rejected, mapped_atomic_publication_and_leases. Final line `C++ x86_64 mapped Java fixture: PASS`.
   An earlier run of this same command failed AFTER the shared writer succeeded: the existing Java ContractTests entry continued into client suites, producing three `NoClassDefFoundError: dev/jay/dstmc/client/FramePublisher` cases and missing `src/contractTest/cpp/publisher_rgba_reader.cpp` from native cwd, then `ARM64 Java writer failed`. Controller approved the minimal dedicated-mode early-return; final complete run above passed. The first writer-only success was never treated as full-test success.
9. `uv run --offline --with jsonschema python -m unittest tests.test_axis_contract -v`: exit 0, 2 tests OK after schema update.
10. `DSTMC_TEST_NATIVE_BUILD=/tmp/dstmc-axis-native.6kxghW uv run --with jsonschema --with lupa python -m unittest tests.test_axis_contract tests.test_first_person_gate.NativeGateTests tests.test_first_person_gate.WindowActivationTests tests.test_first_person_gate.LuaCameraTests tests.test_first_person_gate.LuaConnectionTests tests.test_live_frames.LiveSampleEvaluation tests.test_test_copy -v`: exit 0, **18 tests in 1.646s, OK**, no skips. Schema 2, native gates 2, window activation 1, Lua camera 6, Lua connection 1, sampling metric 3, temp save-copy 3. All copy/lock fixtures used temporary fake saves, not real game saves.
11. `git diff --check`: exit 0, no output at last pre-stop check.

### Setup/command failures (not hidden)

- Twice attempted `./gradlew ...` from repository root, where the wrapper is under `mc/`; shell exit 127 `no such file or directory: ./gradlew`. Corrected to `mc/gradlew -p mc ...` or mc cwd.
- System Python and bundled workspace Python lacked `jsonschema` (ModuleNotFoundError). Initial uv dependency download retried; an attempted offline run before downloads finished failed for unavailable package cache. The original online uv run eventually installed dependencies and produced the schema RED above; subsequent offline schema run passed. Lupa installation similarly retried, then installed and the 18-test run passed.
- A diagnostic `ls -d .venv* ...` hit zsh `no matches found`; no filesystem mutation resulted.

## Artifact identities already measured before stop

Temporary native directory: `/tmp/dstmc-axis-native.6kxghW`.
Temporary dylib: `/tmp/dstmc-axis-native.6kxghW/libdstmc_probe.dylib`.
SHA-256: `5fb38399c52eae3189957cae33b41cdd3ae0c6091941b766487471792d8bd2e0`.
Temporary executables include lease_test, transform_status_test, compositor_test, frame_reader_test, gl_state_test, frame_contract_test. The final lease/status test-only edits rebuilt their executables after dylib hashing; production sources did not change afterward.

Repository `native/build/libdstmc_probe.dylib` remained SHA-256 `8079000eb6e56fa915e91fe1d5c6ae465e5eeaf494b1efced3480f0c2737a77d` at the last read. It was never rebuilt/replaced by this worker. This is the controller-reported loaded library for Steam DST PID22823; the worker did not operate or independently inspect the game process.

Identity golden `protocol/fixtures/frame-v2.bin` SHA-256 remained `54b0d06af56abd1d06962e0afc8d944f57c5d6b80fcbafe73e914eb22c3e7205`; Java core tests regenerated identical bytes (no Git diff).

Temporary cross-process mapping directories now use `/tmp/dstmc-axis-shared-XXXXXX`, instead of writing test mappings under native/build; tests remove their own mappings on completion. No deployment artifacts were copied into user game/mod/save locations.

## Known remaining issue and risks

1. **Unfixed existing Lua handshake origin mismatch:** `dst-mod/scripts/dstmc/connection.lua:39` sends `mc_origin={x=.5,y=64,z=.5}`, while existing production WorldExchange accepts only `(0,64,0)`. This can reject the real integration handshake independently of the axis fix. Worker reported evidence; controller explicitly instructed not to fix it after user requested handoff. No Lua files were changed.
2. No independent review has occurred. Self-inspection covered ownership, math, persistence, schema and fail-closed paths, but this WIP must still receive an independent code review before any real refresh.
3. No real deployment/reload/native replacement/MC launch/live handshake/real graphics acceptance was performed. All five Task4 graphics gate items remain **NOT_VERIFIED**. Actual shoreline/water evidence does not establish ground depth or final acceptance.
4. HTTP listener integration fixture (`NativeHttpTests`) was deliberately not run: it hardcodes real ports39379/39380 and real DST occupies39380. Pure native parser/service tests and schema tests do not replace live HTTP integration coverage. Full Python discovery was not run because it includes those listeners and LiveFrames game access. Gradle full `check` was run.
5. New native discovery intentionally rejects old status producers without origins/axes; old Java/native mixes are not compatible for first-person use. Persistence legacy identity records stay intact and cannot silently activate reflection; no migration tool implemented.
6. Native transformed-frame metadata is required to agree with status; unsupported transforms and failed discovery clear cached readiness/proof. Real rendering, ray alignment away from the recorded calibration, ground/tree/creature/UI occlusion and runtime performance still require controller-owned live verification.
7. No AABB transform existed in the implemented consumers; none was added. No Task5–8 work or renderer build-fingerprint/profile weakening was done.

## Explicitly not done

- No Lua origin correction; no further product/test code change after stop.
- No commit, push, branch cleanup, worktree archival, directory clearing, or removal of temporary native outputs by worker.
- No final task-4-axis-report.md completion report; this handoff report supersedes that deliverable because the work stopped as WIP.
- No subagents spawned.
- No real ports used or HTTP game endpoint called by worker.
- No game/Steam/UI control, process kill, game client launch, mod/jar deployment or native extension reload.
- No original `/Users/jay/Downloads/.minecraft/saves/DST-MC-Test` writes, final copy writes, or real test-world creation.
- No actual graphics-gate item promoted to verified.
