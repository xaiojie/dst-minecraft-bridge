package dev.jay.dstmc.client;

import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.file.*;
import java.util.*;
import dev.jay.dstmc.protocol.*;
import static dev.jay.dstmc.protocol.BridgeTypes.*;

/** Render-thread producer. Only complete, same-generation world + HUD readbacks may commit. */
public final class FramePublisher implements AutoCloseable {
    public static final long MAX_EXACT_HTTP_INTEGER=9007199254740991L;
    private final Path directory;
    private final PairKey pair;
    private final UUID epoch;
    private final WorldTransform transform;
    private FrameLayout layout;
    private Path path;
    private long generation, id;
    private int width,height;
    private Pose pose;
    private ByteBuffer color,depth,hud;
    private FrameKey latest;
    public FramePublisher(Path directory,PairKey pair,UUID epoch,WorldTransform transform) throws IOException {
        this.directory=directory;this.pair=pair;this.epoch=epoch;this.transform=transform;Files.createDirectories(directory);
    }
    public long generation(){return generation;}
    public Path path(){return path;}
    public FrameKey latest(){return latest;}
    public int width(){return width;}
    public int height(){return height;}
    /** New file even when old readers still hold leases. Old files remain valid for those readers. */
    public void resize(int w,int h) throws IOException {
        FrameLayout.layerBytes(w,h);
        clearPending(); latest=null;
        if(layout!=null)layout.close();
        path=directory.resolve("frame-"+epoch+"-"+(++generation)+"-"+UUID.randomUUID()+".bin");
        layout=FrameLayout.create(path,w,h);width=w;height=h;
    }
    public void world(long g,Pose pose,ByteBuffer color,ByteBuffer depth) {
        if(g!=generation || layout==null)return;
        clearPending();
        this.pose=Objects.requireNonNull(pose);this.color=snapshot(color);this.depth=snapshot(depth);
    }
    public void hud(long g,ByteBuffer hud) {if(g==generation && pose!=null)this.hud=snapshot(hud);}
    private ByteBuffer snapshot(ByteBuffer bytes) {
        if(bytes.remaining()!=FrameLayout.layerBytes(width,height))throw new IllegalArgumentException("incomplete layer");
        var copy=ByteBuffer.allocate(bytes.remaining());copy.put(bytes.duplicate()).flip();return copy;
    }
    public Optional<FrameKey> publishCompleted() {
        if(pose==null || color==null || depth==null || hud==null)return Optional.empty();
        if(id>=MAX_EXACT_HTTP_INTEGER)throw new IllegalStateException("HTTP_UINT64_NOT_EXACT");
        FrameKey key=new FrameKey(pair,epoch,id+1);
        boolean committed=layout.publish(key,transform,pose,width,height,color,depth,hud);
        clearPending();
        if(!committed)return Optional.empty();
        id++;latest=key;return Optional.of(key);
    }
    public void discardPending(){clearPending();}
    private void clearPending(){pose=null;color=null;depth=null;hud=null;}
    /** Operate on RGBA byte channels; independent of host integer endianness. */
    public static void premultiplyRgba(ByteBuffer bytes) {
        for(int i=bytes.position();i<bytes.limit();i+=4){int a=bytes.get(i+3)&255;for(int c=0;c<3;c++)bytes.put(i+c,(byte)(((bytes.get(i+c)&255)*a+127)/255));}
    }
    @Override public void close() throws IOException {clearPending();latest=null;if(layout!=null){layout.close();layout=null;}generation++;}
}
