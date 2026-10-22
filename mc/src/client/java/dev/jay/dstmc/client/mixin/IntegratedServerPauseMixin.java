package dev.jay.dstmc.client.mixin;
import dev.jay.dstmc.BridgeMod;
import net.minecraft.client.server.IntegratedServer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.*;
/** Keep real server TNT, actors and queues ticking while MC is unfocused. */
@Mixin(IntegratedServer.class)
public abstract class IntegratedServerPauseMixin {
    @Redirect(method="tickServer",at=@At(value="INVOKE",target="Lnet/minecraft/client/Minecraft;isPaused()Z"))
    private boolean bridgeUnpaused(net.minecraft.client.Minecraft client){return BridgeMod.server!=null&&BridgeMod.server.active()!=null?false:client.isPaused();}
}
