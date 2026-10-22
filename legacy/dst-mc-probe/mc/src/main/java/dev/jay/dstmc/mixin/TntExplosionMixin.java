package dev.jay.dstmc.mixin;

import dev.jay.dstmc.DstMcProbe;
import net.minecraft.world.entity.item.PrimedTnt;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Inject;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;

@Mixin(PrimedTnt.class)
public abstract class TntExplosionMixin {
    @Inject(method = "explode", at = @At("TAIL"))
    private void dstmc$recordActualExplosion(CallbackInfo callback) {
        DstMcProbe.afterRealExplosion((PrimedTnt) (Object) this);
    }
}
