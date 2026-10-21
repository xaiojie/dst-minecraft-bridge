# Local DST / Minecraft bridge protocol v2

This contract is shared by the Java ARM64 producer and C++ x86_64 consumer. No game APIs are used here. Runtime game integrations must execute game operations on their own game threads and graphical operations on their render threads.

## Identity, spaces and persistence

`BridgeTypes` contains the common immutable Java value types as nested records/enums. Import them with `import dev.jay.dstmc.protocol.BridgeTypes.*;`. `Vec3` uses finite doubles; `Box` is a half-open AABB, `Cell` uses signed 32-bit coordinates. Revisions and frame IDs are unsigned 64-bit values; Java stores their bit patterns in `long`. HTTP JSON must preserve the unsigned integer exactly, never round it through a binary64 parser.

`PairKey(dst_world, dst_shard, mc_world, mc_dimension, region)` uses persistent world UUIDs and the exact shard, dimension and region strings. Epoch is a UUID for one handshake. Both pair and epoch must match before any side effect. `Body.id` is the persistent DST object UUID, not a runtime GUID. Damage deduplication at the combat layer uses `(pair, id, target)`; generic commands use `(pair, id)` with the epoch and parameter fingerprint checked on retries.

Pair hash input is UTF-8 JSON with no BOM, whitespace or final newline. Keys appear in this **fixed order**: `dst_world`, `dst_shard`, `mc_world`, `mc_dimension`, `region`. UUIDs are lowercase RFC 4122 strings; strings escape quotes and backslashes with a backslash and U+0000–001F as lowercase `\u00xx`. Other valid Unicode stays UTF-8; there is no Unicode normalization. Invalid surrogate sequences are rejected. `BridgeTypes.canonicalPair` and `pairHash` implement this representation. The golden input and SHA-256 are in `fixtures/frame-v2.json`.

Initial calibration is one DST unit to one MC block, identity axes:

```
MC = DST - dstOrigin + mcOrigin
DST = MC - mcOrigin + dstOrigin
```

The golden origins `(100,0,-50)` and `(0,64,0)` map DST `(106.5,2,-47)` to MC `(6.5,66,3)`. `WorldTransform.toMc` / `toDst` never recalibrate in response to movement. `PairingStore(Path)` atomically saves a pair's first origins; `loadOrCreate(pair, dstOrigin, mcOrigin)` returns those saved origins on subsequent calls. Different pairs use different SHA-256 file names. Malformed records fail closed. Creation is protected by a stable lock inode, and each record is forced, atomically renamed, then its parent directory is forced. The current binary store is private to Java; the shared interchange format is this document and HTTP schema.

`RequestLedger(Path, pair, epoch)` owns an exclusive OS file lock for that pair until `close()`. A second live owner is rejected immediately. Use try-with-resources and close before reopening a ledger. `receive(Command)` rejects foreign identity **before** inspecting/mutating command state. The first valid receipt is forced to durable `PENDING` before returning. `pollPending(): Optional<Command>` removes one item from the in-memory game-thread scheduling queue; duplicate receipts return the existing outcome and never enqueue again. Reusing an ID with different parameters or epoch is rejected. A game-thread consumer calls `finish(id, result)` only after actual application/rejection. `APPLIED` and `REJECTED` terminal outcomes cannot be rewritten. `UNRESOLVED` may be reconciled explicitly through `finish`, but is never automatically queued.

Opening a ledger converts persisted `PENDING` records to durable `UNRESOLVED`. It does not replay them, even if the same epoch was reused by a test. Old-epoch records remain evidence and cannot be finished through a new-epoch ledger. There is no claim of crash-safe exactly-once game mutation: a crash after a game effect and before durable APPLIED requires reconciliation. Payload fingerprints use sorted object keys, ordered arrays, exact strings and normalized finite JSON decimal numbers; command payloads are copied recursively on construction. All accepted Number values are snapshotted from their decimal text into immutable BigDecimal values before fingerprinting or scheduling. This preserves arbitrary-precision finite decimal/integer values without narrowing through double; NaN, infinity and nondecimal numeric text are rejected.

## Mapped file layout

