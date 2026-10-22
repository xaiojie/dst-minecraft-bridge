# Task4 camera calibration evidence (read-only research)

Actual forest-paused-depth/draws.jsonl frame18586 draw566 MatrixV 3x3 rows:
[[-0.707106829, 0, 0.707106829], [-0.480954766, 0.733051896, -0.480954766], [0.518345952, 0.680172741, 0.518345952]]
Determinant=-1.0000001004256598

This is an observed reflected view basis (approximately -1), while a conventional MC rotation view has determinant+1. Native MatrixP x/y scales in the sampled old camera are positive; clipping z near/far differ from MC. This raises a concrete handedness/mirroring risk; verify a controlled left/right landmark under the first-person camera before deciding on calibration. Do not silently ignore a sign mismatch or claim matrices match from FOV alone.

Current WorldTransform is translation-only identity axes; PairingStore currently persists two origins only, and frame-v2.md describes identity axes as initial calibration. Design spec section5 allows a persistent coordinate-axis transform. If actual first-person tests require reflection, request controller ruling and update shared transform/persistence/reader validation consistently with targeted tests; do not independently negate a camera or block coordinate at one endpoint. Preserve binary field layout and old identity fixture compatibility. This note identifies a risk, not a pre-approved product change.

Near/far terms from actual native MatrixP imply about1..200. Compare matching world rays/camera pose, not raw z projection coefficients; reconstruct each engine depth with its own projection and transform to common space.

Installed followcamera.lua lines238–267 confirms SetCameraDir receives the forward vector (dx,dy,dz), while camera_pos=currentpos-forward*distance. Lines269–280 compute camera_up; it is the true upward basis. This narrows the reflected-basis concern rather than explaining it as a backwards API parameter. A persistent Z reflection is one candidate to test; any chosen mapping must transform positions, directions, AABBs, blocks and shared-frame axes consistently. Existing two-origin/identity WorldTransform and stored pairing format do not yet support it. Do not change an already paired save's axes silently.
