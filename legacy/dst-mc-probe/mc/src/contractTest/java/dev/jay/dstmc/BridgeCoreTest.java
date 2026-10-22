package dev.jay.dstmc;

public final class BridgeCoreTest {
    public static void main(String[] args) throws Exception {
        int failed = 0;
        // A wrong axis or missing origin offset would move the MC player to the wrong place.
        try {
            var p = BridgeCore.toMinecraft(106.5, -47.0, 100, -50);
            if (p.x() != 6.5 || p.z() != 3.0) throw new AssertionError("expected (6.5,3.0), got " + p);
            System.out.println("PASS relative ground coordinates");
        } catch (AssertionError ex) { failed++; System.out.println("FAIL coordinates: " + ex.getMessage()); }
        // Retrying one TNT request must not create two explosions.
        try {
            var once = new BridgeCore.Once();
            if (!once.accept("session-a:1") || once.accept("session-a:1") || !once.accept("session-a:2")) {
                throw new AssertionError("a repeated event was accepted or a new event was rejected");
            }
            System.out.println("PASS retry deduplication");
        } catch (AssertionError ex) { failed++; System.out.println("FAIL deduplication: " + ex.getMessage()); }
        // Restarting the MC test process must not replay an already accepted TNT request.
        var parent = java.nio.file.Path.of("build");
        java.nio.file.Files.createDirectories(parent);
        var directory = java.nio.file.Files.createTempDirectory(parent, "once-contract-");
        var journal = directory.resolve("requests.txt");
        try {
            var first = new BridgeCore.Once(journal);
            if (!first.accept("completed-tnt-1")) throw new AssertionError("first request was rejected");
            var restarted = new BridgeCore.Once(journal);
            if (restarted.accept("completed-tnt-1")) throw new AssertionError("restart replayed the completed TNT request");
            System.out.println("PASS restart does not replay completed TNT");
        } catch (AssertionError ex) { failed++; System.out.println("FAIL restart: " + ex.getMessage()); }
        finally { java.nio.file.Files.deleteIfExists(journal); java.nio.file.Files.deleteIfExists(directory); }
        if (failed > 0) throw new AssertionError(failed + " contract tests failed");
    }
}
