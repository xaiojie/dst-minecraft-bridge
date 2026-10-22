package dev.jay.dstmc.client;

import com.mojang.blaze3d.opengl.GlTexture;
import com.mojang.blaze3d.systems.RenderSystem;
import dev.jay.dstmc.BridgeMod;
import dev.jay.dstmc.server.*;
import dev.jay.dstmc.protocol.FrameLayout;
import static dev.jay.dstmc.protocol.BridgeTypes.*;
import net.minecraft.client.Minecraft;
import org.lwjgl.glfw.GLFW;
import org.lwjgl.opengl.*;
import org.lwjgl.system.MemoryUtil;
import java.nio.*;

/** Synchronous GL readback: glReadPixels returns only after the current GPU writes
 * complete. No callback can publish partially filled buffers. GL state restored. */
public final class FrameCapture implements AutoCloseable {
    private FramePublisher publisher;
    private WorldExchange.HandshakeResult session;
    private long context,generation;
    private int width,height;
    private ByteBuffer color,depth,hud;
    public void captureWorld(Pose pose){
        if(!BridgeClient.active()||pose==null){close();return;}
        var mc=Minecraft.getInstance();var target=mc.getMainRenderTarget();var bridge=BridgeMod.server;
        try {
            long current=GLFW.glfwGetCurrentContext();
            if(publisher==null||session!=bridge.active()||context!=current){close();session=bridge.active();context=current;publisher=new FramePublisher(bridge.framesDirectory(),session.pair(),session.epoch(),session.transform());}
            if(width!=target.width||height!=target.height){
                releaseBuffers();FrameLayout.layerBytes(target.width,target.height);width=target.width;height=target.height;
                publisher.resize(width,height);generation=publisher.generation();bridge.invalidateStream();int bytes=FrameLayout.layerBytes(width,height);
                color=MemoryUtil.memAlloc(bytes);depth=MemoryUtil.memAlloc(bytes).order(ByteOrder.LITTLE_ENDIAN);hud=MemoryUtil.memAlloc(bytes);
            }
            read(target,true,color,depth);
            // The clear and normal MC blend state already produce premultiplied color.
            zeroTransparent(color);publisher.world(generation,pose,color,depth);
            RenderSystem.getDevice().createCommandEncoder().clearColorTexture(target.getColorTexture(),0);
        }catch(Exception error){close();throw new IllegalStateException("MC frame capture failed",error);}
    }
    public void captureHud(){
        if(publisher==null)return;
        if(!BridgeClient.active()||GLFW.glfwGetCurrentContext()!=context||BridgeMod.server.active()!=session){close();return;}
        var target=Minecraft.getInstance().getMainRenderTarget();
        if(target.width!=width||target.height!=height){publisher.discardPending();return;}
        read(target,false,hud,null);zeroTransparent(hud);publisher.hud(generation,hud);
        publisher.publishCompleted().ifPresent(key->BridgeMod.server.updateStream(session,new BridgeServer.Stream(key,publisher.path().toString(),generation,width,height)));
    }
    private static void zeroTransparent(ByteBuffer bytes){for(int i=0;i<bytes.limit();i+=4)if(bytes.get(i+3)==0){bytes.put(i,(byte)0);bytes.put(i+1,(byte)0);bytes.put(i+2,(byte)0);}}
    private static void read(com.mojang.blaze3d.pipeline.RenderTarget target,boolean withDepth,ByteBuffer rgba,ByteBuffer depth){
        int oldFbo=GL11.glGetInteger(GL30.GL_READ_FRAMEBUFFER_BINDING),oldPack=GL11.glGetInteger(GL21.GL_PIXEL_PACK_BUFFER_BINDING);
        int align=GL11.glGetInteger(GL11.GL_PACK_ALIGNMENT),row=GL11.glGetInteger(GL11.GL_PACK_ROW_LENGTH),skipRows=GL11.glGetInteger(GL11.GL_PACK_SKIP_ROWS),skipPixels=GL11.glGetInteger(GL11.GL_PACK_SKIP_PIXELS),swap=GL11.glGetInteger(GL11.GL_PACK_SWAP_BYTES);
        int fbo=GL30.glGenFramebuffers();
        try {
            GL30.glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER,fbo);
            GL30.glFramebufferTexture2D(GL30.GL_READ_FRAMEBUFFER,GL30.GL_COLOR_ATTACHMENT0,GL11.GL_TEXTURE_2D,((GlTexture)target.getColorTexture()).glId(),0);
            if(withDepth)GL30.glFramebufferTexture2D(GL30.GL_READ_FRAMEBUFFER,GL30.GL_DEPTH_ATTACHMENT,GL11.GL_TEXTURE_2D,((GlTexture)target.getDepthTexture()).glId(),0);
            if(GL30.glCheckFramebufferStatus(GL30.GL_READ_FRAMEBUFFER)!=GL30.GL_FRAMEBUFFER_COMPLETE)throw new IllegalStateException("incomplete read FBO");
            GL11.glReadBuffer(GL30.GL_COLOR_ATTACHMENT0);GL15.glBindBuffer(GL21.GL_PIXEL_PACK_BUFFER,0);
            GL11.glPixelStorei(GL11.GL_PACK_ALIGNMENT,1);GL11.glPixelStorei(GL11.GL_PACK_ROW_LENGTH,0);GL11.glPixelStorei(GL11.GL_PACK_SKIP_ROWS,0);GL11.glPixelStorei(GL11.GL_PACK_SKIP_PIXELS,0);GL11.glPixelStorei(GL11.GL_PACK_SWAP_BYTES,0);
            GL11.glReadPixels(0,0,target.width,target.height,GL11.GL_RGBA,GL11.GL_UNSIGNED_BYTE,rgba);
            if(withDepth)GL11.glReadPixels(0,0,target.width,target.height,GL11.GL_DEPTH_COMPONENT,GL11.GL_FLOAT,depth);
        }finally{
            GL15.glBindBuffer(GL21.GL_PIXEL_PACK_BUFFER,oldPack);GL11.glPixelStorei(GL11.GL_PACK_ALIGNMENT,align);GL11.glPixelStorei(GL11.GL_PACK_ROW_LENGTH,row);GL11.glPixelStorei(GL11.GL_PACK_SKIP_ROWS,skipRows);GL11.glPixelStorei(GL11.GL_PACK_SKIP_PIXELS,skipPixels);GL11.glPixelStorei(GL11.GL_PACK_SWAP_BYTES,swap);
            GL30.glBindFramebuffer(GL30.GL_READ_FRAMEBUFFER,oldFbo);GL30.glDeleteFramebuffers(fbo);
        }
    }
    private void releaseBuffers(){if(color!=null)MemoryUtil.memFree(color);if(depth!=null)MemoryUtil.memFree(depth);if(hud!=null)MemoryUtil.memFree(hud);color=depth=hud=null;width=height=0;}
    @Override public void close(){try{if(publisher!=null)publisher.close();}catch(java.io.IOException e){throw new java.io.UncheckedIOException(e);}finally{publisher=null;session=null;releaseBuffers();var bridge=BridgeMod.server;if(bridge!=null)bridge.invalidateStream();}}
}
