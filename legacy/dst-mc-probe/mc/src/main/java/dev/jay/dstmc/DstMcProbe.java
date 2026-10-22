package dev.jay.dstmc;

import com.google.gson.*;
import com.sun.net.httpserver.HttpServer;
import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerLifecycleEvents;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerTickEvents;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.core.BlockPos;
import net.minecraft.world.level.ChunkPos;
import net.minecraft.world.entity.item.PrimedTnt;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.*;
import java.util.concurrent.ConcurrentLinkedQueue;

/** Throwaway feasibility experiment. The two games still have separate pictures. */
public final class DstMcProbe implements ModInitializer {
    public static final Logger LOG = LoggerFactory.getLogger("dst_mc_probe");
    private static final Gson JSON = new Gson();
    private static final String SESSION = UUID.randomUUID().toString();
    private static final Path EVENTS_FILE = Path.of("config", "dst_mc_probe_explosions.json");
    private static final BridgeCore.Once COMMANDS_ONCE = new BridgeCore.Once(Path.of("config", "dst_mc_probe_accepted_requests.txt"));
    private static final ConcurrentLinkedQueue<JsonObject> COMMANDS = new ConcurrentLinkedQueue<>();
    private static final List<JsonObject> EXPLOSIONS = Collections.synchronizedList(new ArrayList<>());
    private static final Map<UUID, ChunkPos> OWN_FORCED_CHUNKS = new HashMap<>();
    private static volatile JsonObject lastDst;
    private static volatile long lastDstTime;
    private static volatile JsonObject snapshot = initialSnapshot();
    private static String dstSession;
    private static double dstOriginX, dstOriginZ, mcOriginX, mcOriginZ;
    private static int spawnedTnt, movementSamples;
    private static boolean anchored;

    private static JsonObject initialSnapshot() {
        var state = new JsonObject();
        state.addProperty("protocol", 1);
        state.addProperty("session", SESSION);
        state.addProperty("world_loaded", false);
        state.addProperty("players", 0);
        return state;
    }

    @Override public void onInitialize() {
        try {
            if (Files.exists(EVENTS_FILE)) {
                var saved = JsonParser.parseString(Files.readString(EVENTS_FILE)).getAsJsonArray();
                for (var event : saved) EXPLOSIONS.add(event.getAsJsonObject());
            }
            var http = HttpServer.create(new InetSocketAddress("127.0.0.1", 39379), 0);
            http.createContext("/", exchange -> {
                JsonObject response;
                int code = 200;
                try {
                    var path = exchange.getRequestURI().getPath();
                    if (path.equals("/exchange") && exchange.getRequestMethod().equals("POST")) {
                        var body = new String(exchange.getRequestBody().readNBytes(65536), StandardCharsets.UTF_8);
                        var input = JsonParser.parseString(body).getAsJsonObject();
                        lastDst = input.deepCopy();
                        lastDstTime = System.currentTimeMillis();
                        if (input.has("commands")) {
                            for (var command : input.getAsJsonArray("commands")) {
                                var item = command.getAsJsonObject();
                                if (COMMANDS_ONCE.accept(item.get("id").getAsString())) COMMANDS.add(item.deepCopy());
                            }
                        }
                        response = currentStatus();
                    } else if (path.equals("/probe/tnt") && exchange.getRequestMethod().equals("POST")) {
                        var input = JsonParser.parseString(new String(exchange.getRequestBody().readNBytes(4096), StandardCharsets.UTF_8)).getAsJsonObject();
                        var id = input.get("id").getAsString();
                        boolean fresh = COMMANDS_ONCE.accept(id);
                        if (fresh) {
                            input.addProperty("type", "probe_tnt");
                            COMMANDS.add(input);
                        }
                        response = new JsonObject();
                        response.addProperty("accepted", fresh);
                    } else if (path.equals("/status")) {
                        response = currentStatus();
                    } else {
                        code = 404;
                        response = new JsonObject();
                        response.addProperty("error", "unknown_endpoint");
                    }
                } catch (Exception failure) {
                    code = 400;
                    response = new JsonObject();
                    response.addProperty("error", failure.getClass().getSimpleName());
                    LOG.warn("Probe request rejected", failure);
                }
                byte[] bytes = JSON.toJson(response).getBytes(StandardCharsets.UTF_8);
                exchange.getResponseHeaders().set("Content-Type", "application/json; charset=utf-8");
                exchange.sendResponseHeaders(code, bytes.length);
                try (var out = exchange.getResponseBody()) { out.write(bytes); }
                exchange.close();
            });
            http.start();
            Runtime.getRuntime().addShutdownHook(new Thread(() -> http.stop(0)));
            LOG.info("DST_MC_PROBE listening on 127.0.0.1:39379; temporary experiment; session={}", SESSION);
        } catch (Exception error) {
            throw new IllegalStateException("Could not start the local feasibility bridge", error);
        }
        ServerTickEvents.END_SERVER_TICK.register(DstMcProbe::tick);
        ServerLifecycleEvents.SERVER_STOPPED.register(server -> {
            snapshot = initialSnapshot();
            anchored = false;
            COMMANDS.clear();
        });
    }

