package dev.jay.dstmc.server;
import net.minecraft.core.Registry;
import net.minecraft.core.registries.*;
import net.minecraft.resources.*;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockBehaviour;
import net.minecraft.world.entity.*;
import net.fabricmc.fabric.api.object.builder.v1.entity.FabricDefaultAttributeRegistry;
public final class BridgeRegistries {
    public static TerrainProxyBlock TERRAIN;
    public static EntityType<DstActorProxy> ACTOR;
    public static void initialize(){
        var blockId=ResourceKey.create(Registries.BLOCK,Identifier.fromNamespaceAndPath("dst_mc_bridge","terrain_proxy"));
        TERRAIN=Registry.register(BuiltInRegistries.BLOCK,blockId,new TerrainProxyBlock(BlockBehaviour.Properties.of().setId(blockId).strength(-1,3600000).noLootTable().noOcclusion().dynamicShape().isSuffocating((s,l,p)->false).isViewBlocking((s,l,p)->false)));
        var actorId=ResourceKey.create(Registries.ENTITY_TYPE,Identifier.fromNamespaceAndPath("dst_mc_bridge","actor_proxy"));
        ACTOR=Registry.register(BuiltInRegistries.ENTITY_TYPE,actorId,EntityType.Builder.<DstActorProxy>of(DstActorProxy::new,MobCategory.MISC).sized(.8f,1.8f).noSave().noSummon().build(actorId));
        FabricDefaultAttributeRegistry.register(ACTOR,LivingEntity.createLivingAttributes());
    }
}
