package dev.jay.dstmc.server;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
import com.google.gson.*;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.*;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.BuiltInRegistries;
import net.minecraft.world.level.block.*;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraft.world.entity.*;
import net.minecraft.world.entity.item.PrimedTnt;
import net.minecraft.world.entity.projectile.Projectile;
import net.minecraft.world.damagesource.DamageSource;
import net.minecraft.tags.DamageTypeTags;
import java.nio.file.*;
import java.util.*;
/** Server-thread adapter. Source/target ownership is enforced before any game mutation. */
public final class GameplayRuntime implements AutoCloseable {
    private static final Gson JSON=new Gson();
    private final MinecraftServer game;private final ServerLevel level;private final Path directory;
    private final BlockStream blocks;private final ActorRegistry actors=new ActorRegistry();private final TerrainProxyStore terrain;
    private final Map<UUID,DstActorProxy> proxies=new HashMap<>();private final ChunkLeaseManager chunks;
    private final Map<UUID,WorldExchange.HandshakeResult> tntSessions=new HashMap<>();
    private WorldExchange.HandshakeResult session;private DamageBridge damage;private EventOutbox outbox;private long lastSeen;private long snapshotSequence=-1;
    private final SnapshotWindow snapshotWindow=new SnapshotWindow();
    private static long monotonicMillis(){return System.nanoTime()/1_000_000L;}
    private List<Cell> terrainConflicts=List.of();private boolean updating;private boolean inputMC=true;private boolean terrainReady;
    private final Map<UUID,Vec3> frozen=new HashMap<>();
    public GameplayRuntime(MinecraftServer game,Path save){
        this.game=game;level=Objects.requireNonNull(game.getLevel(BridgeServer.STAGE));directory=save.resolve("dst-mc-bridge");
        blocks=new BlockStream(directory.resolve("blocks.bin"),8192);terrain=new TerrainProxyStore(level,directory.resolve("terrain-cells.json"));
        chunks=new ChunkLeaseManager(k->level.getForceLoadedChunks().contains(k),(k,v)->level.setChunkForced((int)(long)k,(int)(k>>32),v));
        // Reconcile the index against the actual MC chunk save after a crash.
        for(var c:blocks.touched())blockChanged(new BlockPos(c.x(),c.y(),c.z()),level.getBlockState(new BlockPos(c.x(),c.y(),c.z())));
        // Remove the old prototype's temporary barrier floor once in this copied save.
        Path migrated=directory.resolve("terrain-v2.migrated");
        if(!Files.exists(migrated)){for(int x=-16;x<=16;x++)for(int z=-16;z<=16;z++){var p=new BlockPos(x,63,z);if(level.getBlockState(p).is(Blocks.BARRIER))level.setBlockAndUpdate(p,Blocks.AIR.defaultBlockState());}try{Files.writeString(migrated,"native ground sampling\n");}catch(java.io.IOException e){throw new java.io.UncheckedIOException(e);}}
    }
    public void bind(WorldExchange.HandshakeResult value){
        if(session!=null&&session.epoch().equals(value.epoch()))return;
        disconnect();session=value;damage=new DamageBridge(directory.resolve("incoming-damage"),value.pair(),value.epoch());outbox=new EventOutbox(directory.resolve("outgoing.json"));snapshotSequence=-1;lastSeen=System.currentTimeMillis();inputMC=true;
    }
    public boolean connected(){return session!=null&&System.currentTimeMillis()-lastSeen<2500;}
    public boolean controlsPlayer(){return connected()&&inputMC&&terrainReady&&actors.fresh(monotonicMillis());}
    public ActorRegistry actors(){return actors;}
    public void tick(){
        if(!controlsPlayer()){
            for(var p:game.getPlayerList().getPlayers())if(p.level()==level){var at=frozen.computeIfAbsent(p.getUUID(),id->new Vec3(p.getX(),p.getY(),p.getZ()));p.setDeltaMovement(net.minecraft.world.phys.Vec3.ZERO);p.teleportTo(level,at.x(),at.y(),at.z(),Set.of(),p.getYRot(),p.getXRot(),false);}
        }else frozen.clear();
        if(!connected()){if(session!=null)disconnect();return;}
        if(!actors.fresh(monotonicMillis())){for(var e:proxies.values())e.discard();proxies.clear();}
        Set<UUID> live=new HashSet<>();
        for(Entity e:level.getAllEntities())if(e instanceof PrimedTnt){live.add(e.getUUID());trackTnt((PrimedTnt)e);}
        for(UUID id:new HashSet<>(tntSessions.keySet()))if(!live.contains(id)){chunks.release(id);tntSessions.remove(id);}
    }
    public void blockChanged(BlockPos pos,BlockState state){
        if(updating||state.is(BridgeRegistries.TERRAIN)||state.is(Blocks.BARRIER))return;
        Cell c=new Cell(pos.getX(),pos.getY(),pos.getZ());
        // Collision/full-cube placement is the supported first-version contract.
        String id=state.isAir()||!Block.isShapeFullBlock(state.getCollisionShape(level,pos))?"minecraft:air":BuiltInRegistries.BLOCK.getKey(state.getBlock()).toString();
        blocks.set(c,id);
    }
    public String placement(BlockPos pos,BlockState state){
        if(!controlsPlayer())return "联动尚未连接或控制权在饥荒";
        if(!Block.isShapeFullBlock(state.getCollisionShape(level,pos)))return "当前仅支持完整方块";
        return PlacementGuard.reason(new Cell(pos.getX(),pos.getY(),pos.getZ()),actors,monotonicMillis());
    }
    private ServerPlayer player(){return game.getPlayerList().getPlayers().stream().filter(p->p.level()==level).findFirst().orElse(null);}
    private void syncActors(ActorSnapshot snapshot,long capturedAfter){
        if(!actors.update(snapshot,capturedAfter))return;Set<UUID> live=new HashSet<>();
        for(Body b:snapshot.bodies())if(b.health()>0){live.add(b.id());var proxy=proxies.get(b.id());if(proxy==null){proxy=new DstActorProxy(BridgeRegistries.ACTOR,level);proxy.apply(b);if(!level.addFreshEntity(proxy))continue;proxies.put(b.id(),proxy);}else proxy.apply(b);}
        proxies.entrySet().removeIf(e->{if(live.contains(e.getKey()))return false;e.getValue().discard();return true;});
    }
    public Map<String,Object> exchange(JsonObject request){
        if(session==null)throw new IllegalArgumentException("SESSION_EXPIRED");
        long clientBlocks=-1;
        for(var item:request.getAsJsonArray("commands")){
            JsonObject command=item.getAsJsonObject();if(!command.get("kind").getAsString().equals("world_snapshot"))throw new IllegalArgumentException("unknown command");
            JsonObject payload=command.getAsJsonObject("payload");long sequence=payload.get("sequence").getAsLong();
            clientBlocks=payload.get("block_revision").getAsLong();
            if(sequence<=snapshotSequence)continue;
            ActorSnapshot snapshot=JSON.fromJson(payload.get("actors"),ActorSnapshot.class);
            if(snapshot.bodies().size()>2048)throw new IllegalArgumentException("too many actors");
            // Validate every snapshot before publishing it to placement/proxies.
            for(Body b:snapshot.bodies()){var min=b.box().min();var max=b.box().max();if(max.x()-min.x()>32||max.y()-min.y()>64||max.z()-min.z()>32)throw new IllegalArgumentException("actor bounds");}
            String ticket=payload.has("snapshot_ticket")&&!payload.get("snapshot_ticket").isJsonNull()?payload.get("snapshot_ticket").getAsString():null;
            if(snapshotWindow.accepts(ticket,monotonicMillis())){
                syncActors(snapshot,snapshotWindow.issuedAt());
                if(payload.has("terrain")&&!payload.get("terrain").isJsonNull())applyTerrain(payload.getAsJsonObject("terrain"));
            }else{
                actors.clear();for(var proxy:proxies.values())proxy.discard();proxies.clear();
            }
            if(payload.has("results"))outbox.acknowledge(payload.getAsJsonArray("results"));
            inputMC=!payload.has("input_owner")||payload.get("input_owner").getAsString().equals("MC");snapshotSequence=sequence;
        }
        lastSeen=System.currentTimeMillis();List<CommandResult> results=new ArrayList<>();
        for(var item:request.getAsJsonArray("damage_events"))results.add(damage.apply(JSON.fromJson(item,DamageEvent.class),Space.DST,this::damagePlayer));
        var p=player();Map<String,Object> result=new LinkedHashMap<>();var delta=blocks.since(clientBlocks);
        result.put("snapshot_ticket",snapshotWindow.issue(monotonicMillis()));result.put("results",results);result.put("blocks",Map.of("revision",blocks.revision(),"from",clientBlocks,"full",delta.needs_snapshot(),"changes",delta.needs_snapshot()?blocks.snapshot().changes():delta.changes()));
        result.put("player",p==null?null:Map.of("id",p.getUUID().toString(),"position",session.transform().toDst(new Vec3(p.getX(),p.getY(),p.getZ())),"health",p.getHealth(),"max_health",p.getMaxHealth(),"alive",p.isAlive()));
        result.put("events",outbox.values());result.put("terrain_conflicts",terrainConflicts);result.put("input_owner",inputMC?"MC":"DST");return result;
    }
    private void applyTerrain(JsonObject payload){
        long revision=payload.get("revision").getAsLong();var cells=new HashMap<Cell,List<Box>>();
        JsonArray ground=payload.getAsJsonArray("ground");if(ground.size()>1024)throw new IllegalArgumentException("terrain rows limit");
        for(var item:ground){var row=item.getAsJsonObject();int x=row.get("x").getAsInt(),y=row.get("y").getAsInt(),z=row.get("z").getAsInt(),length=row.get("length").getAsInt();if(length<1||length>65)throw new IllegalArgumentException("terrain length");for(int n=0;n<length;n++)cells.put(new Cell(x+n,y,z),new ArrayList<>(List.of(new Box(new Vec3(0,0,0),new Vec3(1,1,1)))));}
        JsonArray obstacles=payload.getAsJsonArray("obstacles");if(obstacles.size()>2048)throw new IllegalArgumentException("terrain obstacle limit");
        for(var item:obstacles){Box b=JSON.fromJson(item,Box.class);int minX=(int)Math.floor(b.min().x()),maxX=(int)Math.ceil(b.max().x()),minY=(int)Math.floor(b.min().y()),maxY=(int)Math.ceil(b.max().y()),minZ=(int)Math.floor(b.min().z()),maxZ=(int)Math.ceil(b.max().z());
            if((long)(maxX-minX)*(maxY-minY)*(maxZ-minZ)>4096)throw new IllegalArgumentException("oversized obstacle");
            for(int x=minX;x<maxX;x++)for(int y=minY;y<maxY;y++)for(int z=minZ;z<maxZ;z++)cells.computeIfAbsent(new Cell(x,y,z),k->new ArrayList<>()).add(new Box(new Vec3(Math.max(0,b.min().x()-x),Math.max(0,b.min().y()-y),Math.max(0,b.min().z()-z)),new Vec3(Math.min(1,b.max().x()-x),Math.min(1,b.max().y()-y),Math.min(1,b.max().z()-z))));
        }
        if(cells.size()>20000)throw new IllegalArgumentException("terrain cell limit");
        updating=true;try{terrainConflicts=terrain.apply(revision,cells.entrySet().stream().map(e->new TerrainCell(e.getKey(),e.getValue())).toList());terrainReady=true;}finally{updating=false;}
    }
    private String damagePlayer(DamageEvent e){
        var p=player();if(p==null||!e.target().equals(p.getUUID())||!controlsPlayer())return "player unavailable";
        Vec3 hit=session.transform().toMc(e.position());double dx=p.getX()-hit.x(),dy=p.getY()-hit.y(),dz=p.getZ()-hit.z();
        if(dx*dx+dy*dy+dz*dz>16)return "native hit position out of range";
        p.hurtServer(level,p.damageSources().generic(),(float)(e.amount()/10));return "";
    }
    public boolean proxyHit(UUID target,DamageSource source,float amount){
        if(!controlsPlayer()||!actors.fresh(monotonicMillis())||!Float.isFinite(amount)||amount<=0)return false;
        var body=actors.find(target);if(body.isEmpty()||body.get().health()<=0)return false;
        var direct=source.getDirectEntity();var attacker=source.getEntity();
        boolean explosion=source.is(DamageTypeTags.IS_EXPLOSION),projectile=direct instanceof Projectile;
        if(explosion && direct instanceof PrimedTnt tnt){var created=tntSessions.get(tnt.getUUID());if(created==null||!created.epoch().equals(session.epoch()))return false;}
        if(!(attacker instanceof ServerPlayer)&&!projectile&&!explosion)return false;
        var proxy=proxies.get(target);if(proxy==null)return false;
        if(!explosion&&!projectile&&(attacker.distanceToSqr(proxy)>36||!((ServerPlayer)attacker).hasLineOfSight(proxy)))return false;
        Vec3 position=new Vec3(proxy.getX(),proxy.getY(),proxy.getZ());
        var event=new DamageEvent(UUID.randomUUID(),session.pair(),session.epoch(),Space.MC,target,position,amount,explosion?"explosion":projectile?"projectile":"melee");
        JsonObject json=JSON.toJsonTree(event).getAsJsonObject();json.addProperty("type","damage");outbox.add(json);return true;
    }
    public void trackTnt(PrimedTnt tnt){
        if(tnt.level()!=level||session==null)return;
        var created=tntSessions.computeIfAbsent(tnt.getUUID(),id->session);
        if(created.epoch().equals(session.epoch()))chunks.acquire(tnt.chunkPosition().toLong(),tnt.getUUID());
    }
    public void exploded(PrimedTnt tnt){
        var origin=tntSessions.get(tnt.getUUID());if(origin==null||session==null||!origin.epoch().equals(session.epoch()))return;
        JsonObject e=new JsonObject();e.addProperty("id",UUID.randomUUID().toString());e.addProperty("type","explosion");e.add("pair",JSON.toJsonTree(origin.pair()));e.addProperty("epoch",origin.epoch().toString());e.add("position",JSON.toJsonTree(origin.transform().toDst(new Vec3(tnt.getX(),tnt.getY(),tnt.getZ()))));e.addProperty("radius",4);outbox.add(e);
        chunks.release(tnt.getUUID());tntSessions.remove(tnt.getUUID());
    }
    public Map<String,Object> status(){return Map.of("connected",connected(),"block_revision",blocks.revision(),"block_count",blocks.snapshot().changes().size(),"proxy_count",proxies.size(),"terrain_cells",terrain.size(),"pending_events",outbox==null?0:outbox.values().size(),"snapshot_sequence",snapshotSequence);}
    private void disconnect(){terrainReady=false;updating=true;try{terrain.close();}finally{updating=false;}for(var p:proxies.values())p.discard();proxies.clear();actors.clear();snapshotWindow.clear();chunks.close();if(damage!=null)damage.close();damage=null;session=null;}
    public void close(){disconnect();updating=true;try{terrain.close();}finally{updating=false;}}
}
