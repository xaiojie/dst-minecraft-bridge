package dev.jay.dstmc.client.mixin;
import dev.jay.dstmc.client.BridgeClient;
import net.minecraft.client.DeltaTracker;
import net.minecraft.client.renderer.GameRenderer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.*;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
@Mixin(GameRenderer.class)
public abstract class GuiCaptureMixin {
    @Inject(method="render",at=@At(value="INVOKE",target="Lnet/minecraft/client/gui/render/GuiRenderer;render(Lcom/mojang/blaze3d/buffers/GpuBufferSlice;)V",shift=At.Shift.AFTER))
    private void afterGuiDraw(DeltaTracker delta,boolean renderLevel,CallbackInfo ci){BridgeClient.CAPTURE.captureHud();}
}
