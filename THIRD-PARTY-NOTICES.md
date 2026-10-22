# Third-party and distribution notes

This development archive contains project source, a compiled Fabric mod, the DST Lua adapter, and the project's compiled macOS adapter. It does not include Minecraft/DST executables, installed game assets, user saves, account data or access tokens.

Minecraft is a Mojang/Microsoft product; Don't Starve Together is a Klei Entertainment product. Users must supply their own installed games. The archive does not grant rights to redistribute either game's proprietary code or assets.

Build/runtime dependencies include Fabric Loader, Fabric API, Fabric Loom, Gradle and the Gradle wrapper, LWJGL, Gson and the Java runtime, with macOS OpenGL/Cocoa frameworks supplied by the operating system. Dependency licenses continue to apply; Gradle resolves the dependencies declared in mc/build.gradle. The wrapper JAR and properties are retained from the existing repository. Test tools jsonschema and lupa are installed separately and are not bundled.

No project-wide LICENSE file was present at the reviewed baseline. This notice does not create or change a license for the project. Review the repository owner's licensing choice and dependency notices before public redistribution.
