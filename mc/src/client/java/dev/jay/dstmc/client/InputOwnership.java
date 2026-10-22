package dev.jay.dstmc.client;
import com.google.gson.*;
import dev.jay.dstmc.BridgeMod;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
import net.minecraft.client.*;
import org.lwjgl.glfw.GLFW;
import java.net.*;
import java.net.http.*;
import java.time.Duration;
import java.util.*;
import java.util.concurrent.CompletableFuture;
/** Native process arbitrates F8 for whichever application currently has focus. */
public final class InputOwnership {
    private static final HttpClient HTTP=HttpClient.newBuilder().connectTimeout(Duration.ofMillis(200)).build();
    private static final Gson JSON=new Gson();
    private static final InputSwitch intent=new InputSwitch();
    private static Object session;private static CompletableFuture<HttpResponse<String>> pending;
    private static boolean mc=true,keyDown;private static long version=-1,lastPoll,lastSuccess,dispatched;
    public static boolean ownsInput(){return mc;}
    public static void tick(){
        var bridge=BridgeMod.server;var current=bridge==null?null:bridge.active();long now=System.nanoTime();
        if(current!=session){session=current;if(pending!=null)pending.cancel(false);pending=null;version=-1;intent.reset();lastSuccess=now;}
        if(current==null)return;
        if(pending!=null&&pending.isDone()){
            var response=pending;pending=null;
            try{var r=response.join();if(r.statusCode()==409)version=-1;if(r.statusCode()!=200||now-dispatched>500_000_000L)throw new IllegalStateException();var value=JsonParser.parseString(r.body()).getAsJsonObject();long revision=value.get("version").getAsLong();if(revision>=version){version=revision;boolean confirmed=value.get("owner").getAsString().equals("MC");intent.confirmed(confirmed);setOwner(confirmed);lastSuccess=now;}}catch(Exception ignored){}
        }
        if(now-lastSuccess>2_500_000_000L){setOwner(false);PassthroughWindow.restore();}
        boolean down=GLFW.glfwGetKey(Minecraft.getInstance().getWindow().handle(),GLFW.GLFW_KEY_F8)==GLFW.GLFW_PRESS;
        boolean toggle=down&&!keyDown;keyDown=down;if(toggle)intent.press(mc);
        if(pending!=null||(intent.desired()==null&&now-lastPoll<100_000_000L))return;
        String hash=HexFormat.of().formatHex(pairHash(current.pair()));
        HttpRequest.Builder request=HttpRequest.newBuilder().timeout(Duration.ofMillis(300));
        if(intent.desired()!=null&&version>=0){
            var body=Map.of("protocol",2,"key",new FrameKey(current.pair(),current.epoch(),0),"owner",intent.desired()?"MC":"DST","version",version);
            request.uri(URI.create("http://127.0.0.1:39380/v2/input")).header("Content-Type","application/json").POST(HttpRequest.BodyPublishers.ofString(JSON.toJson(body)));
        }else request.uri(URI.create("http://127.0.0.1:39380/v2/input?pair_hash="+hash+"&epoch="+current.epoch())).GET();
        lastPoll=dispatched=now;pending=HTTP.sendAsync(request.build(),HttpResponse.BodyHandlers.ofString());
    }
    private static void setOwner(boolean value){
        if(mc==value)return;mc=value;
        KeyMapping.releaseAll();var client=Minecraft.getInstance();
        if(!value){client.mouseHandler.releaseMouse();PassthroughWindow.restore();GLFW.glfwIconifyWindow(client.getWindow().handle());}
        else {GLFW.glfwRestoreWindow(client.getWindow().handle());GLFW.glfwFocusWindow(client.getWindow().handle());if(client.screen==null)client.mouseHandler.grabMouse();}
    }
}
