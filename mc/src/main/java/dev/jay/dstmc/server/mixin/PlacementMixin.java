package dev.jay.dstmc.server.mixin;
import dev.jay.dstmc.BridgeMod;
import dev.jay.dstmc.server.BridgeServer;
import net.minecraft.world.item.BlockItem;
import net.minecraft.world.item.context.BlockPlaceContext;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.network.chat.Component;
import org.spongepowered.asm.mixin.Mixin;
import org.spongepowered.asm.mixin.injection.*;
import org.spongepowered.asm.mixin.injection.callback.CallbackInfoReturnable;
@Mixin(BlockItem.class)
public abstract class PlacementMixin {
    @Inject(method="placeBlock",at=@At("HEAD"),cancellable=true)
    private void guard(BlockPlaceContext context,BlockState state,CallbackInfoReturnable<Boolean> ci){
        var bridge=BridgeMod.server;
        if(!context.getLevel().isClientSide()&&context.getLevel().dimension().equals(BridgeServer.STAGE)&&bridge!=null&&bridge.gameplay()!=null){
            String reason=bridge.gameplay().placement(context.getClickedPos(),state);
            if(!reason.isEmpty()){if(context.getPlayer()!=null)context.getPlayer().displayClientMessage(Component.literal(reason),true);ci.setReturnValue(false);}
        }
    }
}
