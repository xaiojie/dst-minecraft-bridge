# Windows Native Bridge Implementation Plan

> **For agentic workers:** Use superpowers:subagent-driven-development or superpowers:executing-plans; complete the authorized coding and push without another approval round.

**Goal:** Deliver Windows x64 native fusion code and reproducible build/deploy/acceptance entry points.

**Architecture:** Reuse Java/Lua/protocol gameplay. Add a Windows ANGLE/GLES/EGL native backend and Steam-preserving loader; share the frame ABI and camera lease logic. Keep macOS functioning.

**Tech Stack:** Java 21/Fabric 1.21.11, Lua, C++17, Windows API, ANGLE GLES2/EGL, Python 3, CMake.

**Spec:** docs/superpowers/specs/2026-10-23-windows-native-design.md

## Global Constraints

- Windows x64; no CrossOver/Wine dependency; DST launches through Steam.
- MC 1.21.11, Java 21, protocol 2, ports 39379/39380 bound to loopback only.
- Preserve same-frame pixel/depth/pose, pair/epoch/freshness checks and safe input restoration.
- Single player, integrated MC server, DST ground, solid cubes, scale 1, fixed X reflection.
- No original-save mutation, game redistribution, credentials, or global security changes.
- Actual Windows rendering/input/gameplay/performance acceptance remains NOT_VERIFIED.

## Review Focus

Unicode/space paths and Windows quoting; target x64/Steam identity; DLL load failure and restore; DPI/resize/session change before first composed frame; mapped-file deletion and atomic persistence on Windows.

### Task 1: Windows native backend

**Files:** native/windows/**, native/CMakeLists.txt, native/cmake/**; minimal platform-neutral header changes if needed.
**Interfaces:** Reuses native/include/frame_protocol.h, CameraService and protocol v2 HTTP contracts. Produces native/build-windows/dstmc_bridge.dll, CMake offline contract tests, backend diagnostics and Win32 client geometry. Supports GET /v2/window/geometry?pair_hash=...&epoch=... separately from proven GET /v2/window?pair_hash=...&epoch=.... Geometry never grants transparency.
- [x] Add portable contract tests first; observe failures, implement the native backend and build targets.
- [x] Implement GLES/EGL real hook path, shader matrix observation, color/depth/HUD composition, bounded frame mapping, camera/input/mailbox HTTP and cleanup.
- [x] Preserve GL state and refuse unsupported capabilities with a precise diagnostic; do not fabricate successful composition.
- [x] Build portable C++ tests on macOS and cross-compile x64 DLL; record exact commands/results.

### Task 2: Windows tools and deployment

**Files:** tools/*.py, tools/*.ps1, tools/*.cmd, tests/test_windows*.py, tests/test_steam*.py, tests/test_test_copy.py, tests/test_delivery.py.
**Interfaces:** Uses native/build-windows/dstmc_bridge.dll, keeps existing macOS library. Launch command prints the exact Steam option and wraps %command%; Windows loader may inject only the verified game process it creates from Steam's supplied command.
- [x] Write failing tests for PE architecture, Windows Steam catalogue, command quoting, lock ownership, loader failures and binary/source packaging.
- [x] Implement platform discovery, safe Windows loader, test copy lock, launcher/check/package/deploy commands and scripts.
- [x] Run Python/Lua suite and verify dry-run deployment/packaging excludes saves/tokens.

### Task 3: MC window and persistence portability

**Files:** mc/src/client/**, mc/src/main/**, mc/src/contractTest/**, mc/build.gradle, protocol/**; native/src/camera_http.mm for geometry parity only.
**Interfaces:** Geometry polling sizes the capture before composition; fresh /v2/window proof alone activates transparent presentation. glfw window placement is logical; framebuffer dimensions are physical; account for measured per-axis scale. World binding commits atomic file data without opening Windows directories as FileChannels.
- [x] Add failing contract cases for bootstrap sizing, 150%/200% DPI, invalid/session-expired proofs and persistent binding restart.
- [x] Add Windows GLFW behavior guarded from Cocoa APIs; maintain restore on disconnect, resize and F8.
- [x] Update resource default paths and Java atomic persistence for Windows.
- [x] Run clean Java check/build and applicable native Mac regression tests.

### Task 4: Integration, CI, docs and push

**Files:** .github/workflows/**, README.md, docs/windows-start.md, docs/HANDOFF.md, docs/development-2026-10-23.md, THIRD-PARTY-NOTICES.md.
**Interfaces:** Uses deliverables and commands from Tasks 1–3; keeps live acceptance explicit.
- [x] Add Windows native/Java/Python build CI and startup documentation with separate copied saves.
- [x] Run full applicable local checks, cross-compile, inspect package manifest and independently review the complete diff.
- [ ] Resolve material review findings; commit all intended changes and push to origin on the development branch; compare local/remote SHA.