All numeric values are **little-endian**, except UUIDs, which are the 16 RFC 4122 bytes in textual/network order. Floats are IEEE 754. No native struct packing is assumed. The mapping base must be at least 8-byte aligned, writable, and `MAP_SHARED` for the reader's atomic lease words. A `FrameView` exposes only const image pointers and copied validated metadata.

There is a 4096-byte file header and exactly three slots, each with a 512-byte slot header. Production physical capacity is bounded by **1920×1080**. Capacity is chosen when creating a new mapping; the small golden fixture uses 2×2 capacity and is 5824 bytes. Slot stride is `alignUp(512 + capacity_width*capacity_height*12, 64)`. File length is exactly `4096 + 3*stride`. Each frame may be no larger than capacity on either axis. Frame sizes are physical framebuffer pixels, not macOS logical points.

`FrameLayout.create(path, capacityWidth, capacityHeight)` requires a new, nonexistent path. It cannot overwrite/truncate an existing mapping. A resolution change exceeding capacity or a new pair/epoch requires a **fresh mapping generation/path**, published through handshake. A file must never be truncated or replaced in place while a reader may hold a view. Keep each old mapping alive until its leases are released, then retire it. Never unmap while a `FrameView` exists. Closing the Java writer closes its channel; mapped bytes remain subject to the JVM mapping lifetime.

File header:

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 8 | ASCII `DSTMCF2` followed by NUL |
| 8 | 4 | Version = 2 |
| 12 | 4 | File header bytes = 4096 |
| 16 | 4 | Slot count = 3 |
| 20 | 4 | Slot header bytes = 512 |
| 24 | 4 | Capacity width, 1…1920 |
| 28 | 4 | Capacity height, 1…1080 |
| 32 | 8 | Slot stride, aligned to 64 |
| 40 | 8 | Exact total file bytes |
| 48 | 4048 | Reserved, zero on creation |

Slot `i` starts at `4096 + i*stride`:

| Offset | Bytes | Field |
|---:|---:|---|
| 0 | 8 | Atomic commit sequence: 0 empty; odd writing; nonzero even complete |
| 8 | 8 | Atomic lease: 0 free; UINT64_MAX writer; other nonzero value reader |
| 16 | 32 | SHA-256 of canonical PairKey JSON |
| 48 | 16 | Epoch UUID bytes |
| 64 | 8 | Frame ID, unsigned, increasing within epoch |
| 72 | 4 | Physical width |
| 76 | 4 | Physical height |
| 80 | 4 | World color format = 1 (premultiplied RGBA8) |
| 84 | 4 | Depth format = 2 (OpenGL float32) |
| 88 | 4 | HUD format = 1 (premultiplied RGBA8) |
| 92 | 4 | Reserved = 0 |
| 96 | 8 | World layer offset = 512 |
| 104 | 8 | Depth layer offset = 512 + layerBytes |
| 112 | 8 | HUD layer offset = 512 + 2*layerBytes |
| 120 | 8 | layerBytes = width*height*4 |
| 128 | 24 | DST origin, 3 float64 |
| 152 | 24 | MC origin, 3 float64 |
| 176 | 72 | DST→MC 3×3 axes, 9 float64, identity in initial calibration |
| 248 | 24 | Pose position in MC space, 3 float64 |
| 272 | 24 | Pose forward in MC space, 3 float64 |
| 296 | 24 | Pose up in MC space, 3 float64 |
| 320 | 64 | MC view matrix, 16 float32, column-major |
| 384 | 64 | MC projection matrix, 16 float32, column-major |
| 448 | 64 | Reserved, zero on creation |

The three packed layers immediately follow the header in world/depth/HUD order, with no row padding. Rows follow OpenGL framebuffer order: row zero is the bottom row. World and HUD use premultiplied alpha; alpha zero contributes no color. Depth is the MC raw OpenGL [0,1] depth. Reconstruct space positions using the matching inverse projection/view and world transform before a cross-engine depth comparison. Never directly compare MC and DST raw depth values. A shared frame's Pose is MC space; a camera lease returns the converted DST-space Pose. Absolute view matrices across spaces are not interchangeable.

