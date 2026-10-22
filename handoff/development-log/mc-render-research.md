# Task 3 read-only findings from pinned 1.21.11 sources

Source is the prior probe cached official-mapped minecraft-merged sources jar (same pinned version). Do not redistribute the full source archive.

GameRenderer.renderLevel lines 747-808: extractCamera; obtain FOV; construct projection; multiply hurt and bob PoseStack; apply optional portal/nausea matrix distortion; install world projection; construct matrix4f2 solely from conjugate camera rotation; pass camera, matrix4f2, projection into LevelRenderer.renderLevel; then install hand projection and clear main depth before drawing hand.

Consequences requiring implementation decisions: capture the actual LevelRenderer projection, not just nominal FOV. The view supplied to LevelRenderer is rotation-only because Minecraft renders in camera-relative coordinates. A shared full world view must include the camera translation, or the consumer must explicitly reconstruct camera-relative positions plus Pose.position; document one convention consistently. Eye-space hurt/bob and nausea distort projection beyond what SetCameraFOV alone can reproduce, so matching must handle or temporarily disable these cosmetic effects while fused. Do not publish a nominal camera with pixels from a distorted projection and claim matching.

RenderTarget provides getColorTexture/getDepthTexture; GlTexture exposes glId() and getFbo(DirectStateAccess, depthTexture); GlDevice has public directStateAccess(). A new valid GL read FBO can also attach actual textures if state is restored.

FlatLevelGeneratorSettings codec has required layers; lakes/features default false; biome defaults Plains; structure_overrides optional. Empty layers plus explicit empty structure overrides provides the void scene approach, to be verified with actual game loading.

Task 1 journal numeric payload leaves are BigDecimal; use Number access and semantic range/finite checks at game API boundaries. Its HTTP uint64 fields must not be silently rounded by a Lua binary64 decoder: runtime adapters must check exact supported values or use an explicit lossless representation in a controller-recorded contract update.

Test-save copying must interoperate with Minecraft's actual Java FileChannel session lock, not merely check that session.lock exists or test only a Python-specific lock family. The regression should use a real Java lock holder as the other process. Existing session.lock files remain after normal game exit. Acquire a compatible nonblocking source lock for the duration of the copy; never modify source save bytes.

The current native read_frame API consumes an exact FrameKey; it does not expose an unsafe unleased latest-ID read. Task 3 status can publish latest_frame plus mapping generation so later native camera services can discover a committed key without reading mutable slot headers outside a lease. Any shared-header selector extension needs a bounded/leased implementation and review, not raw racing reads.

Task4 camera clue from actual DST draw260/target1/program28 in render-probe-2: MatrixV is full world view; MatrixP is a perspective projection with M00=1.77294087, M11=3.17159438, M22=-1.0100503, M23=-1, M32=-2.0100503. This corresponds to native near1/far200 while MC near/far differ. Do not require raw projection element equality unless native clip distances can be configured or a native render hook substitutes the projection consistently. Reconstructed world-space depth comparison can tolerate distinct clip ranges but screen-space camera rays still must match. Installed followcamera.lua uses SetCameraPos/Dir/Up/FOV; no clip setter in that file. This is read-only evidence, not a validated matching algorithm.
