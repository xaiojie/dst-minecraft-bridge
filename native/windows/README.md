# Windows ANGLE backend

Build on Windows x64 using Visual Studio 2022 (C++ desktop workload) and CMake:

```powershell
cmake -S native -B native/build-windows -A x64
cmake --build native/build-windows --config Release
ctest --test-dir native/build-windows -C Release --output-on-failure
```

The DLL is `native/build-windows/dstmc_bridge.dll`. `publisher_rgba_reader.exe`
is a separate Java/native mapped-frame contract helper. The build downloads
SHA256-pinned MinHook and nlohmann/json sources. Khronos interface headers are
vendored with original licenses and recorded source hashes; no game or ANGLE
runtime is included.

Cross-compile on macOS with Homebrew `cmake` and `mingw-w64`:

```sh
cmake -S native -B native/build-windows -DCMAKE_TOOLCHAIN_FILE=cmake/mingw-x64.cmake -DCMAKE_BUILD_TYPE=Release
cmake --build native/build-windows -j 4
```

Portable contracts (no Windows runtime required):

```sh
cmake -S native -B native/build-contracts
cmake --build native/build-contracts -j 4
ctest --test-dir native/build-contracts --output-on-failure
```

## Runtime contract

The Steam-preserving loader injects this x64 DLL and supplies `DSTMC_PROBE_DIR`
as a Unicode absolute directory. The worker binds only `127.0.0.1:39380`; an
existing listener causes startup failure. Logs go to `camera-gate.jsonl`.
It discovers `libGLESv2.dll` / `libEGL.dll` exports in the running process.
No replacement game DLL, OpenGL launch flag or D3D assumption is involved.

HTTP routes and camera-mailbox files follow the macOS protocol. Requests are
size/time bounded; the server handles Content-Length, chunked bodies and
100-continue. Duplicate lengths and ambiguous framing are rejected. Windows
frame files use UTF-16 paths, sharing for read/write/delete, bounded writable
mappings and the existing slot lease ABI. Relative, UNC/device and reparse-point
frame paths are rejected.

`/v2/window/geometry?pair_hash=...&epoch=...` provides recent client geometry
for the active session before composition. `/v2/window?...` additionally requires
an acknowledged, successfully composited and presented frame within 250 ms.
Only the latter may authorize transparency. Coordinates are physical Windows
pixels (`scale=1`); geometry queries temporarily adopt a per-monitor DPI thread
context, restoring it afterwards. The process DPI policy is not changed.

The current GLES2 path requires OES or ANGLE depth textures, OES float textures and EXT
fragment depth. It observes actual MatrixV/MatrixP uniforms, validates the lease
pose/rays/size, and replays eligible world draws with the original shader and
vertex/sampler state into supplemental depth. Blended shaders without discard,
custom fragment-depth shaders, active stencil masks, inconsistent world framebuffer targets, mismatched
viewports/ranges and singular projections refuse composition. World colors and
MC depth are uploaded together from the pinned slot, compared in view space,
MC world color is composed into the observed world target before a draw that samples that target’s color attachment or an ANGLE/core framebuffer blit that reads it; MC arms/HUD are overlaid separately at EGL present. Every modified GLES2 raster/binding/attribute state
is saved and restored explicitly; no desktop GL immediate mode or attribute
stacks are used.

F8 switches input ownership. Native input suppression requires fresh composition
proof, and release events always reach the original handler to prevent stuck
keys/buttons. Proof expiry, failed present, session/size changes and context loss
remove activation. `DSTMC_Stop` requests shutdown; the DLL is deliberately pinned
so live detour trampolines cannot be unloaded. Stopped hooks pass through and GL
resources are released on the next owning-context present or destruction.

## Evidence boundary

Windows gameplay/rendering/input/performance acceptance is **NOT_VERIFIED**.
Cross-compilation and portable tests cannot establish the current game's GLES
version, shader layout, alpha-discard behavior, final framebuffer organization,
Raw Input behavior or multi-monitor DPI behavior. GLES3 contexts are explicitly
rejected until their additional VAO/PBO/indexed state is implemented. A shader
whose attached sources are unavailable also fails the depth eligibility gate.
Runtime refusals are logged instead of generating a transparency proof.

The optional ANGLE/core blit detours resolve through either GLES exports or
`eglGetProcAddress`. Read and draw framebuffer bindings are preserved separately
when the framebuffer-blit extension is present. Partial, flipped or scaled
world blits withhold activation until their ray mapping is verified.

Windows CTest additionally runs `windows_loader_http_smoke`, loading the real
bridge DLL into an isolated fixture process and checking UTF-16 directory paths,
loopback framing and fail-closed startup/shutdown. It does not load fake GLES
modules or generate composition evidence. `loader_fixture.dll` is a separate
minimal DLL used by the Python process-injection smoke test, not by gameplay.
