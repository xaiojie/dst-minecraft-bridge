# Task 1 implementation report

Status: DONE_WITH_CONCERNS (bounded lifecycle/validation limits below, no blocking test failures).

Commit: `0e8ac4b9d7aaa10ac84e15517b8de83b47426612` — `feat: add versioned bridge protocol and persistent world pairing`.

Worktree: `/Users/jay/Documents/Codex/2026-10-20/https-mp-weixin-qq-com-s/work/dst-mc-bridge/.worktrees/implementation`.

Only the task brief was used as implementation requirements; the whole plan was not read. No subagents/reviewers, games, original saves, or external game installs were used. The old probe's wrapper files and checked version references were the only copied old implementation material. The controller owns progress/docs. This ignored `.superpowers` report is intentionally not included in the implementation commit.

## Delivered behavior and interfaces

- Shared nested records/enums in `BridgeTypes`: Vec3, half-open Box, Cell, PairKey, Space, Pose, FrameKey, FrameLease, Body, BlockChange, TerrainCell, ActorSnapshot, Command, CommandResult/Status, DamageEvent. Pose matrices and command container payloads are copied; non-finite vectors/matrices and invalid JSON values are rejected.
- `WorldTransform.toMc(Vec3)` / `toDst(Vec3)` with fixed pair origins, one-unit scale and identity axes; golden `(106.5,2,-47)` -> `(6.5,66,3)` and inverse.
- `PairingStore(Path).loadOrCreate(pair,dstOrigin,mcOrigin)` with pair-hash file identity, fixed origins after restart, stable creation lock and forced atomic replacement. Bad storage fails closed.
- `RequestLedger(Path,pair,epoch)` validates foreign identity before mutation; receive returns durable PENDING, duplicate IDs do not schedule twice, conflicting parameters reject, game-thread finish persists terminal outcomes, and restart converts outstanding PENDING to durable UNRESOLVED without replay.
- Additive scheduling/lifecycle interface, approved by controller: `pollPending(): Optional<Command>` and `AutoCloseable.close()`. The directory/pair has one exclusive live file-lock owner. Close the previous owner before reopening. An unknown/foreign command cannot be finished; terminal outcomes are immutable. Explicit reconciliation may finish UNRESOLVED.
- `FrameLayout.create(Path,int,int)` / synchronized `publish(FrameKey,WorldTransform,Pose,int,int,ByteBuffer,ByteBuffer,ByteBuffer)` / `close()`. New paths only; fixed 4096-byte header, 3 slots, 512-byte slot headers, capacity-specific aligned stride bounded by 1920x1080. Odd/even commits and shared 64-bit lease CAS protect publication and zero-copy readers. False publication means all slots are leased and does not consume frame ID.
- C++ `read_frame(const void*,size_t,FrameKey)` returns an optional move-only RAII `FrameView`, with const image pointers and copied validated pose/origin/axis metadata. Header arithmetic, capacity/length, canonical layer ranges, formats, finite matrices, pair/epoch/id, incomplete sequence and busy slots are checked.
- Canonical PairKey JSON and SHA-256 documented precisely, along with UUID order, row order, raw depth semantics, physical pixel sizing, HTTP envelopes/routes and mapping lifetime. HTTP runtime handlers remain subsequent-task work.

## RED evidence (actual assertion failures, not compiler/setup failures)

Command from `mc/`:

```
./gradlew coreTest --console plain
```

Compiled stubs with tests first. After strengthening the application persistence assertion, actual output before implementation:

```
> Task :coreTest FAILED
FAIL coordinate_roundtrip: java.lang.AssertionError: expected MC (6.5,66,3), got Vec3[x=106.5, y=2.0, z=-47.0]
FAIL restart_keeps_origin: java.lang.AssertionError: restart changed persisted origin
FAIL foreign_epoch_rejected: java.lang.AssertionError: old epoch was accepted
FAIL receipt_is_not_application: java.lang.AssertionError: receipt must be PENDING
FAIL applied_survives_restart: java.lang.AssertionError: must await game thread
java.lang.AssertionError: 5 contract assertion(s) failed
BUILD FAILED
```

