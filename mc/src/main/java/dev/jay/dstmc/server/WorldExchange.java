package dev.jay.dstmc.server;

import java.io.*;
import java.nio.channels.FileChannel;
import java.nio.file.*;
import java.util.*;
import dev.jay.dstmc.protocol.*;
import static dev.jay.dstmc.protocol.BridgeTypes.*;

/** One persistent binding per copied save. All calls are made on the server thread. */
public final class WorldExchange {
    public record HandshakeResult(PairKey pair,UUID epoch,WorldTransform transform,String reason) {}
    private final Path directory;
    private final UUID mcWorld;
    private PairKey bound;
    private WorldTransform transform;
    private HandshakeResult active;
    public WorldExchange(Path save) {
        directory=save.resolve("dst-mc-bridge");
        try {
            Files.createDirectories(directory);
            Path id=directory.resolve("world.uuid");
            if(!Files.exists(id))writeAtomic(id,UUID.randomUUID().toString().getBytes(java.nio.charset.StandardCharsets.UTF_8));
            mcWorld=UUID.fromString(Files.readString(id).trim());
            Path binding=directory.resolve("binding.bin");
            if(Files.exists(binding))try(var in=new DataInputStream(Files.newInputStream(binding))){
                int version=in.readInt();
                if(version!=0x444D4232 && version!=0x444D4233)throw new IOException("invalid binding version");
                bound=new PairKey(UUID.fromString(in.readUTF()),in.readUTF(),mcWorld,"dst_mc_bridge:stage","ground");
                Vec3 dst=new Vec3(in.readDouble(),in.readDouble(),in.readDouble());
                Vec3 mc=version==0x444D4232?new Vec3(0,64,0):new Vec3(in.readDouble(),in.readDouble(),in.readDouble());
                var mode=version==0x444D4232?WorldTransform.AxisMode.IDENTITY:WorldTransform.AxisMode.valueOf(in.readUTF());
                if(!mc.equals(new Vec3(0,64,0)))throw new IOException("invalid bound MC origin");
                transform=new WorldTransform(dst,mc,mode);
                if(in.read()!=-1)throw new IOException("trailing binding data");
            }
        } catch(IOException e){throw new UncheckedIOException(e);}
    }
    public UUID mcWorld(){return mcWorld;}
    /** A launch property cannot turn an arbitrary manually selected save into a fixture. */
    public static boolean frameFixture(Path save, boolean requested){
        if(requested && !save.toAbsolutePath().normalize().getFileName().toString().equals("DST-MC-Frame-Fixture"))
            throw new IllegalArgumentException("FIXTURE_SAVE_MISMATCH");
        return requested;
    }
    public HandshakeResult active(){return active;}
    public HandshakeResult handshake(UUID dstWorld,String shard,Vec3 dstOrigin){return handshake(new PairKey(dstWorld,shard,mcWorld,"dst_mc_bridge:stage","ground"),UUID.randomUUID(),dstOrigin,new Vec3(0,64,0));}
    public HandshakeResult handshake(PairKey pair,UUID epoch,Vec3 dstOrigin,Vec3 mcOrigin) {
        if(!pair.mc_world().equals(mcWorld)||!pair.mc_dimension().equals("dst_mc_bridge:stage")||!pair.region().equals("ground")||!mcOrigin.equals(new Vec3(0,64,0))||(bound!=null&&!bound.equals(pair)))
            return new HandshakeResult(null,null,null,"WORLD_MISMATCH");
        if(bound!=null && transform.axisMode()!=WorldTransform.AxisMode.REFLECT_X)
            return new HandshakeResult(null,null,null,"TRANSFORM_MISMATCH");
        if(bound==null){
            try {
                var bytes=new ByteArrayOutputStream();try(var out=new DataOutputStream(bytes)){out.writeInt(0x444D4233);out.writeUTF(pair.dst_world().toString());out.writeUTF(pair.dst_shard());out.writeDouble(dstOrigin.x());out.writeDouble(dstOrigin.y());out.writeDouble(dstOrigin.z());out.writeDouble(mcOrigin.x());out.writeDouble(mcOrigin.y());out.writeDouble(mcOrigin.z());out.writeUTF(WorldTransform.AxisMode.REFLECT_X.name());}
                writeAtomic(directory.resolve("binding.bin"),bytes.toByteArray());
                bound=pair;transform=new WorldTransform(dstOrigin,mcOrigin,WorldTransform.AxisMode.REFLECT_X);
            }catch(IOException e){throw new UncheckedIOException(e);}
        }
        active=new HandshakeResult(bound,epoch,transform,"");return active;
    }
    private static void writeAtomic(Path path,byte[] data)throws IOException{
        Path tmp=Files.createTempFile(path.getParent(),".pending-",".tmp");
        try{try(var ch=FileChannel.open(tmp,StandardOpenOption.WRITE)){var b=java.nio.ByteBuffer.wrap(data);while(b.hasRemaining())ch.write(b);ch.force(true);}Files.move(tmp,path,StandardCopyOption.ATOMIC_MOVE);try(var dir=FileChannel.open(path.getParent(),StandardOpenOption.READ)){dir.force(true);}}finally{Files.deleteIfExists(tmp);}
    }
}
