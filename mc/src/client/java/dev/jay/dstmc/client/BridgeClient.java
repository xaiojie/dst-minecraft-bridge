package dev.jay.dstmc.client;
import dev.jay.dstmc.BridgeMod;
import dev.jay.dstmc.server.BridgeServer;
import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientLifecycleEvents;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.minecraft.client.Minecraft;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
public final class BridgeClient implements ClientModInitializer {
    private String lastScreen="";
    public static final FrameCapture CAPTURE=new FrameCapture();
    public static Pose renderPose;
    public static boolean active(){var mc=Minecraft.getInstance();var bridge=BridgeMod.server;return bridge!=null && bridge.active()!=null && mc.level!=null && mc.level.dimension().equals(BridgeServer.STAGE);}
    @Override public void onInitializeClient(){
        net.fabricmc.fabric.api.client.rendering.v1.EntityRendererRegistry.register(dev.jay.dstmc.server.BridgeRegistries.ACTOR, net.minecraft.client.renderer.entity.NoopRenderer::new);
        ClientTickEvents.END_CLIENT_TICK.register(mc->{
            InputOwnership.tick();
            PassthroughWindow.tick();
            if(Boolean.getBoolean("dstmc.frameFixture")){
                String screen=mc.screen==null?"game":mc.screen.getClass().getName()+": "+mc.screen.getTitle().getString();
                if(!screen.equals(lastScreen)){org.slf4j.LoggerFactory.getLogger("dstmc-fixture").info("Fixture screen: {}",screen);lastScreen=screen;}
            }
            if(BridgeMod.server!=null){mc.options.pauseOnLostFocus=false;mc.options.bobView().set(false);mc.options.screenEffectScale().set(0.0);mc.options.renderDistance().set(4);}
        });
        ClientLifecycleEvents.CLIENT_STOPPING.register(mc->{PassthroughWindow.restore();CAPTURE.close();});
    }
}
