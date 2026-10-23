package dev.jay.dstmc.client;

import com.google.gson.JsonParser;
import dev.jay.dstmc.BridgeMod;
import net.minecraft.client.Minecraft;
import org.lwjgl.glfw.*;
import org.lwjgl.opengl.*;
import org.lwjgl.system.MemoryStack;
import org.lwjgl.system.JNI;
import org.lwjgl.system.macosx.ObjCRuntime;
import java.net.URI;
import java.net.http.*;
import java.time.Duration;
import java.util.concurrent.CompletableFuture;

/** GLFW and platform window operations stay on the Minecraft client thread. */
public final class PassthroughWindow {
    private static final boolean MAC=System.getProperty("os.name").startsWith("Mac");
    private static final boolean WINDOWS=System.getProperty("os.name").startsWith("Windows");
    private static final boolean CONFIGURED=Boolean.getBoolean("dstmc.firstPerson")&&(MAC||WINDOWS);
    private static final HttpClient HTTP=HttpClient.newBuilder().connectTimeout(Duration.ofMillis(150)).build();
    private record Pending(WindowActivation.Ticket ticket, CompletableFuture<WindowGeometry> response) {}
    private static final WindowActivation ACTIVATION = new WindowActivation();
    private static Pending pending;
    private static CompletableFuture<WindowGeometry> geometryPending;
    private static long geometryDispatched;
    private static boolean active,saved;
    private static long lastPoll,cocoa;
    private static int x,y,width,height,decorated,floating;
    private static boolean ignoresMouse,shadow;
    private static WindowGeometry bounds;
    private static long msgSend(){return ObjCRuntime.getLibrary().getFunctionAddress("objc_msgSend");}
    private static boolean getBool(long target,String selector){return JNI.invokePPZ(target,ObjCRuntime.sel_registerName(selector),msgSend());}
    private static void setBool(long target,String selector,boolean value){JNI.invokePPV(target,ObjCRuntime.sel_registerName(selector),value,msgSend());}
    public static boolean configured(){return CONFIGURED;}
    public static boolean active(){return active&&BridgeClient.active()&&ACTIVATION.active(BridgeMod.server.active(),System.nanoTime());}
    public static void creationHints(){
        if(CONFIGURED){
            GLFW.glfwWindowHint(GLFW.GLFW_TRANSPARENT_FRAMEBUFFER,GLFW.GLFW_TRUE);
            if(MAC)GLFW.glfwWindowHint(GLFW.GLFW_COCOA_RETINA_FRAMEBUFFER,GLFW.GLFW_FALSE);
        }
    }
    private static CompletableFuture<WindowGeometry> request(String route,String identity){
        var request=HttpRequest.newBuilder(URI.create("http://127.0.0.1:39380"+route+identity)).timeout(Duration.ofMillis(150)).GET().build();
        return HTTP.sendAsync(request,HttpResponse.BodyHandlers.ofString()).thenApply(response->{
            if(response.statusCode()!=200||response.body().length()>4096)throw new IllegalStateException("native fusion inactive");
            var j=JsonParser.parseString(response.body()).getAsJsonObject();
            if(j.get("protocol").getAsInt()!=2)throw new IllegalStateException("native protocol mismatch");
            double scale=j.get("scale").getAsDouble();
            return new WindowGeometry((int)Math.round(j.get("screen_x").getAsDouble()),(int)Math.round(j.get("screen_y").getAsDouble()),
                j.get("logical_width").getAsInt(),j.get("logical_height").getAsInt(),j.get("physical_width").getAsInt(),j.get("physical_height").getAsInt(),
                scale,j.has("scale_y")?j.get("scale_y").getAsDouble():scale);
        });
    }
    public static void tick(){
        if(!CONFIGURED)return;
        if(!InputOwnership.ownsInput()){restore();return;}
        var session=BridgeClient.active()?BridgeMod.server.active():null;
        if(ACTIVATION.session(session)){
            if(pending!=null){pending.response().cancel(false);pending=null;}
            if(geometryPending!=null){geometryPending.cancel(false);geometryPending=null;}
            restore();
        }
        if(session==null){restore();return;}
        long now=System.nanoTime();
        if(geometryPending!=null&&geometryPending.isDone()){
            var response=geometryPending;geometryPending=null;
            try{if(now-geometryDispatched<200_000_000L)align(response.join());}catch(Exception ignored){deactivate();}
        }
        if(pending!=null&&pending.response().isDone()){
            var result=pending;pending=null;
            try{
                var value=result.response().join();
                if(ACTIVATION.accept(result.ticket(),now))enable(value);else deactivate();
            }catch(Exception e){deactivate();}
        }
        if(active&&!ACTIVATION.active(session,now))deactivate();
        if(now-lastPoll>=50_000_000L){
            lastPoll=now;
            String identity="?pair_hash="+java.util.HexFormat.of().formatHex(dev.jay.dstmc.protocol.BridgeTypes.pairHash(session.pair()))+"&epoch="+session.epoch();
            if(geometryPending==null){geometryDispatched=now;geometryPending=request("/v2/window/geometry",identity);}
            if(pending==null)pending=new Pending(ACTIVATION.dispatch(now),request("/v2/window",identity));
        }
    }
    private static void saveWindow(long handle){
        if(saved)return;
        int[] a=new int[1],b=new int[1];GLFW.glfwGetWindowPos(handle,a,b);x=a[0];y=b[0];GLFW.glfwGetWindowSize(handle,a,b);width=a[0];height=b[0];
        decorated=GLFW.glfwGetWindowAttrib(handle,GLFW.GLFW_DECORATED);floating=GLFW.glfwGetWindowAttrib(handle,GLFW.GLFW_FLOATING);
        if(MAC){cocoa=GLFWNativeCocoa.glfwGetCocoaWindow(handle);ignoresMouse=getBool(cocoa,"ignoresMouseEvents");shadow=getBool(cocoa,"hasShadow");}
        saved=true;
    }
    private static void align(WindowGeometry value){
        var window=Minecraft.getInstance().getWindow();long handle=window.handle();
        if(window.isFullscreen())return;
        int[] w=new int[1],h=new int[1],fw=new int[1],fh=new int[1];
        GLFW.glfwGetWindowSize(handle,w,h);GLFW.glfwGetFramebufferSize(handle,fw,fh);
        if(w[0]<=0||h[0]<=0||fw[0]<=0||fh[0]<=0)return;
        int targetWidth=value.windowWidth((double)fw[0]/w[0]),targetHeight=value.windowHeight((double)fh[0]/h[0]);
        saveWindow(handle);
        if(!value.equals(bounds)||w[0]!=targetWidth||h[0]!=targetHeight){
            if(active)deactivate();
            bounds=value;GLFW.glfwSetWindowPos(handle,value.x(),value.y());GLFW.glfwSetWindowSize(handle,targetWidth,targetHeight);
        }
    }
    public static void enable(WindowGeometry value){
        var window=Minecraft.getInstance().getWindow();long handle=window.handle();
        if(window.isFullscreen()||GLFW.glfwGetWindowAttrib(handle,GLFW.GLFW_TRANSPARENT_FRAMEBUFFER)!=GLFW.GLFW_TRUE){deactivate();return;}
        align(value);
        int[] w=new int[1],h=new int[1];GLFW.glfwGetFramebufferSize(handle,w,h);
        if(w[0]!=value.physicalWidth()||h[0]!=value.physicalHeight()){deactivate();return;}
        if(!active){
            saveWindow(handle);active=true;
            GLFW.glfwSetWindowAttrib(handle,GLFW.GLFW_DECORATED,GLFW.GLFW_FALSE);GLFW.glfwSetWindowAttrib(handle,GLFW.GLFW_FLOATING,GLFW.GLFW_TRUE);
            if(MAC){setBool(cocoa,"setIgnoresMouseEvents:",false);setBool(cocoa,"setHasShadow:",false);}
            GLFW.glfwFocusWindow(handle);
        }
    }
    private static void deactivate(){
        ACTIVATION.invalidate();
        if(!active)return;
        long handle=Minecraft.getInstance().getWindow().handle();active=false;
        GLFW.glfwSetWindowAttrib(handle,GLFW.GLFW_DECORATED,decorated);GLFW.glfwSetWindowAttrib(handle,GLFW.GLFW_FLOATING,floating);
        if(MAC){setBool(cocoa,"setIgnoresMouseEvents:",ignoresMouse);setBool(cocoa,"setHasShadow:",shadow);}
        net.minecraft.client.KeyMapping.releaseAll();Minecraft.getInstance().mouseHandler.releaseMouse();
    }
    public static void restore(){
        deactivate();bounds=null;
        if(!saved)return;
        long handle=Minecraft.getInstance().getWindow().handle();saved=false;
        GLFW.glfwSetWindowSize(handle,width,height);GLFW.glfwSetWindowPos(handle,x,y);
    }
    /** Suppress only the duplicate final blit; capture still reads the main target. */
    public static void clearWindow(){
        int fbo=GL11.glGetInteger(GL30.GL_DRAW_FRAMEBUFFER_BINDING);boolean scissor=GL11.glIsEnabled(GL11.GL_SCISSOR_TEST);
        try(MemoryStack stack=MemoryStack.stackPush()){
            var color=stack.mallocFloat(4);var mask=stack.malloc(4);GL11.glGetFloatv(GL11.GL_COLOR_CLEAR_VALUE,color);GL11.glGetBooleanv(GL11.GL_COLOR_WRITEMASK,mask);
            try{GL30.glBindFramebuffer(GL30.GL_DRAW_FRAMEBUFFER,0);GL11.glDisable(GL11.GL_SCISSOR_TEST);GL11.glColorMask(true,true,true,true);GL11.glClearColor(0,0,0,0);GL11.glClear(GL11.GL_COLOR_BUFFER_BIT);}
            finally{GL11.glClearColor(color.get(0),color.get(1),color.get(2),color.get(3));GL11.glColorMask(mask.get(0)!=0,mask.get(1)!=0,mask.get(2)!=0,mask.get(3)!=0);if(scissor)GL11.glEnable(GL11.GL_SCISSOR_TEST);GL30.glBindFramebuffer(GL30.GL_DRAW_FRAMEBUFFER,fbo);}
        }
    }
}
