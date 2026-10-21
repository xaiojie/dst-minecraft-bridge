package dev.jay.dstmc.protocol;
import java.util.*;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
public final class BridgeTypes {
    private BridgeTypes() {}
    public static String canonicalPair(PairKey p) {
        return "{\"dst_world\":" + json(p.dst_world().toString()) + ",\"dst_shard\":" + json(p.dst_shard())
            + ",\"mc_world\":" + json(p.mc_world().toString()) + ",\"mc_dimension\":" + json(p.mc_dimension())
            + ",\"region\":" + json(p.region()) + "}";
    }
    public static byte[] pairHash(PairKey p) { return sha256(canonicalPair(p)); }
    public static byte[] sha256(String text) {
        try { return MessageDigest.getInstance("SHA-256").digest(text.getBytes(StandardCharsets.UTF_8)); }
        catch (java.security.NoSuchAlgorithmException impossible) { throw new AssertionError(impossible); }
    }
    /** Canonical JSON subset used for object payload fingerprints: sorted keys, finite numbers. */
    public static String json(Object value) {
        if (value == null) return "null";
        if (value instanceof String text) {
            StringBuilder b = new StringBuilder("\"");
            for (int i=0;i<text.length();i++) {
                char c=text.charAt(i);
                if (Character.isSurrogate(c)) {
                    if (!Character.isHighSurrogate(c) || i+1>=text.length() || !Character.isLowSurrogate(text.charAt(i+1)))
                        throw new IllegalArgumentException("unpaired JSON surrogate");
                    b.append(c).append(text.charAt(++i));
                } else if (c == '\\' || c == '"') b.append('\\').append(c);
                else if (c < 32) b.append(String.format(Locale.ROOT,"\\u%04x",(int)c));
                else b.append(c);
            }
            return b.append('"').toString();
        }
        if (value instanceof Boolean) return value.toString();
        if (value instanceof Number n) {
            if (!Double.isFinite(n.doubleValue())) throw new IllegalArgumentException("non-finite JSON number");
            return new java.math.BigDecimal(n.toString()).stripTrailingZeros().toPlainString();
        }
        if (value instanceof Map<?,?> map) {
            var keys = new TreeMap<String,Object>();
            map.forEach((k,v) -> { if (!(k instanceof String)) throw new IllegalArgumentException("JSON key must be string"); keys.put((String)k,v); });
            var entries = new ArrayList<String>(); keys.forEach((k,v)->entries.add(json(k)+":"+json(v)));
            return "{"+String.join(",",entries)+"}";
        }
        if (value instanceof List<?> list) return "["+String.join(",",list.stream().map(BridgeTypes::json).toList())+"]";
        throw new IllegalArgumentException("unsupported JSON value: " + value.getClass());
    }
    public static void finite(double... values) { for (double v:values) if (!Double.isFinite(v)) throw new IllegalArgumentException("non-finite value"); }
    public static void matrix(float[] matrix) { if (matrix.length!=16) throw new IllegalArgumentException("expected 4x4 matrix"); for(float v:matrix) finite(v); }

    public record Vec3(double x, double y, double z) { public Vec3 { finite(x,y,z); } }
    public record Box(Vec3 min, Vec3 max) { public Box { Objects.requireNonNull(min); Objects.requireNonNull(max); if(min.x()>max.x() || min.y()>max.y() || min.z()>max.z()) throw new IllegalArgumentException("inverted box"); } }
    public record Cell(int x, int y, int z) {}
    public record PairKey(UUID dst_world, String dst_shard, UUID mc_world, String mc_dimension, String region) {
        public PairKey { Objects.requireNonNull(dst_world); Objects.requireNonNull(mc_world); for (String s:List.of(dst_shard,mc_dimension,region)) if(s.isEmpty()) throw new IllegalArgumentException("empty pair field"); }
    }
    public enum Space { MC, DST }
    public record Pose(Space space, Vec3 position, Vec3 forward, Vec3 up, float[] view, float[] projection) {
        public Pose { Objects.requireNonNull(space); Objects.requireNonNull(position); Objects.requireNonNull(forward); Objects.requireNonNull(up); matrix(view); matrix(projection); view=view.clone(); projection=projection.clone(); }
        @Override public float[] view() { return view.clone(); }
        @Override public float[] projection() { return projection.clone(); }
    }
    public record FrameKey(PairKey pair, UUID epoch, long id) { public FrameKey { Objects.requireNonNull(pair); Objects.requireNonNull(epoch); } }
    public record FrameLease(FrameKey key, Pose pose, int width, int height) {}
    public record Body(UUID id, Box box, double health, double max_health, long revision) {}
    public record BlockChange(long revision, Cell cell, String state) {}
    public record TerrainCell(Cell cell, List<Box> boxes) { public TerrainCell { boxes=List.copyOf(boxes); } }
    public record ActorSnapshot(long revision, List<Body> bodies) { public ActorSnapshot { bodies=List.copyOf(bodies); } }
    public record Command(UUID id, PairKey pair, UUID epoch, String kind, Map<String,Object> payload) {
        public Command { Objects.requireNonNull(id); Objects.requireNonNull(pair); Objects.requireNonNull(epoch); if(kind==null || kind.isEmpty()) throw new IllegalArgumentException("empty command kind"); payload=freezeMap(payload); json(payload); }
    }
    private static Map<String,Object> freezeMap(Map<String,Object> map) {
        var copy=new TreeMap<String,Object>(); map.forEach((k,v)->copy.put(Objects.requireNonNull(k), freeze(v))); return Collections.unmodifiableMap(copy);
    }
    private static Object freeze(Object value) {
        if(value instanceof Map<?,?> map) { var copy=new TreeMap<String,Object>(); map.forEach((k,v)->{ if(!(k instanceof String)) throw new IllegalArgumentException("JSON key"); copy.put((String)k,freeze(v)); }); return Collections.unmodifiableMap(copy); }
        if(value instanceof List<?> list) return Collections.unmodifiableList(list.stream().map(BridgeTypes::freeze).toList());
        return value;
    }
    public enum Status { PENDING, APPLIED, REJECTED, UNRESOLVED }
    public record CommandResult(UUID id, Status status, String reason) { public CommandResult { Objects.requireNonNull(id); Objects.requireNonNull(status); Objects.requireNonNull(reason); } }
    public record DamageEvent(UUID id, PairKey pair, UUID epoch, Space source, UUID target, Vec3 position, double amount, String kind) {}
}
