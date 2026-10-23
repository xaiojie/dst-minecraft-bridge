# Third-party and distribution notes

This development archive contains project source, a compiled Fabric mod, the DST Lua adapter, and the project's compiled Windows or macOS adapter. It does not include Minecraft/DST executables, installed game assets, user saves, account data or access tokens.

Minecraft is a Mojang/Microsoft product; Don't Starve Together is a Klei Entertainment product. Users must supply their own installed games. The archive does not grant rights to redistribute either game's proprietary code or assets.

Build/runtime dependencies include Fabric Loader, Fabric API, Fabric Loom, Gradle and the Gradle wrapper, LWJGL, Gson and the Java runtime, with macOS OpenGL/Cocoa frameworks supplied by the operating system. Dependency licenses continue to apply; Gradle resolves the dependencies declared in mc/build.gradle. The wrapper JAR and properties are retained from the existing repository. Test tools jsonschema and lupa are installed separately and are not bundled.

No project-wide LICENSE file was present at the reviewed baseline. This notice does not create or change a license for the project. Review the repository owner's licensing choice and dependency notices before public redistribution.

## Windows native dependencies

The Windows adapter uses MinHook (BSD 2-clause, upstream commit c3fcafdc10146beb5919319d0683e44e3c30d537) and nlohmann/json (MIT, upstream commit 9cca280a4d0ccf0c08f47a99aa71d1b0e52f8d03). Full license notices accompany the source/development package in native/windows/third_party/MinHook-LICENSE.txt and nlohmann-json-LICENSE.MIT. CMake pins archive SHA256 values; it does not download a game binary.

Khronos EGL/GLES/KHR interface headers retain their copyright/license notices. Exact sources and hashes are recorded in native/windows/third_party/SOURCES.md. ANGLE, Windows APIs and the two games are supplied by the user's own installations; no proprietary game or ANGLE runtime is bundled. Similar projects cited in the design are architecture references; their game-specific loaders and assets are not redistributed here.
