package dev.jay.dstmc.client.mixin;
import com.mojang.blaze3d.pipeline.RenderTarget;
import dev.jay.dstmc.client.PassthroughWindow;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.*;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
@Mixin(RenderTarget.class)
public abstract class WindowPresentMixin {
    @Inject(method="blitToScreen",at=@At("HEAD"),cancellable=true)
    private void suppressDuplicateImage(CallbackInfo ci){if(PassthroughWindow.active()){PassthroughWindow.clearWindow();ci.cancel();}}
}