The first initial run had four failures, and the too-weak APPLIED test passed against a constant-return stub; that test was corrected before implementation and produced the five-failure output above. No compiler errors were treated as RED.

The mapped writer's separate assertion RED, before implementing writer behavior:

```
FAIL java_exports_binary_frame: java.lang.AssertionError: writer did not publish complete frame
java.lang.AssertionError: 1 contract assertion(s) failed
BUILD FAILED
```

Command from repository root:

```
make -C native contract-test
```

With an empty native reader and the ARM64 Java-produced fixture, before reader implementation:

```
FAIL java_fixture_is_readable: Java mapped fixture was rejected
PASS truncated_file_rejected
PASS odd_sequence_rejected
PASS oversize_rejected
PASS nan_matrix_rejected
PASS layer_offset_rejected
PASS foreign_epoch_rejected
PASS foreign_pair_rejected
PASS writer_lease_rejected
PASS oversize_stride_rejected
C++ x86_64 mapped Java fixture: FAIL
make: *** [contract-test] Error 1
```

Malformed-input tests initially pass for an empty reader; the positive golden assertion is the reader's RED evidence. After reader implementation, both positive and rejection cases pass. The cross-process publication/lease coverage was added as integration coverage after the golden writer/reader RED-GREEN cycle; it is not claimed as a separate preimplementation RED.

Additional ownership RED before adding the ledger lock:

```
FAIL exclusive_ledger_owner: java.lang.AssertionError: two live ledgers acquired the same pair journal
java.lang.AssertionError: 1 contract assertion(s) failed
BUILD FAILED
```

## Final GREEN evidence

Full Java suite from `mc/`, including clean compilation:

```
./gradlew clean check coreTest --console plain

> Task :coreTest
PASS coordinate_roundtrip
PASS restart_keeps_origin
PASS foreign_epoch_rejected
PASS receipt_is_not_application
PASS applied_survives_restart
PASS exclusive_ledger_owner
PASS reused_id_and_terminal_mutation_rejected
PASS java_exports_binary_frame
Java aarch64 exported frame-v2.bin
> Task :test NO-SOURCE
> Task :check
BUILD SUCCESSFUL in 980ms
4 actionable tasks: 4 executed
```

All project Java tests currently live in the independent `ContractTests.main(String[])` entry point, which `check` depends on. `test NO-SOURCE` is expected; no JUnit suite was skipped. Subsequent task suites should join this entry point.

Full native suite, rebuilt from clean, from repository root:

```
make -C native clean contract-test

xcrun clang++ -std=c++17 -Wall -Wextra -Werror -O2 -arch x86_64 -Iinclude tests/frame_contract_test.cpp -o build/frame_contract_test
cd ../mc && ./gradlew contractTestClasses --console plain
BUILD SUCCESSFUL
Java aarch64 shared writer: PASS (leased slot backpressure + 200 concurrent publications)
PASS java_fixture_is_readable
PASS truncated_file_rejected
PASS odd_sequence_rejected
PASS oversize_rejected
PASS nan_matrix_rejected
PASS layer_offset_rejected
PASS foreign_epoch_rejected
PASS foreign_pair_rejected
PASS writer_lease_rejected
PASS oversize_stride_rejected
PASS mapped_atomic_publication_and_leases
C++ x86_64 mapped Java fixture: PASS
```

`file native/build/frame_contract_test` returned `Mach-O 64-bit executable x86_64`. Java's fixture export and subprocess output identify `aarch64`; the native harness explicitly launches the writer via `/usr/bin/arch -arm64` and asserts the Java architecture.

The integration test uses the same real `MAP_SHARED` file in both processes. Native acquires all three initial frames; Java observes all-slots-leased backpressure. Native releases one view; Java reuses only that available slot, while the other two pinned frames retain their complete bytes. Then 200 subsequent concurrent publications check all color/HUD bytes, every depth value, pose and matrix samples. Native child cleanup only targets the Java subprocess it creates. The test uses resolution-sized buffers and does not claim full-resolution throughput.

