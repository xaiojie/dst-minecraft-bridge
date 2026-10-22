package dev.jay.dstmc.client.mixin;
import dev.jay.dstmc.client.BridgeClient;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
import com.mojang.blaze3d.buffers.GpuBufferSlice;
import com.mojang.blaze3d.resource.GraphicsResourceAllocator;
import net.minecraft.client.Camera;
import net.minecraft.client.DeltaTracker;
import net.minecraft.client.renderer.LevelRenderer;
import org.joml.*;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.*;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
@Mixin(LevelRenderer.class)
public abstract class BridgeSceneMixin {
    @Inject(method="renderLevel",at=@At("HEAD"))
    private void captureMatrices(GraphicsResourceAllocator allocator,DeltaTracker delta,boolean outline,Camera camera,Matrix4f rotation,Matrix4f projection,Matrix4f culling,GpuBufferSlice fog,Vector4f fogColor,boolean sky,CallbackInfo ci){
        BridgeClient.renderPose=null;
        if(!BridgeClient.active())return;
        var eye=camera.position();var forward=new Vector3f(0,0,-1).rotate(camera.rotation());var up=new Vector3f(0,1,0).rotate(camera.rotation());
        var view=new Matrix4f(rotation).translate((float)-eye.x,(float)-eye.y,(float)-eye.z);
        BridgeClient.renderPose=new Pose(Space.MC,new Vec3(eye.x,eye.y,eye.z),new Vec3(forward.x,forward.y,forward.z),new Vec3(up.x,up.y,up.z),view.get(new float[16]),projection.get(new float[16]));
        fogColor.set(0,0,0,0); // Actual world clear is transparent black, preserving premultiplied blending.
    }
    @Inject(method={"addSkyPass","addCloudsPass"},at=@At("HEAD"),cancellable=true)
    private void removeBackground(CallbackInfo ci){if(BridgeClient.active())ci.cancel();}
}
