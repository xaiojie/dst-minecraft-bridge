package dev.jay.dstmc.mixin;

import dev.jay.dstmc.DstMcProbe;
import net.minecraft.client.Minecraft;
import net.minecraft.client.server.IntegratedServer;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.At;
import org.spongepowered.asm.mixin.injection.Redirect;

/** The local test world must keep simulating while the other game drives it. */
@Mixin(IntegratedServer.class)
public abstract class IntegratedServerPauseMixin {
    @Redirect(method = "tickServer", at = @At(value = "INVOKE", target = "Lnet/minecraft/client/Minecraft;isPaused()Z"))
    private boolean dstmc$continueWhileDstIsConnected(Minecraft client) {
        return !DstMcProbe.hasLiveDstConnection() && client.isPaused();
    }
}