Additional final checks:

- `git diff --cached --check` passed before commit.
- JSON parsing and all local `$ref` targets in the HTTP schema passed a standard-library structural check.
- Independently recomputed canonical PairKey SHA-256 matched the JSON fixture and mapped binary.
- Independently checked fixed binary length 5824, frame ID 42 and pose `(6.5,66,3)`.
- `git status --short` was empty immediately after commit.

## Changed files

- `protocol/frame-v2.md`
- `protocol/http-v2.schema.json`
- `protocol/fixtures/frame-v2.bin`
- `protocol/fixtures/frame-v2.json`
- `protocol/fixtures/http-v2.json`
- `mc/build.gradle`, `mc/settings.gradle`, `mc/gradle.properties`, `mc/gradlew`
- `mc/gradle/wrapper/gradle-wrapper.jar`, `mc/gradle/wrapper/gradle-wrapper.properties`
- `mc/src/main/java/dev/jay/dstmc/protocol/{BridgeTypes,WorldTransform,PairingStore,RequestLedger,FrameLayout}.java`
- `mc/src/contractTest/java/dev/jay/dstmc/ContractTests.java`
- `mc/src/contractTest/java/dev/jay/dstmc/protocol/ProtocolContractTest.java`
- `native/include/frame_protocol.h`
- `native/tests/frame_contract_test.cpp`
- `native/Makefile`

21 implementation/configuration/fixture files, 1992 added lines, committed. Existing `.gitignore` already excludes build output, Gradle caches and `.superpowers`, so no extension was needed.

## Self-review and remaining concerns

Reviewed the staged diff and arithmetic/lifecycle paths before commit. No changes outside task ownership were staged. All task tests passed; no known test failures remain.

1. **Mapping lifetime is a caller obligation:** the native mapping must be writable/aligned for atomic lease words and must outlive every FrameView. A resize/new identity requires a fresh mapping path and retirement after leases. Never truncate/recreate a mapping under readers. A crashed reader's lease is not automatically timed out/reused. These rules are documented and need preservation in Tasks 3/4.
2. **No strict exactly-once claim:** forced ledger files protect receipt/result evidence; they cannot atomically commit an external game mutation. Crash between effect and APPLIED remains UNRESOLVED and needs explicit reconciliation. This is deliberate approved behavior.
3. **Schema validation scope:** schema JSON syntax, internal references and golden bytes were checked; a full JSON Schema 2020-12 validator was not present in system/bundled dependencies, so full validator conformance was not independently run. No dependencies were installed outside the worktree. Runtime HTTP semantic checks remain future work (finite float32 conversion, identity match, actual application).
4. **Platform/scale:** tested macOS ARM64 Java -> Rosetta x86_64 C++, with lock-free 64-bit atomics and 2x2 buffers. No Windows/Linux portability, 1920x1080 throughput, renderer integration, game launch or 60-second FPS/synchronization acceptance is claimed for Task 1.
5. Build is deliberately Java-only for protocol contracts; verified MC/Fabric/Loom version references are retained in gradle.properties but no game plugin/client entrypoint was introduced. Later tasks can enable the game build without pulling game code into core tests.

No blocker to controller review/Task 2 handoff. Additive interfaces to relay: nested `BridgeTypes.*`; `RequestLedger.pollPending()` and close-before-reopen exclusive ownership; `FrameLayout.create/publish/close`; move-only native `FrameView` and writable-mapping lifetime requirement.

# Fix round 1/5 — numeric command snapshot and transition readability

Base: `0e8ac4b9d7aaa10ac84e15517b8de83b47426612`.
Fix commit: `1e3df9629e91a1cf81feda37c2d909e34afc26fa` — `fix: snapshot numeric command payloads before journaling`.

