package dev.jay.dstmc.protocol;
import java.util.Objects;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
/** First calibration: one MC block per DST unit, identity axes, fixed origins. */
public record WorldTransform(Vec3 dstOrigin, Vec3 mcOrigin) {
    public WorldTransform { Objects.requireNonNull(dstOrigin); Objects.requireNonNull(mcOrigin); }
    public Vec3 toMc(Vec3 p) { return new Vec3(p.x()-dstOrigin.x()+mcOrigin.x(), p.y()-dstOrigin.y()+mcOrigin.y(), p.z()-dstOrigin.z()+mcOrigin.z()); }
    public Vec3 toDst(Vec3 p) { return new Vec3(p.x()-mcOrigin.x()+dstOrigin.x(), p.y()-mcOrigin.y()+dstOrigin.y(), p.z()-mcOrigin.z()+dstOrigin.z()); }
    public double[] axes() { return new double[]{1,0,0,0,1,0,0,0,1}; }
}
