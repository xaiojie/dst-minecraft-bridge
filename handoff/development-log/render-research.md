# Read-only rendering research for Task 2

Inspected installed DST resources on 2026-10-21. This is local research, not a passed runtime probe.

- Current DST executable imports glDrawArrays/glDrawElements and NSOpenGLContext. Shader program operations are not direct undefined symbols in the executable, so fixed-function projection/modelview queries alone will not reveal the engine camera.
- Local archive: /Users/jay/Library/Application Support/Steam/steamapps/common/Don't Starve Together/dontstarve_steam.app/Contents/data/databundles/shaders.zip
- .ksh entries are binary containers with embedded readable GLSL. Do not redistribute the archive or original shaders.
- anim.ksh non-skinned vertex path uses MatrixP, MatrixV, MatrixW; skinned path uses pv, fastanim_xform, fastanim_bones. ground.ksh uses MatrixPVW and MatrixW. Actual gl_Position is built from those matrices, with no unconditional fake z overwrite observed in the inspected paths.
- anim fragment source includes alpha-test discard and premultiplied output. ui_anim.ksh has overlapping matrix names and additional UI-specific uniforms; names alone do not distinguish world/UI reliably.
- render_depth.ksh exists, but its name is not evidence it produces a suitable active depth target. Actual GL depth write/test state and target must be sampled.
- The game log reported OpenGL 2.1 Metal on Apple M4, Threaded Renderer DISABLED. Binary is x86_64, with allow-dyld-environment-variables and disable-library-validation entitlements. Confirm current values in preflight.
- CUA inspection confirmed current world is paused via native pause menu (world day 77). Do not assume it is safe to kill. Controller will handle save/disconnect/exit via UI before extension launch. Workers must not act on desktop UI through shell APIs.

Task 1 implementer interface decisions (awaiting task review): Java records/enums nested under BridgeTypes (import dev.jay.dstmc.protocol.BridgeTypes.*); PairingStore(Path directory); RequestLedger(Path directory, PairKey pair, UUID epoch); native read_frame returns move-only RAII FrameView, pinning a slot until release. Consult committed task 1 contract after approval, not this preliminary note.

## Unvalidated depth-pass option for later evaluation
If the runtime probe shows sprite depth writes are disabled, a possible fallback is to replay each verified scene draw immediately into an owned depth FBO using the still-bound original geometry/program/textures, enabling depth writes and a transparent-alpha rejection test, then restoring every state before returning. This avoids reconstructing game vertex animation or distributing game shaders. It remains unvalidated: program-stage classification, FBO sizes, alpha output and scene/UI boundary must first be observed. Fully transparent fragments must not write a solid rectangular depth footprint; semitransparent native sprites need explicit evaluation rather than assuming their depth is opaque.
