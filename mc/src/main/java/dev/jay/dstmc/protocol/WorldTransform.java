package dev.jay.dstmc.protocol;
import java.util.Objects;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
/** Unit scale and fixed paired origins. Only the two explicitly calibrated bases are supported. */
public record WorldTransform(Vec3 dstOrigin, Vec3 mcOrigin, AxisMode axisMode) {
    public enum AxisMode { IDENTITY(1), REFLECT_X(-1); final int x; AxisMode(int x){this.x=x;} }
    /** Compatibility API for the original identity calibration and golden fixture. */
    public WorldTransform(Vec3 dstOrigin, Vec3 mcOrigin) { this(dstOrigin,mcOrigin,AxisMode.IDENTITY); }
    public WorldTransform { Objects.requireNonNull(dstOrigin); Objects.requireNonNull(mcOrigin); Objects.requireNonNull(axisMode); }
    public Vec3 toMc(Vec3 p) { return new Vec3(axisMode.x*(p.x()-dstOrigin.x())+mcOrigin.x(), p.y()-dstOrigin.y()+mcOrigin.y(), p.z()-dstOrigin.z()+mcOrigin.z()); }
    public Vec3 toDst(Vec3 p) { return new Vec3(axisMode.x*(p.x()-mcOrigin.x())+dstOrigin.x(), p.y()-mcOrigin.y()+dstOrigin.y(), p.z()-mcOrigin.z()+dstOrigin.z()); }
    public Vec3 directionToMc(Vec3 v) { return new Vec3(axisMode.x*v.x(),v.y(),v.z()); }
    public Vec3 directionToDst(Vec3 v) { return directionToMc(v); }
    public double[] axes() { return new double[]{axisMode.x,0,0,0,1,0,0,0,1}; }
}
