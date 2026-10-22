package dev.jay.dstmc.server;

import com.google.gson.*;
import com.sun.net.httpserver.*;
import dev.jay.dstmc.protocol.*;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.core.registries.Registries;
import net.minecraft.resources.*;
import net.minecraft.world.level.Level;
import net.minecraft.world.level.block.Blocks;
import net.minecraft.world.level.storage.LevelResource;
import java.io.*;
import java.net.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.util.*;
import java.util.concurrent.*;
import java.util.function.Supplier;

/** Loopback HTTP adapter. Game API access is confined to the server tick thread. */
public final class BridgeServer implements AutoCloseable {
    public static final ResourceKey<Level> STAGE=ResourceKey.create(Registries.DIMENSION,Identifier.fromNamespaceAndPath("dst_mc_bridge","stage"));
    private static final Gson JSON=new GsonBuilder().serializeNulls().create();
    private final MinecraftServer game;
    private final HttpServer http;
    private final ExecutorService executor=Executors.newFixedThreadPool(2,r->{var t=new Thread(r,"dstmc-http");t.setDaemon(true);return t;});
    private final WorldExchange exchange;
    private final String runId=UUID.randomUUID().toString();
    private final long started=System.currentTimeMillis();
    private final boolean fixture;
    private volatile WorldExchange.HandshakeResult active;
    private volatile Stream stream;
    private volatile long heartbeat,lastPeerMs;
    private volatile boolean stageReady;
    private final Set<UUID> placed=new HashSet<>();
    public record Stream(FrameKey key,String path,long generation,int width,int height){}
    public BridgeServer(MinecraftServer game){
        this.game=game;
        Path save=game.getWorldPath(LevelResource.ROOT);
        fixture=WorldExchange.frameFixture(save,Boolean.getBoolean("dstmc.frameFixture"));
        if(!Files.isRegularFile(save.resolve("dst-mc-copy-source.json")))throw new IllegalStateException("Bridge requires an independent prepared test save");
        exchange=new WorldExchange(save);
        try{http=HttpServer.create(new InetSocketAddress("127.0.0.1",39379),8);http.createContext("/",this::handle);http.setExecutor(executor);http.start();}
        catch(IOException e){executor.shutdownNow();throw new IllegalStateException("Port 39379 conflict; close the other test instance (including protocol=1) yourself",e);}
    }
    public WorldExchange.HandshakeResult active(){return active;}
    public Path framesDirectory(){return Path.of("dst-mc-frames",runId).toAbsolutePath();}
    public void updateStream(WorldExchange.HandshakeResult session,Stream value){if(active==session)stream=value;}
    public void invalidateStream(){stream=null;}
    public void tick(){
        heartbeat++;
        ServerLevel level=game.getLevel(STAGE);if(level==null)return;
        if(!stageReady){for(int x=-16;x<=16;x++)for(int z=-16;z<=16;z++)level.setBlockAndUpdate(new BlockPos(x,63,z),Blocks.BARRIER.defaultBlockState());level.setBlockAndUpdate(new BlockPos(0,64,3),Blocks.STONE.defaultBlockState());stageReady=true;}
        for(var player:game.getPlayerList().getPlayers())if(placed.add(player.getUUID()))player.teleportTo(level,.5,64,.5,Set.of(),0,12,false);
    }
    private <T>T onGame(Supplier<T> action)throws Exception{
        CompletableFuture<T> future=new CompletableFuture<>();game.execute(()->{if(!future.isCancelled())try{future.complete(action.get());}catch(Throwable e){future.completeExceptionally(e);}});
        try{return future.get(8,TimeUnit.SECONDS);}catch(TimeoutException e){future.cancel(false);throw e;}
    }
    public Map<String,Object> status(){
        var m=new LinkedHashMap<String,Object>();var a=active;var s=stream;
        if(a==null || (s!=null && (!s.key().pair().equals(a.pair()) || !s.key().epoch().equals(a.epoch()))))s=null;
        m.put("protocol",2);m.put("status",a==null?"UNPAIRED":"PAIRED");m.put("pair",a==null?null:pair(a.pair()));m.put("epoch",a==null?null:a.epoch().toString());
        m.put("mc_world",exchange.mcWorld().toString());m.put("pid",HttpIntegers.exact(ProcessHandle.current().pid()));m.put("run_id",runId);m.put("started_at_ms",HttpIntegers.exact(started));
        m.put("heartbeat",HttpIntegers.exact(heartbeat));m.put("peer_last_seen_ms",HttpIntegers.exact(lastPeerMs));m.put("fixture",fixture);m.put("stage_ready",stageReady);
        m.put("frame_path",s==null?null:s.path());m.put("generation",s==null?null:HttpIntegers.exact(s.generation()));m.put("latest_frame",s==null?null:key(s.key()));m.put("width",s==null?null:s.width());m.put("height",s==null?null:s.height());
        return m;
    }
    private void handle(HttpExchange httpExchange)throws IOException{
        int code=200;Object output;
        try {
            String path=httpExchange.getRequestURI().getPath(),method=httpExchange.getRequestMethod();
            if(path.equals("/v2/status")&&method.equals("GET"))output=status();
            else if(path.equals("/v2/handshake")&&method.equals("POST")){
                var input=body(httpExchange);requireKeys(input,"protocol","pair","epoch","dst_origin","mc_origin");protocol(input);
                PairKey pair=parsePair(input.getAsJsonObject("pair"));UUID epoch=UUID.fromString(input.get("epoch").getAsString());Vec3 dst=vec(input.getAsJsonObject("dst_origin")),mc=vec(input.getAsJsonObject("mc_origin"));
                var result=onGame(()->{var r=exchange.handshake(pair,epoch,dst,mc);if(r.reason().isEmpty()){active=r;stream=null;lastPeerMs=System.currentTimeMillis();}return r;});
                if(!result.reason().isEmpty())throw new IllegalArgumentException(result.reason());
                long until=System.nanoTime()+TimeUnit.SECONDS.toNanos(8);Stream s;
                while((s=stream)==null&&System.nanoTime()<until)Thread.sleep(10);
                if(s==null||!s.key().epoch().equals(epoch))throw new IllegalStateException("FRAME_NOT_READY");
                output=Map.of("protocol",2,"pair",pair(result.pair()),"epoch",epoch.toString(),"dst_origin",vec(result.transform().dstOrigin()),"mc_origin",vec(result.transform().mcOrigin()),"axes",result.transform().axes(),"frame_path",s.path());
            } else if(path.equals("/v2/exchange")&&method.equals("POST")){
                var input=body(httpExchange);requireKeys(input,"protocol","pair","epoch","commands","damage_events");protocol(input);
                output=onGame(()->{var a=active;if(a==null||!a.pair().equals(parsePair(input.getAsJsonObject("pair")))||!a.epoch().equals(UUID.fromString(input.get("epoch").getAsString())))throw new IllegalArgumentException("SESSION_MISMATCH");
                    if(!input.getAsJsonArray("commands").isEmpty()||!input.getAsJsonArray("damage_events").isEmpty())throw new IllegalArgumentException("COMMANDS_NOT_IMPLEMENTED");lastPeerMs=System.currentTimeMillis();
                    return Map.of("protocol",2,"pair",pair(a.pair()),"epoch",a.epoch().toString(),"results",List.of(),"actors",Map.of("revision",0,"bodies",List.of()),"block_changes",List.of(),"terrain",List.of());});
            } else if(path.equals("/test/scene")&&method.equals("POST")&&fixture){
                var input=body(httpExchange);boolean stone=input.get("stone").getAsBoolean();
                output=onGame(()->{game.getLevel(STAGE).setBlockAndUpdate(new BlockPos(0,64,3),(stone?Blocks.STONE:Blocks.AIR).defaultBlockState());return Map.of("stone",stone);});
            } else {code=404;output=Map.of("protocol",2,"error","NOT_FOUND","reason","unknown endpoint or method");}
        }catch(Exception e){code=400;Throwable cause=e instanceof ExecutionException?e.getCause():e;output=Map.of("protocol",2,"error","REQUEST_REJECTED","reason",String.valueOf(cause.getMessage()));}
        byte[] bytes=JSON.toJson(output).getBytes(StandardCharsets.UTF_8);httpExchange.getResponseHeaders().set("Content-Type","application/json");httpExchange.sendResponseHeaders(code,bytes.length);try(var out=httpExchange.getResponseBody()){out.write(bytes);}
    }
    private static JsonObject body(HttpExchange ex)throws IOException{byte[] b=ex.getRequestBody().readNBytes(65537);if(b.length>65536)throw new IllegalArgumentException("body too large");return JsonParser.parseString(new String(b,StandardCharsets.UTF_8)).getAsJsonObject();}
    private static void requireKeys(JsonObject o,String... keys){if(!o.keySet().equals(Set.of(keys)))throw new IllegalArgumentException("unexpected request fields");}
    private static void protocol(JsonObject o){if(o.get("protocol").getAsBigDecimal().compareTo(java.math.BigDecimal.valueOf(2))!=0)throw new IllegalArgumentException("protocol must be 2");}
    private static Vec3 vec(JsonObject o){requireKeys(o,"x","y","z");return new Vec3(o.get("x").getAsDouble(),o.get("y").getAsDouble(),o.get("z").getAsDouble());}
    private static PairKey parsePair(JsonObject o){requireKeys(o,"dst_world","dst_shard","mc_world","mc_dimension","region");return new PairKey(UUID.fromString(o.get("dst_world").getAsString()),o.get("dst_shard").getAsString(),UUID.fromString(o.get("mc_world").getAsString()),o.get("mc_dimension").getAsString(),o.get("region").getAsString());}
    private static Object pair(PairKey p){return JsonParser.parseString(canonicalPair(p));}
    private static Object key(FrameKey k){return Map.of("pair",pair(k.pair()),"epoch",k.epoch().toString(),"id",HttpIntegers.exact(k.id()));}
    private static Object vec(Vec3 v){return Map.of("x",v.x(),"y",v.y(),"z",v.z());}
    @Override public void close(){http.stop(0);executor.shutdownNow();stream=null;active=null;}
}