## Atomic publication and leases

The protocol uses aligned, lock-free 64-bit atomics on ARM64 and x86_64. Java uses little-endian ByteBuffer VarHandles; C++ uses lock-free compiler atomic operations on the mapped words. The header is initialized before the mapping is announced and then remains immutable. There is one Java producer per mapping.

1. Writer CAS-acquires a slot's lease from 0 to UINT64_MAX. A nonzero lease prevents selection; if all three are held, `publish` returns false without advancing its frame ID or sequence.
2. Writer stores an odd commit sequence with volatile/full ordering before changing metadata or pixels, writes the complete header and three layers, then release-stores the nonzero even sequence.
3. Writer release-stores lease 0 only after the complete commit. Failed/incomplete writes leave an odd sequence, which readers reject.
4. Reader CAS-acquires lease 0 to a nonzero reader token with acquire ordering, then acquire-loads sequence. It validates the whole header, identity, dimensions, stride, lengths, formats, layer bounds, origins, axes and all matrix values. It rechecks the sequence before returning a view.
5. C++ `read_frame(const void*, size_t, FrameKey)` returns an optional **move-only** `FrameView`; the view owns the lease. Destruction or move-assignment releases it with a release CAS. Moving transfers ownership without releasing the slot. A second reader cannot acquire that same slot until release.

The slot lease excludes writes while its zero-copy pointers are in use; the sequence alone is not enough to protect zero-copy reads. Reader tokens need only be nonzero and distinct from UINT64_MAX; exclusive CAS ownership and noncopyable views prevent accidental release by another view. A crashed holder is not reclaimed by a timeout. Reconcile process liveness and start a fresh epoch/mapping; do not force-clear an old live lease. This is process-shared memory visibility, not per-frame disk durability; frames are disposable after a crash.

Readers check capacity before multiplying and validate the exact calculated stride/file length before accessing any slot. Layer sizes are computed in 64-bit arithmetic and offsets must equal the canonical packed offsets. Malformed, truncated, writing, foreign, busy or unsupported-transform frames return no view. The native reader currently supports little-endian hosts with lock-free 64-bit atomics and rejects unsupported builds at compile time.

## HTTP envelopes

`http-v2.schema.json` is JSON Schema 2020-12. Its `$defs` describe common values and endpoint envelopes; `x-endpoints` associates each local route with request/response definitions. Root `anyOf` accepts the supported complete envelopes. Validate a common value such as CommandResult through its `$defs` reference. Finite float32 conversion, matching live identities, valid vectors, AABB ordering and health bounds require semantic checks as well as JSON Schema validation.

| Bind address | Method / route | Purpose |
|---|---|---|
| 127.0.0.1:39379 | POST /v2/handshake | Pair/epoch, fixed origins, identity axes and new mapping path |
| 127.0.0.1:39379 | POST /v2/exchange | Commands/events and confirmed authoritative state/results |
| 127.0.0.1:39379 | GET /v2/status | Protocol and live identity/status |
| 127.0.0.1:39380 | POST /v2/camera/lease | Frame-keyed camera lease in DST space |
| 127.0.0.1:39380 | POST /v2/camera/applied | Confirm/reject that specific camera frame |
| 127.0.0.1:39380 | GET /v2/window | DST content screen origin, logical points, physical pixels, scale |

Both services bind loopback only. A legacy protocol=1 owner of 39379 is a visible conflict requiring that test instance to be closed; never kill an unrelated process. Network callbacks queue work for game/render threads and do not invoke game APIs. Receipt PENDING is never displayed as application. HTTP implementations and game APIs belong to subsequent tasks.

## Verification

```
cd mc && ./gradlew coreTest --console plain
cd .. && make -C native contract-test
```

`ContractTests.main(String[])` is the common Java test entry point; subsequent tasks add their suites there. Java tests regenerate the deterministic golden binary. Native tests compile explicitly for x86_64 and execute against that Java ARM64 file. The two-process test launches Java explicitly with `arch -arm64`, maps the same runtime file, pins all three slots, proves backpressure and safe reuse, then verifies 200 concurrent frame publications. No game launch, mod install or original save is involved.
