package dev.jay.dstmc.server;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
import java.io.*;
import java.nio.file.*;
import java.util.*;
/** Durable index of real player blocks. The MC save remains authoritative on reload. */
public final class BlockStream {
    public record Delta(long from,long to,List<BlockChange> changes,boolean needs_snapshot){}
    public record Snapshot(long revision,List<BlockChange> changes){}
    private final Path path;private final int capacity;private long revision;
    private final Map<Cell,String> blocks=new HashMap<>();private final ArrayDeque<BlockChange> history=new ArrayDeque<>();
    public BlockStream(Path path,int capacity){
        this.path=path;this.capacity=capacity;
        if(Files.exists(path))try(var in=new DataInputStream(Files.newInputStream(path))){
            if(in.readInt()!=0x424c4b32)throw new IOException("bad block index");revision=in.readLong();int count=in.readInt();
            if(count<0||count>1000000)throw new IOException("block index size");
            for(int i=0;i<count;i++)blocks.put(new Cell(in.readInt(),in.readInt(),in.readInt()),in.readUTF());
        }catch(IOException e){throw new UncheckedIOException(e);}
    }
    public void set(Cell cell,String state){
        String old=blocks.getOrDefault(cell,"minecraft:air");if(old.equals(state))return;
        blocks.put(cell,state); // Keep tombstones until the actual chunk save can be reconciled.
        history.add(new BlockChange(++revision,cell,state));while(history.size()>capacity)history.removeFirst();persist();
    }
    public long revision(){return revision;}
    public Set<Cell> touched(){return Set.copyOf(blocks.keySet());}
    public Snapshot snapshot(){return new Snapshot(revision,blocks.entrySet().stream().filter(e->!e.getValue().equals("minecraft:air")).sorted(Comparator.comparingInt((Map.Entry<Cell,String> e)->e.getKey().x()).thenComparingInt(e->e.getKey().y()).thenComparingInt(e->e.getKey().z())).map(e->new BlockChange(revision,e.getKey(),e.getValue())).toList());}
    public Delta since(long from){
        boolean gap=from<0||from>revision||(from<revision&&(history.isEmpty()||from<history.getFirst().revision()-1));
        return new Delta(from,revision,gap?List.of():history.stream().filter(c->c.revision()>from).toList(),gap);
    }
    private void persist(){
        try{Files.createDirectories(path.getParent());Path temp=Files.createTempFile(path.getParent(),"blocks-",".tmp");
            try{try(var out=new DataOutputStream(Files.newOutputStream(temp))){out.writeInt(0x424c4b32);out.writeLong(revision);out.writeInt(blocks.size());for(var e:blocks.entrySet()){out.writeInt(e.getKey().x());out.writeInt(e.getKey().y());out.writeInt(e.getKey().z());out.writeUTF(e.getValue());}}Files.move(temp,path,StandardCopyOption.REPLACE_EXISTING,StandardCopyOption.ATOMIC_MOVE);}finally{Files.deleteIfExists(temp);}
        }catch(IOException e){throw new UncheckedIOException(e);}
    }
}
