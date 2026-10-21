package dev.jay.dstmc.protocol;

import java.io.*;
import java.lang.invoke.*;
import java.nio.*;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.util.UUID;
import static dev.jay.dstmc.protocol.BridgeTypes.*;

/** v2 mapped writer; one producer, three slots. See protocol/frame-v2.md. */
public final class FrameLayout implements AutoCloseable {
    public static final int HEADER_BYTES=4096, SLOT_HEADER_BYTES=512, SLOT_COUNT=3;
    public static final int MAX_WIDTH=1920, MAX_HEIGHT=1080;
    public static final long WRITER_LEASE=-1L;
    private static final VarHandle U64=MethodHandles.byteBufferViewVarHandle(long[].class,ByteOrder.LITTLE_ENDIAN);
    private final FileChannel channel;
    private final MappedByteBuffer map;
    private final int capacityWidth,capacityHeight,stride;
    private boolean closed;
    private FrameKey session;
    private long sequence;
    private int nextSlot;
    private FrameLayout(FileChannel channel,MappedByteBuffer map,int w,int h,int stride) {
        this.channel=channel; this.map=map; capacityWidth=w;capacityHeight=h;this.stride=stride;
    }
    public static FrameLayout create(Path path,int width,int height) throws IOException {
        int layer=layerBytes(width,height), stride=(SLOT_HEADER_BYTES+3*layer+63)&~63;
        long length=HEADER_BYTES+(long)SLOT_COUNT*stride;
        var channel=FileChannel.open(path,StandardOpenOption.CREATE_NEW,StandardOpenOption.READ,StandardOpenOption.WRITE);
        try {
            channel.position(length-1);channel.write(ByteBuffer.wrap(new byte[1]));
            var map=channel.map(FileChannel.MapMode.READ_WRITE,0,length);map.order(ByteOrder.LITTLE_ENDIAN);
            map.put(new byte[]{'D','S','T','M','C','F','2',0});
            map.putInt(8,2);map.putInt(12,HEADER_BYTES);map.putInt(16,SLOT_COUNT);map.putInt(20,SLOT_HEADER_BYTES);
            map.putInt(24,width);map.putInt(28,height);map.putLong(32,stride);map.putLong(40,length);map.force();
            return new FrameLayout(channel,map,width,height,stride);
        } catch(Throwable error) { channel.close();Files.deleteIfExists(path);throw error; }
    }
    public static int layerBytes(int width,int height) {
        if(width<=0 || height<=0 || width>MAX_WIDTH || height>MAX_HEIGHT) throw new IllegalArgumentException("invalid physical frame size");
        return Math.multiplyExact(Math.multiplyExact(width,height),4);
    }
    /** Buffers must have exactly one layer remaining. Returns false only when all slots are leased. */
    public synchronized boolean publish(FrameKey key,WorldTransform transform,Pose pose,int width,int height,ByteBuffer color,ByteBuffer depth,ByteBuffer hud) {
        if(closed) throw new IllegalStateException("closed frame writer");
        int bytes=layerBytes(width,height);
        if(width>capacityWidth || height>capacityHeight) throw new IllegalArgumentException("resolution exceeds mapping capacity; rebuild mapping");
        if(pose.space()!=Space.MC) throw new IllegalArgumentException("shared frame pose must use MC space");
        if(color.remaining()!=bytes || depth.remaining()!=bytes || hud.remaining()!=bytes) throw new IllegalArgumentException("layer length mismatch");
        if(session!=null && (!session.pair().equals(key.pair()) || !session.epoch().equals(key.epoch()))) throw new IllegalArgumentException("new handshake requires a new mapping");
        if(session!=null && Long.compareUnsigned(key.id(),session.id())<=0) throw new IllegalArgumentException("frame id must increase within epoch");
        var pair=pairHash(key.pair());
        for(int attempt=0;attempt<SLOT_COUNT;attempt++) {
            int slot=(nextSlot+attempt)%SLOT_COUNT, base=HEADER_BYTES+slot*stride;
            if(!(boolean)U64.compareAndSet(map,base+8,0L,WRITER_LEASE)) continue;
            try {
                long seq=sequence+2;
                U64.setVolatile(map,base,seq-1); // Odd before any mutable payload/metadata.
                var b=map.duplicate().order(ByteOrder.LITTLE_ENDIAN);b.position(base+16);b.put(pair);putUuid(b,key.epoch());b.putLong(key.id());
                b.putInt(width).putInt(height).putInt(1).putInt(2).putInt(1).putInt(0);
                b.putLong(512).putLong(512L+bytes).putLong(512L+2L*bytes).putLong(bytes);
                putVec(b,transform.dstOrigin());putVec(b,transform.mcOrigin());for(double axis:transform.axes())b.putDouble(axis);
                putVec(b,pose.position());putVec(b,pose.forward());putVec(b,pose.up());
                for(float v:pose.view())b.putFloat(v);for(float v:pose.projection())b.putFloat(v);
                b.position(base+512);b.put(color.duplicate());b.put(depth.duplicate());b.put(hud.duplicate());
                U64.setRelease(map,base,seq);sequence=seq;session=key;nextSlot=(slot+1)%SLOT_COUNT;
                return true;
            } finally { U64.setRelease(map,base+8,0L); }
        }
        return false;
    }
    private static void putVec(ByteBuffer b,Vec3 v) { b.putDouble(v.x()).putDouble(v.y()).putDouble(v.z()); }
    private static void putUuid(ByteBuffer b,UUID id) {
        // RFC 4122 bytes (network order), independent of numeric field endianness.
        long hi=id.getMostSignificantBits(),lo=id.getLeastSignificantBits();
        for(int i=7;i>=0;i--)b.put((byte)(hi>>>(8*i)));for(int i=7;i>=0;i--)b.put((byte)(lo>>>(8*i)));
    }
    @Override public synchronized void close() throws IOException { if(!closed) { closed=true;channel.close(); } }
}
