package dev.jay.dstmc.server;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.*;
import net.minecraft.world.level.BlockGetter;
import net.minecraft.core.BlockPos;
import net.minecraft.world.phys.shapes.*;
import java.util.concurrent.ConcurrentHashMap;
/** Local integrated client/server share immutable shape values. Never usable in remote multiplayer. */
public final class TerrainProxyBlock extends Block {
    static final ConcurrentHashMap<BlockPos,VoxelShape> SHAPES=new ConcurrentHashMap<>();
    public TerrainProxyBlock(Properties properties){super(properties);}
    @Override protected RenderShape getRenderShape(BlockState state){return RenderShape.INVISIBLE;}
    @Override protected VoxelShape getShape(BlockState state,BlockGetter level,BlockPos pos,CollisionContext context){return SHAPES.getOrDefault(pos,Shapes.empty());}
    @Override protected VoxelShape getCollisionShape(BlockState state,BlockGetter level,BlockPos pos,CollisionContext context){return getShape(state,level,pos,context);}
}
