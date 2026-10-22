package dev.jay.dstmc.server.mixin;
import dev.jay.dstmc.BridgeMod;
import net.minecraft.world.entity.item.PrimedTnt;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.*;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfo;
@Mixin(PrimedTnt.class)
public abstract class TntExplosionMixin {
    @Inject(method="tick",at=@At("HEAD"))
    private void beforeTick(CallbackInfo ci){var bridge=BridgeMod.server;if(bridge!=null&&bridge.gameplay()!=null)bridge.gameplay().trackTnt((PrimedTnt)(Object)this);}
    @Inject(method="explode",at=@At(value="INVOKE",target="Lnet/minecraft/world/level/Level;explode(Lnet/minecraft/world/entity/Entity;Lnet/minecraft/world/damagesource/DamageSource;Lnet/minecraft/world/level/ExplosionDamageCalculator;DDDFZLnet/minecraft/world/level/Level$ExplosionInteraction;)V",shift=At.Shift.AFTER))
    private void exploded(CallbackInfo ci){var bridge=BridgeMod.server;if(bridge!=null&&bridge.gameplay()!=null)bridge.gameplay().exploded((PrimedTnt)(Object)this);}
}
