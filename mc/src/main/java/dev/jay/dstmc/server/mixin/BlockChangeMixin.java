package dev.jay.dstmc.server.mixin;
import dev.jay.dstmc.BridgeMod;
import dev.jay.dstmc.server.BridgeServer;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.core.BlockPos;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.*;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
@Mixin(Level.class)
public abstract class BlockChangeMixin {
    @Inject(method="setBlock(Lnet/minecraft/core/BlockPos;Lnet/minecraft/world/level/block/state/BlockState;II)Z",at=@At("RETURN"))
    private void changed(BlockPos pos,BlockState state,int flags,int depth,CallbackInfoReturnable<Boolean> ci){
        var level=(Level)(Object)this;var bridge=BridgeMod.server;
        if(ci.getReturnValueZ()&&!level.isClientSide()&&level.dimension().equals(BridgeServer.STAGE)&&bridge!=null&&bridge.gameplay()!=null)bridge.gameplay().blockChanged(pos,state);
    }
}
