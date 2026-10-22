package dev.jay.dstmc.client;

import com.google.gson.JsonParser;
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

/** GLFW/Cocoa operations are confined to the Minecraft client/render thread. */
public final class PassthroughWindow {
    public record WindowBounds(int x,int y,int logicalWidth,int logicalHeight,int physicalWidth,int physicalHeight,double scale) {
        public WindowBounds {
            if(logicalWidth<=0||logicalHeight<=0||physicalWidth<=0||physicalHeight<=0||physicalWidth>1920||physicalHeight>1080||!Double.isFinite(scale)||scale<=0
                ||Math.abs(physicalWidth-logicalWidth*scale)>.5||Math.abs(physicalHeight-logicalHeight*scale)>.5)throw new IllegalArgumentException("inconsistent native render size");
        }
    }
    private static final boolean CONFIGURED=Boolean.getBoolean("dstmc.firstPerson")&&System.getProperty("os.name").startsWith("Mac");
    private static final HttpClient HTTP=HttpClient.newBuilder().connectTimeout(Duration.ofMillis(150)).build();
    private static CompletableFuture<WindowBounds> pending;
    private static boolean active;
    private static long validUntil,lastPoll,cocoa;
    private static int x,y,width,height,decorated,floating;
    private static boolean ignoresMouse,shadow;
    private static WindowBounds bounds;
    private static long msgSend(){return ObjCRuntime.getLibrary().getFunctionAddress("objc_msgSend");}
    private static boolean getBool(long target,String selector){return JNI.invokePPZ(target,ObjCRuntime.sel_registerName(selector),msgSend());}
    private static void setBool(long target,String selector,boolean value){JNI.invokePPV(target,ObjCRuntime.sel_registerName(selector),value,msgSend());}
    public static boolean configured(){return CONFIGURED;}
    public static boolean active(){return active&&System.nanoTime()<validUntil;}
    public static void creationHints(){if(CONFIGURED){GLFW.glfwWindowHint(GLFW.GLFW_TRANSPARENT_FRAMEBUFFER,GLFW.GLFW_TRUE);GLFW.glfwWindowHint(GLFW.GLFW_COCOA_RETINA_FRAMEBUFFER,GLFW.GLFW_FALSE);}}
    public static void tick(){
        if(!CONFIGURED)return;
        if(!BridgeClient.active()){if(pending!=null){pending.cancel(false);pending=null;}restore();return;}
        long now=System.nanoTime();
        if(pending!=null&&pending.isDone()){
            var result=pending;pending=null;
            try{WindowBounds value=result.join();validUntil=now+200_000_000L;enable(value);}catch(Exception e){restore();}
        }
        if(active&&now>=validUntil)restore();
        if(pending==null&&now-lastPoll>=50_000_000L){
            lastPoll=now;
            var request=HttpRequest.newBuilder(URI.create("http://127.0.0.1:39380/v2/window")).timeout(Duration.ofMillis(150)).GET().build();
            pending=HTTP.sendAsync(request,HttpResponse.BodyHandlers.ofString()).thenApply(response->{
                if(response.statusCode()!=200||response.body().length()>4096)throw new IllegalStateException("native fusion inactive");
                var j=JsonParser.parseString(response.body()).getAsJsonObject();if(j.get("protocol").getAsInt()!=2)throw new IllegalStateException("native protocol mismatch");
                return new WindowBounds((int)Math.round(j.get("screen_x").getAsDouble()),(int)Math.round(j.get("screen_y").getAsDouble()),(int)Math.round(j.get("logical_width").getAsDouble()),(int)Math.round(j.get("logical_height").getAsDouble()),j.get("physical_width").getAsInt(),j.get("physical_height").getAsInt(),j.get("scale").getAsDouble());
            });
        }
    }
    public static void enable(WindowBounds value){
        var window=Minecraft.getInstance().getWindow();long handle=window.handle();
        if(window.isFullscreen()||GLFW.glfwGetWindowAttrib(handle,GLFW.GLFW_TRANSPARENT_FRAMEBUFFER)!=GLFW.GLFW_TRUE){restore();return;}
        if(value.physicalWidth()!=value.logicalWidth()||value.physicalHeight()!=value.logicalHeight()){restore();return;}
        if(!active){
            int[] a=new int[1],b=new int[1];GLFW.glfwGetWindowPos(handle,a,b);x=a[0];y=b[0];GLFW.glfwGetWindowSize(handle,a,b);width=a[0];height=b[0];
            decorated=GLFW.glfwGetWindowAttrib(handle,GLFW.GLFW_DECORATED);floating=GLFW.glfwGetWindowAttrib(handle,GLFW.GLFW_FLOATING);
            cocoa=GLFWNativeCocoa.glfwGetCocoaWindow(handle);ignoresMouse=getBool(cocoa,"ignoresMouseEvents");shadow=getBool(cocoa,"hasShadow");
            active=true;GLFW.glfwSetWindowAttrib(handle,GLFW.GLFW_DECORATED,GLFW.GLFW_FALSE);GLFW.glfwSetWindowAttrib(handle,GLFW.GLFW_FLOATING,GLFW.GLFW_TRUE);setBool(cocoa,"setIgnoresMouseEvents:",false);setBool(cocoa,"setHasShadow:",false);
        }
        if(!value.equals(bounds)){bounds=value;GLFW.glfwSetWindowPos(handle,value.x(),value.y());GLFW.glfwSetWindowSize(handle,value.logicalWidth(),value.logicalHeight());}
        int[] w=new int[1],h=new int[1];GLFW.glfwGetFramebufferSize(handle,w,h);if(w[0]!=value.physicalWidth()||h[0]!=value.physicalHeight())restore();
    }
    public static void restore(){
        if(!active)return;
        long handle=Minecraft.getInstance().getWindow().handle();active=false;bounds=null;validUntil=0;
        GLFW.glfwSetWindowAttrib(handle,GLFW.GLFW_DECORATED,decorated);GLFW.glfwSetWindowAttrib(handle,GLFW.GLFW_FLOATING,floating);GLFW.glfwSetWindowSize(handle,width,height);GLFW.glfwSetWindowPos(handle,x,y);
        setBool(cocoa,"setIgnoresMouseEvents:",ignoresMouse);setBool(cocoa,"setHasShadow:",shadow);
        net.minecraft.client.KeyMapping.releaseAll();Minecraft.getInstance().mouseHandler.releaseMouse();
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
