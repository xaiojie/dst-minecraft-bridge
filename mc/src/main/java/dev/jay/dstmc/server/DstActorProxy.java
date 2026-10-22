package dev.jay.dstmc.server;
import dev.jay.dstmc.BridgeMod;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
import net.minecraft.world.entity.*;
import net.minecraft.world.level.Level;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.network.syncher.*;
import net.minecraft.world.phys.AABB;
import java.util.UUID;
/** A real hittable MC living body; only DST owns its health and lifetime. */
public final class DstActorProxy extends LivingEntity {
    private static final EntityDataAccessor<Float> WIDTH=SynchedEntityData.defineId(DstActorProxy.class,EntityDataSerializers.FLOAT);
    private static final EntityDataAccessor<Float> HEIGHT=SynchedEntityData.defineId(DstActorProxy.class,EntityDataSerializers.FLOAT);
    private UUID target;
    public DstActorProxy(EntityType<? extends DstActorProxy> type,Level level){super(type,level);setInvisible(true);setNoGravity(true);setSilent(true);}
    @Override protected void defineSynchedData(SynchedEntityData.Builder builder){super.defineSynchedData(builder);builder.define(WIDTH,.8f);builder.define(HEIGHT,1.8f);}
    @Override public HumanoidArm getMainArm(){return HumanoidArm.RIGHT;}
    @Override protected EntityDimensions getDefaultDimensions(net.minecraft.world.entity.Pose pose){return EntityDimensions.scalable(entityData.get(WIDTH),entityData.get(HEIGHT));}
    @Override public void onSyncedDataUpdated(EntityDataAccessor<?> key){super.onSyncedDataUpdated(key);if(key==WIDTH||key==HEIGHT)refreshDimensions();}
    @Override public boolean isPickable(){return !isRemoved();}
    @Override public boolean isPushable(){return false;}
    @Override public void tick(){/* Network position and snapshots own this stationary proxy. */}
    public void apply(Body body){
        target=body.id();Box b=body.box();entityData.set(WIDTH,(float)Math.max(b.max().x()-b.min().x(),b.max().z()-b.min().z()));entityData.set(HEIGHT,(float)(b.max().y()-b.min().y()));
        setPos((b.min().x()+b.max().x())/2,b.min().y(),(b.min().z()+b.max().z())/2);
        setBoundingBox(new AABB(b.min().x(),b.min().y(),b.min().z(),b.max().x(),b.max().y(),b.max().z()));setHealth((float)Math.max(.1,20*body.health()/body.max_health()));
    }
    @Override public boolean hurtServer(ServerLevel level,DamageSource source,float amount){var server=BridgeMod.server;return server!=null&&target!=null&&server.gameplay()!=null&&server.gameplay().proxyHit(target,source,amount);}
}