Reviewed `task-1-review-findings.md` and reproduced the mutable-number defect with the real Command/RequestLedger classes before changing production code. An AtomicInteger amount changed from 5 to 99 after receive() and before pollPending(); a nested AtomicInteger changed from 7 to 101. The game-thread queue exposed the mutated values even though receipt fingerprinting had used the original values.

Covering test file: `mc/src/contractTest/java/dev/jay/dstmc/protocol/ProtocolContractTest.java`, executed through `mc/src/contractTest/java/dev/jay/dstmc/ContractTests.java` by coreTest/check.

Added regression cases:

- `mutable_number_snapshot_matches_receipt`: mutate top-level and nested AtomicInteger values after receive and before pollPending; assert literal queued JSON still contains amounts 5 and 7; assert an equivalent immutable retry matches the persisted identity and never requeues.
- `exact_finite_json_numbers_preserved`: preserve a large BigInteger and high-precision BigDecimal, accept the finite decimal `1e309` without narrowing through double, reject NaN and positive/negative infinity.

RED command from worktree root:

```
./mc/gradlew -p mc coreTest --console plain
```

Actual output before implementation:

```
PASS coordinate_roundtrip
PASS restart_keeps_origin
PASS foreign_epoch_rejected
PASS receipt_is_not_application
PASS applied_survives_restart
PASS exclusive_ledger_owner
PASS reused_id_and_terminal_mutation_rejected
FAIL mutable_number_snapshot_matches_receipt: java.lang.AssertionError: queued command changed after receipt: {"amount":99,"nested":[{"amount":101}]}
FAIL exact_finite_json_numbers_preserved: java.lang.IllegalArgumentException: non-finite JSON number
PASS java_exports_binary_frame
java.lang.AssertionError: 2 contract assertion(s) failed
BUILD FAILED in 813ms
```

The mutation regression produced a real assertion failure; the exact-number regression additionally exposed the existing lossy double-range rejection. No compiler failures were used as RED evidence.

Fix: recursive payload freezing now snapshots every Number into a new immutable BigDecimal from its decimal text. JSON normalization uses that same exact-decimal path and does not call doubleValue(), preserving finite arbitrary-precision integer/decimal values. Invalid/nonfinite numeric text rejects with IllegalArgumentException. The command is fully snapshotted at construction, before any durable fingerprint or scheduling; no caller-owned mutable Number is retained. This deliberately makes numeric payload leaves BigDecimal values; consumers should treat JSON numeric leaves as Number rather than assuming Integer. The protocol document records this policy.

Expanded receive(), pollPending() and finish() transitions into separate persistence, in-memory update and queue operations. Ordering and journal semantics are unchanged. Updated the old payload test to compare the numeric JSON value rather than a specific Java wrapper class.

Focused GREEN command:

```
./mc/gradlew -p mc coreTest --console plain
```

Output:

```
PASS coordinate_roundtrip
PASS restart_keeps_origin
PASS foreign_epoch_rejected
PASS receipt_is_not_application
PASS applied_survives_restart
PASS exclusive_ledger_owner
PASS reused_id_and_terminal_mutation_rejected
PASS mutable_number_snapshot_matches_receipt
PASS exact_finite_json_numbers_preserved
PASS java_exports_binary_frame
Java aarch64 exported frame-v2.bin
BUILD SUCCESSFUL in 624ms
```

Required full Java verification, once after the fix:

```
./mc/gradlew -p mc check --console plain
```

Output included all 10 PASS cases above, `> Task :check`, and:

```
BUILD SUCCESSFUL in 538ms
3 actionable tasks: 1 executed, 2 up-to-date
```

Native code/binary format and the generated golden binary were unchanged; native stress was not repeated as instructed. `git diff --check` and staged whitespace checks passed. Self-review verified the snapshot is recursive, its exact-decimal form matches fingerprint serialization, no stale mutable value reaches the pending queue, and persistence still occurs before queue insertion. Only four owned files changed: BridgeTypes.java, RequestLedger.java, ProtocolContractTest.java, protocol/frame-v2.md. Working tree was clean after committing. No new unresolved findings or blockers.
