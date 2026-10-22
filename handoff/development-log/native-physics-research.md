# Native mesh API: read-only installed-script evidence

Installed build756039 scripts.zip has real Physics:SetTriangleMesh(flat_triangles) calls. Exact source refs are in native-physics-research.json; do not copy game archives into distribution.

scripts/prefabs/vaultcollision.lua lines88–139 emits a flat coordinate array: each triangle is nine scalar values, two triangles per vertical plane from y0 to y1. Its AddPlane ordering is vertices (x0,y0,z0),(x0,y1,z0),(x1,y0,z1) then (x1,y0,z1),(x0,y1,z0),(x1,y1,z1). Lines142–165 add Transform/Network/Physics, mass0, collision group CHARACTERS and mask CHARACTERS, call SetTriangleMesh, set pristine, and mark master entity persists=false. This supports custom static triangle collision, not an inference from unavailable SetBox. Other real calls exist in cave_hole, golf shape and boats.

The Task6 generated cube mesh must validate winding/sidedness, connected surface generation, correct world/local conversion, dynamic replacement cleanup, character/creature collision groups and actual pig movement in-game. The script API observation alone does not establish those runtime effects. No box/mesh approximation is accepted without task acceptance.
