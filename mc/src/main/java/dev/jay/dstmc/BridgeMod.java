package dev.jay.dstmc;
import dev.jay.dstmc.server.BridgeServer;
import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerLifecycleEvents;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerTickEvents;
public final class BridgeMod implements ModInitializer {
    public static volatile BridgeServer server;
    @Override public void onInitialize(){
        dev.jay.dstmc.server.BridgeRegistries.initialize();
        ServerLifecycleEvents.SERVER_STARTED.register(game->{server=new BridgeServer(game);});
        ServerTickEvents.END_SERVER_TICK.register(game->{var bridge=server;if(bridge!=null)bridge.tick();});
        ServerLifecycleEvents.SERVER_STOPPING.register(game->{var bridge=server;server=null;if(bridge!=null)bridge.close();});
    }
}