    private static JsonObject currentStatus() {
        var state = snapshot.deepCopy();
        state.addProperty("dst_age_ms", lastDstTime == 0 ? -1 : System.currentTimeMillis() - lastDstTime);
        if (lastDst != null) state.add("dst", lastDst.deepCopy());
        var events = new JsonArray();
        synchronized (EXPLOSIONS) { for (var event : EXPLOSIONS) events.add(event.deepCopy()); }
        state.add("explosions", events);
        return state;
    }

    public static boolean hasLiveDstConnection() {
        return lastDst != null && System.currentTimeMillis() - lastDstTime < 2500;
    }

    private static void tick(MinecraftServer server) {
        var state = initialSnapshot();
        state.addProperty("world_loaded", true);
        var players = server.getPlayerList().getPlayers();
        state.addProperty("players", players.size());
        if (players.isEmpty()) { snapshot = state; return; }
        var player = players.getFirst();
        var world = player.level();
        JsonObject dst = lastDst;
        if (dst != null && System.currentTimeMillis() - lastDstTime < 2500 && dst.has("x") && dst.has("z")) {
            String session = dst.get("session").getAsString();
            if (!anchored || !session.equals(dstSession)) {
                dstOriginX = dst.get("x").getAsDouble();
                dstOriginZ = dst.get("z").getAsDouble();
                mcOriginX = player.getX();
                mcOriginZ = player.getZ();
                dstSession = session;
                anchored = true;
                LOG.info("DST_MC_PROBE anchored DST=({}, {}) MC=({}, {})", dstOriginX, dstOriginZ, mcOriginX, mcOriginZ);
            }
            var relative = BridgeCore.toMinecraft(dst.get("x").getAsDouble(), dst.get("z").getAsDouble(), dstOriginX, dstOriginZ);
            player.teleportTo(mcOriginX + relative.x(), player.getY(), mcOriginZ + relative.z());
            movementSamples++;
        }
        JsonObject command;
        while ((command = COMMANDS.poll()) != null) {
            boolean fromDst = command.get("type").getAsString().equals("tnt");
            if (fromDst && !anchored) continue;
            double x, z;
            if (fromDst) {
                x = mcOriginX + command.get("x").getAsDouble() - dstOriginX;
                z = mcOriginZ + command.get("z").getAsDouble() - dstOriginZ;
            } else {
                x = player.getX() + 6;
                z = player.getZ();
            }
            var tnt = new PrimedTnt(world, x, player.getY(), z, player);
            tnt.setFuse(60);
            tnt.setNoGravity(true);
            tnt.setDeltaMovement(0, 0, 0);
            var chunk = new ChunkPos(BlockPos.containing(x, player.getY(), z));
            if (world.setChunkForced(chunk.x, chunk.z, true)) OWN_FORCED_CHUNKS.put(tnt.getUUID(), chunk);
            world.getChunk(chunk.x, chunk.z);
            world.addFreshEntity(tnt);
            spawnedTnt++;
            LOG.info("DST_MC_PROBE real TNT spawned id={} entity={} at=({}, {}, {})", command.get("id"), tnt.getUUID(), x, player.getY(), z);
        }
        state.addProperty("mc_x", player.getX());
        state.addProperty("mc_y", player.getY());
        state.addProperty("mc_z", player.getZ());
        state.addProperty("dst_origin_x", dstOriginX);
        state.addProperty("dst_origin_z", dstOriginZ);
        state.addProperty("mc_origin_x", mcOriginX);
        state.addProperty("mc_origin_z", mcOriginZ);
        state.addProperty("tnt_spawn_count", spawnedTnt);
        state.addProperty("movement_samples", movementSamples);
        state.addProperty("anchored", anchored);
        snapshot = state;
    }

    /** Called only after vanilla PrimedTnt.explode returns on the logical server. */
    public static void afterRealExplosion(PrimedTnt tnt) {
        if (tnt.level().isClientSide()) return;
        var event = new JsonObject();
        event.addProperty("id", SESSION + ":" + tnt.getUUID());
        event.addProperty("type", "tnt_exploded");
        event.addProperty("mc_x", tnt.getX());
        event.addProperty("mc_z", tnt.getZ());
        event.addProperty("dst_x", dstOriginX + tnt.getX() - mcOriginX);
        event.addProperty("dst_z", dstOriginZ + tnt.getZ() - mcOriginZ);
        event.addProperty("time_ms", System.currentTimeMillis());
        synchronized (EXPLOSIONS) {
            EXPLOSIONS.add(event);
            if (EXPLOSIONS.size() > 64) EXPLOSIONS.removeFirst();
            try {
                Files.createDirectories(EVENTS_FILE.getParent());
                Files.writeString(EVENTS_FILE, JSON.toJson(EXPLOSIONS));
            } catch (java.io.IOException error) { LOG.error("Could not preserve the real explosion history", error); }
        }
        LOG.info("DST_MC_PROBE real vanilla TNT explosion completed {}", event);
        var chunk = OWN_FORCED_CHUNKS.remove(tnt.getUUID());
        if (chunk != null && tnt.level() instanceof ServerLevel world) {
            world.setChunkForced(chunk.x, chunk.z, false);
        }
    }
}
