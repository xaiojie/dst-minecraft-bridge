package dev.jay.dstmc.server;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.phys.shapes.*;
import java.util.*;
/** Complete spatial snapshots: disappearing cells are removed, never overwrite player blocks. */
public final class TerrainProxyStore implements AutoCloseable {
    private final java.nio.file.Path journal;
    private final ServerLevel level;private Set<BlockPos> occupied=new HashSet<>();private final Set<BlockPos> touched=new HashSet<>();private long revision=-1;
    public TerrainProxyStore(ServerLevel level,java.nio.file.Path journal){
        this.level=level;this.journal=journal;
        if(java.nio.file.Files.exists(journal))try{var cells=new com.google.gson.Gson().fromJson(java.nio.file.Files.readString(journal),Cell[].class);for(Cell c:cells)touched.add(new BlockPos(c.x(),c.y(),c.z()));occupied.addAll(touched);close();}catch(java.io.IOException e){throw new java.io.UncheckedIOException(e);}
    }
    private void persist(){try{java.nio.file.Files.createDirectories(journal.getParent());var tmp=java.nio.file.Files.createTempFile(journal.getParent(),"terrain-",".tmp");try{java.nio.file.Files.writeString(tmp,new com.google.gson.Gson().toJson(touched.stream().map(p->new Cell(p.getX(),p.getY(),p.getZ())).toList()));java.nio.file.Files.move(tmp,journal,java.nio.file.StandardCopyOption.ATOMIC_MOVE,java.nio.file.StandardCopyOption.REPLACE_EXISTING);}finally{java.nio.file.Files.deleteIfExists(tmp);}}catch(java.io.IOException e){throw new java.io.UncheckedIOException(e);}}

    public List<Cell> apply(long version,List<TerrainCell> cells){
        if(version<=revision)return List.of();
        Map<BlockPos,VoxelShape> wanted=new HashMap<>();List<Cell> conflicts=new ArrayList<>();
        for(TerrainCell c:cells){var p=new BlockPos(c.cell().x(),c.cell().y(),c.cell().z());VoxelShape shape=Shapes.empty();
            for(Box b:c.boxes())shape=Shapes.or(shape,Shapes.box(b.min().x(),b.min().y(),b.min().z(),b.max().x(),b.max().y(),b.max().z()));wanted.put(p,shape);}
        var previous=new HashSet<>(occupied);touched.addAll(wanted.keySet());persist();
        for(BlockPos p:previous)if(!wanted.containsKey(p)){TerrainProxyBlock.SHAPES.remove(p);if(level.getBlockState(p).is(BridgeRegistries.TERRAIN))level.setBlockAndUpdate(p,Blocks.AIR.defaultBlockState());}
        var next=new HashSet<BlockPos>();
        for(var e:wanted.entrySet()){var state=level.getBlockState(e.getKey());if(!state.isAir()&&!state.is(BridgeRegistries.TERRAIN)&&!state.is(Blocks.BARRIER)){conflicts.add(new Cell(e.getKey().getX(),e.getKey().getY(),e.getKey().getZ()));continue;}
            TerrainProxyBlock.SHAPES.put(e.getKey(),e.getValue());if(!state.is(BridgeRegistries.TERRAIN))level.setBlockAndUpdate(e.getKey(),BridgeRegistries.TERRAIN.defaultBlockState());next.add(e.getKey());}
        occupied=next;revision=version;persist();return conflicts;
    }
    public int size(){return occupied.size();}
    public void close(){for(BlockPos p:occupied)if(level.getBlockState(p).is(BridgeRegistries.TERRAIN))level.setBlockAndUpdate(p,Blocks.AIR.defaultBlockState());occupied.clear();TerrainProxyBlock.SHAPES.clear();revision=-1;persist();}
}
