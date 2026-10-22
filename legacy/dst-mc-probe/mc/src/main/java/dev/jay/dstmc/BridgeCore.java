package dev.jay.dstmc;

/** Temporary feasibility probe; not a finished crossover mod. */
public final class BridgeCore {
    public record Position(double x, double z) {}
    public static Position toMinecraft(double dstX, double dstZ, double originX, double originZ) {
        return new Position(dstX - originX, dstZ - originZ);
    }
    public static final class Once {
        private final java.util.Set<String> seen = new java.util.HashSet<>();
        private final java.nio.file.Path persistenceFile;
        public Once() { persistenceFile = null; }
        public Once(java.nio.file.Path persistenceFile) {
            this.persistenceFile = persistenceFile;
            try {
                if (java.nio.file.Files.exists(persistenceFile)) seen.addAll(java.nio.file.Files.readAllLines(persistenceFile));
            } catch (java.io.IOException error) { throw new IllegalStateException("Cannot read accepted requests", error); }
        }
        public synchronized boolean accept(String id) {
            if (seen.contains(id)) return false;
            if (persistenceFile != null) {
                try {
                    if (persistenceFile.getParent() != null) java.nio.file.Files.createDirectories(persistenceFile.getParent());
                    java.nio.file.Files.writeString(persistenceFile, id + "\n", java.nio.file.StandardOpenOption.CREATE, java.nio.file.StandardOpenOption.APPEND);
                } catch (java.io.IOException error) { throw new IllegalStateException("Cannot record accepted request", error); }
            }
            seen.add(id);
            return true;
        }
    }
}
