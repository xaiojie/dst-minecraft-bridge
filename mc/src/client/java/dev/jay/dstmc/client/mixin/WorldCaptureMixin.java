package dev.jay.dstmc.client.mixin;
import dev.jay.dstmc.client.BridgeClient;
import com.mojang.blaze3d.vertex.PoseStack;
import net.minecraft.client.DeltaTracker;
import net.minecraft.client.renderer.GameRenderer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.*;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
@Mixin(GameRenderer.class)
public abstract class WorldCaptureMixin {
    @Inject(method="renderLevel",at=@At(value="INVOKE",target="Lcom/mojang/blaze3d/systems/CommandEncoder;clearDepthTexture(Lcom/mojang/blaze3d/textures/GpuTexture;D)V",shift=At.Shift.BEFORE))
    private void beforeHandDepthClear(DeltaTracker delta,CallbackInfo ci){BridgeClient.CAPTURE.captureWorld(BridgeClient.renderPose);}
    @Inject(method="bobHurt",at=@At("HEAD"),cancellable=true)
    private void disableHurtProjection(PoseStack stack,float tick,CallbackInfo ci){if(BridgeClient.active())ci.cancel();}
}
