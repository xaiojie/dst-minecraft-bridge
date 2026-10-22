package dev.jay.dstmc.server;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
import java.util.*;
public final class ActorRegistry {
    private ActorSnapshot snapshot=new ActorSnapshot(0,List.of());private long observed=Long.MIN_VALUE;
    public boolean update(ActorSnapshot value,long now){
        if(value.revision()<=snapshot.revision())return false;
        Set<UUID> ids=new HashSet<>();for(Body b:value.bodies()){
            if(!ids.add(b.id())||!Double.isFinite(b.health())||!Double.isFinite(b.max_health())||b.health()<0||b.max_health()<=0||b.health()>b.max_health())throw new IllegalArgumentException("invalid actor");
        }
        snapshot=value;observed=now;return true;
    }
    public boolean fresh(long now){return observed!=Long.MIN_VALUE&&now>=observed&&now-observed<=250;}
    public ActorSnapshot snapshot(){return snapshot;}
    public Optional<Body> find(UUID id){return snapshot.bodies().stream().filter(b->b.id().equals(id)).findFirst();}
    public void clear(){snapshot=new ActorSnapshot(0,List.of());observed=Long.MIN_VALUE;}
}
