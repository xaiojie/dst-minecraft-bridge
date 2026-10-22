package dev.jay.dstmc.server;
import java.util.*;
import java.util.function.*;
/** One dimension per manager; never undo a pre-existing forced chunk. */
public final class ChunkLeaseManager implements AutoCloseable {
    private record Entry(boolean owned,Set<UUID> owners){}
    private final Map<Long,Entry> chunks=new HashMap<>();private final LongPredicate forced;private final BiConsumer<Long,Boolean> force;
    public ChunkLeaseManager(LongPredicate forced,BiConsumer<Long,Boolean> force){this.forced=forced;this.force=force;}
    public void acquire(long chunk,UUID owner){var e=chunks.computeIfAbsent(chunk,k->{boolean owned=!forced.test(k);if(owned)force.accept(k,true);return new Entry(owned,new HashSet<>());});e.owners.add(owner);}
    public int count(long chunk){var e=chunks.get(chunk);return e==null?0:e.owners.size();}
    public void release(UUID owner){var it=chunks.entrySet().iterator();while(it.hasNext()){var e=it.next();e.getValue().owners.remove(owner);if(e.getValue().owners.isEmpty()){if(e.getValue().owned)force.accept(e.getKey(),false);it.remove();}}}
    public void close(){for(var e:chunks.entrySet())if(e.getValue().owned)force.accept(e.getKey(),false);chunks.clear();}
}
